#!/usr/bin/env bash
# Nightly build-and-test of the agent images against the newest upstream sprig.
#
# This script never deploys. It answers "could we upgrade right now if we
# wanted to?" and stops there. Deploying is agent-promote.sh's job, gated on
# PROMOTE_ENABLED, because a rebuild that breaks Hermes, ED-209 and Swordfish
# at once leaves nobody able to fix it -- so that step carries its own
# readiness gate and its own rollback. nightly.sh runs the two in order.
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

# Five of the seven seats build from the same Dockerfile.goose, but only
# `goose-agent` declares an `image:` matching the primary target above. Compose
# names the other four <project>-<service>, so they are separate image *names*
# carrying identical content. Building once and tagging the result onto all of
# them is what makes a later promote reach the whole fleet -- tagging only the
# primary upgrades 3 of 7 seats and splits the fleet across two buzz-acp
# versions with no error anywhere. image|alias alias...
ALIASES=(
  "buzz-prod-goose-agent|buzz-prod-goose-crash buzz-prod-goose-ed209 buzz-prod-goose-mcp buzz-prod-goose-swordfish"
)

# Every image name a promote must touch, primaries and aliases together.
all_images() {
  local target image aliasrow primary rest
  for target in "${TARGETS[@]}"; do
    IFS='|' read -r _ image _ <<<"${target}"
    printf '%s\n' "${image}"
    for aliasrow in "${ALIASES[@]}"; do
      IFS='|' read -r primary rest <<<"${aliasrow}"
      [[ "${primary}" == "${image}" ]] && printf '%s\n' ${rest}
    done
  done
}

aliases_of() {
  local aliasrow primary rest
  for aliasrow in "${ALIASES[@]}"; do
    IFS='|' read -r primary rest <<<"${aliasrow}"
    [[ "${primary}" == "$1" ]] && printf '%s\n' ${rest}
  done
}

# Asserted for every seat: the ACP runtime the entrypoint execs into.
COMMON_SMOKE='command -v sprig-entrypoint >/dev/null; command -v buzz-acp >/dev/null; command -v buzz >/dev/null'


log_json() {
  printf '{"ts":"%s","outcome":"%s","detail":"%s","sprig":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "${SPRIG_DIGEST:-}" >>"${LOG_FILE}"
  printf '%s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" >"${STATUS_FILE}"
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

  # Same content, other seats' image names, so a promote can retag all seven.
  while read -r alias_image; do
    [[ -n "${alias_image}" ]] || continue
    docker tag "${tag}" "${alias_image}:candidate-${SHORT}"
  done < <(aliases_of "${image}")
done

# Keep a couple of candidates for manual promotion; drop the rest so nightly
# builds cannot fill the disk.
while read -r image; do
  docker images --format '{{.Repository}}:{{.Tag}} {{.ID}}' |
    awk -v img="${image}" '$1 ~ "^"img":candidate-" {print $1}' |
    tail -n "+$((KEEP_CANDIDATES + 1))" |
    xargs -r -n1 docker rmi -f >/dev/null 2>&1 || true
done < <(all_images)

if ((${#failures[@]} > 0)); then
  die red "$(printf '%s; ' "${failures[@]}")candidates built: ${#built[@]}/${#TARGETS[@]}"
fi

IMAGE_COUNT="$(all_images | wc -l | tr -d ' ')"
log_json green "${#TARGETS[@]} builds cover ${IMAGE_COUNT} seat images and all smoke-test against sprig main; promote with ${STATE_DIR}/agent-promote.sh (never a bare docker tag -- that reaches 3 of ${IMAGE_COUNT})"
echo "buzz-agent-build-check: green against ${SPRIG_REF}"
