#!/usr/bin/env bash
# Tracked-project safety for Claude's per-task hook wiring file.
# Sourced by bin/fm-spawn.sh and bin/fm-teardown.sh; no side effects on source.
#
# Why one owner: `.claude/settings.local.json` is the only worktree artifact
# Firstmate writes that a project may legitimately TRACK. Every other per-task
# hook artifact is Firstmate's alone, so writing it is a plain overwrite and
# retiring it is a plain `rm`. Here both of those are wrong twice over: an
# overwrite destroys committed project content, and the `.git/info/exclude`
# entry that keeps the untracked case out of git's view does nothing for a
# tracked path, so the resulting modification reads to teardown as unlanded
# worker work and refuses cleanup.
#
# The contract is therefore split by what git already knows about the path:
#
#   tracked   - the arm MERGES the task's hook entries into the project's own
#               committed JSON, keeping every other key and appending to any
#               hook array the project already declares; the exact bytes it
#               produced are recorded; and retiring restores the committed
#               content with `git checkout --`. A malformed or non-object base
#               refuses at spawn rather than overwriting.
#   untracked - unchanged: the arm writes Firstmate's own hooks file and the
#               retire removes it, because nothing there is project content.
#
# The recorded bytes are what make the tracked case decidable. A worktree copy
# byte-identical to the record is Firstmate's own edit and nothing else, so it
# is safe to exclude from teardown's uncommitted-work test and safe to restore.
# Any other content is a change Firstmate did not write: teardown still refuses
# it, and a relaunch refuses to write over it.

# The one path this file governs, relative to the task worktree.
FM_CLAUDE_SETTINGS_REL='.claude/settings.local.json'

# Where the exact bytes an arm produced are kept for this task. Written only in
# the tracked case, which is the only case that has to be decidable later.
fm_claude_settings_record_path() {  # <state-dir> <id>
  local state=${1-} id=${2-}
  [ -n "$state" ] && [ -n "$id" ] || return 1
  printf '%s\n' "$state/$id.claude-settings"
}

# 0 when the project itself tracks the path in worktree $1.
fm_claude_settings_tracked() {  # <worktree>
  local wt=${1-}
  [ -n "$wt" ] || return 1
  git -C "$wt" ls-files --error-unmatch -- "$FM_CLAUDE_SETTINGS_REL" >/dev/null 2>&1
}

# 0 when the tracked path carries no unstaged modification.
fm_claude_settings_unmodified() {  # <worktree>
  local wt=${1-}
  [ -n "$wt" ] || return 1
  git -C "$wt" diff --quiet -- "$FM_CLAUDE_SETTINGS_REL" >/dev/null 2>&1
}

# 0 when the worktree copy is byte-identical to what this task's arm produced.
fm_claude_settings_is_own_edit() {  # <worktree> <state-dir> <id>
  local wt=${1-} record
  [ -n "$wt" ] || return 1
  record=$(fm_claude_settings_record_path "${2-}" "${3-}") || return 1
  [ -f "$record" ] || return 1
  cmp -s "$wt/$FM_CLAUDE_SETTINGS_REL" "$record"
}

