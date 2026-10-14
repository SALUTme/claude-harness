#!/usr/bin/env bash
# harness | перенос обвязки из основы в проект.
# Использование: harness-sync.sh <папка_основы> [папка_проекта] [--skip-workflows]
# Печатает отчёт в формате Markdown для описания PR. Код выхода 0 при успехе.
#
# Что делает:
# - хуки .claude/hooks/*.sh и скиллы harness, harness-setup, harness-new заменяет версиями основы;
# - .claude/settings.json сливает через merge-settings.sh: права и хуки проекта сохраняются;
# - в .claude/harness.env добавляет недостающие ключи со значениями по умолчанию, значения проекта не меняет;
# - в .harness/bootstrap-state.json добавляет недостающие фазы, пройденные не трогает;
# - в docs/STATE.md добавляет недостающие разделы шаблона;
# - .github/workflows/harness-*.yml заменяет версиями основы. С --skip-workflows только сообщает о различиях:
#   встроенный токен GitHub Actions не может менять workflow;
# - в .harness/source.json записывает версию основы.
# Файлы проекта не трогает: docs/ кроме новых разделов STATE.md, wiki/, raw/, CLAUDE.md, README.md,
# .claude/hooks/project-setup.sh, свои скиллы проекта и свои workflow.
set -u

TPL=""; PROJ="."; SKIP_WF=0
for a in "$@"; do
  case "$a" in
    --skip-workflows) SKIP_WF=1 ;;
    *) if [ -z "$TPL" ]; then TPL="$a"; else PROJ="$a"; fi ;;
  esac
done
[ -n "$TPL" ] || { echo "harness-sync: укажи папку основы" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "harness-sync: нужен jq" >&2; exit 2; }
TPL=$(cd "$TPL" 2>/dev/null && pwd) || { echo "harness-sync: нет папки основы" >&2; exit 2; }
PROJ=$(cd "$PROJ" 2>/dev/null && pwd) || { echo "harness-sync: нет папки проекта" >&2; exit 2; }
S="$TPL/.claude/skills/harness-setup"
[ -f "$TPL/.harness/source.json" ] && [ -f "$S/hooks/settings.template.json" ] \
  || { echo "harness-sync: $TPL не похожа на основу harness" >&2; exit 2; }
[ "$TPL" != "$PROJ" ] || { echo "harness-sync: папка основы и проекта совпадают" >&2; exit 2; }

NEW_VER=$(jq -r '.version // empty' "$TPL/.harness/source.json")
OLD_VER=$(jq -r '.version // empty' "$PROJ/.harness/source.json" 2>/dev/null)
changed=""; attention=""; details=""
note()  { changed="$changed- $1"$'\n'; }
watch() { attention="$attention- $1"$'\n'; }

# Кладёт файл основы в проект, если он отличается. $1 = источник, $2 = путь в проекте от его корня.
# Результат в PUT: same, added или updated. С третьим аргументом quiet в отчёт не пишет: итог подводит вызывающий.
PUT=same
put() {
  local dst="$PROJ/$2"
  PUT=same
  cmp -s "$1" "$dst" && return 0
  PUT=updated; [ -e "$dst" ] || PUT=added
  mkdir -p "$(dirname "$dst")" && cp "$1" "$dst" || { echo "harness-sync: не удалось записать $2" >&2; exit 1; }
  [ "${3:-}" = quiet ] && return 0
  if [ "$PUT" = updated ]; then note "\`$2\` обновлён"; else note "\`$2\` добавлен"; fi
}

