#!/usr/bin/env bash
# Drives nightly.sh against fabricated state and prints the headline it produced.
# Nothing is sent: BUZZ_REPORT_DRYRUN is set for every case.
set -uo pipefail

NIGHTLY="${1:?path to nightly.sh}"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "${SANDBOX}"' EXIT

# Stubs: the report is what is under test, not the two jobs it wraps.
printf '#!/bin/sh\nexit 0\n' >"${SANDBOX}/agent-build-check.sh"
printf '#!/bin/sh\nexit 0\n' >"${SANDBOX}/agent-promote.sh"
chmod +x "${SANDBOX}/agent-build-check.sh" "${SANDBOX}/agent-promote.sh"

now() { date -u -d "-$1 hours" +%Y-%m-%dT%H:%M:%SZ; }

relay_line() { # relay_line <outcome> <age-hours>
  printf '{"ts":"%s","outcome":"%s","detail":"detalj for %s","running":"sha256:aaa","candidate":"sha256:bbb"}\n' \
    "$(now "$2")" "$1" "$1"
}

setup() { # setup <build-outcome> <promote-outcome> <relay-outcome> <relay-age-h>
  printf '%s %s tekst fra byggejobben\n' "$(now 0)" "$1" >"${SANDBOX}/agent-build.status"
  if [[ "$2" == "off" ]]; then
    rm -f "${SANDBOX}/PROMOTE_ENABLED" "${SANDBOX}/agent-promote.jsonl"
  else
    : >"${SANDBOX}/PROMOTE_ENABLED"
    printf '{"ts":"%s","outcome":"%s","detail":"detalj for %s"}\n' "$(now 0)" "$2" "$2" \
      >"${SANDBOX}/agent-promote.jsonl"
  fi
  if [[ "$3" == "tom" ]]; then
    : >"${SANDBOX}/updates.jsonl"
  else
    relay_line "$3" "$4" >"${SANDBOX}/updates.jsonl"
  fi
}

run_case() { # run_case <navn> <forventet-overskrift-fragment> <build> <promote> <relay> <alder>
  local name="$1" expect="$2"
  setup "$3" "$4" "$5" "$6"
  local out headline
  out="$(BUZZ_AUTOUPDATE_DIR="${SANDBOX}" BUZZ_REPORT_DRYRUN=1 bash "${NIGHTLY}" 2>&1)"
  headline="$(head -n1 <<<"${out}")"
  if [[ "${headline}" == *"${expect}"* ]]; then
    printf 'PASS  %-34s %s\n' "${name}" "${headline}"
  else
    printf 'FAIL  %-34s ventet «%s», fikk «%s»\n' "${name}" "${expect}" "${headline}"
    printf '%s\n' "${out}" | sed 's/^/      /'
    FAILED=1
  fi
}

FAILED=0
run_case alt-gronn                 'gronn'                 noop   promoted        deployed        0
run_case relay-rullet-tilbake      'relay=rolled_back'     noop   promoted        rolled_back     2
run_case relay-pull-feilet         'relay=failed_pull'     green  promoted        failed_pull     1
run_case relay-rollback-feilet     'relay=rollback_failed' noop   promoted        rollback_failed 3
run_case relay-foreldet            'relay=foreldet'        noop   promoted        deployed        40
run_case relay-ingen-kjoringer     'relay=ingen-kjoringer' noop   promoted        tom             0
run_case promote-blokkert          'promote=blocked'       noop   blocked         deployed        0
run_case bygg-feilet               'bygg=failed'           failed promoted        deployed        0
run_case alle-tre-rode             'bygg=failed promote=rolled_back relay=rolled_back' \
                                                           failed rolled_back     rolled_back     5
run_case promote-av-ellers-gronn   'gronn'                 noop   off             noop            12
run_case relay-ovelse-ikke-rod      'gronn'                 noop   promoted        rolled_back_drill 2
run_case promote-ovelse-ikke-rod    'gronn'                 noop   rolled_back_drill deployed      0

