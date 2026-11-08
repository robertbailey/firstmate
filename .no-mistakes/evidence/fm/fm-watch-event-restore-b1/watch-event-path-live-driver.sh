#!/usr/bin/env bash
# Live driver: the real watcher's event_wait_or_sleep + real herdr adapter
# against a real isolated fm-lab-* Herdr session and a disposable lab FM_HOME.
# Usage: watch-event-path-live-driver.sh <code-root>
set -u
ROOT=$1
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
unset FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
SESSION="fm-lab-evoff-$$"
export HERDR_SESSION="$SESSION"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || { echo "lab home create failed"; exit 1; }
export FM_HOME="$LAB"
cleanup() { rm -rf "$LAB"; fm_herdr_lab_teardown "$SESSION" >/dev/null 2>&1 || echo "teardown problem"; }
trap cleanup EXIT
fm_herdr_lab_prepare "$SESSION" || { echo "lab prepare failed"; exit 1; }
export FM_POLL=2 FM_EVENT_CAP_RETRY_SECS=6
. "$ROOT/bin/fm-watch.sh"
fm_backend_source herdr || { echo "adapter source failed"; exit 1; }
wake() { printf 'WAKE: %s\n' "$1"; return 0; }
lab() { fm_herdr_lab_cli "$SESSION" "$@"; }
step() { printf '\n=== %s\n' "$*"; }
meta() { printf 'window=%s\nbackend=herdr\nkind=ship\n' "$2" > "$STATE/$1.meta"; }
triage() { cat "$STATE/.watch-triage.log" 2>/dev/null | sed 's/^/  triage| /'; }
echo "FM_HOME=$FM_HOME STATE=$STATE SESSION=$SESSION ROOT=$ROOT"

C=$(fm_backend_herdr_container_ensure /tmp); CONT=${C%%$'\t'*}; TAB=${C#*$'\t'}
mk() { local ids; ids=$(fm_backend_herdr_create_task "$CONT" "$1" /tmp "$2"); printf '%s' "${ids##*[[:space:]]}"; }
G1=$(mk evg1 "$TAB"); G2=$(mk evg2 ""); LIVE=$(mk evlive "")
for p in "$G1" "$G2" "$LIVE"; do lab pane report-agent "$p" --source fm-evtest --agent claude --state idle >/dev/null 2>&1; done
lab pane close "$G1" >/dev/null 2>&1; lab pane close "$G2" >/dev/null 2>&1
echo "gone panes: $G1 $G2 (presence: $(fm_backend_herdr_pane_presence_state "$SESSION" "$G1") $(fm_backend_herdr_pane_presence_state "$SESSION" "$G2")); live pane: $LIVE"

step "S1: only gone panes recorded -> 3 failed cycles must switch the event path off WITH a named cause"
meta tg1 "$SESSION:$G1"; meta tg2 "$SESSION:$G2"
for i in 1 2 3; do event_wait_or_sleep; echo "cycle $i: _event_cap_ok=$_event_cap_ok fails=$_event_cap_fails"; done
triage

step "S2: path off, same pane set -> next cycle polls only (no event wait)"
t0=$(date +%s); event_wait_or_sleep; echo "cycle took $(( $(date +%s) - t0 ))s, _event_cap_ok=$_event_cap_ok"

step "S3: a live task is added -> pane set change re-arms; gone panes dropped; live blocked edge wakes"
meta tlive "$SESSION:$LIVE"
( sleep 1; lab pane report-agent "$LIVE" --source fm-evtest --agent claude --state blocked >/dev/null 2>&1 ) &
t0=$(date +%s); event_wait_or_sleep; wait
echo "cycle took $(( $(date +%s) - t0 ))s, _event_cap_ok=$_event_cap_ok fails=$_event_cap_fails"
triage
echo "wake-queue:"; sed 's/^/  queue| /' "$STATE/.wake-queue" 2>/dev/null || echo "  (no wake-queue)"

step "S4: live task removed again -> gone-only set fails 3x -> off; after FM_EVENT_CAP_RETRY_SECS the timer re-arms (probation) and a repeat failure is named again"
rm -f "$STATE/tlive.meta"; : > "$STATE/.watch-triage.log"
for i in 1 2 3; do event_wait_or_sleep; done
echo "after 3 cycles: _event_cap_ok=$_event_cap_ok"
sleep 7
event_wait_or_sleep
echo "after timer cycle: _event_cap_ok=$_event_cap_ok"
triage
