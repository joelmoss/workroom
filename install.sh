#!/bin/sh
set -e

REPO="joelmoss/workroom"
BINARY="workroom"

# Clean up temp dir on exit
cleanup() {
  [ -n "$TMPDIR_CREATED" ] && rm -rf "$TMPDIR_CREATED"
}
trap cleanup EXIT

detect_os() {
  case "$(uname -s)" in
    Darwin*) echo "darwin" ;;
    Linux*)  echo "linux" ;;
    *)
      echo "Error: Unsupported operating system: $(uname -s)" >&2
      exit 1
      ;;
  esac
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  echo "amd64" ;;
    aarch64|arm64)  echo "arm64" ;;
    *)
      echo "Error: Unsupported architecture: $(uname -m)" >&2
      exit 1
      ;;
  esac
}

api_get() {
  # Fetch a GitHub API URL to stdout.
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$1"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- "$1"
  else
    echo "Error: curl or wget is required" >&2
    exit 1
  fi
}

# Resolve the release tag to install for the given channel. install.sh is curl-piped and can't
# source Scripts/channel-helper.sh, so it inlines the minimal channel routing — NOT tag
# classification (that contract lives in internal/channel + ReleaseChannel + channel-helper.sh):
#   stable  -> GitHub's "Latest" (excludes prereleases by definition)
#   pre     -> newest release that is not the nightly/appcast pseudo-release (GitHub lists newest
#              first and hides drafts from anonymous callers, so this is the newest stable-or-prerelease)
#   nightly -> the fixed rolling "nightly" release
resolve_tag() {
  case "$1" in
    stable)
      api_get "https://api.github.com/repos/${REPO}/releases/latest" |
        grep -o '"tag_name":[ ]*"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/' | head -1
      ;;
    pre)
      api_get "https://api.github.com/repos/${REPO}/releases?per_page=100" |
        grep -o '"tag_name":[ ]*"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/' |
        grep -vxE 'nightly|appcast' | head -1
      ;;
    nightly)
      echo "nightly"
      ;;
  esac
}

download() {
  url="$1"
  output="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "$output" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$output" "$url"
  fi
}

main() {
  OS=$(detect_os)
  ARCH=$(detect_arch)

  CHANNEL="${WORKROOM_CHANNEL:-stable}"
  case "$CHANNEL" in
    stable | pre | nightly) ;;
    *)
      echo "Error: invalid WORKROOM_CHANNEL '$CHANNEL' (want stable, pre, or nightly)" >&2
      exit 1
      ;;
  esac

  if [ -n "$VERSION" ]; then
    # An explicit VERSION pins an exact release and overrides the channel.
    case "$VERSION" in
      v*) ;;
      *) VERSION="v${VERSION}" ;;
    esac
    TAG="$VERSION"
    ARCHIVE="workroom_${VERSION#v}_${OS}_${ARCH}.tar.gz"
  else
    echo "Resolving the ${CHANNEL} channel..."
    TAG=$(resolve_tag "$CHANNEL")
    if [ -z "$TAG" ]; then
      echo "Error: could not resolve a ${CHANNEL} release" >&2
      exit 1
    fi
    if [ "$CHANNEL" = "nightly" ]; then
      # Nightly assets are version-independent (fixed rolling release).
      ARCHIVE="workroom_nightly_${OS}_${ARCH}.tar.gz"
    else
      ARCHIVE="workroom_${TAG#v}_${OS}_${ARCH}.tar.gz"
    fi
  fi

  URL="https://github.com/${REPO}/releases/download/${TAG}/${ARCHIVE}"

  echo "Installing workroom (${CHANNEL} channel, ${OS}/${ARCH})..."

  TMPDIR_CREATED=$(mktemp -d)
  TMPFILE="${TMPDIR_CREATED}/${ARCHIVE}"

  echo "Downloading ${URL}..."
  download "$URL" "$TMPFILE"

  tar -xzf "$TMPFILE" -C "$TMPDIR_CREATED"

  # Nightly installs under a distinct command name so it coexists with a main `workroom` (issue
  # #91) — the nightly archive's binary is already baked to the nightly channel by CI. The archive
  # always contains a binary named `workroom`; only the installed name differs.
  DEST_NAME="workroom"
  [ "$CHANNEL" = "nightly" ] && DEST_NAME="workroom-nightly"

  INSTALL_DIR="${WORKROOM_INSTALL_PATH:-${HOME}/.local/bin}"
  mkdir -p "$INSTALL_DIR"
  cp "${TMPDIR_CREATED}/${BINARY}" "${INSTALL_DIR}/${DEST_NAME}"
  chmod +x "${INSTALL_DIR}/${DEST_NAME}"

  echo "Installed ${DEST_NAME} to ${INSTALL_DIR}/${DEST_NAME}"

  # Remember the `pre` channel so a later `workroom update` stays on it instead of reverting to
  # stable (reuses the CLI's sticky channel logic — a no-op check that only writes config). Stable
  # is the default (nothing to persist); nightly is baked into the `workroom-nightly` binary, so it
  # neither needs nor accepts a channel switch.
  if [ "$CHANNEL" = "pre" ]; then
    "${INSTALL_DIR}/${DEST_NAME}" update --channel pre >/dev/null 2>&1 || true
  fi

  case ":$PATH:" in
    *":${INSTALL_DIR}:"*) ;;
    *)
      echo ""
      echo "Add ${INSTALL_DIR} to your PATH:"
      echo "  export PATH=\"${INSTALL_DIR}:\$PATH\""
      echo ""
      echo "Add this line to your shell profile (~/.bashrc, ~/.zshrc, etc.) to make it permanent."
      ;;
  esac

  # Verify installation
  if command -v "$DEST_NAME" >/dev/null 2>&1; then
    echo ""
    "$DEST_NAME" version
  fi
}

main
