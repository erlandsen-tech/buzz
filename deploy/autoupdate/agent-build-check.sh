#!/usr/bin/env bash
# Nightly build-and-test of the agent images against the newest upstream sprig.
#
# Deliberately does NOT deploy. The agent containers are the crew; a 04:30
# rebuild that breaks Hermes, ED-209 and Swordfish at once leaves nobody able to
# fix it. This job only answers "could we upgrade right now if we wanted to?",
# so promotion stays a manual, awake-human decision.
set -euo pipefail

STATE_DIR=/opt/buzz-autoupdate
REPO_DIR=/opt/buzz-selfhost
LOG_FILE="${STATE_DIR}/agent-build.jsonl"
STATUS_FILE="${STATE_DIR}/agent-build.status"
KILL_SWITCH="${STATE_DIR}/DISABLED"
SPRIG_REPO=ghcr.io/block/buzz-sprig
MIN_FREE_MB=20000
KEEP_CANDIDATES=2

# dockerfile|image|smoke-command. The three seats ship different runtimes --
# goose has no place in the Hermes image and neither goose nor node exists in
# the pi image -- so each target asserts only the binaries it actually needs.
TARGETS=(
  "Dockerfile.goose|buzz-prod-goose-agent|goose --version >/dev/null; node --version >/dev/null; pnpm --version >/dev/null"
  "Dockerfile.hermes|buzz-prod-goose-hermes|node --version >/dev/null; npm --version >/dev/null; command -v uv >/dev/null; command -v hermes-agent-entrypoint >/dev/null"
  "Dockerfile.pi|buzz-prod-pi-agent|command -v pi >/dev/null; command -v pi-acp >/dev/null; command -v pi-agent-entrypoint >/dev/null"
)

# Asserted for every seat: the ACP runtime the entrypoint execs into.
COMMON_SMOKE='command -v sprig-entrypoint >/dev/null; command -v buzz-acp >/dev/null; command -v buzz >/dev/null'

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

log_json() {
  printf '{"ts":"%s","outcome":"%s","detail":"%s","sprig":"%s"}\n' \
    "${TS}" "$1" "$2" "${SPRIG_DIGEST:-}" >>"${LOG_FILE}"
  printf '%s %s %s\n' "${TS}" "$1" "$2" >"${STATUS_FILE}"
}

die() {
  log_json "$1" "$2"
  echo "buzz-agent-build-check: $1: $2" >&2
  exit 1
}

[[ -e "${KILL_SWITCH}" ]] && { log_json skipped "kill switch present"; exit 0; }

FREE_MB="$(df -Pm / | awk 'NR==2{print $4}')"
((FREE_MB >= MIN_FREE_MB)) || die blocked "only ${FREE_MB}MB free on /, need ${MIN_FREE_MB}MB to build"

# buzz-sprig publishes a floating `main` tag; resolve it to an immutable digest
# so the build and its log entry refer to exactly one image.
TOKEN="$(curl -sf --max-time 20 "https://ghcr.io/token?scope=repository:block/buzz-sprig:pull" |
  sed -e 's/.*"token":"\([^"]*\)".*/\1/')"
[[ -n "${TOKEN}" ]] || die blocked "could not get a ghcr pull token"

SPRIG_DIGEST="$(curl -sf --max-time 20 -D - -o /dev/null \
  -H "Authorization: Bearer ${TOKEN}" \
  -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json' \
  "https://ghcr.io/v2/block/buzz-sprig/manifests/main" | tr -d '\r' |
  awk 'tolower($1)=="docker-content-digest:"{print $2}')"
[[ "${SPRIG_DIGEST}" == sha256:* ]] || die blocked "could not resolve ${SPRIG_REPO}:main"

SHORT="${SPRIG_DIGEST#sha256:}"; SHORT="${SHORT:0:12}"
SPRIG_REF="${SPRIG_REPO}:main@${SPRIG_DIGEST}"

# Nothing upstream changed and the last run was green -> no reason to rebuild.
if [[ -f "${STATUS_FILE}" ]] && grep -q " green " "${STATUS_FILE}" &&
  grep -q "\"sprig\":\"${SPRIG_DIGEST}\"" "${LOG_FILE}" 2>/dev/null; then
  log_json noop "already built green against this sprig"
  exit 0
fi

cd "${REPO_DIR}"

failures=()
built=()

for target in "${TARGETS[@]}"; do
  IFS='|' read -r dockerfile image smoke <<<"${target}"
  tag="${image}:candidate-${SHORT}"

  if [[ ! -f "${dockerfile}" ]]; then
    failures+=("${dockerfile} missing")
    continue
  fi

  if ! docker build --pull --build-arg "SPRIG_IMAGE=${SPRIG_REF}" \
    -f "${dockerfile}" -t "${tag}" . >"${STATE_DIR}/build-${image}.log" 2>&1; then
    failures+=("${dockerfile} failed to build (see ${STATE_DIR}/build-${image}.log)")
    continue
  fi

  # Smoke test: the toolchain the entrypoint depends on must actually run. A
  # build that succeeds but ships a broken musl/glibc mix passes `docker build`
  # and then crash-loops the seat, so assert the binaries execute.
  if ! docker run --rm --entrypoint sh "${tag}" -c \
    "set -e; ${COMMON_SMOKE}; ${smoke}" \
    >"${STATE_DIR}/smoke-${image}.log" 2>&1; then
    failures+=("${image} built but failed its smoke test (see ${STATE_DIR}/smoke-${image}.log)")
    continue
  fi

  built+=("${tag}")
done

# Keep a couple of candidates for manual promotion; drop the rest so nightly
# builds cannot fill the disk.
for target in "${TARGETS[@]}"; do
  IFS='|' read -r _ image _ <<<"${target}"
  docker images --format '{{.Repository}}:{{.Tag}} {{.ID}}' |
    awk -v img="${image}" '$1 ~ "^"img":candidate-" {print $1}' |
    tail -n "+$((KEEP_CANDIDATES + 1))" |
    xargs -r -n1 docker rmi -f >/dev/null 2>&1 || true
done

if ((${#failures[@]} > 0)); then
  die red "$(printf '%s; ' "${failures[@]}")candidates built: ${#built[@]}/${#TARGETS[@]}"
fi

log_json green "all ${#TARGETS[@]} agent images build and smoke-test against sprig main; promote manually with: docker tag <candidate> <image>:latest && run.sh up -d"
echo "buzz-agent-build-check: green against ${SPRIG_REF}"
