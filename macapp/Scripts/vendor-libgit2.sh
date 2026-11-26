#!/usr/bin/env bash
#
# Re-vendor libgit2 into macapp/Packages/LibGit2/libgit2/.
#
# libgit2 ships no Package.swift, so SwiftPM cannot take it from github.com. The LibGit2 package
# builds it from this vendored copy of an upstream release instead: no fork sits between us and
# upstream's fixes. This script is the record of which release the copy is, and the refresh path.
#
#   macapp/Scripts/vendor-libgit2.sh                  # vendor LIBGIT2 below
#   LIBGIT2=v1.9.8 macapp/Scripts/vendor-libgit2.sh   # vendor another tag (then update LIBGIT2)
#   macapp/Scripts/vendor-libgit2.sh --check          # verify libgit2/ matches VENDOR.md
#   macapp/Scripts/vendor-libgit2.sh --latest         # print the pinned and the newest tags, and a
#                                                     # `newer:` line for each newer release
#
# `make pre-push` shows the `newer:` lines, so a new libgit2 release (a security fix, usually) is
# noticed at the next push. LIBGIT2_REPO points --latest at another repository (its test does).
#
# The copy is what upstream's CMake compiles for the configuration below, file for file, plus the
# two headers CMake would generate (`src/util/git2_features.h`, `include/git2/experimental.h`),
# rendered here from upstream's own templates. No cmake is needed.
#
# After a bump: read upstream's release notes, diff `src/*/CMakeLists.txt` and `cmake/` between the
# two tags for a changed source glob or default, then `make app-package-test` and `make app-test`.
# A new `#cmakedefine` upstream stops this script until it is decided in ON or OFF below.
set -euo pipefail

PKG="$(cd "$(dirname "${BASH_SOURCE[0]}")/../Packages/LibGit2" && pwd)"
LIB="$PKG/libgit2"
MANIFEST="$PKG/VENDOR.md"
REPO="${LIBGIT2_REPO:-https://github.com/libgit2/libgit2}"
LIBGIT2_DEFAULT="v1.9.7"

# The configuration: upstream CMake's macOS defaults, except that every network transport and
# authenticator is off. libgit2 only ever reads local repositories here; fetch, push and pull run
# the git CLI (ADR 0003), so HTTPS, SSH, NTLM and GSSAPI would be attack surface with no caller.
# Plain http:// and git:// stay compiled because upstream has no switch for them; nothing calls
# them. The regex backend is the system's regcomp_l, as upstream's CMake picks on macOS, so no
# regex engine is bundled. SHA-256 is CommonCrypto, upstream's macOS choice while HTTPS is on:
# with HTTPS off its CMake would fall back to the bundled rfc6234 code, and the system's
# implementation is kept instead. SHA-1 is upstream's default, the collision-detecting SHA1DC.
#
# ON: each `#cmakedefine NAME` here becomes `#define NAME VALUE` (an empty value is a bare define).
ON=(
  GIT_THREADS=1
  GIT_ARCH_64=1
  GIT_USE_ICONV=1
  GIT_USE_NSEC=1
  GIT_USE_STAT_MTIMESPEC=1
  GIT_USE_FUTIMENS=1
  GIT_REGEX_REGCOMP_L=
  GIT_QSORT_BSD=
  GIT_HTTPPARSER_BUILTIN=1
  GIT_SHA1_COLLISIONDETECT=1
  GIT_SHA256_COMMON_CRYPTO=1
  GIT_COMPRESSION_ZLIB=1
  GIT_RAND_GETLOADAVG=1
  GIT_IO_POLL=1
  GIT_IO_SELECT=1
)
# OFF: each becomes `/* #undef NAME */`. A template name in neither list fails the run.
OFF=(
  GIT_DEBUG_POOL GIT_DEBUG_STRICT_ALLOC GIT_DEBUG_STRICT_OPEN GIT_WIN32_LEAKCHECK GIT_ARCH_32
  GIT_USE_STAT_MTIM GIT_USE_STAT_MTIME_NSEC
  GIT_REGEX_REGCOMP GIT_REGEX_PCRE GIT_REGEX_PCRE2 GIT_REGEX_BUILTIN
  GIT_QSORT_GNU GIT_QSORT_C11 GIT_QSORT_MSC
  GIT_SSH GIT_SSH_EXEC GIT_SSH_LIBSSH2 GIT_SSH_LIBSSH2_MEMORY_CREDENTIALS
  GIT_NTLM GIT_GSSAPI GIT_GSSFRAMEWORK
  GIT_WINHTTP GIT_HTTPS GIT_OPENSSL GIT_OPENSSL_DYNAMIC GIT_SECURE_TRANSPORT GIT_MBEDTLS
  GIT_SCHANNEL GIT_HTTPPARSER_HTTPPARSER GIT_HTTPPARSER_LLHTTP
  GIT_SHA1_WIN32 GIT_SHA1_COMMON_CRYPTO GIT_SHA1_OPENSSL GIT_SHA1_OPENSSL_FIPS
  GIT_SHA1_OPENSSL_DYNAMIC GIT_SHA1_MBEDTLS
  GIT_SHA256_BUILTIN GIT_SHA256_WIN32 GIT_SHA256_OPENSSL GIT_SHA256_OPENSSL_FIPS
  GIT_SHA256_OPENSSL_DYNAMIC GIT_SHA256_MBEDTLS
  GIT_COMPRESSION_BUILTIN GIT_IO_WSAPOLL
  GIT_EXPERIMENTAL_SHA256
  # Upstream's CMake looks for getentropy in unistd.h, where macOS does not declare it (it is in
  # sys/random.h), so its macOS builds leave this off too.
  GIT_RAND_GETENTROPY
)

