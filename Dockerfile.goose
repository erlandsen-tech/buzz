# syntax=docker/dockerfile:1.7

# Runtime ABI image published by block/buzz. Keep this immutable because the
# resulting container receives the agent's Nostr private key.
ARG SPRIG_IMAGE=ghcr.io/block/buzz-sprig:sha-6530b58@sha256:17facfc7608d8ddb33bc056c9aaba1098f4ef6abe5655702fbfd7584d1f74d76
FROM ${SPRIG_IMAGE}

USER root

ARG TARGETARCH
ARG GOOSE_VERSION=1.45.0
ARG GOOSE_SHA256_AMD64=37023a7fa9ab032ac3d237bc381e1e6f3071b966353381c31be6de8ce6dcbb29
ARG GOOSE_SHA256_ARM64=1f22bf558c433b399c5d51c806806d5f59a5cfa96bf69076ff722bb1a9d3ec63

# Goose publishes native musl archives, so no glibc compatibility layer is
# needed on sprig's Alpine base. Verify the release asset before installing it.
RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) goose_arch="x86_64"; goose_sha256="${GOOSE_SHA256_AMD64}" ;; \
      arm64) goose_arch="aarch64"; goose_sha256="${GOOSE_SHA256_ARM64}" ;; \
      *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    archive="goose-${goose_arch}-unknown-linux-musl.tar.bz2"; \
    url="https://github.com/aaif-goose/goose/releases/download/v${GOOSE_VERSION}/${archive}"; \
    apk add --no-cache su-exec; \
    apk add --no-cache --virtual .goose-install-deps bzip2; \
    curl --fail --location --silent --show-error "${url}" --output "/tmp/${archive}"; \
    echo "${goose_sha256}  /tmp/${archive}" | sha256sum -c -; \
    mkdir /tmp/goose; \
    tar -xjf "/tmp/${archive}" -C /tmp/goose; \
    install -o root -g root -m 0755 /tmp/goose/goose /usr/local/bin/goose; \
    goose --version; \
    rm -rf "/tmp/${archive}" /tmp/goose; \
    apk del .goose-install-deps

COPY --chmod=0755 scripts/goose-agent-entrypoint.sh /usr/local/bin/goose-agent-entrypoint

# The wrapper fixes ownership of fresh named-volume mount roots, then execs as
# uid 1000. sprig-entrypoint subsequently execs buzz-acp; Compose's tiny init
# remains PID 1 to reap any orphaned ACP child processes.
ENTRYPOINT ["/usr/local/bin/goose-agent-entrypoint"]
