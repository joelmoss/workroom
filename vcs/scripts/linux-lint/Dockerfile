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
      0.17.1/aarch64) arch=aarch64; sha=a1546d5646eb184437918d6635ca6b762a0e889eac09cef720ee7a1ed3fe7795 ;; \
      0.17.1/x86_64) arch=x86_64; sha=3581863e3cbcfd0fce0efc682ce7e9e93da96668a977791d356a26d2a7e9b17a ;; \
      *) echo "Unsupported Zig version/architecture; update the verified release checksums" >&2; exit 1 ;; \
    esac; \
    curl -fsSL --retry 3 "https://ziglang.org/download/${ZIG_VERSION}/zig-${arch}-linux-${ZIG_VERSION}.tar.xz" -o /tmp/zig.tar.xz; \
    echo "$sha  /tmp/zig.tar.xz" | sha256sum --check --strict; \
    mkdir /opt/zig; \
    tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1; \
    rm /tmp/zig.tar.xz

ENV PATH="/opt/zig:${PATH}"
