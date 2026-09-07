#!/usr/bin/env bash
# Behavior tests for the tracked-project case of Claude's per-task hook wiring
# file, whose contract bin/fm-claude-settings-lib.sh owns.
#
# A project may legitimately TRACK .claude/settings.local.json. Before this
# contract existed, spawn overwrote it (destroying committed project settings)
# and the resulting modification read to teardown as unlanded worker work,
# because the .git/info/exclude entry that hides the untracked case does
# nothing for a tracked path.
#
# Every case drives the real bin/fm-spawn.sh and bin/fm-teardown.sh against a
# scratch project that tracks the file, with a fake tmux pane, so the merge,
# the recorded bytes, the uncommitted-work test, and the restore are exercised
# together end to end.
#
# Matrix:
#   (a) tracked settings + spawn      -> unrelated keys and project hook
#                                        entries survive, task hooks appended
#   (b) tracked settings + teardown   -> cleanup succeeds and the tracked file
#                                        is restored byte-identical
#   (c) tracked settings + a change firstmate did not write -> teardown REFUSES
#   (d) malformed tracked settings    -> spawn REFUSES and leaves it untouched
#   (e) untracked settings            -> unchanged plain write and removal
#
# The untracked relaunch retirement stays with tests/fm-control-relaunch.test.sh,
# which already owns the harness-switch wiring fixtures.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

fm_git_identity fmtest fmtest@example.invalid

TMP_ROOT=$(fm_test_tmproot fm-claude-settings)
SETTINGS_REL='.claude/settings.local.json'

# A tracked settings file the project owns: one unrelated key plus a hook entry
# of its own, so a merge that silently replaced `hooks` would be visible.
PROJECT_SETTINGS='{"enabledMcpjsonServers":["stitch"],"hooks":{"Stop":[{"hooks":[{"type":"command","command":"project-own-stop"}]}]}}'

# make_case <name> [settings-content]
# Builds home + project + task worktree. With <settings-content>, the project
# TRACKS .claude/settings.local.json carrying it, committed before the bare
# origin is cloned so the spawn's base refresh keeps it. Echoes
# "<home>|<project>|<worktree>|<fakebin>".
make_case() {
  local name=$1 settings=${2-} case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  mkdir -p "$case_dir"

  fakebin=$(fm_fakebin "$case_dir/fake")
  fm_test_fake_tmux_spawn "$fakebin"
  fm_test_fake_no_mistakes "$fakebin"
  fm_test_fake_gh "$fakebin"
  fm_test_fake_gh_axi "$fakebin"
  fm_fake_exit0 "$fakebin" treehouse claude
  fm_test_spawn_home "$home" claude

  fm_git_init_commit "$proj"
  if [ -n "$settings" ]; then
    mkdir -p "$proj/.claude"
    printf '%s\n' "$settings" > "$proj/$SETTINGS_REL"
    # -f because a machine-level global ignore for this path is common and
    # would otherwise make the fixture silently untracked.
    git -C "$proj" add -f -- "$SETTINGS_REL"
    git -C "$proj" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
      commit -qm "track the project's own claude settings"
  fi
  fm_git_add_origin "$proj" "$proj.origin.git"
  git -C "$proj" worktree add --quiet -b "task-$name" "$wt"

  printf '%s\n' "$home|$proj|$wt|$fakebin"
}

