#!/usr/bin/env bash
# Agent smoke test: mention the compose-managed agent as the owner and assert
# a reply arrives. Complements the relay-only validation in README.md — an
# agent container can be "Up" yet never deliver a reply (bad auth tag, wrong
# model creds, respond-to gate); this makes that failure visible.
#
# Usage:
#   BUZZ_OWNER_SECRET_KEY=<owner nsec/hex> ./verify-agent.sh [options]
#
# Options:
#   --channel <uuid>   Use an existing channel the agent is already a member
#                      of (skips the create+join step).
#   --service <name>   Compose service to test (default: goose-agent).
#   --timeout <secs>   How long to wait for a reply (default: 180).
#
# The owner key never leaves this host: it is injected only into one-off
# `docker compose exec` invocations against the agent container's buzz CLI.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

SERVICE=goose-agent
CHANNEL=""
TIMEOUT=180
while [[ $# -gt 0 ]]; do
  case "$1" in
    --channel) CHANNEL="${2:?--channel needs a uuid}"; shift 2 ;;
    --service) SERVICE="${2:?--service needs a name}"; shift 2 ;;
    --timeout) TIMEOUT="${2:?--timeout needs seconds}"; shift 2 ;;
    -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

OWNER_KEY="${BUZZ_OWNER_SECRET_KEY:?set BUZZ_OWNER_SECRET_KEY to the community owner secret key, nsec or 64-hex}"

# Reuse run.sh's compose-file selection so exec targets the right project.
BUZZ_COMPOSE_TLS="${BUZZ_COMPOSE_TLS:-$(grep -E '^BUZZ_COMPOSE_TLS=' .env | tail -n1 | cut -d= -f2- || true)}"
COMPOSE_FILES=(-f compose.yml -f compose.agents.yml)
if [[ "${BUZZ_COMPOSE_TLS:-false}" == "true" ]]; then
  COMPOSE_FILES=(-f compose.yml -f compose.caddy.yml -f compose.agents.yml)
fi

compose() { docker compose --env-file .env "${COMPOSE_FILES[@]}" "$@"; }

# buzz CLI as the agent (container's own identity/env).
agent_buzz() { compose exec -T "${SERVICE}" buzz "$@"; }
# buzz CLI as the sender (override identity; replace the agent's auth tag
# with BUZZ_SENDER_AUTH_TAG — empty for the community owner, or a NIP-OA tag
# when testing with a delegated identity instead of the owner key).
owner_buzz() {
  compose exec -T \
    -e BUZZ_PRIVATE_KEY="${OWNER_KEY}" \
    -e BUZZ_AUTH_TAG="${BUZZ_SENDER_AUTH_TAG:-}" \
    "${SERVICE}" buzz "$@"
}

fail() { echo "FAIL: $*" >&2; exit 1; }

echo "· resolving agent pubkey from ${SERVICE} logs"
AGENT_PUBKEY="$(compose logs --no-color "${SERVICE}" 2>/dev/null \
  | grep -oE 'buzz-acp starting: [^ ]* pubkey=[0-9a-f]{64}' \
  | tail -n1 | grep -oE '[0-9a-f]{64}$' || true)"
[[ -n "${AGENT_PUBKEY}" ]] || fail "could not find 'buzz-acp starting: … pubkey=' in ${SERVICE} logs — is the container running?"
echo "  agent pubkey: ${AGENT_PUBKEY}"

if [[ -z "${CHANNEL}" ]]; then
  NAME="smoke-$(date +%s)"
  echo "· creating open channel ${NAME} as owner"
  CREATE_JSON="$(owner_buzz channels create --name "${NAME}" --type stream --visibility open)"
  CHANNEL="$(printf '%s' "${CREATE_JSON}" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("channel_id",""))' 2>/dev/null || true)"
  if [[ -z "${CHANNEL}" || "${CHANNEL}" == "None" ]]; then
    CHANNEL="$(printf '%s' "${CREATE_JSON}" | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -n1 || true)"
  fi
  [[ -n "${CHANNEL}" ]] || fail "channel create returned no id: ${CREATE_JSON}"
  echo "  channel: ${CHANNEL}"
  echo "· joining channel as agent (harness auto-subscribes on membership)"
  agent_buzz channels join --channel "${CHANNEL}" >/dev/null
  sleep 3
fi

START_TS="$(date +%s)"
echo "· mentioning agent in ${CHANNEL}"
SEND_JSON="$(owner_buzz messages send \
  --channel "${CHANNEL}" \
  --content "Smoke test: please reply with a short confirmation." \
  --mention "${AGENT_PUBKEY}")"
echo "  sent: ${SEND_JSON}"

echo "· waiting up to ${TIMEOUT}s for a reply authored by the agent"
DEADLINE=$(( START_TS + TIMEOUT ))
while (( $(date +%s) < DEADLINE )); do
  sleep 5
  REPLY="$(owner_buzz messages get --channel "${CHANNEL}" --limit 50 --kinds 9 2>/dev/null \
    | python3 -c "
import sys, json
events = json.load(sys.stdin)
for e in events:
    if e.get('pubkey') == '${AGENT_PUBKEY}' and e.get('created_at', 0) >= ${START_TS}:
        print(e.get('content', '')[:200])
        break
" || true)"
  if [[ -n "${REPLY}" ]]; then
    echo "PASS: agent replied: ${REPLY}"
    exit 0
  fi
  echo "  … no reply yet ($(( DEADLINE - $(date +%s) ))s left)"
done

echo "Recent ${SERVICE} logs:" >&2
compose logs --no-color --tail 40 "${SERVICE}" >&2 || true
fail "no reply from agent within ${TIMEOUT}s — check auth tag, respond-to gate, and model credentials"
