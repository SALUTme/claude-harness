#!/usr/bin/env bash
# harness-setup | Stop
# Не даёт закончить ход, если код изменён, а тесты красные.
# В пределах одного хода блокирует не больше HARNESS_STOP_MAX_BLOCKS раз, потом отпускает с сообщением человеку.
# Сдавшееся красное состояние запоминается и не блокирует следующие ходы, пока код не изменится.
# Зелёный прогон кэшируется по отпечатку изменённых файлов кода и команды тестов.
set -u

ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
RUNTIME="$ROOT/.harness/runtime"
mkdir -p "$RUNTIME" 2>/dev/null
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$HOOK_DIR/_harness_lib.sh" ]; then . "$HOOK_DIR/_harness_lib.sh"; harness_load_env "$ROOT/.claude/harness.env"
else echo "harness: рядом с хуком нет _harness_lib.sh, проверка пропущена" >&2; exit 0; fi

log() { printf '%s\tstop-gate\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" >> "$RUNTIME/hooks.log" 2>/dev/null; }

command -v jq >/dev/null 2>&1 || exit 0
input=$(cat)
active=$(jq -r '.stop_hook_active // false' <<<"$input")
session=$(jq -r '.session_id // "nosession"' <<<"$input" | tr -cd '[:alnum:]_-')
session=${session:-nosession}

[ "${HARNESS_GATES_ACTIVE:-0}" = "1" ] || exit 0
[ -n "${HARNESS_TEST_CMD:-}" ] || exit 0
cd "$ROOT" || exit 0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

counter="$RUNTIME/stop-blocks-$session"
last_red="$RUNTIME/last-red-$session"
gave_up="$RUNTIME/gave-up-$session"
reset_turn() { rm -f "$counter" "$last_red" 2>/dev/null; }
reset_all()  { rm -f "$counter" "$last_red" "$gave_up" 2>/dev/null; }

# Новый ход начинает счёт блокировок заново
[ "$active" = "true" ] || reset_turn

# Изменённые пути и те из них, что проверяются воротами. Правила отбора общие с гейтом коммита.
paths=$(harness_changed_paths)
code=$(harness_code_paths "$paths")
if [ -z "$code" ]; then
  reset_all
  exit 0
fi

# Отпечаток общий с гейтом коммита: зелёный прогон там не повторяется здесь, и наоборот.
fp=$(harness_fingerprint "$code")

if [ "$fp" = "$(cat "$RUNTIME/last-green" 2>/dev/null)" ]; then
  reset_all
  exit 0
fi
if [ "$fp" = "$(cat "$gave_up" 2>/dev/null)" ]; then
  exit 0
fi

give_up() {
  printf '%s' "$fp" > "$gave_up"
  reset_turn
  log giveup "$1"
  jq -n --arg msg "$2" '{systemMessage:$msg}'
  exit 0
}

if [ "$active" = "true" ] && [ "$fp" = "$(cat "$last_red" 2>/dev/null)" ]; then
  give_up "no code changes since last block" "harness: тесты всё ещё красные, а новых правок кода после блокировки нет. Завершение хода разрешено. Проверь docs/STATE.md."
fi

out=$(bash -c "$HARNESS_TEST_CMD" 2>&1); rc=$?
max="${HARNESS_STOP_MAX_BLOCKS:-3}"

if [ "$rc" -ne 0 ]; then
  n=$(cat "$counter" 2>/dev/null); n=${n:-0}; n=$((n + 1))
  if [ "$n" -gt "$max" ]; then
    give_up "rc=$rc blocks=$max" "harness: тесты красные после $max попыток починки. Завершение хода разрешено, нужна помощь человека."
  fi
  printf '%s' "$n" > "$counter"
  printf '%s' "$fp" > "$last_red"
  tail_out=$(printf '%s\n' "$out" | tail -n 40)
  reason=$(printf 'Нельзя завершать ход: код изменён, а тесты красные, код %s. Попытка %s из %s. Почини, а если не выходит, опиши проблему в docs/STATE.md.\n\n%s' "$rc" "$n" "$max" "$tail_out")
  log block "rc=$rc attempt=$n/$max"
  jq -n --arg r "$reason" '{decision:"block",reason:$r}'
  exit 0
fi

printf '%s' "$fp" > "$RUNTIME/last-green"
harness_fingerprint "$paths" > "$RUNTIME/last-green-all"
reset_all
log pass "tests green"

if [ "$active" != "true" ] && [ "${HARNESS_REQUIRE_STATE_UPDATE:-1}" = "1" ] && ! printf '%s\n' "$paths" | grep -qx 'docs/STATE.md'; then
  log remind "STATE.md not updated"
  jq -n '{hookSpecificOutput:{hookEventName:"Stop",additionalContext:"Тесты зелёные, но docs/STATE.md не обновлён. Запиши, что сделано, чем проверено и что дальше."}}'
fi
exit 0
