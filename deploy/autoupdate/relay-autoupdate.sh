#!/usr/bin/env bash
# Guardrailed auto-update for the buzz relay.
#
# Flow: resolve newest ghcr.io/block/buzz:main digest -> pin it in .env ->
# recreate only the relay service -> gate on container health + public HTTPS ->
# roll back to the previous digest automatically if either gate fails.
#
# The relay is upstream's prebuilt image, so there is nothing to compile here.
# Agent images are built from our fork and are deliberately out of scope.
set -euo pipefail

STATE_DIR=/opt/buzz-autoupdate
COMPOSE_DIR=/opt/buzz-selfhost/deploy/compose
ENV_FILE="${COMPOSE_DIR}/.env"
LOG_FILE="${STATE_DIR}/updates.jsonl"
KILL_SWITCH="${STATE_DIR}/DISABLED"
IMAGE_REPO=ghcr.io/block/buzz
IMAGE_TAG=main
RELAY_SERVICE=relay
RELAY_CONTAINER=buzz-prod-relay-1
HEALTH_TIMEOUT="${BUZZ_AUTOUPDATE_HEALTH_TIMEOUT:-240}"
MIN_FREE_MB=5000
# Drill hook: pin an arbitrary digest instead of whatever :main resolves to, so
# the rollback path can be exercised on purpose with a known-bad image.
FORCE_DIGEST="${BUZZ_AUTOUPDATE_FORCE_DIGEST:-}"
FORCE_REPO="${BUZZ_AUTOUPDATE_FORCE_REPO:-}"

# Recreating the relay with a partial file set would make every other service an
# orphan. Always drive compose with the exact set the running project was
# created from, and never pass --remove-orphans.
# Absolute paths: -f is resolved against the caller's CWD, not --project-directory.
COMPOSE_FILES=(
  -f "${COMPOSE_DIR}/compose.yml"
  -f "${COMPOSE_DIR}/compose.caddy.yml"
  -f "${COMPOSE_DIR}/compose.agents.yml"
)

mkdir -p "${STATE_DIR}/backups"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

log_json() {
  # log_json <outcome> <detail> [running_digest] [candidate_digest]
  printf '{"ts":"%s","outcome":"%s","detail":"%s","running":"%s","candidate":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "${3:-}" "${4:-}" >>"${LOG_FILE}"
}

die() {
  log_json "$1" "$2" "${RUNNING_DIGEST:-}" "${CANDIDATE_DIGEST:-}"
  echo "buzz-autoupdate: $1: $2" >&2
  exit 1
}

compose() {
  docker compose --project-directory "${COMPOSE_DIR}" --env-file "${ENV_FILE}" \
    "${COMPOSE_FILES[@]}" "$@"
}

public_url() {
  local domain
  domain="$(grep -E '^BUZZ_DOMAIN=' "${ENV_FILE}" | tail -n1 | cut -d= -f2-)"
  [[ -n "${domain}" ]] || return 1
  printf 'https://%s/' "${domain}"
}

# Both gates must pass: the container's own /_readiness healthcheck, and a real
# request through Caddy from outside the compose network.
gates_pass() {
  local health status
  health="$(docker inspect "${RELAY_CONTAINER}" --format '{{.State.Health.Status}}' 2>/dev/null || echo missing)"
  [[ "${health}" == "healthy" ]] || return 1
  status="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "$(public_url)" || echo 000)"
  [[ "${status}" == "200" ]] || return 1
  return 0
}

wait_for_gates() {
  local deadline=$((SECONDS + HEALTH_TIMEOUT))
  while ((SECONDS < deadline)); do
    if gates_pass; then return 0; fi
    sleep 5
  done
  return 1
}

running_digest() {
  docker inspect "${RELAY_CONTAINER}" --format '{{.Image}}' 2>/dev/null || true
}

registry_digest() {
  local token
  token="$(curl -sf --max-time 20 "https://ghcr.io/token?scope=repository:block/buzz:pull" |
    sed -e 's/.*"token":"\([^"]*\)".*/\1/')"
  [[ -n "${token}" ]] || return 1
  curl -sf --max-time 20 -D - -o /dev/null \
    -H "Authorization: Bearer ${token}" \
    -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json' \
    "https://ghcr.io/v2/block/buzz/manifests/${IMAGE_TAG}" |
    tr -d '\r' | awk 'tolower($1)=="docker-content-digest:"{print $2}'
}

