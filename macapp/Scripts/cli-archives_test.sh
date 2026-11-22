#!/bin/sh
#
# Test for cli-archives.sh, the standalone archives a release and the Nightly publish (ADR 0078,
# #681), and for the swap they make: an old Go CLI's `workroom update` installs the Rust binary
# from them. Run: sh macapp/Scripts/cli-archives_test.sh   (exits non-zero on any mismatch).
#
# 1. What the archives ship agrees with the notices: about.toml's targets are the four the script
#    builds, and its features are the notices' and the app's (#714).
# 2. The script refuses a version an updated binary could not update from (dev, or none), and a
#    platform workroom does not ship on.
# 3. It builds both channels' archives as the workflows do (ad hoc signed here): the names, each
#    archive's two files, checksums.txt, and a binary stamped with the version and channel. Only
#    this Mac's platform by default (CLI_ARCHIVES_PLATFORMS), since each build of the four costs
#    CI's script tests minutes; CLI_ARCHIVES_TEST_PLATFORMS="darwin_arm64 darwin_amd64
#    linux_arm64 linux_amd64" builds all four, as the release does.
# 4. `check` refuses a Go binary, a Windows archive, a bad checksum and an unstamped binary.
# 5. A Go CLI built from this checkout, pointed at a releases server on 127.0.0.1 that serves the
#    archives from 3 under GitHub's API shape, updates itself into the Rust binary with
#    `workroom update`, as `workroom` (stable) and as `workroom-nightly`, in a throwaway prefix
#    and home. It is the Go updater as it ships, with only its releases URL replaced at build time
#    (`go build -overlay`), so the checksum, extraction and swap are the ones users run. Needs go
#    and python3, and skips without them: no release or Nightly runner has Go since the swap.
#
# The builds share build-daemon_test.sh's cargo target directory, so only the workroom crate is
# rebuilt.
set -u

# What cli-archives.sh and notarize.sh read, which a release or Nightly job exports for its own
# build (VERSION=3.2.0-nightly.2807 failed publish-assets_test.sh's cases): each case sets its own.
unset VERSION WORKROOM_RELEASE_CHANNEL CLI_ARCHIVES_PLATFORMS CODESIGN_IDENTITY \
  NOTARY_KEY_PATH NOTARY_KEY_ID NOTARY_ISSUER_ID NOTARY_PROFILE

DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$DIR/../.." && pwd)"
SCRIPT="${CLI_ARCHIVES:-$DIR/cli-archives.sh}"
fails=0

fail() {
  echo "FAIL: $1"
  fails=$((fails + 1))
}

# --- 1. the archives' targets and features are the notices' ---------------------------------
script_targets="$(sed -n '/^rust_target()/,/^}/s/.*) echo \([^ ]*\) ;;/\1/p' "$SCRIPT" | LC_ALL=C sort)"
about_targets="$(awk '/^targets = \[/{f=1;next} f&&/^\]/{f=0} f{gsub(/[",[:space:]]/,""); if ($0 != "") print}' \
  "$REPO/third-party/about.toml" | LC_ALL=C sort)"
[ -n "$script_targets" ] && [ "$script_targets" = "$about_targets" ] \
  || fail "cli-archives.sh builds '$(echo "$script_targets" | tr '\n' ' ')', but third-party/about.toml's targets are '$(echo "$about_targets" | tr '\n' ' ')'"
script_features="$(sed -n 's/^FEATURES="\(.*\)"$/\1/p' "$SCRIPT")"
notices_features="$(sed -n 's/^FEATURES = "\(.*\)"$/\1/p' "$REPO/scripts/third_party_notices.py")"
app_features="$(sed -n 's/^DAEMON_FEATURES="\(.*\)"$/\1/p' "$DIR/build-daemon.sh")"
[ -n "$script_features" ] && [ "$script_features" = "$notices_features" ] && [ "$script_features" = "$app_features" ] \
  || fail "features differ: cli-archives.sh '$script_features', the notices '$notices_features', build-daemon.sh '$app_features'"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/cli-archives_test.XXXXXX")"
