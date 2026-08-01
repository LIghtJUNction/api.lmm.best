FROM oven/bun:1@sha256:0733e50325078969732ebe3b15ce4c4be5082f18c4ac1a0f0ca4839c2e4e42a7 AS web-builder

WORKDIR /build/web
COPY web/package.json web/bun.lock ./
RUN bun install --frozen-lockfile
COPY web/ ./
COPY VERSION /build/VERSION
RUN DISABLE_ESLINT_PLUGIN=true VITE_REACT_APP_VERSION="$(cat /build/VERSION)" bun run build

FROM rust:1.88.0-bookworm@sha256:af306cfa71d987911a781c37b59d7d67d934f49684058f96cf72079c3626bfe0 AS rust-builder

WORKDIR /build/rust
COPY rust/Cargo.toml rust/Cargo.lock ./
COPY rust/apps ./apps
COPY rust/crates ./crates

ARG LMM_BUILD_REVISION=unknown
RUN LMM_BUILD_REVISION="${LMM_BUILD_REVISION}" \
    cargo build --locked --release --package lmm-api-rs

FROM debian:bookworm-slim@sha256:f06537653ac770703bc45b4b113475bd402f451e85223f0f2837acbf89ab020a

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates tzdata wget \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --system --gid 10001 lmm-api-rs \
    && useradd --system --uid 10001 --gid lmm-api-rs --home-dir /var/lib/lmm-api-rs --create-home lmm-api-rs

COPY --from=rust-builder /build/rust/target/release/lmm-api-rs /usr/local/bin/lmm-api-rs
COPY --from=web-builder /build/web/dist /opt/lmm-api-rs/web/dist
COPY LICENSE NOTICE THIRD-PARTY-LICENSES.md /licenses/

ENV LMM_RS_LISTEN_ADDR=0.0.0.0:3000 \
    LMM_RS_SLOT=blue \
    LMM_WEB_DIST_DIR=/opt/lmm-api-rs/web/dist
EXPOSE 3000
WORKDIR /var/lib/lmm-api-rs
USER 10001:10001
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD wget --quiet --spider http://127.0.0.1:3000/readyz || exit 1
ENTRYPOINT ["/usr/local/bin/lmm-api-rs"]
