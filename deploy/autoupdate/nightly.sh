#!/usr/bin/env bash
# One nightly entry point: relay update -> agent build check -> optional promote
# -> report.
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

STATE_DIR="${BUZZ_AUTOUPDATE_DIR:-/opt/buzz-autoupdate}"
BUILD_STATUS="${STATE_DIR}/agent-build.status"
PROMOTE_LOG="${STATE_DIR}/agent-promote.jsonl"
RELAY_LOG="${STATE_DIR}/updates.jsonl"
PROMOTE_SWITCH="${STATE_DIR}/PROMOTE_ENABLED"
REPORT_CONTAINER="${BUZZ_REPORT_CONTAINER:-buzz-prod-goose-swordfish-1}"
# Scheduled jobs. Owner's call 2026-08-17: every scheduled-job report lands here,
# not in Driftsautonomisering, so one channel is the whole cron surface.
REPORT_CHANNEL="${BUZZ_REPORT_CHANNEL:-950674b5-0f1f-412b-9389-f29c9b30584d}"
OWNER_PUBKEY="${BUZZ_REPORT_OWNER:-749745220321323ad9c340d92ea39e45028fadca474d5c726967f0f6e65450f9}"
# The relay line should be from the run this script just made. If it is not -- a
# relay job that died before logging, or someone running the report alone -- the
# line just stops moving, and stale is reported rather than accepted as tonight's
# result. Wider than the 24h period so a late or skipped run is not called stale.
RELAY_STALE_HOURS="${BUZZ_RELAY_STALE_HOURS:-30}"

last_detail() { # last_detail <jsonl> <field>
  [[ -s "$1" ]] || { printf 'ingen kjoringer\n'; return 0; }
  tail -n1 "$1" | sed -e "s/.*\"$2\":\"\([^\"]*\)\".*/\1/"
  return 0
}

age_hours() { # age_hours <iso8601-ts> -> whole hours, or empty if unparseable
  local when
  when="$(date -u -d "$1" +%s 2>/dev/null)" || return 0
  [[ -n "${when}" ]] || return 0
  printf '%s\n' "$(( ( $(date -u +%s) - when ) / 3600 ))"
  return 0
}

# Relay first, and from inside this script rather than on its own timer. The relay
# job used to fire 45 minutes AFTER this report, so the report's relay line was
# always the previous night's result -- it described a run that had not happened
# yet. Owner's call 2026-08-17: one job, one report, same window. The separate
# buzz-relay-autoupdate.timer is disabled; its .service unit is kept for manual
# and drill runs.
if [[ -x "${STATE_DIR}/relay-autoupdate.sh" ]]; then
  "${STATE_DIR}/relay-autoupdate.sh" >/dev/null 2>&1 || true
fi

# Stamped, because a relay job that dies before it logs leaves the previous line
# in place: without the timestamp that reads as tonight's result. A rollback drill
# from this morning looked exactly like an overnight failure the first time this
# report ran.
relay_ts="$(last_detail "${RELAY_LOG}" ts)"
relay_outcome="$(last_detail "${RELAY_LOG}" outcome)"
relay_age="$(age_hours "${relay_ts}")"
relay_line="${relay_ts} ${relay_outcome}: $(last_detail "${RELAY_LOG}" detail)"

build_check_exit=0
"${STATE_DIR}/agent-build-check.sh" >/dev/null 2>&1 || build_check_exit=$?

promote_outcome="off"
promote_line="ikke kjort (promotering er av)"
if [[ -e "${PROMOTE_SWITCH}" ]]; then
  # Promote's readiness gate waits for every seat to report agent_pool_ready, which
  # it cannot do while the relay is down. Promoting into that would fail the gate
  # and roll all seven seats back for a reason that has nothing to do with the
  # candidate -- a second, invented failure on top of the real one.
  if [[ "${relay_outcome}" == rollback_failed* ]]; then
    promote_outcome="hoppet_over"
    promote_line="hoppet over: relay er nede (${relay_outcome}), seter kan ikke naa agent_pool_ready"
  else
    "${STATE_DIR}/agent-promote.sh" >/dev/null 2>&1 || true
    promote_outcome="$(last_detail "${PROMOTE_LOG}" outcome)"
    promote_line="${promote_outcome}: $(last_detail "${PROMOTE_LOG}" detail)"
  fi
fi

build_status="$(cat "${BUILD_STATUS}" 2>/dev/null || echo 'ingen status')"
build_outcome="$(awk '{print $2}' <<<"${build_status}")"

# Three independent jobs, one headline. The headline is red if ANY of them is,
# because the first version of this report called the night green while the relay
# line right under it said the candidate had failed its gates and been rolled
# back -- a green headline over a red body is worse than no report at all.
# A `_drill` suffix means the job was run with a forced known-bad artifact to
# exercise its rollback. That is a rehearsal, not a production outcome, so it is
# labelled in the body and left out of the headline -- otherwise every drill
# turns the next report red and the report stops meaning anything.
bad=""
case "${build_outcome}" in green|noop) ;; *) bad="bygg=${build_outcome:-ukjent}" ;; esac
case "${promote_outcome}" in
  off|promoted) ;;
  *_drill) promote_line="${promote_line} [ovelse - tvunget image, ikke et produksjonsresultat]" ;;
  *) bad="${bad:+${bad} }promote=${promote_outcome}" ;;
esac
# A rollback is the guardrail working, not an outage -- but it means the relay is
# still on the old digest and someone has to look. Judged only while fresh: past
# the window the line is stale, which is its own red (a dead timer reports nothing
# and would otherwise show as green forever on its last good line).
if [[ -z "${relay_age}" ]]; then
  bad="${bad:+${bad} }relay=ingen-kjoringer"
  relay_line="ingen kjoringer"
elif (( relay_age > RELAY_STALE_HOURS )); then
  bad="${bad:+${bad} }relay=foreldet"
  relay_line="${relay_line} [${relay_age}t gammel - relay-timeren har ikke kjort]"
else
  case "${relay_outcome}" in
    deployed|noop) ;;
    *_drill) relay_line="${relay_line} [ovelse - tvunget digest, ikke et produksjonsresultat]" ;;
    *) bad="${bad:+${bad} }relay=${relay_outcome}" ;;
  esac
fi

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

# BUZZ_REPORT_DRYRUN prints the message instead of sending it. This exists because
# every defect this script has ever had was found by running it, and without a way
# to see the rendered report you cannot check the headline without spamming the
# channel.
if [[ -n "${BUZZ_REPORT_DRYRUN:-}" ]]; then
  printf '%s\n' "${body}"
  printf -- '--- ville sendt til kanal %s, mention: %s\n' "${REPORT_CHANNEL}" "${mention[*]:-ingen}"
else
  printf '%s' "${body}" | docker exec -i "${REPORT_CONTAINER}" \
    buzz messages send --channel "${REPORT_CHANNEL}" --content - "${mention[@]}" \
    >>"${STATE_DIR}/report.log" 2>&1 ||
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) report send FAILED" >>"${STATE_DIR}/report.log"
fi

exit "${build_check_exit}"
