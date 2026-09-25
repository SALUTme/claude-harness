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

kind=""
if [ -f .harness/bootstrap-state.json ]; then
  if command -v jq >/dev/null 2>&1; then
    kind=$(jq -r '.kind // ""' .harness/bootstrap-state.json 2>/dev/null)
  else
    kind=$(grep -Eo '"kind"[[:space:]]*:[[:space:]]*"[a-z]+"' .harness/bootstrap-state.json | head -n 1 | sed -E 's/.*"([a-z]+)"$/\1/')
  fi
fi

# harness.env не исполняется: его читает тот же разборщик, что и хуки.
LIB=".claude/hooks/_harness_lib.sh"
env_lib_missing=0
[ -f .claude/harness.env ] && [ ! -f "$LIB" ] && env_lib_missing=1
env_val() { # ключ
  [ -f "$LIB" ] || return 0
  ( . "$LIB" 2>/dev/null && harness_load_env .claude/harness.env 2>/dev/null && eval "printf '%s' \"\${$1:-}\"" )
}

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
if [ "$kind" = "research" ]; then
  [ -s research/plan.md ] && P "план исследования" "research/plan.md есть" || F "план исследования" "нет research/plan.md"
  grep -qs '{{' research/plan.md && W "план исследования" "остались заглушки шаблона"
fi
for f in docs/BRIEF.md docs/PRD.md docs/NORTH_STAR.md; do
  [ "$kind" = "research" ] && [ "$f" = "docs/PRD.md" ] && continue
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
[ "$env_lib_missing" = "1" ] && F "чтение harness.env" "нет .claude/hooks/_harness_lib.sh, значения проверок прочитать нечем"
if [ -f .claude/harness.env ]; then
  (
    gates=$(env_val HARNESS_GATES_ACTIVE); testcmd=$(env_val HARNESS_TEST_CMD); fastcmd=$(env_val HARNESS_FAST_CHECK_CMD)
    [ "${gates:-0}" = "1" ] && printf 'PASS  %-24s %s\n' "гейты" "включены" || printf 'WARN  %-24s %s\n' "гейты" "выключены, HARNESS_GATES_ACTIVE=0"
    [ -n "$testcmd" ] && printf 'PASS  %-24s %s\n' "команда тестов" "$testcmd" || printf 'FAIL  %-24s %s\n' "команда тестов" "HARNESS_TEST_CMD пустая"
    if [ -n "$fastcmd" ]; then printf 'PASS  %-24s %s\n' "быстрая проверка" "$fastcmd"
    elif [ "$kind" = "research" ]; then printf 'PASS  %-24s %s\n' "быстрая проверка" "не нужна в исследовании"
    else printf 'WARN  %-24s %s\n' "быстрая проверка" "HARNESS_FAST_CHECK_CMD пустая"; fi
  ) > /tmp/harness-audit-env.$$
  while IFS= read -r l; do
    case "$l" in PASS*) pass=$((pass + 1)) ;; WARN*) warn=$((warn + 1)) ;; FAIL*) fail=$((fail + 1)) ;; esac
    printf '%s\n' "$l"
  done < /tmp/harness-audit-env.$$
  rm -f /tmp/harness-audit-env.$$
else
  F harness.env "нет .claude/harness.env"
fi
for h in _harness_lib block-dangerous secret-guard after-edit-check commit-gate stop-gate harness-status env-setup; do
  f=".claude/hooks/$h.sh"
  if [ -f "$f" ]; then P "хук $h" "есть"; else F "хук $h" "нет файла"; fi
done
if [ -f .claude/settings.json ] && jq -e . .claude/settings.json >/dev/null 2>&1; then
  P settings.json "валидный JSON"
  jq -e '.disableAllHooks == false' .claude/settings.json >/dev/null && P disableAllHooks "false" || W disableAllHooks "не задан явно, глобальные настройки могут выключить хуки"
  for h in block-dangerous secret-guard after-edit-check commit-gate stop-gate harness-status env-setup; do
    jq -e --arg h "$h" '[.hooks[]?[]?.hooks[]?.command // empty] | any(test(".claude/hooks/" + $h + "[.]sh"))' .claude/settings.json >/dev/null \
      && P "подключён $h" "есть в settings.json" || F "подключён $h" "нет в settings.json"
  done
  for r in 'Edit(/.claude/hooks/**)' 'Edit(/.claude/skills/**)' 'Edit(/.claude/settings.json)' 'Edit(/.claude/harness.env)'; do
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
if [ "$kind" = "research" ]; then
  [ -s research/tasks.md ] && P "вопросы исследования" "research/tasks.md есть" || F "вопросы исследования" "нет research/tasks.md"