SERVER_PID=""
cleanup() {
  if [ -n "$SERVER_PID" ]; then kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# --- 2. refusals before any build -------------------------------------------------------------
expect_refused() {
  label="$1"
  want="$2"
  shift 2
  out="$(env "$@" bash "$SCRIPT" build "$WORK/refused" 2>&1)"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    fail "$label: build exited 0"
  else
    case "$out" in *"$want"*) ;; *) fail "$label: the error does not say '$want': $out" ;; esac
  fi
  if [ -e "$WORK/refused" ]; then
    fail "$label: build wrote $WORK/refused"
    rm -rf "$WORK/refused"
  fi
}
expect_refused "no VERSION" "VERSION must be" VERSION=
expect_refused "VERSION=dev" "cannot update itself" VERSION=dev
expect_refused "another channel" "nightly or empty" VERSION=1.0.0 WORKROOM_RELEASE_CHANNEL=beta
expect_refused "a Windows build" "not a platform workroom ships on" VERSION=1.0.0 \
  CLI_ARCHIVES_PLATFORMS=windows_amd64
mkdir "$WORK/taken"
out="$(VERSION=1.0.0 bash "$SCRIPT" build "$WORK/taken" 2>&1)" \
  && fail "an existing output directory: build exited 0"
case "${out:-}" in *"already exists"*) ;; *) fail "an existing output directory: '$out'" ;; esac

# --- 3. both channels' archives, built as the workflows build them ----------------------------
case "$(uname -m)" in
  arm64) HOST=darwin_arm64 ;;
  *) HOST=darwin_amd64 ;;
esac
PLATFORMS="${CLI_ARCHIVES_TEST_PLATFORMS:-$HOST}"
export CLI_ARCHIVES_PLATFORMS="$PLATFORMS"
TOOLCHAIN="$(awk '$1 == "VCS_RUST" && $2 == ":=" {print $3}' "$REPO/mk/vcs.mk")"
skip_build=""
[ "$(uname -s)" = Darwin ] || skip_build="not macOS"
command -v cargo-zigbuild >/dev/null 2>&1 || skip_build="cargo-zigbuild not installed"
command -v rustup >/dev/null 2>&1 || skip_build="rustup not installed"
for p in $PLATFORMS; do
  target="$(sed -n "/^rust_target()/,/^}/s/^ *$p) echo \([^ ]*\) ;;/\1/p" "$SCRIPT")"
  rustup target list --installed --toolchain "$TOOLCHAIN" 2>/dev/null | grep -qx "$target" \
    || skip_build="rustup target '$target' not installed for $TOOLCHAIN"
done
if [ -n "$skip_build" ]; then
  if [ "$fails" -ne 0 ]; then echo "cli-archives_test: $fails failure(s)"; exit 1; fi
  echo "cli-archives_test: SKIP the builds and the update ($skip_build)"
  exit 0
fi
export CARGO_TARGET_DIR="${BUILD_DAEMON_TEST_TARGET_DIR:-$REPO/vcs/target/build-daemon-test}"

# build <name> <VERSION> <channel>: sets RC; the archives land in $WORK/<name>.
build() {
  VERSION="$2" WORKROOM_RELEASE_CHANNEL="$3" bash "$SCRIPT" build "$WORK/$1" >"$WORK/$1.log" 2>&1
  RC=$?
  if [ "$RC" -ne 0 ]; then
    fail "build $1 ($2, ${3:-main}) exited $RC. Its log's end:"
    tail -20 "$WORK/$1.log" | sed 's/^/    /'
  fi
}