# The reported defect, spelled out: the body must not contradict the headline.
setup noop promoted rolled_back 2
body="$(BUZZ_AUTOUPDATE_DIR="${SANDBOX}" BUZZ_REPORT_DRYRUN=1 bash "${NIGHTLY}" 2>&1)"
if grep -q 'gronn' <<<"${body}" && grep -q 'rolled_back' <<<"${body}"; then
  printf 'FAIL  %-34s gronn overskrift over rullet-tilbake kropp\n' "ingen-gronn-over-rod-kropp"
  FAILED=1
else
  printf 'PASS  %-34s ingen gronn overskrift nar kroppen er rod\n' "ingen-gronn-over-rod-kropp"
fi
if grep -q -- '--mention 7497452' <<<"${body}"; then
  printf 'PASS  %-34s eier nevnt pa rod natt\n' "mention-pa-rod"
else
  printf 'FAIL  %-34s eier ikke nevnt pa rod natt\n' "mention-pa-rod"; FAILED=1
fi
if grep -q '950674b5-0f1f-412b-9389-f29c9b30584d' <<<"${body}"; then
  printf 'PASS  %-34s rapporterer til Scheduled jobs\n' "kanal"
else
  printf 'FAIL  %-34s feil kanal\n' "kanal"; FAILED=1
fi

# nightly.sh must drive the relay job itself now, not read a line some other timer
# left behind. Sandbox gets a stub relay job; the report must show ITS line.
cat >"${SANDBOX}/relay-autoupdate.sh" <<'STUB'
#!/bin/sh
printf '{"ts":"%s","outcome":"deployed","detail":"stub relay-jobb kjorte","running":"sha256:aaa","candidate":"sha256:aaa"}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$(dirname "$0")/updates.jsonl"
STUB
chmod +x "${SANDBOX}/relay-autoupdate.sh"
setup noop promoted rolled_back 20
body="$(BUZZ_AUTOUPDATE_DIR="${SANDBOX}" BUZZ_REPORT_DRYRUN=1 bash "${NIGHTLY}" 2>&1)"
if grep -q 'stub relay-jobb kjorte' <<<"${body}" && grep -q 'gronn' <<<"${body}"; then
  printf 'PASS  %-34s relay-jobben kjores av nightly, fersk linje brukt\n' "relay-kjores-inline"
else
  printf 'FAIL  %-34s nightly kjorte ikke relay-jobben\n' "relay-kjores-inline"
  printf '%s\n' "${body}" | sed 's/^/      /'; FAILED=1
fi

# Relay down => promote must not run: its gate needs the relay to reach the seats.
cat >"${SANDBOX}/relay-autoupdate.sh" <<'STUB'
#!/bin/sh
printf '{"ts":"%s","outcome":"rollback_failed","detail":"kandidat og tilbakerulling feilet","running":"sha256:aaa","candidate":"sha256:bbb"}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$(dirname "$0")/updates.jsonl"
STUB
printf '#!/bin/sh\ntouch "$(dirname "$0")/PROMOTE_RAN"\nexit 0\n' >"${SANDBOX}/agent-promote.sh"
chmod +x "${SANDBOX}/relay-autoupdate.sh" "${SANDBOX}/agent-promote.sh"
setup noop promoted deployed 0
rm -f "${SANDBOX}/PROMOTE_RAN"
body="$(BUZZ_AUTOUPDATE_DIR="${SANDBOX}" BUZZ_REPORT_DRYRUN=1 bash "${NIGHTLY}" 2>&1)"
if [[ ! -e "${SANDBOX}/PROMOTE_RAN" ]] && grep -q 'hoppet over: relay er nede' <<<"${body}"; then
  printf 'PASS  %-34s promote hoppet over nar relay er nede\n' "promote-hoppes-over"
else
  printf 'FAIL  %-34s promote kjorte med relay nede\n' "promote-hoppes-over"
  printf '%s\n' "${body}" | sed 's/^/      /'; FAILED=1
fi

printf '\n%s\n' "$([[ ${FAILED} -eq 0 ]] && echo 'ALLE TESTER GRONNE' || echo 'TESTER FEILET')"
exit "${FAILED}"