elif [ -d .specify ] || [ -d specs ]; then P спецификация "Spec Kit"
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
if command -v codex >/dev/null 2>&1; then P "Codex CLI" "установлен"
elif [ "${CLAUDE_CODE_REMOTE:-}" = "true" ]; then P "Codex CLI" "облачная сессия: ревью Codex откладывается до сессии на Mac"
else W "Codex CLI" "не установлен, ревью делает запасной агент"; fi
if [ -f .claude/settings.json ]; then
  jq -e '(.enabledPlugins // {})["oh-my-claudecode@omc"] == true' .claude/settings.json >/dev/null 2>&1 \
    && P "плагин OMC" "объявлен в settings.json, облако поставит его само" || W "плагин OMC" "не объявлен в settings.json, в облаке не будет deep-interview и агентов OMC"
fi

if [ "$kind" = "research" ]; then
  section "Вики"
  if [ -f "$SKILL_DIR/scripts/wiki-lint.sh" ]; then
    lout=$(bash "$SKILL_DIR/scripts/wiki-lint.sh" . 2>&1); lrc=$?
    lsum=$(printf '%s\n' "$lout" | grep -E '^Итог' | tail -n 1)
    [ -z "$lsum" ] && lsum=$(printf '%s\n' "$lout" | grep -E '^ПРОБЛЕМА' | head -n 1)
    [ -z "$lsum" ] && lsum="wiki-lint не отработал"
    [ "$lrc" -eq 0 ] && P "проверка вики" "$lsum" || F "проверка вики" "$lsum"
  fi
  case "$(env_val HARNESS_TEST_CMD)" in
    *wiki-lint.sh*) P "команда проверок" "ворота запускают wiki-lint" ;;
    *)              F "команда проверок" "HARNESS_TEST_CMD не запускает wiki-lint, ворота проверяют не то" ;;
  esac
  gate_ok=1
  for key in HARNESS_GATE_EXCLUDE_REGEX HARNESS_CHECK_SKIP_REGEX; do
    val=$(env_val "$key")
    if [ -z "$val" ]; then
      if [ "$key" = "HARNESS_GATE_EXCLUDE_REGEX" ]; then
        W "ворота и вики" "$key не задан: действует значение для кода, правки вики не проверяются"; gate_ok=0
      fi
      continue
    fi
    printf 'x\n' | grep -Eq -- "$val" 2>/dev/null
    if [ "$?" -gt 1 ]; then
      F "ворота и вики" "$key не разбирается как регулярное выражение"; gate_ok=0
    elif printf 'wiki/page.md\nraw/material.pdf\n' | grep -Eq -- "$val" 2>/dev/null; then
      F "ворота и вики" "$key исключает вики или материалы: правки не проверяются"; gate_ok=0
    fi
  done
  [ "$gate_ok" = "1" ] && P "ворота и вики" "правки вики попадают под ворота"
fi

section "7b. Окружение"
if [ "$kind" = "research" ] && [ ! -f .claude/hooks/project-setup.sh ]; then
  P "подготовка окружения" "не нужна в исследовании"
elif [ -f .claude/hooks/project-setup.sh ]; then
  P "подготовка окружения" ".claude/hooks/project-setup.sh есть"
  if [ -f .harness/runtime/env-setup.log ]; then P "лог подготовки" "есть, последний запуск в .harness/runtime/env-setup.log"; fi
else
  W "подготовка окружения" "нет .claude/hooks/project-setup.sh, зависимости в новой сессии ставятся вручную"
fi
if find .github/workflows -maxdepth 1 \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null | grep -q .; then
  P CI "есть .github/workflows"
  grep -rqs --include='*.yml' --include='*.yaml' 'HARNESS_TEST_CMD' .github/workflows && P "CI и тесты" "CI запускает HARNESS_TEST_CMD" || W "CI и тесты" "CI не использует HARNESS_TEST_CMD, команды могут разойтись"
else
  [ "$kind" = "research" ] && W CI "нет .github/workflows, проверка вики не запускается без агента" || W CI "нет .github/workflows, сломанный код не будет виден без агента"
fi
if [ -f docs/HARNESS.md ] && grep -q '^## Окружение' docs/HARNESS.md; then P "окружение в HARNESS.md" "раздел есть"; else W "окружение в HARNESS.md" "нет раздела «Окружение» в docs/HARNESS.md"; fi

if [ "$RUN_TESTS" = "1" ] && [ -f .claude/harness.env ]; then
  section "8. Тесты проекта"
  cmd=$(env_val HARNESS_TEST_CMD)
  if [ -n "$cmd" ]; then
    bash -c "$cmd" >/dev/null 2>&1 && P "тесты" "зелёные" || F "тесты" "красные: $cmd"
  fi
fi

printf '\nИтог: PASS=%s WARN=%s FAIL=%s\n' "$pass" "$warn" "$fail"
[ "$fail" -eq 0 ]