# expect_archives <name> <label>: the files, each archive's entries, modes and owner.
expect_archives() {
  want="$(for p in $PLATFORMS; do echo "workroom_$2_$p.tar.gz"; done; echo checksums.txt)"
  got="$(cd "$WORK/$1" && find . -mindepth 1 | sed 's|^\./||' | LC_ALL=C sort)"
  [ "$got" = "$(printf '%s\n' "$want" | LC_ALL=C sort)" ] \
    || fail "$1: the archives are '$(echo "$got" | tr '\n' ' ')'"
  for p in $PLATFORMS; do
    archive="$WORK/$1/workroom_$2_$p.tar.gz"
    listing="$(tar -tvzf "$archive" 2>/dev/null)"
    # install.sh copies `workroom` from the archive's root, and the updaters find it by name.
    printf '%s\n' "$listing" | grep -Eq '^-rwxr-xr-x +[0-9]* *root +root .* workroom$' \
      || fail "$1/$p: no executable, root-owned workroom at the archive's root: $listing"
    printf '%s\n' "$listing" | grep -Eq '^-rw-r--r-- +[0-9]* *root +root .* THIRD-PARTY-NOTICES.txt$' \
      || fail "$1/$p: no THIRD-PARTY-NOTICES.txt at the archive's root: $listing"
    [ "$(printf '%s\n' "$listing" | wc -l | tr -d ' ')" -eq 2 ] \
      || fail "$1/$p: the archive holds more than workroom and its notices: $listing"
    line="$(grep -F "workroom_$2_$p.tar.gz" "$WORK/$1/checksums.txt")"
    [ "$line" = "$(shasum -a 256 "$archive" | awk '{print $1}')  workroom_$2_$p.tar.gz" ] \
      || fail "$1/$p: checksums.txt says '$line'"
  done
}

build stable v9.9.9 ""
[ "$RC" -eq 0 ] && expect_archives stable 9.9.9
build nightly 9.9.9-nightly.7 nightly
[ "$RC" -eq 0 ] && expect_archives nightly nightly
# The script's own check ran the host's binary: stamped, on its channel, stating its daemon build.
grep -q "$HOST: runs; version 9.9.9, stable; daemon-build " "$WORK/stable.log" 2>/dev/null \
  || fail "stable: the build did not run its $HOST binary"
if [ "$fails" -ne 0 ]; then
  echo "cli-archives_test: $fails failure(s)"
  exit 1
fi

# --- 4. check refuses what must not ship ----------------------------------------------------
# mutant <name>: a copy of the stable archives to break.
mutant() {
  cp -R "$WORK/stable" "$WORK/$1"
}
resum() {
  (cd "$WORK/$1" && for f in workroom_*.tar.gz; do echo "$(shasum -a 256 "$f" | awk '{print $1}')  $f"; done) \
    >"$WORK/$1.sums"
  mv "$WORK/$1.sums" "$WORK/$1/checksums.txt"
}
# expect_check_fails <name> <error substring> [VERSION]
expect_check_fails() {
  out="$(VERSION="${3:-9.9.9}" WORKROOM_RELEASE_CHANNEL="" bash "$SCRIPT" check "$WORK/$1" 2>&1)" \
    && { fail "$1: check passed"; return; }
  case "$out" in *"$2"*) ;; *) fail "$1: check failed without saying '$2': $out" ;; esac
}
out="$(VERSION=9.9.9 bash "$SCRIPT" check "$WORK/stable" 2>&1)" || fail "check of the built archives: $out"

mutant windows
echo zip >"$WORK/windows/workroom_9.9.9_windows_amd64.zip"
expect_check_fails windows "holds the wrong files"

mutant tampered
printf 'x' >>"$WORK/tampered/workroom_9.9.9_$HOST.tar.gz"
expect_check_fails tampered "checksums.txt has"

# A binary stamped with another version than its archives are named for.
mkdir "$WORK/unstamped"
for p in $PLATFORMS; do
  cp "$WORK/stable/workroom_9.9.9_$p.tar.gz" "$WORK/unstamped/workroom_9.9.8_$p.tar.gz"
done
resum unstamped
expect_check_fails unstamped "want version 9.9.8 on the stable channel" 9.9.8
# The nightly's binary is baked to the nightly channel: under the main binary's names, it is refused.
mkdir "$WORK/baked"
for p in $PLATFORMS; do
  cp "$WORK/nightly/workroom_nightly_$p.tar.gz" "$WORK/baked/workroom_9.9.9-nightly.7_$p.tar.gz"
done
resum baked
expect_check_fails baked "want version 9.9.9-nightly.7 on the stable channel" 9.9.9-nightly.7

