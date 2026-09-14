#!/usr/bin/env bash
# harness-setup | PreToolUse, matcher Bash, if Bash(git *)
# Запрещает коммит при красных тестах. Коммит определяется по настоящей подкоманде git.
set -u

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
RUNTIME="$ROOT/.harness/runtime"
mkdir -p "$RUNTIME" 2>/dev/null

log() { printf '%s\tcommit-gate\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" >> "$RUNTIME/hooks.log" 2>/dev/null; }

command -v jq >/dev/null 2>&1 || { echo "harness: jq не найден, гейт коммита пропущен" >&2; exit 0; }
[ -f "$HOOK_DIR/_harness_lib.sh" ] || { echo "harness: нет _harness_lib.sh, гейт коммита пропущен" >&2; exit 0; }
. "$HOOK_DIR/_harness_lib.sh"
harness_load_env "$ROOT/.claude/harness.env"

[ "${HARNESS_GATES_ACTIVE:-0}" = "1" ] || exit 0
[ -n "${HARNESS_TEST_CMD:-}" ] || exit 0

input=$(cat)
cmd=$(jq -r '.tool_input.command // empty' <<<"$input")
[ -z "$cmd" ] && exit 0

is_commit=0
while IFS= read -r raw; do
  seg=$(harness_trim "$raw")
  [ -z "$seg" ] && continue
  [ "$(harness_cmdword "$seg")" = "git" ] || continue
  if [ "$(harness_git_subcmd "$seg")" = "commit" ]; then is_commit=1; break; fi
done <<< "$(harness_segments "$cmd")"
[ "$is_commit" = "1" ] || exit 0

out=$(cd "$ROOT" && bash -c "$HARNESS_TEST_CMD" 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then
  tail_out=$(printf '%s\n' "$out" | tail -n 40)
  reason=$(printf 'Коммит запрещён: тесты красные, код %s. Сначала почини.\n\n%s' "$rc" "$tail_out")
  log deny "rc=$rc"
  jq -n --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
fi
log pass "tests green"
exit 0
