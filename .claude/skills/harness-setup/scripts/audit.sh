#!/usr/bin/env bash
# harness-setup | аудит готовности проекта по воротам фаз.
# Ничего не меняет в проекте. Тесты проекта запускает только с флагом --run-tests.
# Использование: audit.sh [папка_проекта] [--run-tests]
# Код выхода: 0 без FAIL, 1 если есть хотя бы один FAIL.
set -u

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SELF_DIR/.." && pwd)"
PROJECT="."
RUN_TESTS=0
for a in "$@"; do
  case "$a" in
    --run-tests) RUN_TESTS=1 ;;
    *) PROJECT="$a" ;;
  esac
done
cd "$PROJECT" 2>/dev/null || { echo "FAIL  папка проекта не найдена: $PROJECT"; exit 1; }

pass=0; warn=0; fail=0
P() { pass=$((pass + 1)); printf 'PASS  %-24s %s\n' "$1" "$2"; }
W() { warn=$((warn + 1)); printf 'WARN  %-24s %s\n' "$1" "$2"; }
F() { fail=$((fail + 1)); printf 'FAIL  %-24s %s\n' "$1" "$2"; }
section() { printf '\n== %s\n' "$1"; }

section "0. Основа"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 && P git "репозиторий есть" || F git "не git-репозиторий"
command -v jq >/dev/null 2>&1 && P jq "установлен" || F jq "не установлен, хуки не будут работать"
if [ -f .harness/bootstrap-state.json ] && jq -e . .harness/bootstrap-state.json >/dev/null 2>&1; then
  pending=$(jq -r '.phases | to_entries[] | select(.value.status != "done" and .value.status != "skipped") | .key' .harness/bootstrap-state.json | tr '\n' ' ')
  skipped=$(jq -r '.phases | to_entries[] | select(.value.status == "skipped") | .key' .harness/bootstrap-state.json | tr '\n' ' ')
  [ -z "$pending" ] && P фазы "все фазы пройдены" || W фазы "не завершены: $pending"
  [ -n "$skipped" ] && W пропуски "пропущены: $skipped"
else
  F фазы "нет .harness/bootstrap-state.json, harness-setup не запускался"
fi

section "1-2. Бриф, PRD, Северная звезда"
for f in docs/BRIEF.md docs/PRD.md docs/NORTH_STAR.md; do
  [ -s "$f" ] && P "$(basename "$f")" "есть" || F "$(basename "$f")" "нет файла"
done
if [ -f docs/NORTH_STAR.md ] && grep -q '^Одно предложение\.$' docs/NORTH_STAR.md; then
  W NORTH_STAR "остались заглушки шаблона, заполни цель и инварианты"
fi
if [ -f docs/PRD.md ] && grep -q '^Статус: черновик' docs/PRD.md; then
  W PRD "статус черновик, PRD не одобрен"
fi

section "3. Скиллы и агенты"
if [ -f docs/HARNESS.md ]; then
  rows=$(awk '/^## Скиллы и агенты/{f=1;next} /^## /{f=0} /^Отклонено/{f=0} f && /^\|/ && !/^\|[- |:]+\|$/ && !/^\| *Что *\|/' docs/HARNESS.md | wc -l | tr -d ' ')
  [ "$rows" -gt 0 ] && P "состав обвязки" "записей о скиллах и агентах: $rows" || W "состав обвязки" "раздел скиллов и агентов пуст"
else
  F HARNESS.md "нет docs/HARNESS.md"
fi

section "4. Каркас и вики"
if [ -f CLAUDE.md ]; then
  lines=$(wc -l < CLAUDE.md | tr -d ' ')
  [ "$lines" -le 80 ] && P CLAUDE.md "$lines строк" || F CLAUDE.md "$lines строк, предел 80"
  grep -q '{{' CLAUDE.md && W CLAUDE.md "остались плейсхолдеры {{...}}"
else
  F CLAUDE.md "нет файла"
fi
for f in docs/STATE.md docs/DECISIONS.md wiki/SCHEMA.md wiki/index.md wiki/log.md; do
  [ -f "$f" ] && P "$f" "есть" || F "$f" "нет файла"
done
[ -d raw ] && P raw/ "есть" || F raw/ "нет папки"
if [ -f wiki/log.md ]; then
  entries=$(grep -c '^## \[' wiki/log.md 2>/dev/null); entries=${entries:-0}
  [ "$entries" -gt 0 ] && P "wiki/log.md" "записей: $entries" || W "wiki/log.md" "нет записей в формате ## [дата] операция | название"
fi
if [ -f .gitignore ]; then
  for pat in .harness/runtime/ .env raw/private/; do
    grep -qxF "$pat" .gitignore && P ".gitignore" "содержит $pat" || F ".gitignore" "нет строки $pat"
  done
else
  F .gitignore "нет файла"
fi

