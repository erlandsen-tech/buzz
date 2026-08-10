#!/usr/bin/env bash
set -euo pipefail

# Generates deploy/compose/.env from .env.example with stable secrets and the
# public domain filled in. Run once per deployment; re-running requires --force
# and rotates every generated secret (existing data volumes keep working, but
# clients must re-fetch the relay identity if the relay key changes).
#
# Usage:
#   ./bootstrap.sh --domain buzz.example.com [--owner-pubkey <64-hex>] [--force]
#
# Secrets are generated as hex so they stay safe inside URLs such as
# redis://:<password>@redis:6379 (compose.yml interpolates them verbatim).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

DOMAIN=""
OWNER_PUBKEY=""
FORCE=false

usage() {
  grep -E '^#( |$)' "${BASH_SOURCE[0]}" | sed -E 's/^# ?//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="${2:?--domain requires a value}"; shift 2 ;;
    --owner-pubkey) OWNER_PUBKEY="${2:?--owner-pubkey requires a value}"; shift 2 ;;
    --force) FORCE=true; shift ;;
    -h|--help) usage ;;
    *) echo "Unknown argument: $1" >&2; usage 1 ;;
  esac
done

[[ -n "${DOMAIN}" ]] || { echo "Missing required --domain" >&2; usage 1; }
[[ "${DOMAIN}" != *://* && "${DOMAIN}" == *.* ]] ||
  { echo "--domain must be a hostname such as buzz.example.com, not a URL" >&2; exit 1; }
if [[ -n "${OWNER_PUBKEY}" && ! "${OWNER_PUBKEY}" =~ ^[0-9a-f]{64}$ ]]; then
  echo "--owner-pubkey must be 64 lowercase hex characters" >&2
  exit 1
fi
command -v openssl >/dev/null 2>&1 || { echo "openssl is required" >&2; exit 1; }

if [[ -f .env && "${FORCE}" != "true" ]]; then
  echo ".env already exists; pass --force to regenerate (rotates all secrets)" >&2
  exit 1
fi

secret() { openssl rand -hex "$1"; }

cp .env.example .env
chmod 600 .env

# BSD and GNU sed differ on -i; write via a temp file instead.
substitute() {
  local pattern="$1"
  local replacement="$2"
  local tmp
  tmp="$(mktemp "${SCRIPT_DIR}/.env.XXXXXX")"
  sed -E "s|${pattern}|${replacement}|" .env >"${tmp}"
  mv "${tmp}" .env
  chmod 600 .env
}

substitute "buzz\.example\.com" "${DOMAIN}"
substitute "^BUZZ_RELAY_PRIVATE_KEY=.*" "BUZZ_RELAY_PRIVATE_KEY=$(secret 32)"
substitute "^BUZZ_GIT_HOOK_HMAC_SECRET=.*" "BUZZ_GIT_HOOK_HMAC_SECRET=$(secret 32)"
substitute "^POSTGRES_PASSWORD=.*" "POSTGRES_PASSWORD=$(secret 24)"
substitute "^REDIS_PASSWORD=.*" "REDIS_PASSWORD=$(secret 24)"
substitute "^BUZZ_S3_ACCESS_KEY=.*" "BUZZ_S3_ACCESS_KEY=$(secret 10)"
substitute "^BUZZ_S3_SECRET_KEY=.*" "BUZZ_S3_SECRET_KEY=$(secret 24)"
if [[ -n "${OWNER_PUBKEY}" ]]; then
  substitute "^RELAY_OWNER_PUBKEY=.*" "RELAY_OWNER_PUBKEY=${OWNER_PUBKEY}"
fi

# Agent-stack credentials are only needed with BUZZ_COMPOSE_AGENTS=true, but
# run.sh refuses to start while any CHANGE_ME value is active. Comment them out
# so a relay-only deployment starts; uncomment and fill them to enable agents.
for agent_var in BUZZ_AGENT_PRIVATE_KEY BUZZ_AGENT_AUTH_TAG BUZZ_AGENT_MODEL OPENROUTER_API_KEY; do
  substitute "^(${agent_var}=.*CHANGE_ME.*)" "#\1"
done

# Persist the TLS switch so ./run.sh includes compose.caddy.yml without needing
# the flag exported in every shell.
if ! grep -q '^BUZZ_COMPOSE_TLS=' .env; then
  printf '\n# Compose profile switches read by run.sh.\nBUZZ_COMPOSE_TLS=true\n' >>.env
fi

echo "Wrote ${SCRIPT_DIR}/.env for ${DOMAIN}"
if grep -q CHANGE_ME_OWNER_PUBKEY .env; then
  cat <<'MSG'

RELAY_OWNER_PUBKEY is still unset. Get your 64-hex Nostr pubkey from Buzz
Desktop (or any Nostr key tool) and either re-run with --owner-pubkey or edit
.env directly. ./run.sh start refuses to run until it is set.
MSG
fi
cat <<MSG

Next:
  ./run.sh start
  curl -fsS https://${DOMAIN}/_liveness

Back up .env now — it holds the relay identity and all datastore credentials.
MSG
