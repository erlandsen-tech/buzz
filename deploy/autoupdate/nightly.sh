#!/usr/bin/env bash
# One nightly entry point: build check -> optional promote -> report.
#
# The reporting half is the point. Before this existed both jobs wrote their
# outcome to a jsonl file on the VM and nothing else, so a red night was
# invisible until somebody thought to go look. A job whose failure nobody sees
# is not a guardrail.
#
# The report is posted by the Swordfish seat because the VM host has no buzz
# CLI and no identity of its own, and because a Nostr channel only accepts
# messages from its members -- Condor's own key is not on this machine.
set -uo pipefail

STATE_DIR=/opt/buzz-autoupdate
BUILD_STATUS="${STATE_DIR}/agent-build.status"
PROMOTE_LOG="${STATE_DIR}/agent-promote.jsonl"
RELAY_LOG="${STATE_DIR}/updates.jsonl"
PROMOTE_SWITCH="${STATE_DIR}/PROMOTE_ENABLED"
REPORT_CONTAINER="${BUZZ_REPORT_CONTAINER:-buzz-prod-goose-swordfish-1}"
REPORT_CHANNEL="${BUZZ_REPORT_CHANNEL:-76686747-a635-4eb8-bd7c-691dcc782387}"
OWNER_PUBKEY="${BUZZ_REPORT_OWNER:-749745220321323ad9c340d92ea39e45028fadca474d5c726967f0f6e65450f9}"

last_detail() { # last_detail <jsonl> <field>
  [[ -s "$1" ]] || { printf 'ingen kjoringer\n'; return; }
  tail -n1 "$1" | sed -e "s/.*\"$2\":\"\([^\"]*\)\".*/\1/"
}

build_check_exit=0
"${STATE_DIR}/agent-build-check.sh" >/dev/null 2>&1 || build_check_exit=$?

promote_outcome="off"
promote_line="ikke kjort (promotering er av)"
if [[ -e "${PROMOTE_SWITCH}" ]]; then
  "${STATE_DIR}/agent-promote.sh" >/dev/null 2>&1 || true
  promote_outcome="$(last_detail "${PROMOTE_LOG}" outcome)"
  promote_line="${promote_outcome}: $(last_detail "${PROMOTE_LOG}" detail)"
fi

build_status="$(cat "${BUILD_STATUS}" 2>/dev/null || echo 'ingen status')"
build_outcome="$(awk '{print $2}' <<<"${build_status}")"
# Stamped, because the relay job runs on its own timer: without the timestamp a
# months-old line reads as tonight's result. A rollback drill from this morning
# looked exactly like an overnight failure the first time this report ran.
relay_line="$(last_detail "${RELAY_LOG}" ts) $(last_detail "${RELAY_LOG}" outcome): $(last_detail "${RELAY_LOG}" detail)"

bad=""
case "${build_outcome}" in green|noop) ;; *) bad="bygg=${build_outcome:-ukjent}" ;; esac
case "${promote_outcome}" in off|promoted) ;; *) bad="${bad:+${bad} }promote=${promote_outcome}" ;; esac

if [[ -z "${bad}" ]]; then
  headline="Nattlig autoupdate: **gronn**."
else
  headline="@John Inge Nattlig autoupdate: **${bad}** — se detaljene under."
fi

body="$(
  printf '%s\n\n' "${headline}"
  printf '```\n'
  printf 'agent-bygg   %s\n' "${build_status}"
  printf 'promote      %s\n' "${promote_line}"
  printf 'relay        %s\n' "${relay_line}"
  printf '```\n'
  if [[ -n "${bad}" ]]; then
    printf '\nLogger paa VM-en: `%s/build-*.log`, `%s/smoke-*.log`, `%s/agent-promote.jsonl`.\n' \
      "${STATE_DIR}" "${STATE_DIR}" "${STATE_DIR}"
  fi
)"

# A red night must reach a human, so mention the owner only when it is red --
# a nightly green that pings him every morning trains him to ignore the ping.
mention=()
[[ -n "${bad}" ]] && mention=(--mention "${OWNER_PUBKEY}")

printf '%s' "${body}" | docker exec -i "${REPORT_CONTAINER}" \
  buzz messages send --channel "${REPORT_CHANNEL}" --content - "${mention[@]}" \
  >>"${STATE_DIR}/report.log" 2>&1 ||
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) report send FAILED" >>"${STATE_DIR}/report.log"

exit "${build_check_exit}"