if command -v go >/dev/null 2>&1; then
  mutant go-binary
  mkdir "$WORK/gobin" "$WORK/gobin/pkg"
  printf 'module gobin\n\ngo 1.21\n' >"$WORK/gobin/pkg/go.mod"
  printf 'package main\n\nfunc main() { println("daemon-build Third-party software notices 9.9.9") }\n' \
    >"$WORK/gobin/pkg/main.go"
  goarch="${HOST#darwin_}"
  if (cd "$WORK/gobin/pkg" && CGO_ENABLED=0 GOOS=darwin GOARCH="$goarch" GOFLAGS=-mod=mod go build -o "$WORK/gobin/workroom" .) >/dev/null 2>&1; then
    cp "$REPO/vcs/crates/workroomd/THIRD-PARTY-NOTICES.txt" "$WORK/gobin/"
    chmod 0644 "$WORK/gobin/THIRD-PARTY-NOTICES.txt"
    COPYFILE_DISABLE=1 tar -czf "$WORK/go-binary/workroom_9.9.9_$HOST.tar.gz" -C "$WORK/gobin" \
      workroom THIRD-PARTY-NOTICES.txt
    resum go-binary
    expect_check_fails go-binary "is a Go binary"
  else
    fail "could not build a Go binary for the Go-binary case"
  fi
fi

# --- 5. an old Go CLI updates itself into the Rust binary --------------------------------------
if ! command -v go >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
  # CI's app-scripts job installs both: there, a missing one would hide the swap's one end-to-end
  # test behind a skip that prints OK.
  if [ -n "${CI:-}" ]; then
    fail "go or python3 is not on PATH in CI, so the Go CLI update cannot run"
  fi
  if [ "$fails" -ne 0 ]; then echo "cli-archives_test: $fails failure(s)"; exit 1; fi
  echo "cli-archives_test: OK (SKIP the Go CLI update: go or python3 not on PATH)"
  exit 0
fi

# The releases server: GitHub's API paths the updaters read, as files.
SRV="$WORK/srv"
API="$SRV/repos/joelmoss/workroom/releases"
mkdir -p "$API/tags" "$SRV/download/v9.9.9" "$SRV/download/nightly"
cp "$WORK/stable/"* "$SRV/download/v9.9.9/"
cp "$WORK/nightly/"* "$SRV/download/nightly/"
# Not `python3 -m http.server`: its HTTPServer.server_bind names the server by socket.getfqdn, a
# reverse lookup of 127.0.0.1, before it prints the port, and on a GitHub macOS runner that lookup
# outlasted the wait below with nothing printed (#681). This binds the port and prints it, with no
# name lookup; each request is still logged to stderr, which the error check at the end reads.
python3 -I -u -c '
import functools, http.server, socketserver, sys

class Server(http.server.ThreadingHTTPServer):
    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]

handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=sys.argv[1])
with Server(("127.0.0.1", 0), handler) as server:
    print("releases server port", server.server_port)
    server.serve_forever()
' "$SRV" >"$WORK/server.log" 2>&1 &
SERVER_PID=$!
PORT=""
tries=0
while [ -z "$PORT" ] && [ "$tries" -lt 100 ]; do
  PORT="$(sed -n 's/^releases server port \([0-9][0-9]*\)$/\1/p' "$WORK/server.log")"
  [ -n "$PORT" ] || { tries=$((tries + 1)); sleep 0.1; }
done
if [ -z "$PORT" ]; then
  if kill -0 "$SERVER_PID" 2>/dev/null; then state="still running, printed nothing"; else state="exited"; fi
  fail "the releases server did not start ($(python3 --version 2>&1), $state): $(cat "$WORK/server.log")"
  exit 1
fi
BASE="http://127.0.0.1:$PORT"

# release_json <tag> <name> <download dir>: the release as GitHub's API returns it.
release_json() {
  assets=""
  for f in "$SRV/download/$3/"*; do
    name="$(basename "$f")"
    assets="${assets:+$assets,}{\"name\":\"$name\",\"browser_download_url\":\"$BASE/download/$3/$name\"}"
  done
  printf '{"tag_name":"%s","name":"%s","draft":false,"prerelease":%s,"assets":[%s]}\n' \
    "$1" "$2" "$([ "$1" = nightly ] && echo true || echo false)" "$assets"
}
release_json v9.9.9 v9.9.9 v9.9.9 >"$API/latest"
release_json nightly 9.9.9-nightly.7 nightly >"$API/tags/nightly"