# One SHA-256 over every vendored file's path and content, so --check sees a changed, added or
# removed file alike.
tree_sha() {
  (cd "$PKG" && find libgit2 -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256) \
    | shasum -a 256 | awk '{print $1}'
}

if [[ "${1:-}" == "--check" ]]; then
  [[ -f "$MANIFEST" ]] || { echo "no VENDOR.md; run without --check first"; exit 1; }
  want="$(grep -E '^- Tree SHA-256:' "$MANIFEST" | awk -F'`' '{print $2}')"
  have="$(tree_sha)"
  if [[ "$want" != "$have" ]]; then
    echo "MISMATCH libgit2/: manifest=$want disk=$have"; exit 1
  fi
  echo "OK libgit2/ ($have)"
  exit 0
fi

# Release tags only (vX.Y.Z), newest last. Pre-releases such as v2.0.0-rc.1 are left out.
release_tags() {
  git ls-remote --tags --refs "$REPO" | sed 's#.*refs/tags/##' \
    | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V
}

if [[ "${1:-}" == "--latest" ]]; then
  pinned="$(grep -E '^- Version:' "$MANIFEST" 2>/dev/null | awk -F'`' '{print $2}')"
  pinned="${pinned:-$LIBGIT2_DEFAULT}"
  tags="$(release_tags)" || { echo "couldn't list the tags of $REPO" >&2; exit 1; }
  [[ -n "$tags" ]] || { echo "$REPO has no release tags" >&2; exit 1; }
  line="$(sed -E 's/^(v[0-9]+\.[0-9]+)\..*/\1/' <<<"$pinned")"
  on_line="$(grep -E "^${line//./\\.}\." <<<"$tags" | tail -1 || true)"
  newest="$(tail -1 <<<"$tags")"
  echo "pinned:              $pinned"
  echo "newest on ${line}:     ${on_line:-none}"
  echo "newest release:      $newest"
  # newer A B: A sorts after B as a version.
  newer() { [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" == "$1" ]]; }
  if [[ -n "$on_line" ]] && newer "$on_line" "$pinned"; then
    echo "newer: libgit2 $on_line is out (pinned $pinned); read its release notes, then vendor it:" \
      "LIBGIT2=$on_line macapp/Scripts/vendor-libgit2.sh"
  fi
  if [[ "$newest" != "$on_line" ]] && newer "$newest" "$pinned"; then
    echo "newer: libgit2 $newest is out, a new release line (pinned $pinned); its API may" \
      "have changed, so read its release notes before vendoring it"
  fi
  exit 0
fi

tag="${LIBGIT2:-$LIBGIT2_DEFAULT}"

# Render one CMake template: every `#cmakedefine NAME [VALUE]` line by the ON and OFF lists.
render() { # template output
  local name value line rendered=() decided=" ${OFF[*]} "
  for entry in "${ON[@]}"; do decided+=" ${entry%%=*} "; done
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^#cmakedefine[[:space:]]+([A-Za-z0-9_]+) ]]; then
      name="${BASH_REMATCH[1]}"
      [[ "$decided" == *" $name "* ]] || {
        echo "$1: upstream added $name; decide it in ON or OFF in $0" >&2; exit 1
      }
      line="/* #undef $name */"
      for entry in "${ON[@]}"; do
        if [[ "${entry%%=*}" == "$name" ]]; then
          value="${entry#*=}"
          line="#define $name${value:+ $value}"
        fi
      done
    fi
    rendered+=("$line")
  done <"$1"
  printf '%s\n' "${rendered[@]}" >"$2"
}

work="$(mktemp -d "${TMPDIR:-/tmp}/vendor-libgit2.XXXXXX")"
trap 'rm -rf "$work"' EXIT
echo "→ libgit2 $tag"
git -c advice.detachedHead=false clone -q --depth 1 --branch "$tag" "$REPO" "$work/src"
commit="$(git -C "$work/src" rev-parse HEAD)"
up="$work/src"

# Every name in ON and OFF must still be one of upstream's, or a rename would leave a feature
# silently off.
known="$(cat "$up/src/util/git2_features.h.in" "$up/src/libgit2/experimental.h.in" \
  | sed -nE 's/^#cmakedefine[[:space:]]+([A-Za-z0-9_]+).*/\1/p')"
for name in "${OFF[@]}" "${ON[@]%%=*}"; do
  grep -qx "$name" <<<"$known" || { echo "upstream $tag has no $name; update $0" >&2; exit 1; }
done

# copy <glob relative to the upstream root>...: each file to the same path under libgit2/.
copy() {
  local f
  for f in "$@"; do
    [[ -f "$up/$f" ]] || continue
    mkdir -p "$LIB/$(dirname "$f")"
    cp "$up/$f" "$LIB/$f"
  done
}

rm -rf "$LIB"
mkdir -p "$LIB"
(
  cd "$up"
  shopt -s nullglob
  # The same globs as upstream's CMakeLists.txt files, for the configuration above.
  copy COPYING include/git2.h include/git2/*.h include/git2/sys/*.h
  copy src/libgit2/*.c src/libgit2/*.h src/libgit2/streams/*.[ch] src/libgit2/transports/*.[ch]
  copy src/util/*.c src/util/*.h src/util/allocators/*.[ch] src/util/unix/*.[ch]
  copy src/util/hash/sha.h src/util/hash/collisiondetect.* src/util/hash/sha1dc/*
  copy src/util/hash/common_crypto.*
  copy deps/xdiff/*.[ch] deps/llhttp/*.[ch] deps/llhttp/LICENSE-MIT
)
render "$up/src/util/git2_features.h.in" "$LIB/src/util/git2_features.h"
render "$up/src/libgit2/experimental.h.in" "$LIB/include/git2/experimental.h"

version="$(sed -nE 's/^#define LIBGIT2_VERSION[[:space:]]+"([^"]+)".*/\1/p' "$LIB/include/git2/version.h")"
[[ "v$version" == "$tag" ]] || { echo "$tag's version.h says $version" >&2; exit 1; }

{
  echo "# Vendored libgit2"
  echo
  echo "\`libgit2/\` is the part of upstream's tree that its CMake build compiles on macOS for the"
  echo "configuration in \`macapp/Scripts/vendor-libgit2.sh\`, unmodified, except for the two"
  echo "headers CMake would generate, which that script renders from upstream's templates:"
  echo "\`src/util/git2_features.h\` (not in upstream's tree) and \`include/git2/experimental.h\`"
  echo "(replacing the copy upstream's tree carries)."
  echo "**Do not edit these files by hand.** Refresh with \`macapp/Scripts/vendor-libgit2.sh\`."
  echo
  echo "- Version: \`$tag\`"
  echo "- Commit: \`$commit\`"
  echo "- Source: $REPO/tree/$tag"
  echo "- Tree SHA-256: \`$(tree_sha)\`"
} >"$MANIFEST"
echo "wrote $MANIFEST"
