#!/usr/bin/env bash
# Promote the agent images that agent-build-check.sh already built and smoke
# tested, then prove the fleet came back -- or roll it back.
#
# Why this is not a `docker tag`: only `goose-agent` and `hermes-nikon` declare
# an `image:` in compose.agents.yml. The other five seats get compose's derived
# <project>-<service> name, so they are five separate image *names* holding
# identical content. Retagging just the primaries upgrades 3 of 7 seats and
# leaves the fleet split across two buzz-acp versions with nothing logged
# anywhere. Every image name below must move together.
#
# The pin also lives in .env as BUZZ_SPRIG_IMAGE, interpolated into each build's
# SPRIG_IMAGE arg. Without that a later `run.sh up -d --build` would silently
# rebuild the promoted seats back onto the old Dockerfile ARG default.
set -euo pipefail

STATE_DIR=/opt/buzz-autoupdate
REPO_DIR=/opt/buzz-selfhost
COMPOSE_DIR="${REPO_DIR}/deploy/compose"
ENV_FILE="${COMPOSE_DIR}/.env"
LOG_FILE="${STATE_DIR}/agent-promote.jsonl"
STATUS_FILE="${STATE_DIR}/agent-build.status"
BUILD_LOG="${STATE_DIR}/agent-build.jsonl"
KILL_SWITCH="${STATE_DIR}/DISABLED"
PROMOTE_SWITCH="${STATE_DIR}/PROMOTE_ENABLED"
SPRIG_REPO=ghcr.io/block/buzz-sprig
READY_TIMEOUT="${BUZZ_PROMOTE_READY_TIMEOUT:-300}"

# image|container|service, in the order compose starts them.
SEATS=(
  "buzz-prod-goose-agent|buzz-prod-goose-agent-1|goose-agent"
  "buzz-prod-goose-crash|buzz-prod-goose-crash-1|goose-crash"
  "buzz-prod-goose-ed209|buzz-prod-goose-ed209-1|goose-ed209"
  "buzz-prod-goose-mcp|buzz-prod-goose-mcp-1|goose-mcp"
  "buzz-prod-goose-swordfish|buzz-prod-goose-swordfish-1|goose-swordfish"
  "buzz-prod-goose-hermes|buzz-prod-hermes-nikon-1|hermes-nikon"
  "buzz-prod-pi-agent|buzz-prod-pi-agent-1|pi-agent"
)

# Drill hook: promote a deliberately broken image instead of the candidate, so
# the rollback path can be exercised on purpose rather than asserted.
FORCE_IMAGE="${BUZZ_PROMOTE_FORCE_IMAGE:-}"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

log_json() {
  # Stamped when the line is written, not when the script started. A single
  # start-of-run TS made a cutover and the rollback that followed it minutes
  # later share one timestamp, which reads as an instant rollback and hides
  # how long the readiness gate actually waited.
  printf '{"ts":"%s","outcome":"%s","detail":"%s","sprig":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "${SPRIG_DIGEST:-}" >>"${LOG_FILE}"
}

die() {
  log_json "$1" "$2"
  echo "buzz-agent-promote: $1: $2" >&2
  exit 1
}

compose() { (cd "${COMPOSE_DIR}" && ./run.sh "$@"); }

set_env_pin() {
  local pinned="$1" tmp
  tmp="$(mktemp)"
  awk -v repl="BUZZ_SPRIG_IMAGE=${pinned}" \
    '/^BUZZ_SPRIG_IMAGE=/ { print repl; found=1; next } { print } END { if (!found) print repl }' \
    "${ENV_FILE}" >"${tmp}"
  cat "${tmp}" >"${ENV_FILE}"
  rm -f "${tmp}"
}

# A seat is back only when its process reports the pool it was configured with.
# "Running" is not enough: a broken image restarts in a loop and still reads
# Running between crashes.
seat_ready() {
  local container="$1" since="$2" state
  state="$(docker inspect "${container}" --format '{{.State.Running}}' 2>/dev/null || echo false)"
  [[ "${state}" == "true" ]] || return 1
  docker logs --since "${since}" "${container}" 2>&1 | grep -q 'agent_pool_ready' || return 1
  return 0
}