section "5. Ограждения"
if [ -f .claude/harness.env ]; then
  (
    . .claude/harness.env
    [ "${HARNESS_GATES_ACTIVE:-0}" = "1" ] && printf 'PASS  %-24s %s\n' "гейты" "включены" || printf 'WARN  %-24s %s\n' "гейты" "выключены, HARNESS_GATES_ACTIVE=0"
    [ -n "${HARNESS_TEST_CMD:-}" ] && printf 'PASS  %-24s %s\n' "команда тестов" "$HARNESS_TEST_CMD" || printf 'FAIL  %-24s %s\n' "команда тестов" "HARNESS_TEST_CMD пустая"
    [ -n "${HARNESS_FAST_CHECK_CMD:-}" ] && printf 'PASS  %-24s %s\n' "быстрая проверка" "$HARNESS_FAST_CHECK_CMD" || printf 'WARN  %-24s %s\n' "быстрая проверка" "HARNESS_FAST_CHECK_CMD пустая"
  ) > /tmp/harness-audit-env.$$
  while IFS= read -r l; do
    case "$l" in PASS*) pass=$((pass + 1)) ;; WARN*) warn=$((warn + 1)) ;; FAIL*) fail=$((fail + 1)) ;; esac
    printf '%s\n' "$l"
  done < /tmp/harness-audit-env.$$
  rm -f /tmp/harness-audit-env.$$
else
  F harness.env "нет .claude/harness.env"
fi
for h in _harness_lib block-dangerous secret-guard after-edit-check commit-gate stop-gate harness-status; do
  f=".claude/hooks/$h.sh"
  if [ -f "$f" ]; then P "хук $h" "есть"; else F "хук $h" "нет файла"; fi
done
if [ -f .claude/settings.json ] && jq -e . .claude/settings.json >/dev/null 2>&1; then
  P settings.json "валидный JSON"
  jq -e '.disableAllHooks == false' .claude/settings.json >/dev/null && P disableAllHooks "false" || W disableAllHooks "не задан явно, глобальные настройки могут выключить хуки"
  for h in block-dangerous secret-guard after-edit-check commit-gate stop-gate harness-status; do
    jq -e --arg h "$h" '[.hooks[]?[]?.hooks[]?.command // empty] | any(test(".claude/hooks/" + $h + "[.]sh"))' .claude/settings.json >/dev/null \
      && P "подключён $h" "есть в settings.json" || F "подключён $h" "нет в settings.json"
  done
  for r in 'Edit(/.claude/hooks/**)' 'Edit(/.claude/settings.json)' 'Edit(/.claude/harness.env)'; do
    jq -e --arg r "$r" '.permissions.ask // [] | any(. == $r)' .claude/settings.json >/dev/null && P "подтверждение" "$r" || F "подтверждение" "нет правила $r"
  done
  jq -e '.permissions.deny // [] | any(. == "Read(/.env)")' .claude/settings.json >/dev/null && P "deny" "Read(/.env)" || F "deny" "нет правила Read(/.env)"
else
  F settings.json "нет файла или невалидный JSON"
fi
if [ -f "$SKILL_DIR/hooks/smoke-test.sh" ] && [ -d .claude/hooks ]; then
  out=$(bash "$SKILL_DIR/hooks/smoke-test.sh" .claude/hooks 2>&1); rc=$?
  summary=$(printf '%s\n' "$out" | grep -E '^Итог' | tail -n 1)
  [ -z "$summary" ] && summary=$(printf '%s\n' "$out" | grep -E '^FAIL' | head -n 1 | sed -E 's/^FAIL +//')
  [ "$rc" -eq 0 ] && P "автотест хуков" "$summary" || F "автотест хуков" "$summary"
fi

section "6. Спецификация и приёмка"
if [ -d .specify ] || [ -d specs ]; then P спецификация "Spec Kit"
elif [ -d openspec ]; then P спецификация "OpenSpec"
else W спецификация "нет .specify, specs или openspec"; fi
if [ -f docs/ACCEPTANCE.md ]; then
  total=$(grep -cE '^\| *[A-Za-zА-Яа-я]*-?[0-9]+ *\|' docs/ACCEPTANCE.md 2>/dev/null); total=${total:-0}
  nocmd=$(awk -F'|' '/^\| *[A-Za-zА-Яа-я]*-?[0-9]+ *\|/ { gsub(/ /, "", $5); gsub(/ /, "", $6); if ($5 == "" && $6 != "manual") n++ } END { print n + 0 }' docs/ACCEPTANCE.md)
  if [ "$total" -eq 0 ]; then W приёмка "в docs/ACCEPTANCE.md нет критериев"
  elif [ "$nocmd" -gt 0 ]; then W приёмка "критериев $total, без команды проверки: $nocmd"
  else P приёмка "критериев $total, у всех есть проверка"; fi
else
  F ACCEPTANCE.md "нет docs/ACCEPTANCE.md"
fi

section "7. Роли проверки"
if [ -f CLAUDE.md ] && grep -q '^## Готово, когда' CLAUDE.md; then P "определение готовности" "раздел есть в CLAUDE.md"; else F "определение готовности" "нет раздела «Готово, когда» в CLAUDE.md"; fi
command -v codex >/dev/null 2>&1 && P "Codex CLI" "установлен" || W "Codex CLI" "не установлен, ревью делает запасной агент"

if [ "$RUN_TESTS" = "1" ] && [ -f .claude/harness.env ]; then
  section "8. Тесты проекта"
  cmd=$(. .claude/harness.env; printf '%s' "${HARNESS_TEST_CMD:-}")
  if [ -n "$cmd" ]; then
    bash -c "$cmd" >/dev/null 2>&1 && P "тесты" "зелёные" || F "тесты" "красные: $cmd"
  fi
fi

printf '\nИтог: PASS=%s WARN=%s FAIL=%s\n' "$pass" "$warn" "$fail"
[ "$fail" -eq 0 ]
