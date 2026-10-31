ARG RUST_VERSION
FROM rust:${RUST_VERSION}-bookworm

RUN apt-get update \
    && apt-get install -y --no-install-recommends clang libclang-dev cmake pkg-config python3 libssl-dev \
    && rm -rf /var/lib/apt/lists/* \
    && rustup component add rustfmt clippy

ARG ZIG_VERSION
# Published release checksums: https://ziglang.org/download/index.json.
# The x86_64 pin is the one used by CI's install-zig action.
RUN set -eu; \
    case "${ZIG_VERSION}/$(uname -m)" in \
      0.17.0/aarch64) arch=aarch64; sha=9e8d11661d4ae3bd57702a3832781e23ad151dde5798e16a5ccd503f65234ff8 ;; \
      0.17.0/x86_64) arch=x86_64; sha=1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026 ;; \
      *) echo "Unsupported Zig version/architecture; update the verified release checksums" >&2; exit 1 ;; \
    esac; \
    curl -fsSL --retry 3 "https://ziglang.org/download/${ZIG_VERSION}/zig-${arch}-linux-${ZIG_VERSION}.tar.xz" -o /tmp/zig.tar.xz; \
    echo "$sha  /tmp/zig.tar.xz" | sha256sum --check --strict; \
    mkdir /opt/zig; \
    tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1; \
    rm /tmp/zig.tar.xz

ENV PATH="/opt/zig:${PATH}"
