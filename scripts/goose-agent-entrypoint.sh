#!/bin/sh
set -eu

# Docker named volumes can mask image-time ownership with root-owned mount roots,
# and older starts may have created root-owned Goose state below HOME. Repair the
# mount roots, then chown only the entries that are actually mis-owned.
#
# Do NOT restore `chown -R agent:agent /home/agent` here. These containers run
# `cap_drop: ALL` with only CHOWN/SETGID/SETUID added back, so root has no
# DAC_READ_SEARCH and cannot read a mode-700/711 directory owned by uid 1000.
# `ssh-keygen` creates exactly that (~/.ssh, mode 700). The recursive chown then
# fails with EACCES, `set -e` kills this script, and the container crash-loops
# behind a misleading "chown: /home/agent/.ssh: Permission denied". Any subtree
# root cannot descend into was created by the agent user and is already
# agent-owned, so skipping it loses nothing. -- 2026-08-14
chown agent:agent /home/agent /workspace
find /home/agent \( ! -user agent -o ! -group agent \) -exec chown agent:agent {} + 2>/dev/null || true

exec su-exec agent /usr/local/bin/sprig-entrypoint "$@"