set_env_image() {
  # Rewrite BUZZ_IMAGE in place; .env holds live secrets and is never recreated.
  local pinned="$1" tmp
  tmp="$(mktemp)"
  awk -v repl="BUZZ_IMAGE=${pinned}" \
    '/^BUZZ_IMAGE=/ { print repl; found=1; next } { print } END { if (!found) print repl }' \
    "${ENV_FILE}" >"${tmp}"
  cat "${tmp}" >"${ENV_FILE}"
  rm -f "${tmp}"
}

[[ -e "${KILL_SWITCH}" ]] && { log_json skipped "kill switch present"; exit 0; }
[[ -f "${ENV_FILE}" ]] || die error "missing ${ENV_FILE}"

FREE_MB="$(df -Pm / | awk 'NR==2{print $4}')"
((FREE_MB >= MIN_FREE_MB)) || die blocked "only ${FREE_MB}MB free on /, need ${MIN_FREE_MB}MB"

RUNNING_DIGEST="$(running_digest)"
[[ -n "${RUNNING_DIGEST}" ]] || die blocked "relay container ${RELAY_CONTAINER} not running"

if [[ -n "${FORCE_DIGEST}" ]]; then
  CANDIDATE_DIGEST="${FORCE_DIGEST}"
  [[ -n "${FORCE_REPO}" ]] && IMAGE_REPO="${FORCE_REPO}"
else
  CANDIDATE_DIGEST="$(registry_digest)" || die blocked "could not resolve ${IMAGE_REPO}:${IMAGE_TAG} from registry"
fi
[[ "${CANDIDATE_DIGEST}" == sha256:* ]] || die blocked "registry returned unexpected digest '${CANDIDATE_DIGEST}'"

if [[ "${CANDIDATE_DIGEST}" == "${RUNNING_DIGEST}" ]]; then
  log_json noop "already on newest ${IMAGE_TAG}" "${RUNNING_DIGEST}" "${CANDIDATE_DIGEST}"
  exit 0
fi

# BUZZ_AUTO_MIGRATE=true, so the candidate may apply schema migrations on boot.
# Rolling the image back does not roll the schema back, so capture a restorable
# dump before the candidate ever starts.
DUMP="${STATE_DIR}/backups/buzz-${STAMP}.sql.gz"
docker exec buzz-prod-postgres-1 pg_dump -U buzz -d buzz --clean --if-exists |
  gzip >"${DUMP}" || die blocked "pre-update pg_dump failed"
[[ -s "${DUMP}" ]] || die blocked "pre-update pg_dump produced an empty file"

ENV_BACKUP="${STATE_DIR}/backups/env-${STAMP}"
cp "${ENV_FILE}" "${ENV_BACKUP}"

if [[ -n "${FORCE_REPO}" ]]; then
  PINNED="${IMAGE_REPO}@${CANDIDATE_DIGEST}"
else
  PINNED="${IMAGE_REPO}:${IMAGE_TAG}@${CANDIDATE_DIGEST}"
fi
set_env_image "${PINNED}"

if ! compose pull "${RELAY_SERVICE}"; then
  cat "${ENV_BACKUP}" >"${ENV_FILE}"
  die failed_pull "could not pull ${PINNED}; .env restored, relay untouched"
fi

compose up -d "${RELAY_SERVICE}"

if wait_for_gates; then
  log_json deployed "healthy on candidate; dump ${DUMP}" "${CANDIDATE_DIGEST}" "${CANDIDATE_DIGEST}"
  exit 0
fi

# Candidate failed its gates. Restore the previous digest and prove the rollback.
cat "${ENV_BACKUP}" >"${ENV_FILE}"
compose up -d "${RELAY_SERVICE}" || true

if wait_for_gates; then
  log_json rolled_back "candidate failed gates; back on previous digest; dump ${DUMP}" \
    "${RUNNING_DIGEST}" "${CANDIDATE_DIGEST}"
  exit 1
fi

log_json rollback_failed "candidate AND rollback both failed gates; manual action required; dump ${DUMP}" \
  "${RUNNING_DIGEST}" "${CANDIDATE_DIGEST}"
exit 2
