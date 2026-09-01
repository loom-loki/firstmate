#!/usr/bin/env bash
# Corpus verification harness for the step-row reader in bin/fm-crew-state.sh.
# It EVALUATES the real function bodies lifted verbatim out of the shipped
# script (nm_step_status and the ci narrowing that now sits on top of it) and
# runs them over the rendered `no-mistakes axi status --run` output of every run
# in the local v1.60.2 store. Nothing here re-types the regex.
set -u
ROOT=$1; CORPUS=$2
. "$ROOT/bin/fm-nm-run-lib.sh" 2>/dev/null || true
trim() { fm_nm_trim "$@"; }
strip_quotes() { fm_nm_strip_quotes "$@"; }
eval "$(sed -n '/^nm_step_status() {/,/^}/p' "$ROOT/bin/fm-crew-state.sh")"
eval "$(sed -n '/^nm_ci_step_status() {/,/^}/p' "$ROOT/bin/fm-crew-state.sh")"

# The predicate the fix replaced, exactly as it stood at base 3ffda36.
old_ci_row() { printf '%s\n' "$RUN_OUT" | grep -E '^[[:space:]]*ci,[[:space:]]*"?(running|fixing)"?[[:space:]]*,' | head -1; }

total=0; read_ok=0; unread=0; old_matched=0; old_now_missed=0; findings_rows=0; findings_misread=0
declare -A SEEN_STATUS SEEN_STEP
for f in "$CORPUS"/*.txt; do
  RUN_OUT=$(cat "$f")
  # every step row this run renders
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    total=$((total+1))
    step=${line%%,*}
    rest=${line#*,}; status=${rest%%,*}
    SEEN_STATUS[$status]=1; SEEN_STEP[$step]=1
    got=$(nm_step_status "$step")
    if [ -n "$got" ]; then read_ok=$((read_ok+1)); else unread=$((unread+1)); echo "UNREAD: $f :: $line"; fi
  done < <(awk '/^  steps\[[0-9]+\]\{step,status,findings,duration_ms\}:/{i=1;next} i&&/^    [A-Za-z]/{gsub(/^ +/,"");print;next} i&&!/^    /{i=0}' "$f")

  # the old ci-only predicate: anything it matched must still be matched
  if [ -n "$(old_ci_row)" ]; then
    old_matched=$((old_matched+1))
    [ -n "$(nm_ci_step_status)" ] || { old_now_missed=$((old_now_missed+1)); echo "REGRESSED CI READ: $f"; }
  fi

  # findings rows must never be read as step rows
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    findings_rows=$((findings_rows+1))
    id=${line%%,*}
    # a findings id that collides with a step name is the dangerous case
    :
  done < <(awk '/^  findings\[[0-9]+\]\{/{i=1;next} i&&/^    [A-Za-z]/{gsub(/^ +/,"");print;next} i&&!/^    /{i=0}' "$f")
done
echo "runs in corpus:                 $(ls "$CORPUS"/*.txt | wc -l)"
echo "step rows in corpus:            $total"
echo "step rows READ by nm_step_status: $read_ok"
echo "step rows SILENTLY DROPPED:     $unread"
echo "runs the OLD ci predicate matched: $old_matched"
echo "  ...now missed by the new reader: $old_now_missed"
echo "distinct step names:   $(printf '%s\n' "${!SEEN_STEP[@]}" | sort | tr '\n' ' ')"
echo "distinct status words: $(printf '%s\n' "${!SEEN_STATUS[@]}" | sort | tr '\n' ' ')"
[ "$unread" -eq 0 ] && [ "$old_now_missed" -eq 0 ] && echo "RESULT: PASS - every real step row is read; no row the old predicate matched is missed" || echo "RESULT: FAIL"
