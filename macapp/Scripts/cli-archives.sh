#!/bin/bash
#
# Builds, or checks, the standalone `workroom` archives a release or the Nightly publishes (ADR
# 0078, #681): the Rust binary, which is both the CLI and the daemon, for each platform it ships
# on, under the names goreleaser gave the Go CLI's archives, so `install.sh` and an older Go CLI's
# `workroom update` reach it.
#
#   cli-archives.sh build <out-dir>   build the four binaries, sign, notarize, archive and check
#   cli-archives.sh check <dir>       check a directory of archives is exactly what ships
#
# Env (both modes):
#   VERSION                   the version stamped into the binary, with or without a leading v
#                             (v2.1.0, 2.1.0-nightly.912). Never `dev`: `update` refuses a dev build.
#   WORKROOM_RELEASE_CHANNEL  `nightly` for the Nightly, else empty. It is baked into the binary
#                             (`workroom-nightly update` tracks it) and names the archives.
# Env (build):
#   CODESIGN_IDENTITY         the identity the darwin binaries are signed with; default `-` (ad
#                             hoc). Any other is signed with the hardened runtime and a secure
#                             timestamp, then notarized (notarize.sh's auth: NOTARY_KEY_PATH,
#                             NOTARY_KEY_ID, NOTARY_ISSUER_ID, or NOTARY_PROFILE).
#   CARGO_TARGET_DIR          cargo's, honoured as cargo honours it.
#
# Each archive is `workroom_<version>_<os>_<arch>.tar.gz` (the Nightly's
# `workroom_nightly_<os>_<arch>.tar.gz`), holding `workroom` and the binary's
# THIRD-PARTY-NOTICES.txt at its root, beside `checksums.txt`, whose lines are `<sha256>  <name>`.
# darwin is one thin Mach-O per arch, linux a static musl ELF per arch. There is no Windows build
# (ADR 0078) and no Go binary: `check` refuses either.
set -euo pipefail

MACAPP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$MACAPP_DIR/.." && pwd)"
NOTICES="$REPO/vcs/crates/workroomd/THIRD-PARTY-NOTICES.txt"

# What ships, as `<os>_<arch>` in goreleaser's names (Go's GOOS and GOARCH) and the Rust target
# each is built for. third-party/about.toml's targets are these four (#714), and so are the
# features: scripts/third_party_notices.py's FEATURES, which build-daemon.sh builds the app's
# binary with. cli-archives_test.sh checks both agree.
SHIPPED_PLATFORMS="darwin_arm64 darwin_amd64 linux_arm64 linux_amd64"
FEATURES="terminal-state"

# CLI_ARCHIVES_PLATFORMS narrows both modes to some of them, for cli-archives_test.sh, which builds
# only this Mac's to keep CI's script tests short. publish-assets.sh's check never takes it, so no
# release publishes fewer, and test-invariants_test.sh pins that no workflow sets it.
PLATFORMS="${CLI_ARCHIVES_PLATFORMS:-$SHIPPED_PLATFORMS}"

rust_target() {
  case "$1" in
    darwin_arm64) echo aarch64-apple-darwin ;;
    darwin_amd64) echo x86_64-apple-darwin ;;
    linux_arm64) echo aarch64-unknown-linux-musl ;;
    linux_amd64) echo x86_64-unknown-linux-musl ;;
  esac
}

# check_file_type <platform> <binary>: it is one thin Mach-O executable (not a universal one), or
# a static ELF, for that platform's arch. A dynamically linked ELF would fail on a host without
# glibc.
#
# The Mach-O header is read, not `file`'s description: `publish` runs this on Linux, whose `file`
# words a Mach-O differently from macOS's. Its first 16 bytes, little-endian: the 64-bit magic
# (feedfacf), the CPU type (arm64 0100000c, x86_64 01000007), the subtype, and the file type
# (MH_EXECUTE, 2). A universal binary starts with cafebabe instead.
check_file_type() {
  local desc header
  case "$1" in
    darwin_*)
      header="$(od -A n -t x1 -N 16 "$2" | tr -d ' \n')"
      case "$1:$header" in
        darwin_arm64:cffaedfe0c000001????????02000000) return 0 ;;
        darwin_amd64:cffaedfe07000001????????02000000) return 0 ;;
      esac
      die "$1: workroom is '$(file -b "$2")' (header $header), not a thin Mach-O executable for $1."
      ;;
  esac
  desc="$(file -b "$2")"
  case "$1:$desc" in
    "linux_arm64:ELF 64-bit LSB "*", ARM aarch64,"*"statically linked"*) ;;
    "linux_amd64:ELF 64-bit LSB "*", x86-64,"*"statically linked"*) ;;
    *) die "$1: workroom is '$desc', not a static ELF for $1." ;;
  esac
}