# The Go CLI as it ships, its releases URL replaced by the server's.
UPDATER="$REPO/internal/updater/updater.go"
const='const releasesAPI = "https://api.github.com/repos/joelmoss/workroom/releases"'
if [ "$(grep -cxF "$const" "$UPDATER")" -ne 1 ]; then
  fail "internal/updater/updater.go no longer has '$const'; update this test"
  exit 1
fi
mkdir "$WORK/overlay"
sed "s|^const releasesAPI = \"https://api.github.com/repos/joelmoss/workroom/releases\"\$|const releasesAPI = \"$BASE/repos/joelmoss/workroom/releases\"|" \
  "$UPDATER" >"$WORK/overlay/updater.go"
printf '{"Replace":{"%s":"%s"}}\n' "$UPDATER" "$WORK/overlay/updater.go" >"$WORK/overlay/overlay.json"
mkdir -p "$WORK/prefix/bin" "$WORK/home"
go_build() {
  (cd "$REPO" && CGO_ENABLED=0 go build -trimpath -overlay "$WORK/overlay/overlay.json" \
    -ldflags "-s -w $2" -o "$WORK/prefix/bin/$1" .) >"$WORK/go-$1.log" 2>&1 \
    || { fail "go build of $1: $(cat "$WORK/go-$1.log")"; return 1; }
}

# update_into_rust <command> <ldflags> <archives> <label> <channel> <version> <want output>
update_into_rust() {
  cmd="$1"
  bin="$WORK/prefix/bin/$cmd"
  go_build "$cmd" "$2" || return
  LC_ALL=C grep -q -a -F 'Go buildinf:' "$bin" || { fail "$cmd: the old CLI is not a Go binary"; return; }
  out="$(HOME="$WORK/home" WORKROOM_CONFIG="$WORK/home/config.json" "$bin" update 2>&1)"
  rc=$?
  [ "$rc" -eq 0 ] || { fail "$cmd update exited $rc: $out"; return; }
  case "$out" in *"$7"*) ;; *) fail "$cmd update printed '$out', want '$7'" ;; esac
  mkdir "$WORK/want-$cmd"
  tar -xzf "$WORK/$3/workroom_$4_$HOST.tar.gz" -C "$WORK/want-$cmd"
  cmp -s "$bin" "$WORK/want-$cmd/workroom" || fail "$cmd: the installed file is not the archive's binary"
  ! LC_ALL=C grep -q -a -F 'Go buildinf:' "$bin" || fail "$cmd: still a Go binary after the update"
  [ -x "$bin" ] || fail "$cmd: the updated binary is not executable"
  protocol="$("$bin" protocol 2>&1)"
  case "$protocol" in *"daemon-build "*) ;; *) fail "$cmd: the updated binary's protocol says '$protocol'" ;; esac
  json="$(HOME="$WORK/home" WORKROOM_CONFIG="$WORK/home/config.json" "$bin" version --json 2>&1)"
  case "$json" in *"\"version\":\"$6\""*) ;; *) fail "$cmd: the updated binary is not version $6: '$json'" ;; esac
  case "$json" in *"\"channel\":\"$5\""*) ;; *) fail "$cmd: the updated binary is not on the $5 channel: '$json'" ;; esac
}
# The Go CLI asks for this Mac's archive.
case " $PLATFORMS " in
  *" $HOST "*)
  update_into_rust workroom "-X main.version=1.0.0" stable 9.9.9 stable 9.9.9 \
    "Updated workroom 1.0.0 → v9.9.9"
  update_into_rust workroom-nightly "-X main.version=9.9.8-nightly.1 -X main.channel=nightly" \
    nightly nightly nightly 9.9.9-nightly.7 "Updated workroom 9.9.8-nightly.1 → 9.9.9-nightly.7"
  # Each fetched only from the server, and every request it made was answered.
  if grep -Eq '" (4|5)[0-9][0-9] ' "$WORK/server.log"; then
    fail "the releases server answered an error: $(grep -E '" (4|5)[0-9][0-9] ' "$WORK/server.log")"
  fi
  ;;
  *) fail "CLI_ARCHIVES_TEST_PLATFORMS leaves out this Mac's $HOST, which the Go CLI update needs" ;;
esac

if [ "$fails" -ne 0 ]; then
  echo "cli-archives_test: $fails failure(s)"
  exit 1
fi
echo "cli-archives_test: OK"
