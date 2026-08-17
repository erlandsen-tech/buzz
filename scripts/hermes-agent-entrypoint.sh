#!/bin/sh
set -eu

# Fresh named volumes present a root-owned mount root; fix that so the agent can
# write. Deliberately NOT recursive, unlike scripts/goose-agent-entrypoint.sh:7 —
# Hermes creates 0700 dirs under HERMES_HOME, and this container drops ALL
# capabilities (only CHOWN/SETGID/SETUID are re-added), so root has no
# CAP_DAC_READ_SEARCH and cannot even traverse them. A recursive chown fails on
# every restart after first boot.
chown agent:agent /home/agent /workspace 2>/dev/null || true

# Seed a fresh HERMES_HOME as the agent, for the same capability reason: root
# cannot write into an agent-owned 0755 home. Hermes builds the rest of the tree
# itself on first run.
gosu agent sh -c 'mkdir -p "$HOME/.hermes"; [ -e "$HOME/.hermes/config.yaml" ] || cp /usr/share/hermes-seed/config.yaml "$HOME/.hermes/config.yaml"; [ -e "$HOME/.hermes/SOUL.md" ] || cp /usr/share/hermes-seed/SOUL.md "$HOME/.hermes/SOUL.md"'

exec gosu agent /usr/local/bin/sprig-entrypoint "$@"