die() {
  echo "error: $*" >&2
  exit 1
}

# A list of lines as one line, for a message.
words() {
  printf '%s\n' "$1" | tr '\n' ' ' | sed 's/ $//'
}

usage() {
  die "usage: cli-archives.sh build <out-dir> | check <dir> (with VERSION, and WORKROOM_RELEASE_CHANNEL for the Nightly)"
}

[ "$#" -eq 2 ] || usage
MODE="$1"
DIR="$2"

for platform in $PLATFORMS; do
  case " $SHIPPED_PLATFORMS " in
    *" $platform "*) ;;
    *) die "'$platform' is not a platform workroom ships on ($SHIPPED_PLATFORMS)." ;;
  esac
done
[ -n "$(echo "$PLATFORMS" | tr -d ' ')" ] || die "CLI_ARCHIVES_PLATFORMS names no platform."

VERSION="${VERSION:-}"
VERSION="${VERSION#v}"
CHANNEL="${WORKROOM_RELEASE_CHANNEL:-}"
case "$VERSION" in
  "" | dev) die "VERSION must be the release's version (got '${VERSION}'): a binary stamped dev cannot update itself." ;;
esac
case "$CHANNEL" in
  "") LABEL="$VERSION" ;;
  nightly) LABEL="nightly" ;;
  *) die "WORKROOM_RELEASE_CHANNEL must be nightly or empty (got '$CHANNEL')." ;;
esac

archive_name() {
  echo "workroom_${LABEL}_$1.tar.gz"
}

# Everything this run stages or unpacks goes under one directory it makes, and only that is
# removed when it ends.
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/cli-archives.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

# The <os>_<arch> of the machine running this, when it is one that ships.
host_platform() {
  local os arch
  case "$(uname -s)" in
    Darwin) os=darwin ;;
    Linux) os=linux ;;
    *) return 0 ;;
  esac
  case "$(uname -m)" in
    arm64 | aarch64) arch=arm64 ;;
    x86_64 | amd64) arch=amd64 ;;
    *) return 0 ;;
  esac
  echo "${os}_${arch}"
}

# set_runner <platform>: sets RUNNER to what runs that platform's binary on this machine (nothing
# for its own, `arch -x86_64` under Rosetta, qemu-user for the other Linux arch), and returns 1 for
# a platform of the other OS, which the other OS's check runs: `build` on macOS runs the darwin
# binaries, `publish` on Linux the linux ones, so every binary has run before anything publishes.
# A binary of this OS that cannot be run here is an error, not a skip.
set_runner() {
  local host candidate
  host="$(host_platform)"
  RUNNER=()
  case "$host:$1" in
    "$1:$1") return 0 ;;
    darwin_arm64:darwin_amd64)
      # Rosetta's absence shows as "Bad CPU type"; `arch` itself exists without it.
      RUNNER=(arch -x86_64)
      "${RUNNER[@]}" /bin/sh -c : 2>/dev/null \
        || die "darwin_amd64 cannot run here: install Rosetta (softwareupdate --install-rosetta --agree-to-license)."
      return 0
      ;;
    linux_amd64:linux_arm64 | linux_arm64:linux_amd64)
      for candidate in "qemu-${1#linux_}-static" "qemu-${1#linux_}"; do
        candidate="${candidate/arm64/aarch64}"
        candidate="${candidate/amd64/x86_64}"
        if command -v "$candidate" >/dev/null 2>&1; then
          RUNNER=("$candidate")
          return 0
        fi
      done
      die "$1 cannot run here: install qemu-user (apt-get install qemu-user)."
      ;;
  esac
  return 1
}