# Merge <hooks-json> (the object value for the settings file's "hooks" key)
# into the JSON in <base-file>, printing the merged document. Existing keys and
# any hook entries the project already declares are preserved; the task's
# entries are appended to each event's array. Prints the concrete reason and
# returns 1 when the base cannot be merged into.
fm_claude_settings_merge() {  # <base-file> <hooks-json>
  local base=${1-} hooks=${2-}
  [ -n "$base" ] && [ -n "$hooks" ] || return 1
  command -v node >/dev/null 2>&1 || {
    echo "node is not installed, so its JSON cannot be merged into" >&2
    return 1
  }
  node - "$base" "$hooks" <<'NODE'
const fs = require("fs");
const [basePath, hooksJson] = process.argv.slice(2);

let raw = "";
try {
  raw = fs.readFileSync(basePath, "utf8");
} catch {
  raw = "";
}

let base;
if (raw.trim() === "") {
  base = {};
} else {
  try {
    base = JSON.parse(raw);
  } catch (error) {
    process.stderr.write(`it is not valid JSON (${error.message})\n`);
    process.exit(1);
  }
}
if (base === null || typeof base !== "object" || Array.isArray(base)) {
  process.stderr.write("its top level is not a JSON object\n");
  process.exit(1);
}

const existingHooks = base.hooks;
if (
  existingHooks !== undefined &&
  (existingHooks === null ||
    typeof existingHooks !== "object" ||
    Array.isArray(existingHooks))
) {
  process.stderr.write('its "hooks" value is not a JSON object\n');
  process.exit(1);
}

const merged = { ...base, hooks: { ...(existingHooks ?? {}) } };
for (const [event, entries] of Object.entries(JSON.parse(hooksJson))) {
  const already = merged.hooks[event];
  if (already !== undefined && !Array.isArray(already)) {
    process.stderr.write(`its "hooks.${event}" value is not a JSON array\n`);
    process.exit(1);
  }
  merged.hooks[event] = [...(already ?? []), ...entries];
}

process.stdout.write(`${JSON.stringify(merged)}\n`);
NODE
}

# Install this task's hook entries, preserving tracked project content, and
# record the exact bytes written when the path is tracked. Prints the concrete
# reason and returns 1 rather than writing over content Firstmate did not
# produce or over JSON it cannot merge into.
fm_claude_settings_arm() {  # <worktree> <state-dir> <id> <hooks-json>
  local wt=${1-} state=${2-} id=${3-} hooks=${4-} path record merged
  [ -n "$wt" ] && [ -n "$state" ] && [ -n "$id" ] && [ -n "$hooks" ] || return 1
  path="$wt/$FM_CLAUDE_SETTINGS_REL"
  mkdir -p "$(dirname "$path")" || return 1

  if ! fm_claude_settings_tracked "$wt"; then
    printf '{"hooks":%s}\n' "$hooks" > "$path" || return 1
    return 0
  fi

  record=$(fm_claude_settings_record_path "$state" "$id") || return 1
  # A prior incarnation's entries are already gone: retiring the wiring it
  # replaces runs first and owns that restore. Anything left here is a change
  # firstmate did not write - a worker's own edit surviving a harness switch,
  # say - and installing over it is the clobber this file exists to prevent.
  if ! fm_claude_settings_unmodified "$wt"; then
    echo "error: $wt has an uncommitted change to the tracked $FM_CLAUDE_SETTINGS_REL that firstmate did not write; refusing to write task hooks over it" >&2
    return 1
  fi

  merged=$(fm_claude_settings_merge "$path" "$hooks") || {
    echo "error: cannot merge task hooks into the tracked $FM_CLAUDE_SETTINGS_REL in $wt (see the reason above); refusing to overwrite committed project content" >&2
    return 1
  }
  printf '%s\n' "$merged" > "$path" || return 1
  cp -- "$path" "$record" || return 1
}

# Retire this task's hook entries: restore the project's committed content when
# the path is tracked, remove Firstmate's own file when it is not. Returns 1
# without changing anything when the tracked path carries a change Firstmate
# did not write, so a worker's own edit is never discarded here.
fm_claude_settings_retire() {  # <worktree> <state-dir> <id>
  local wt=${1-} state=${2-} id=${3-} path record
  [ -n "$wt" ] && [ -n "$state" ] && [ -n "$id" ] || return 1
  path="$wt/$FM_CLAUDE_SETTINGS_REL"
  record=$(fm_claude_settings_record_path "$state" "$id") || return 1

  if ! fm_claude_settings_tracked "$wt"; then
    rm -f -- "$path" || return 1
    rm -f -- "$record" || return 1
    return 0
  fi

  if ! fm_claude_settings_unmodified "$wt"; then
    fm_claude_settings_is_own_edit "$wt" "$state" "$id" || return 1
    git -C "$wt" checkout -- "$FM_CLAUDE_SETTINGS_REL" >/dev/null 2>&1 || return 1
  fi
  rm -f -- "$record" || return 1
}
