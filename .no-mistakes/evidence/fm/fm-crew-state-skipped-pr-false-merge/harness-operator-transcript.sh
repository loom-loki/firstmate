#!/usr/bin/env bash
# Operator-surface transcript: what `bin/fm-crew-state.sh <crew-id>` actually
# PRINTS for two REAL no-mistakes runs, served byte-for-byte from the local
# v1.60.2 store (only branch/head are rebound so the run binds to a throwaway
# worktree, exactly as it would for the live crew).
set -u
IMPL_ROOT=$1; LABEL=$2
d=$(mktemp -d /tmp/fm-op-XXXX)
mkdir -p "$d/fakebin" "$d/state" "$d/wt"
cat > "$d/fakebin/no-mistakes" <<'NM'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  axi) shift; case "${1:-}" in
    status) shift; if [ "${1:-}" = --run ]; then printf '%s\n' "${FM_FAKE_AXI_STATUS_RUN:-}"; else printf '%s\n' "${FM_FAKE_AXI_STATUS:-}"; fi ;;
    logs) printf '%s\n' "${FM_FAKE_CI_LOGS:-}" ;; esac ;;
  runs) printf '%s\n' "${FM_FAKE_RUNS_LIST:-}" ;;
esac
exit 0
NM
cat > "$d/fakebin/tmux" <<'TM'
#!/usr/bin/env bash
case "${1:-}" in display-message) printf '%%1\n';; capture-pane) printf 'all quiet\n> \n';; esac
exit 0
TM
chmod +x "$d/fakebin/no-mistakes" "$d/fakebin/tmux"

emit_for_run() {  # <run-file> <crew-id> <branch>
  local file=$1 id=$2 branch=$3 head
  git -C "$d/wt" init -q 2>/dev/null
  git -C "$d/wt" -c user.email=t@t.invalid -c user.name=t commit -q --allow-empty -m init 2>/dev/null
  git -C "$d/wt" checkout -q -B "$branch"
  head=$(git -C "$d/wt" rev-parse HEAD)
  printf 'window=fm:fm-%s\nworktree=%s\nkind=ship\n' "$id" "$d/wt" > "$d/state/$id.meta"
  local out
  out=$(sed -E "s|^  branch: .*|  branch: $branch|; s|^  head: .*|  head: \"$head\"|" "$file")
  PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE="$d/state" \
    FM_FAKE_AXI_STATUS="$out" "$IMPL_ROOT/bin/fm-crew-state.sh" "$id"
}

echo "########## $LABEL ##########"
echo
echo "--- real run 01M1EA5NJVP18AE7SPY5MBYW42 (pr,skipped / ci,skipped; forge said state=open, merged=false) ---"
grep -E '^    (pr|ci),|^outcome:' /tmp/nm-corpus/01M1EA5NJVP18AE7SPY5MBYW42.txt | sed 's/^/    axi status says: /'
echo "  \$ bin/fm-crew-state.sh karyo-keycloak"
echo -n "  "; emit_for_run /tmp/nm-corpus/01M1EA5NJVP18AE7SPY5MBYW42.txt karyo-keycloak fm/karyo-keycloak-prod-realm-demo-users
echo
echo "--- real run 01M1669Y82JTHWEBSG7PR2TKNH (pr,completed; the pipeline genuinely merged PR 6) ---"
grep -E '^    (pr|ci),|^outcome:|^  pr:' /tmp/nm-corpus/01M1669Y82JTHWEBSG7PR2TKNH.txt | sed 's/^/    axi status says: /'
echo "  \$ bin/fm-crew-state.sh corpus-repin"
echo -n "  "; emit_for_run /tmp/nm-corpus/01M1669Y82JTHWEBSG7PR2TKNH.txt corpus-repin fm/corpus-repin-hive-v040
echo
rm -rf "$d"