# check_binary <platform> <binary>: it is the Rust `workroom` for that platform and no Go CLI. One
# of this machine's OS is also run (check_runs).
check_binary() {
  local platform="$1" bin="$2"
  [ -f "$bin" ] && [ -x "$bin" ] || die "$platform: workroom is missing or not executable."
  check_file_type "$platform" "$bin"
  # A Go binary carries its build info behind this magic (Go's debug/buildinfo). No release ships
  # the Go CLI beside the Rust binary (ADR 0078), nor in its place.
  if LC_ALL=C grep -q -a -F 'Go buildinf:' "$bin"; then
    die "$platform: workroom is a Go binary; a release ships only the Rust workroom (ADR 0078)."
  fi
  # cli-archives_test.sh's own builds point `update` at a releases server on 127.0.0.1
  # (WORKROOM_RELEASES_API_FOR_TESTS); one of those must never ship.
  if LC_ALL=C grep -q -a -E 'http://127\.0\.0\.1:[0-9]+/repos/joelmoss/workroom/releases' "$bin"; then
    die "$platform: workroom's update reaches a test server on 127.0.0.1, not GitHub."
  fi
  # What only the Rust binary holds: the daemon's build identity line (#680) and the notices it
  # embeds (#714).
  if ! LC_ALL=C grep -q -a -F 'daemon-build ' "$bin" \
    || ! LC_ALL=C grep -q -a -F 'Third-party software notices' "$bin"; then
    die "$platform: workroom is not the Rust workroom (no daemon build identity or notices in it)."
  fi
  if set_runner "$platform"; then
    check_runs "$platform" "$bin"
  else
    echo "    $platform: checked; it runs in the $(echo "$platform" | cut -d_ -f1) check"
  fi
}

# json_field <json> <key>: the string value of a top-level key in `version --json`'s one-line
# envelope. `"version":` is not `"cli_version":`, whose key starts with `cli_`.
json_field() {
  printf '%s\n' "$1" | sed -n "s/.*\"$2\":\"\\([^\"]*\\)\".*/\\1/p"
}

# check_runs <platform> <binary>: it runs (through RUNNER), states its daemon build, and its
# `version --json` envelope is ok with exactly this VERSION and channel. A home of its own, so it
# reads no one's config.
check_runs() {
  local platform="$1" bin="$2" home protocol json want_channel version channel
  home="$SCRATCH/home-$platform"
  mkdir "$home"
  protocol="$(${RUNNER[@]+"${RUNNER[@]}"} "$bin" protocol 2>&1 || true)"
  json="$(HOME="$home" WORKROOM_CONFIG="$home/config.json" ${RUNNER[@]+"${RUNNER[@]}"} "$bin" version --json 2>&1 || true)"
  case "$protocol" in
    *"daemon-build "*) ;;
    *) die "$platform: workroom does not state a daemon build: 'protocol' printed '$protocol'." ;;
  esac
  want_channel="${CHANNEL:-stable}"
  version="$(json_field "$json" version)"
  channel="$(json_field "$json" channel)"
  case "$json" in *'"ok":true'*) ;; *) version="" ;; esac
  if [ "$version" != "$VERSION" ] || [ "$channel" != "$want_channel" ]; then
    die "$platform: 'workroom version --json' printed '$json', want version $VERSION on the $want_channel channel."
  fi
  echo "    $platform: runs${RUNNER[*]+ (${RUNNER[*]})}; version $version, $channel; $(printf '%s\n' "$protocol" | grep '^daemon-build ')"
}