wait_for_fleet() {
  local since="$1" deadline=$((SECONDS + READY_TIMEOUT)) seat image container service
  local -a pending
  while ((SECONDS < deadline)); do
    pending=()
    for seat in "${SEATS[@]}"; do
      IFS='|' read -r image container service <<<"${seat}"
      seat_ready "${container}" "${since}" || pending+=("${service}")
    done
    ((${#pending[@]} == 0)) && return 0
    sleep 5
  done
  NOT_READY="$(printf '%s ' "${pending[@]}")"
  return 1
}

[[ -e "${KILL_SWITCH}" ]] && { log_json skipped "kill switch present"; exit 0; }
[[ -e "${PROMOTE_SWITCH}" ]] || { log_json skipped "promotion not enabled (touch ${PROMOTE_SWITCH})"; exit 0; }
[[ -f "${ENV_FILE}" ]] || die error "missing ${ENV_FILE}"

# Only ever promote what the build check actually proved. `noop` counts: it
# means the images were already built green against this same sprig digest.
# Match the outcome field rather than grepping the whole line -- the noop
# message contains the word "green", so a line grep passed on its own prose.
BUILD_OUTCOME="$(awk '{print $2}' "${STATUS_FILE}" 2>/dev/null || true)"
[[ "${BUILD_OUTCOME}" == green || "${BUILD_OUTCOME}" == noop ]] ||
  die blocked "last build check was ${BUILD_OUTCOME:-missing}, not green: $(cat "${STATUS_FILE}" 2>/dev/null || echo missing)"

SPRIG_DIGEST="$(tail -n1 "${BUILD_LOG}" | sed -e 's/.*"sprig":"\([^"]*\)".*/\1/')"
[[ "${SPRIG_DIGEST}" == sha256:* ]] || die blocked "could not read the sprig digest the build check used"
SHORT="${SPRIG_DIGEST#sha256:}"; SHORT="${SHORT:0:12}"

# Every seat image must have a candidate from that same digest, or a promote
# would move part of the fleet and leave the rest behind -- the exact failure
# this script exists to prevent.
declare -A PREVIOUS=()
missing=()
for seat in "${SEATS[@]}"; do
  IFS='|' read -r image container service <<<"${seat}"
  if [[ -z "${FORCE_IMAGE}" ]] && ! docker image inspect "${image}:candidate-${SHORT}" >/dev/null 2>&1; then
    missing+=("${image}:candidate-${SHORT}")
  fi
  PREVIOUS["${image}"]="$(docker image inspect "${image}:latest" --format '{{.Id}}' 2>/dev/null || true)"
  [[ -n "${PREVIOUS["${image}"]}" ]] || die blocked "${image}:latest does not exist; refusing to promote without a rollback target"
done
((${#missing[@]} == 0)) || die blocked "missing candidates: $(printf '%s ' "${missing[@]}")"

ENV_BACKUP="${STATE_DIR}/backups/env-promote-${STAMP}"
mkdir -p "${STATE_DIR}/backups"
cp "${ENV_FILE}" "${ENV_BACKUP}"

restore() {
  local seat image container service
  cat "${ENV_BACKUP}" >"${ENV_FILE}"
  for seat in "${SEATS[@]}"; do
    IFS='|' read -r image container service <<<"${seat}"
    docker tag "${PREVIOUS["${image}"]}" "${image}:latest"
  done
  compose up -d --no-build goose-agent goose-crash goose-ed209 goose-mcp \
    goose-swordfish hermes-nikon pi-agent >/dev/null 2>&1 || true
}

set_env_pin "${SPRIG_REPO}:main@${SPRIG_DIGEST}"

for seat in "${SEATS[@]}"; do
  IFS='|' read -r image container service <<<"${seat}"
  docker tag "${FORCE_IMAGE:-${image}:candidate-${SHORT}}" "${image}:latest"
done

CUTOVER="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
log_json cutover "retagged 7 seat images to candidate-${SHORT}; recreating"

# `compose up` exits non-zero when a container it started has already died, and
# a broken image does exactly that. Under `set -e` an unguarded call here aborts
# the script *before* the gate and the rollback -- which is how a drill with a
# deliberately broken image left all seven seats down instead of restoring them.
# A failed `up` is an expected input to the gate below, not a reason to stop.
compose up -d --no-build goose-agent goose-crash goose-ed209 goose-mcp \
  goose-swordfish hermes-nikon pi-agent || true

if wait_for_fleet "${CUTOVER}"; then
  log_json promoted "all 7 seats report agent_pool_ready on candidate-${SHORT}"
  echo "buzz-agent-promote: promoted ${SHORT}"
  exit 0
fi

FAILED="${NOT_READY:-unknown}"
ROLLBACK_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
restore

if wait_for_fleet "${ROLLBACK_AT}"; then
  log_json rolled_back "candidate-${SHORT} left these seats not ready: ${FAILED}; fleet restored on the previous images"
  exit 1
fi

log_json rollback_failed "candidate AND rollback both failed; seats not ready: ${NOT_READY:-unknown}; manual action required, previous image ids in ${ENV_BACKUP}"
exit 2
