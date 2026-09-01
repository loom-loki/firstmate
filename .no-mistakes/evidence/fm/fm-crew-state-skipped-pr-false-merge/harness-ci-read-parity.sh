#!/usr/bin/env bash
# Old-vs-new parity for the ci read, over REAL run output. The live store holds
# only terminal runs, so no row is natively `ci,running`/`ci,fixing` - the two
# values the replaced predicate existed to catch. This rewrites the real ci row
# of every real run to each of those values and asserts the new reader returns
# exactly what the old predicate did, on the real surrounding output.
set -u
ROOT=$1; CORPUS=$2
. "$ROOT/bin/fm-nm-run-lib.sh" 2>/dev/null || true
trim() { fm_nm_trim "$@"; }
strip_quotes() { fm_nm_strip_quotes "$@"; }
eval "$(sed -n '/^nm_step_status() {/,/^}/p' "$ROOT/bin/fm-crew-state.sh")"
eval "$(sed -n '/^nm_ci_step_status() {/,/^}/p' "$ROOT/bin/fm-crew-state.sh")"

# base 3ffda36's nm_ci_step_status, verbatim.
old_nm_ci_step_status() {
  local row rest
  row=$(printf '%s\n' "$RUN_OUT" | grep -E '^[[:space:]]*ci,[[:space:]]*"?(running|fixing)"?[[:space:]]*,' | head -1)
  [ -n "$row" ] || return 0
  row=$(trim "$row")
  rest=${row#*,}
  strip_quotes "$(trim "${rest%%,*}")"
}

cases=0; agree=0; disagree=0
for f in "$CORPUS"/*.txt; do
  orig=$(cat "$f")
  for v in running fixing completed skipped pending failed queued needs-attention; do
    RUN_OUT=$(printf '%s\n' "$orig" | sed -E "s/^(    ci,)[A-Za-z0-9_-]+,/\1$v,/")
    printf '%s\n' "$RUN_OUT" | grep -qE '^    ci,' || continue
    cases=$((cases+1))
    o=$(old_nm_ci_step_status); n=$(nm_ci_step_status)
    if [ "$o" = "$n" ]; then agree=$((agree+1)); else disagree=$((disagree+1)); echo "DISAGREE $f ci=$v old='$o' new='$n'"; fi
  done
done
echo "ci-status cases exercised over real run output: $cases"
echo "old predicate and new reader agree:             $agree"
echo "disagreements:                                  $disagree"
[ "$disagree" -eq 0 ] && echo "RESULT: PASS - the ci read is behaviour-identical to the predicate it replaced" || echo "RESULT: FAIL"
