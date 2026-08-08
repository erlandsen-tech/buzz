#!/bin/sh
set -eu

# Docker named volumes can mask image-time ownership with root-owned mount roots,
# and older starts may have created root-owned Goose state below HOME. This is a
# dedicated agent-home volume, so repair it recursively; the potentially large
# workspace only needs its mount root adjusted.
chown -R agent:agent /home/agent
chown agent:agent /workspace

exec su-exec agent /usr/local/bin/sprig-entrypoint "$@"
