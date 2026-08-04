FROM oven/bun:1@sha256:0733e50325078969732ebe3b15ce4c4be5082f18c4ac1a0f0ca4839c2e4e42a7 AS web-builder

WORKDIR /build
COPY package.json bun.lock turbo.json ./
COPY apps/web/package.json apps/web/package.json
COPY apps/api-go/package.json apps/api-go/package.json
COPY apps/api-rust/package.json apps/api-rust/package.json
RUN bun install --frozen-lockfile
COPY apps/web apps/web
COPY VERSION VERSION
RUN DISABLE_ESLINT_PLUGIN=true \
    VITE_REACT_APP_VERSION="$(cat VERSION)" \
    bun run --filter @lmm/web build

FROM golang:1.26.1-alpine@sha256:2389ebfa5b7f43eeafbd6be0c3700cc46690ef842ad962f6c5bd6be49ed82039 AS go-builder

ENV GO111MODULE=on CGO_ENABLED=0 GOWORK=off GOEXPERIMENT=greenteagc
ARG TARGETOS=linux
ARG TARGETARCH=amd64
ENV GOOS=${TARGETOS} GOARCH=${TARGETARCH}

WORKDIR /build/apps/api-go
COPY apps/api-go/go.mod apps/api-go/go.sum ./
COPY apps/api-go/relaykit/go.mod relaykit/go.mod
RUN go mod download
COPY apps/api-go ./
COPY VERSION ./VERSION
COPY --from=web-builder /build/apps/web/dist ./web/dist
RUN go build \
    -ldflags "-s -w -X 'github.com/QuantumNous/new-api/common.Version=$(cat VERSION)'" \
    -o /out/lmm-api-go

FROM debian:bookworm-slim@sha256:f06537653ac770703bc45b4b113475bd402f451e85223f0f2837acbf89ab020a

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates tzdata wget \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --system --gid 10001 lmm-api \
    && useradd --system --uid 10001 --gid lmm-api --home-dir /var/lib/lmm-api --create-home lmm-api

COPY --from=go-builder /out/lmm-api-go /usr/local/bin/lmm-api-go
COPY LICENSE NOTICE THIRD-PARTY-LICENSES.md /licenses/

ENV GIN_MODE=release PORT=3000
EXPOSE 3000
WORKDIR /var/lib/lmm-api
USER 10001:10001
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD wget --quiet --spider http://127.0.0.1:3000/api/status || exit 1
ENTRYPOINT ["/usr/local/bin/lmm-api-go"]