read_case_record() {
  IFS='|' read -r HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_spawn() {  # <home> <worktree> <fakebin> <id> <project>
  local home=$1 wt=$2 fakebin=$3 id=$4 proj=$5
  fm_test_spawn_brief "$home" "$id"
  fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --mode no-mistakes --yolo off
}

run_teardown() {  # <home> <fakebin> <id>
  local home=$1 fakebin=$2 id=$3
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1
}

# The project's own committed bytes for the tracked path.
committed_settings() {  # <worktree>
  git -C "$1" show "HEAD:$SETTINGS_REL"
}

settings_json() {  # <worktree> <jq-filter>
  jq -r "$2" "$1/$SETTINGS_REL"
}

test_spawn_preserves_tracked_project_settings() {
  local rec id=cs-arm out settings
  rec=$(make_case arm "$PROJECT_SETTINGS")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "spawn over a tracked settings file should succeed: $out"

  settings="$WT_DIR/$SETTINGS_REL"
  assert_present "$settings" "spawn removed the tracked settings file"
  jq -e . "$settings" >/dev/null || fail "the merged settings file is not valid JSON"

  [ "$(settings_json "$WT_DIR" '.enabledMcpjsonServers[0]')" = stitch ] \
    || fail "spawn dropped the project's own enabledMcpjsonServers key"
  [ "$(settings_json "$WT_DIR" '.hooks.Stop[0].hooks[0].command')" = project-own-stop ] \
    || fail "spawn dropped the project's own Stop hook entry"
  [ "$(settings_json "$WT_DIR" '.hooks.Stop | length')" = 2 ] \
    || fail "the task's Stop entry should be appended after the project's own"
  for ev in UserPromptSubmit Stop StopFailure SessionEnd; do
    settings_json "$WT_DIR" ".hooks[\"$ev\"] | length" | grep -qv '^0$' \
      || fail "the merged settings file lacks a $ev hook entry"
  done
  settings_json "$WT_DIR" '.hooks.Stop[1].hooks[0].command' | grep -q 'fm-busy-event.sh' \
    || fail "the task's own Stop hook is not the appended entry"
  assert_present "$HOME_DIR/state/$id.claude-settings" \
    "spawn recorded none of the bytes it wrote over a tracked settings file"
  pass "spawn merges its task hooks into a tracked settings file instead of overwriting it"
}

test_teardown_restores_the_tracked_file() {
  local rec id=cs-restore out record
  rec=$(make_case restore "$PROJECT_SETTINGS")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "spawn should succeed: $out"
  [ "$(git -C "$WT_DIR" status --porcelain -- "$SETTINGS_REL")" = " M $SETTINGS_REL" ] \
    || fail "the fixture should leave the tracked file modified before cleanup"
  record="$HOME_DIR/state/$id.claude-settings"

  out=$(run_teardown "$HOME_DIR" "$FAKEBIN_DIR" "$id")
  expect_code 0 $? "cleanup should succeed once the only change is the task's own hooks: $out"

  committed_settings "$WT_DIR" | cmp -s - "$WT_DIR/$SETTINGS_REL" \
    || fail "cleanup did not restore the tracked settings file byte-identically"
  [ -z "$(git -C "$WT_DIR" status --porcelain -- "$SETTINGS_REL")" ] \
    || fail "the tracked settings file is still modified after cleanup"
  assert_absent "$record" "cleanup left the recorded settings bytes behind"
  pass "cleanup succeeds and restores the tracked settings file to its committed content"
}

test_teardown_refuses_a_change_firstmate_did_not_write() {
  local rec id=cs-foreign out
  rec=$(make_case foreign "$PROJECT_SETTINGS")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "spawn should succeed: $out"

  printf '%s\n' '{"enabledMcpjsonServers":["stitch","added-by-the-worker"]}' \
    > "$WT_DIR/$SETTINGS_REL"

  out=$(run_teardown "$HOME_DIR" "$FAKEBIN_DIR" "$id")
  expect_code 1 $? "cleanup must refuse a change firstmate did not write: $out"
  assert_contains "$out" "uncommitted changes" \
    "the refusal should name the uncommitted work it is protecting"
  assert_grep 'added-by-the-worker' "$WT_DIR/$SETTINGS_REL" \
    "a refused cleanup must leave the worker's own change in place"
  assert_present "$HOME_DIR/state/$id.meta" "a refused cleanup must keep the task record"
  pass "cleanup still refuses when the tracked settings file carries a change firstmate did not write"
}

test_spawn_refuses_malformed_tracked_settings() {
  local rec id=cs-malformed out before
  rec=$(make_case malformed '{"enabledMcpjsonServers": [')
  read_case_record "$rec"
  before=$(cat "$WT_DIR/$SETTINGS_REL")

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 1 $? "spawn must refuse rather than overwrite settings it cannot merge into: $out"
  assert_contains "$out" "not valid JSON" \
    "the refusal should state why the merge was impossible"
  assert_contains "$out" "$SETTINGS_REL" \
    "the refusal should name the file it refused to overwrite"
  [ "$(cat "$WT_DIR/$SETTINGS_REL")" = "$before" ] \
    || fail "a refused spawn must leave the tracked settings file untouched"
  pass "spawn refuses loudly when the tracked settings file cannot be merged into"
}

test_untracked_settings_keep_the_plain_write_and_removal() {
  local rec id=cs-untracked out settings
  rec=$(make_case untracked)
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "spawn should succeed with no tracked settings file: $out"

  settings="$WT_DIR/$SETTINGS_REL"
  assert_present "$settings" "spawn did not write the task's own settings file"
  [ "$(settings_json "$WT_DIR" '. | keys | join(",")')" = hooks ] \
    || fail "an untracked settings file should carry the task hooks and nothing else"
  assert_absent "$HOME_DIR/state/$id.claude-settings" \
    "an untracked settings file needs no recorded bytes"

  out=$(run_teardown "$HOME_DIR" "$FAKEBIN_DIR" "$id")
  expect_code 0 $? "cleanup should succeed: $out"
  assert_absent "$settings" "cleanup should remove the task's own untracked settings file"
  pass "an untracked settings file keeps its plain write and plain removal"
}

test_spawn_preserves_tracked_project_settings
test_teardown_restores_the_tracked_file
test_teardown_refuses_a_change_firstmate_did_not_write
test_spawn_refuses_malformed_tracked_settings
test_untracked_settings_keep_the_plain_write_and_removal
