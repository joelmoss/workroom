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

get_latest_version() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p'
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- "https://api.github.com/repos/${REPO}/releases/latest" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p'
  else
    echo "Error: curl or wget is required" >&2
    exit 1
  fi
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

  if [ -n "$VERSION" ]; then
    # Ensure version starts with 'v'
    case "$VERSION" in
      v*) ;;
      *)  VERSION="v${VERSION}" ;;
    esac
  else
    echo "Fetching latest version..."
    VERSION=$(get_latest_version)
    if [ -z "$VERSION" ]; then
      echo "Error: Could not determine latest version" >&2
      exit 1
    fi
  fi

  # Strip leading 'v' for the archive filename
  VERSION_NUM="${VERSION#v}"

  ARCHIVE="workroom_${VERSION_NUM}_${OS}_${ARCH}.tar.gz"
  URL="https://github.com/${REPO}/releases/download/${VERSION}/${ARCHIVE}"

  echo "Installing workroom ${VERSION} (${OS}/${ARCH})..."

  TMPDIR_CREATED=$(mktemp -d)
  TMPFILE="${TMPDIR_CREATED}/${ARCHIVE}"

  echo "Downloading ${URL}..."
  download "$URL" "$TMPFILE"

  tar -xzf "$TMPFILE" -C "$TMPDIR_CREATED"

  INSTALL_DIR="${WORKROOM_INSTALL_PATH:-${HOME}/.local/bin}"
  mkdir -p "$INSTALL_DIR"
  cp "${TMPDIR_CREATED}/${BINARY}" "${INSTALL_DIR}/${BINARY}"
  chmod +x "${INSTALL_DIR}/${BINARY}"

  echo "Installed workroom to ${INSTALL_DIR}/${BINARY}"

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
  if command -v workroom >/dev/null 2>&1; then
    echo ""
    workroom version
  fi
}

main
