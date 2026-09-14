#!/usr/bin/env bash
# harness-setup | PostToolUse, matcher Write|Edit|MultiEdit
# Быстрая проверка после правки кода и детектор зацикливания.
# Документы, вики и исходники вики не проверяются и не считаются правками кода.
set -u

ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
RUNTIME="$ROOT/.harness/runtime"
mkdir -p "$RUNTIME" 2>/dev/null
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$HOOK_DIR/_harness_lib.sh" ]; then . "$HOOK_DIR/_harness_lib.sh"; harness_load_env "$ROOT/.claude/harness.env"
else echo "harness: рядом с хуком нет _harness_lib.sh, проверка пропущена" >&2; exit 0; fi

log() { printf '%s\tafter-edit-check\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" >> "$RUNTIME/hooks.log" 2>/dev/null; }

command -v jq >/dev/null 2>&1 || { echo "harness: jq не найден, проверка после правки пропущена" >&2; exit 0; }

input=$(cat)
file=$(jq -r '.tool_input.file_path // empty' <<<"$input")
session=$(jq -r '.session_id // "nosession"' <<<"$input" | tr -cd '[:alnum:]_-')
[ -z "$file" ] && exit 0
rel="${file#"$ROOT"/}"

skip="${HARNESS_CHECK_SKIP_REGEX:-(\.(md|mdx|txt|rst)$|^(docs|wiki|raw)/)}"
if printf '%s' "$rel" | grep -Eq -- "$skip"; then exit 0; fi

ctx=""
max="${HARNESS_MAX_EDITS_PER_FILE:-8}"
counts="$RUNTIME/edits-${session:-nosession}.txt"
n=$(grep -cxF -- "$rel" "$counts" 2>/dev/null); n=${n:-0}; n=$((n + 1))
printf '%s\n' "$rel" >> "$counts"
if [ "$n" -ge "$max" ] && [ $(( (n - max) % 3 )) -eq 0 ]; then
  ctx="Файл $rel правится уже $n раз за сессию. Остановись: запиши гипотезу, почему не сходится, смени подход или эскалируй человеку."
  log loop "$rel x$n"
fi

emit_ctx() {
  [ -z "$ctx" ] && exit 0
  jq -n --arg c "$ctx" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$c}}'
  exit 0
}

[ "${HARNESS_GATES_ACTIVE:-0}" = "1" ] || emit_ctx
[ -n "${HARNESS_FAST_CHECK_CMD:-}" ] || emit_ctx

out=$(cd "$ROOT" && bash -c "$HARNESS_FAST_CHECK_CMD" 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then
  tail_out=$(printf '%s\n' "$out" | tail -n 40)
  reason=$(printf 'Быстрая проверка упала после правки %s, код %s. Почини до следующего шага. Если не сходится после трёх попыток, опиши проблему в docs/STATE.md и эскалируй.\n\n%s' "$rel" "$rc" "$tail_out")
  log fail "$rel rc=$rc"
  jq -n --arg r "$reason" --arg c "$ctx" \
    '{decision:"block",reason:$r} + (if $c != "" then {hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$c}} else {} end)'
  exit 0
fi
log pass "$rel"
emit_ctx