# --- Хуки
for f in "$TPL"/.claude/hooks/*.sh; do
  [ -f "$f" ] || continue
  [ "$(basename "$f")" = "project-setup.sh" ] && continue
  put "$f" ".claude/hooks/$(basename "$f")"
done
for f in "$PROJ"/.claude/hooks/*.sh; do
  [ -f "$f" ] || continue
  b=$(basename "$f")
  [ "$b" = "project-setup.sh" ] && continue
  [ -f "$TPL/.claude/hooks/$b" ] || watch "\`.claude/hooks/$b\` есть в проекте, но не в основе. Если это старый хук обвязки, удали его и убери из настроек"
done

# --- Скиллы обвязки: заменяются целиком, лишние файлы удаляются. Свои скиллы проекта не трогаются.
for d in harness harness-setup harness-new; do
  [ -d "$TPL/.claude/skills/$d" ] || continue
  n_add=0; n_upd=0; n_del=0
  while IFS= read -r f; do
    put "$TPL/.claude/skills/$d/$f" ".claude/skills/$d/$f" quiet
    case "$PUT" in
      added)   n_add=$((n_add + 1)); details="$details- \`.claude/skills/$d/$f\` добавлен"$'\n' ;;
      updated) n_upd=$((n_upd + 1)); details="$details- \`.claude/skills/$d/$f\` обновлён"$'\n' ;;
    esac
  done < <(cd "$TPL/.claude/skills/$d" && find . -type f | sed 's#^\./##' | sort)
  if [ -d "$PROJ/.claude/skills/$d" ]; then
    while IFS= read -r f; do
      if [ ! -e "$TPL/.claude/skills/$d/$f" ]; then
        rm -f "$PROJ/.claude/skills/$d/$f"
        n_del=$((n_del + 1)); details="$details- \`.claude/skills/$d/$f\` удалён, его больше нет в основе"$'\n'
      fi
    done < <(cd "$PROJ/.claude/skills/$d" && find . -type f | sed 's#^\./##' | sort)
    find "$PROJ/.claude/skills/$d" -mindepth 1 -type d -empty -delete 2>/dev/null
  fi
  [ $((n_add + n_upd + n_del)) -gt 0 ] && note "скилл \`$d\`: обновлено $n_upd, добавлено $n_add, удалено $n_del"
done

# --- Настройки: слияние, а не замена
tmp=$(mktemp "${TMPDIR:-/tmp}/harness-sync.XXXXXX")
trap 'rm -f "$tmp"' EXIT
if bash "$S/scripts/merge-settings.sh" "$PROJ/.claude/settings.json" "$S/hooks/settings.template.json" > "$tmp" && [ -s "$tmp" ]; then
  put "$tmp" ".claude/settings.json"
else
  watch "\`.claude/settings.json\` не удалось слить с шаблоном, он не изменён. Проверь, что это валидный JSON"
fi

# --- harness.env: только недостающие ключи вместе с комментариями над ними
ENV_TPL="$S/hooks/harness.env.template"
if [ ! -f "$PROJ/.claude/harness.env" ]; then
  put "$ENV_TPL" ".claude/harness.env"
  watch "\`.claude/harness.env\` создан из шаблона, впиши команды проверок проекта"
else
  add=$(awk '
    FNR == NR { if (match($0, /^[[:space:]]*HARNESS_[A-Z_]+=/)) { k = substr($0, RSTART, RLENGTH); gsub(/[[:space:]=]/, "", k); have[k] = 1 } next }
    /^#/ { buf = buf $0 "\n"; next }
    /^[[:space:]]*$/ { buf = ""; next }
    match($0, /^HARNESS_[A-Z_]+=/) { k = substr($0, 1, RLENGTH - 1); if (!(k in have)) printf "\n%s%s\n", buf, $0; buf = ""; next }
    { buf = "" }' "$PROJ/.claude/harness.env" "$ENV_TPL")
  if [ -n "$add" ]; then
    # Файл без перевода строки в конце: сначала закрываем последнюю строку, чтобы блок не прилип к ней
    [ -n "$(tail -c 1 "$PROJ/.claude/harness.env")" ] && printf '\n' >> "$PROJ/.claude/harness.env"
    printf '%s\n' "$add" >> "$PROJ/.claude/harness.env"
    keys=$(printf '%s\n' "$add" | grep -Eo '^HARNESS_[A-Z_]+' | tr '\n' ' ')
    note "\`.claude/harness.env\`: добавлены ключи со значениями по умолчанию: ${keys% }"
  fi
fi

# --- Состояние подготовки: новые фазы со статусом pending, пройденные не меняются
STATE="$PROJ/.harness/bootstrap-state.json"
if [ -f "$STATE" ]; then
  if jq --slurpfile t "$S/templates/bootstrap-state.json" \
       '.phases = ($t[0].phases + (.phases // {})) | (if has("kind") then . else .kind = null end)' "$STATE" > "$tmp" 2>/dev/null; then
    [ "$(jq -S . "$STATE" 2>/dev/null)" = "$(jq -S . "$tmp")" ] || put "$tmp" ".harness/bootstrap-state.json"
  else
    watch "\`.harness/bootstrap-state.json\` не разобрался как JSON, новые фазы не добавлены"
  fi
fi

# --- docs/STATE.md: недостающие разделы из шаблона
if [ -f "$PROJ/docs/STATE.md" ]; then
  # Заголовки сравниваются без \r и пробелов в конце: иначе файл с переводами строк Windows получит дубли разделов
  add=$(awk '
    { h = $0; sub(/\r$/, "", h); sub(/[ \t]+$/, "", h) }
    FNR == NR { if (h ~ /^## /) have[h] = 1; next }
    h ~ /^## / { on = !(h in have) }
    on { print }' "$PROJ/docs/STATE.md" "$S/templates/STATE.md")
  if [ -n "$add" ]; then
    [ -n "$(tail -c 1 "$PROJ/docs/STATE.md")" ] && printf '\n' >> "$PROJ/docs/STATE.md"
    printf '\n%s\n' "$add" >> "$PROJ/docs/STATE.md"
    note "\`docs/STATE.md\`: добавлены разделы $(printf '%s\n' "$add" | grep '^## ' | sed 's/^## /«/; s/$/»/' | tr '\n' ' ' | sed 's/ $//')"
  fi
fi

# --- Workflow обвязки. Непереносённые запоминаются в source.json, чтобы аудит напоминал о них и после этого PR.
pending=""
for f in "$TPL"/.github/workflows/harness-*.yml; do
  [ -f "$f" ] || continue
  rel=".github/workflows/$(basename "$f")"
  cmp -s "$f" "$PROJ/$rel" && continue
  if [ "$SKIP_WF" = 1 ]; then
    pending="$pending$rel"$'\n'
    watch "\`$rel\` в основе новее, чем в проекте, или его в проекте нет. Встроенный токен GitHub Actions не может менять workflow: перенеси обвязку вручную командой из README основы, раздел «Первое подключение», или скажи в сессии проекта «обнови обвязку из основы»"
  else
    put "$f" "$rel"
  fi
done
pending_json=$(printf '%s' "$pending" | jq -R . | jq -s 'map(select(length > 0))')

# --- Версия основы в проекте
if [ -f "$PROJ/.harness/source.json" ] && jq -e . "$PROJ/.harness/source.json" >/dev/null 2>&1; then
  base_json="$PROJ/.harness/source.json"; base_filter='.'
else
  base_json="$TPL/.harness/source.json"; base_filter='{repo: .repo, ref: (.ref // "main"), template: false}'
fi
jq --arg v "$NEW_VER" --argjson p "$pending_json" \
  "$base_filter | .version = \$v | (if (\$p | length) > 0 then .workflows_pending = \$p else del(.workflows_pending) end)" \
  "$base_json" > "$tmp"
put "$tmp" ".harness/source.json"

# --- Отчёт
printf '## Обвязка %s → %s\n\n' "${OLD_VER:-?}" "${NEW_VER:-?}"
if [ -n "$changed" ]; then printf '### Изменено\n%s\n' "$changed"; else printf 'Изменений нет: проект уже на этой версии.\n\n'; fi
[ -n "$details" ] && printf '<details><summary>Файлы скиллов</summary>\n\n%s\n</details>\n\n' "$details"
[ -n "$attention" ] && printf '### Требует внимания\n%s\n' "$attention"
exit 0