# check <dir>: the directory holds exactly the four archives and checksums.txt, each archive holds
# exactly `workroom` and its notices, and every checksum matches.
check() {
  local dir="$1" want got platform name sum line unpacked
  [ -d "$dir" ] || die "$dir is not a directory."
  want="$(for platform in $PLATFORMS; do archive_name "$platform"; done; echo checksums.txt)"
  want="$(printf '%s\n' "$want" | LC_ALL=C sort)"
  got="$(cd "$dir" && find . -mindepth 1 -maxdepth 1 | sed 's|^\./||' | LC_ALL=C sort)"
  if [ "$got" != "$want" ]; then
    die "$dir holds the wrong files. Want:
$want
Got:
$got"
  fi
  # checksums.txt names each archive once, bare, as goreleaser wrote it: the updaters look the
  # archive's own name up in it.
  got="$(awk '{print $2}' "$dir/checksums.txt" | LC_ALL=C sort)"
  want="$(for platform in $PLATFORMS; do archive_name "$platform"; done | LC_ALL=C sort)"
  [ "$got" = "$want" ] || die "checksums.txt names '$(words "$got")', want '$(words "$want")'."
  unpacked="$SCRATCH/unpacked"
  mkdir "$unpacked"
  for platform in $PLATFORMS; do
    name="$(archive_name "$platform")"
    sum="$(sha256_of "$dir/$name")"
    line="$(grep -F "  $name" "$dir/checksums.txt")"
    [ "$line" = "$sum  $name" ] || die "checksums.txt has '$line' for $name, want '$sum  $name'."
    got="$(tar -tzf "$dir/$name" | LC_ALL=C sort)"
    want="$(printf 'THIRD-PARTY-NOTICES.txt\nworkroom\n')"
    [ "$got" = "$want" ] || die "$name holds '$(words "$got")', want 'THIRD-PARTY-NOTICES.txt workroom'."
    mkdir "$unpacked/$platform"
    tar -xzf "$dir/$name" -C "$unpacked/$platform"
    cmp -s "$unpacked/$platform/THIRD-PARTY-NOTICES.txt" "$NOTICES" \
      || die "$name's THIRD-PARTY-NOTICES.txt is not the binary's ($NOTICES)."
    check_binary "$platform" "$unpacked/$platform/workroom"
  done
  echo "==> $dir: the standalone archives for workroom $VERSION (${CHANNEL:-main}) check out"
}

# The pinned toolchain, Zig and cargo-zigbuild, as build-daemon.sh finds them for the app's
# binary: the notices describe that Rust's runtime (#714), and the daemon build hashes the compiler
# (#680), so the standalone binary is built by the same one.
setup_toolchain() {
  export PATH="/opt/homebrew/bin:/usr/local/bin:${HOME}/.cargo/bin:${HOME}/.local/bin:${PATH}"
  TOOLCHAIN="$(awk '$1 == "VCS_RUST" && $2 == ":=" {print $3}' "$REPO/mk/vcs.mk")"
  [ -n "$TOOLCHAIN" ] || die "cannot read VCS_RUST from mk/vcs.mk."
  command -v rustup >/dev/null 2>&1 || die "the standalone binaries need rustup (Homebrew rust cannot cross-compile)."
  local shipped
  shipped="$(rustup run "$TOOLCHAIN" rustc --version 2>/dev/null | awk '{print $2}' || true)"
  [ "$shipped" = "$TOOLCHAIN" ] \
    || die "the standalone binaries are built by Rust $TOOLCHAIN (mk/vcs.mk's VCS_RUST); it is ${shipped:-not installed}. Run 'rustup toolchain install $TOOLCHAIN'."
  local platform target
  for platform in $PLATFORMS; do
    target="$(rust_target "$platform")"
    rustup target list --installed --toolchain "$TOOLCHAIN" 2>/dev/null | grep -qx "$target" \
      || die "rustup target '$target' is not installed. Run 'rustup target add --toolchain $TOOLCHAIN $target'."
  done
  command -v cargo-zigbuild >/dev/null 2>&1 || die "the Linux binaries need cargo-zigbuild. Run 'cargo install cargo-zigbuild --locked'."
  # The toolchain's own bin first, so cargo-zigbuild's `cargo` is the pinned one, and mise's Zig
  # at libghostty-vt's pin when mise has one (build-daemon.sh does the same).
  TOOLCHAIN_BIN="$(dirname "$(rustup which --toolchain "$TOOLCHAIN" cargo)")"
  RUSTC="$(rustup which --toolchain "$TOOLCHAIN" rustc)"
  export RUSTC
  local zig_version zig_home zig_dir="" candidate
  zig_version="$(awk -F'"' '/^ZIG_VERSION=/{print $2}' "$REPO/vcs/scripts/build-ghostty-vt.sh")"
  if command -v mise >/dev/null 2>&1; then
    mise install "zig@${zig_version}" >/dev/null 2>&1 || true
    zig_home="$(mise where "zig@${zig_version}" 2>/dev/null || true)"
    for candidate in "$zig_home/bin" "$zig_home"; do
      if [ -n "$zig_home" ] && [ -x "$candidate/zig" ]; then
        zig_dir="$candidate"
        break
      fi
    done
  fi
  BUILD_PATH="$TOOLCHAIN_BIN:${zig_dir:+$zig_dir:}$PATH"
  [ "$(PATH="$BUILD_PATH" zig version 2>/dev/null)" = "$zig_version" ] \
    || die "the binaries need zig $zig_version. Install mise, or put zig $zig_version on PATH."
}

build() {
  local out="$1" stage platform target bin
  [ "$(uname -s)" = Darwin ] || die "build runs on macOS: the darwin binaries are signed with codesign."
  # The output directory is this run's alone: made here, never written over.
  mkdir "$out" || die "$out already exists; remove it or name another."
  out="$(cd "$out" && pwd)"
  setup_toolchain
  local cargo_dir="$REPO/vcs"
  local out_root="${CARGO_TARGET_DIR:-$cargo_dir/target}"
  stage="$SCRATCH/stage"
  mkdir "$stage"

  # Read by `option_env!` in the commands module (`workroom version`, `update`'s channel), as
  # build-daemon.sh stamps the app's binary.
  export WORKROOM_VERSION="$VERSION"
  export WORKROOM_RELEASE_CHANNEL="$CHANNEL"
  for platform in $PLATFORMS; do
    target="$(rust_target "$platform")"
    echo "==> Building workroom $VERSION (${CHANNEL:-main}) for $target"
    case "$platform" in
      darwin_*)
        (cd "$cargo_dir" && PATH="$BUILD_PATH" cargo build --release -p workroom \
          --features "$FEATURES" --target "$target")
        ;;
      linux_*)
        (cd "$cargo_dir" && PATH="$BUILD_PATH" cargo zigbuild --release -p workroom \
          --features "$FEATURES" --target "$target")
        ;;
    esac
    mkdir "$stage/$platform"
    bin="$stage/$platform/workroom"
    cp "$out_root/$target/release/workroom" "$bin"
    chmod 0755 "$bin"
    cp "$NOTICES" "$stage/$platform/THIRD-PARTY-NOTICES.txt"
    chmod 0644 "$stage/$platform/THIRD-PARTY-NOTICES.txt"
  done

  local identity="${CODESIGN_IDENTITY:--}"
  local darwin=""
  for platform in $PLATFORMS; do
    case "$platform" in darwin_*) darwin="$darwin $platform" ;; esac
  done
  for platform in $darwin; do
    bin="$stage/$platform/workroom"
    if [ "$identity" = "-" ]; then
      codesign --force --sign - "$bin"
    else
      echo "==> Signing $platform with $identity (hardened runtime + timestamp)"
      codesign --force --options runtime --timestamp --sign "$identity" "$bin"
      codesign --verify --strict --verbose=2 "$bin"
    fi
  done
  if [ "$identity" != "-" ] && [ -n "$darwin" ]; then
    # A bare Mach-O cannot be stapled, so Gatekeeper looks its ticket up online, the first time a
    # quarantined copy (one a browser downloaded) runs. curl sets no quarantine.
    echo "==> Notarizing the darwin binaries"
    # shellcheck source=notarize.sh
    . "$MACAPP_DIR/Scripts/notarize.sh"
    # One submission for both: copies under names of their own (the name is not in the signature).
    mkdir "$SCRATCH/notarize"
    for platform in $darwin; do
      cp -p "$stage/$platform/workroom" "$SCRATCH/notarize/workroom-$platform"
    done
    ditto -c -k --keepParent "$SCRATCH/notarize" "$SCRATCH/darwin.zip"
    notarize "$SCRATCH/darwin.zip"
  fi

  for platform in $PLATFORMS; do
    # No AppleDouble files or extended attributes, and root's ownership, as goreleaser wrote them.
    COPYFILE_DISABLE=1 tar --no-xattrs --uid 0 --gid 0 --uname root --gname root \
      -czf "$out/$(archive_name "$platform")" -C "$stage/$platform" workroom THIRD-PARTY-NOTICES.txt
  done
  (cd "$out" && for platform in $PLATFORMS; do
    name="$(archive_name "$platform")"
    echo "$(sha256_of "$name")  $name"
  done) >"$stage/checksums.txt"
  mv "$stage/checksums.txt" "$out/checksums.txt"
  check "$out"
}

case "$MODE" in
  build) build "$DIR" ;;
  check) check "$DIR" ;;
  *) usage ;;
esac
