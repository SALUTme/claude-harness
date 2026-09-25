#!/usr/bin/env bash
# harness-setup | PreToolUse, matcher Bash
# Страховочная сетка против разрушительных команд и порчи файлов обвязки.
# Regex и разбор команд обходятся глобами, переменными и скриптами. Основная защита: права, песочница и ревью.
set -u

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
RUNTIME="$ROOT/.harness/runtime"
mkdir -p "$RUNTIME" 2>/dev/null

log() { printf '%s\tblock-dangerous\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" >> "$RUNTIME/hooks.log" 2>/dev/null; }

decide() { # $1 = deny|ask, $2 = причина
  log "$1" "$2"
  jq -n --arg d "$1" --arg r "$2" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:$d,permissionDecisionReason:$r}}'
  exit 0
}

if ! command -v jq >/dev/null 2>&1; then
  echo "harness: jq не найден. Команды Bash заблокированы, пока jq не установлен." >&2
  exit 2
fi
if [ ! -f "$HOOK_DIR/_harness_lib.sh" ]; then
  echo "harness: рядом с хуком нет _harness_lib.sh. Команды Bash заблокированы." >&2
  exit 2
fi
. "$HOOK_DIR/_harness_lib.sh"

input=$(cat)
cmd=$(jq -r '.tool_input.command // empty' <<<"$input")
[ -z "$cmd" ] && exit 0

m()    { printf '%s' "$cmd" | grep -Eiq -- "$1"; }
has()  { printf '%s' "$2"   | grep -Eiq -- "$1"; }
hascs(){ printf '%s' "$2"   | grep -Eq  -- "$1"; }
ere_escape() { printf '%s' "$1" | sed 's/[].[\*^$()+?{|]/\\&/g'; }
args_of() { printf '%s' "$1" | awk '{ for (i = 2; i <= NF; i++) if ($i !~ /^-/) print $i }'; }

segments=$(harness_segments "$cmd")

# ---------------------------------------------------------------------------
# 1. Файлы обвязки
#    Проект: .claude/hooks, .claude/settings*.json, .claude/harness.env.
#    Глобально: ~/.claude/settings*.json, через них можно выключить хуки проекта.
#    Запись запрещена, чтение разрешено. Плагины и скиллы в ~/.claude не затрагиваются.
# ---------------------------------------------------------------------------
ROOT_RE=$(ere_escape "$ROOT")
HOME_RE=$(ere_escape "${HOME:-/nonexistent-home}")
HP_START=$'(^|[[:space:]"\'=(<>])'
HP_PREFIX=$'(\\./|"?[$][{]?(CLAUDE_PROJECT_DIR|PWD)[}]?"?/|"?(__SUB__|[$][(][^)]*[)]|`[^`]*`)"?/|([^[:space:]"\'/<>=]+/)*[.][.]/|'"${ROOT_RE}"$'/)?'
HP_TAIL=$'([.]claude(/(hook|settings|harness|skill)[^/[:space:]"\';&|)]*|/[*?[]|/?(["\'[:space:];&|)]|$))|[.]github(/workflows[^[:space:]"\';&|)]*|/[*?[]|/?(["\'[:space:];&|)]|$)))'
HOME_PREFIX=$'"?(~|[$][{]?HOME[}]?|'"${HOME_RE}"$')"?/[.]claude'
HP_GLOBAL="${HOME_PREFIX}/settings([.]local)?[.]json"
HP="((${HP_START}${HP_PREFIX}${HP_TAIL})|(${HP_START}${HP_GLOBAL}))"
HP_GLOBALX="${HP_START}${HP_GLOBAL}"
is_global=0
GLOBAL_DIR="${HP_START}${HOME_PREFIX}"$'/?("|[[:space:];&|)]|$)'
SETJSON=$'(^|[[:space:]"\'=<>/])settings([.]local)?[.]json(["\'[:space:];&|)]|$)'

tamper() {
  if [ "${is_global:-0}" = "1" ]; then
    decide deny "Команда меняет глобальные настройки Claude Code в ~/.claude. Через них можно выключить хуки проекта, поэтому это делает только человек."
  fi
  decide deny "Файлы обвязки проекта в .claude/ и проверки CI в .github/workflows/ через терминал не меняются: в запросе не видно, что именно изменится. Внеси правку через редактирование файла, тогда пользователь увидит изменения и подтвердит их."
}

# Путь явно вне текущего контекста: абсолютный или от домашней папки
outside() {
  case "$1" in
    /*|~*|\$HOME*|\$\{HOME\}*|\"/*|\"~*|\"\$HOME*|\"\$\{HOME\}*) return 0 ;;
    \$TMPDIR*|\$\{TMPDIR*|\"\$TMPDIR*|\"\$\{TMPDIR*) return 0 ;;
  esac
  return 1
}
# Цель записи попадает в файлы обвязки
hits() {
  has "$HP" " $1" && return 0
  [ "$gs" = "1" ] && has "$SETJSON" " $1" && return 0
  [ "$ctx" = "1" ] && ! outside "$1" && return 0
  return 1
}

if [ "${HARNESS_ALLOW_SELF_EDIT:-0}" != "1" ] && { m "$HP" || m "$GLOBAL_DIR"; }; then
  # Вложенная оболочка и eval прячут настоящие команды, разбирать их не пытаемся
  if m '(^|[[:space:](/;&|])((ba|z|k|da)?sh[[:space:]]+-[[:alnum:]]*c|eval)([[:space:]]|$)'; then
    m "$HP_GLOBALX" && is_global=1
    tamper
  fi

  in_claude=0
  in_global=0
  in_loop=0
  prev_hp=0
  while IFS= read -r raw; do
    seg=$(harness_trim "$raw")
    [ -z "$seg" ] && continue
    word=$(harness_cmdword "$seg")
    first=$(printf '%s' "$seg" | awk '{print $1}'); first=${first##*/}

    if [ "$word" = "git" ]; then
      case "$(harness_git_subcmd "$seg")" in
        commit|tag|merge|notes)
          seg=$(printf '%s' "$seg" | sed -E "s/(-[[:alpha:]]*m|--message)(=|[[:space:]]+)(\"[^\"]*\"?|'[^']*'?|[^[:space:]]+)//g") ;;
      esac
    fi

    case "$word" in
      cd|pushd)
        if has "^(cd|pushd)([[:space:]]+-[[:alnum:]]+)*[[:space:]]*${HP}" "$seg"; then
          in_claude=1; in_global=0
        elif has "^(cd|pushd)([[:space:]]+-[[:alnum:]]+)*[[:space:]]*${GLOBAL_DIR}" "$seg"; then
          in_global=1; in_claude=0
        elif [ "$in_claude" = "1" ] || [ "$in_global" = "1" ]; then
          target=$(printf '%s' "$seg" | awk '{ for (i = 2; i <= NF; i++) if ($i !~ /^-/) { print $i; exit } }')
          case "$target" in ""|..*|/*|~*|\$*|-|\"*|\'*) in_claude=0; in_global=0 ;; esac
        fi
        prev_hp=0
        continue ;;
      popd) in_claude=0; in_global=0; prev_hp=0; continue ;;
      for|select)
        has "$HP" "$seg" && in_loop=1
        prev_hp=0
        continue ;;
      done) in_loop=0; prev_hp=0; continue ;;
    esac

    ctx=0
    { [ "$in_claude" = "1" ] || [ "$in_loop" = "1" ]; } && ctx=1
    [ "$first" = "xargs" ] && [ "$prev_hp" = "1" ] && ctx=1
    seg_hp=0
    has "$HP" "$seg" && seg_hp=1
    gs=0
    [ "$in_global" = "1" ] && has "$SETJSON" "$seg" && gs=1
    prev_hp=$seg_hp
    gd=0
    has "$GLOBAL_DIR" "$seg" && gd=1
    [ "$ctx" = "1" ] || [ "$seg_hp" = "1" ] || [ "$gs" = "1" ] || [ "$gd" = "1" ] || continue
    is_global=0
    { [ "$gs" = "1" ] || [ "$gd" = "1" ] || has "$HP_GLOBALX" "$seg"; } && is_global=1

    # Копирование или перенос в саму папку ~/.claude может подменить глобальные настройки
    if [ "$gd" = "1" ]; then
      dest=$(printf '%s' "$seg" | awk '{print $NF}')
      if has "$GLOBAL_DIR" " $dest"; then
        case "$word" in
          rsync) tamper ;;
          cp|mv|ln|install)
            [ "$word" = "cp" ] && has '[[:space:]]-[[:alnum:]]*[ra]' "$seg" && tamper
            while IFS= read -r a; do
              { [ -z "$a" ] || [ "$a" = "$dest" ]; } && continue
              b=$(printf '%s' "$a" | tr -d "\"'" | tr '[:upper:]' '[:lower:]'); b=${b%/}
              case "${b##*/}" in settings.json|settings.local.json) tamper ;; esac
              if [ "$word" = "mv" ]; then
                case "$a" in */|*/\"|*/\') tamper ;; esac
              fi
            done <<< "$(args_of "$seg")"
            ;;
        esac
      fi
    fi

    # Перенаправление вывода
    targets=$(printf '%s' "$seg" | grep -Eo '(^|[^>])&?[0-9]*>>?[|]?[[:space:]]*"?[^[:space:]";|)]+' | sed -E 's/^[^>]*>>?[|]?[[:space:]]*"?//')
    while IFS= read -r t; do
      case "$t" in ""|/dev/*|\&*) continue ;; esac
      hits "$t" && tamper
    done <<< "$targets"

    case "$word" in
      git)
        case "$(harness_git_subcmd "$seg")" in
          checkout|restore|stash|reset|rm|mv|clean|apply|am|cherry-pick|revert|merge|rebase|pull|switch)
            { [ "$seg_hp" = "1" ] || [ "$ctx" = "1" ]; } && tamper ;;
        esac ;;
      tee)
        while IFS= read -r a; do [ -n "$a" ] && hits "$a" && tamper; done <<< "$(args_of "$seg")" ;;
      sed)
        if has '[[:space:]](-[[:alnum:]]*i|--in-place)' "$seg"; then
          last=$(printf '%s' "$seg" | awk '{print $NF}')
          hits "$last" && tamper
        fi ;;
      perl|ruby|python|python[0-9]*|node|nodejs|deno|bun|php|osascript)
        { [ "$seg_hp" = "1" ] || [ "$gs" = "1" ] || [ "$ctx" = "1" ]; } && tamper ;;
      dd)
        of=$(printf '%s' "$seg" | grep -Eo 'of=[^[:space:]]+' | head -n 1 | sed 's/^of=//')
        [ -n "$of" ] && hits "$of" && tamper ;;
      find)
        has '[[:space:]](-delete|-exec|-execdir|-ok|-okdir)([[:space:]]|$)' "$seg" && tamper ;;
      rm|rmdir|mv|chmod|chown|chgrp|truncate|unlink|touch|shred)
        [ "$seg_hp" = "1" ] && tamper
        while IFS= read -r a; do [ -n "$a" ] && hits "$a" && tamper; done <<< "$(args_of "$seg")" ;;
      cp|ln|install|rsync)
        last=$(printf '%s' "$seg" | awk '{print $NF}')
        hits "$last" && tamper ;;
    esac
  done <<< "$segments"
fi

# ---------------------------------------------------------------------------
# 2. Разрушительные команды: запрет
# ---------------------------------------------------------------------------
S='(^|[;&|(`[:space:]])'
RM='(/usr)?(/bin/)?rm[[:space:]]+(-[[:alnum:]]*r[[:alnum:]]*|--recursive)([[:space:]]+-[[:alnum:]-]*)*[[:space:]]+'
END='"?([[:space:]]|$|[;&|)])'

if m "${S}${RM}\"?(/|~|[\$][{]?HOME[}]?|[*]|[.]|[.][.]|[.]git)\"?([*]|/|/[*])?${END}"; then
  decide deny "Рекурсивное удаление корня, домашней папки, текущей папки или .git запрещено обвязкой."
fi
if m "${S}${RM}\"?/(etc|usr|bin|sbin|var|opt|System|Library|Applications|private|Users|home)(/[^/[:space:]\";&|]+)?/?${END}"; then
  decide deny "Рекурсивное удаление системной или домашней папки запрещено обвязкой."
fi
if m '(curl|wget)[^;&]*[|][[:space:]]*(sudo[[:space:]]+)?(ba|z|da|k)?sh([[:space:]]|$)'; then
  decide deny "Запуск скачанного скрипта через пайп запрещён. Скачай файл, покажи его человеку, потом решайте."
fi
if m "${S}(mkfs([.][[:alnum:]]+)?[[:space:]]|dd[[:space:]]+[^;&|]*of=/dev/)" || m '>[[:space:]]*/dev/(disk|sd|nvme)' \
   || m "${S}chmod[[:space:]]+-R[[:space:]]+0?777[[:space:]]+(/|~)"; then
  decide deny "Операции с дисками и массовая смена прав запрещены обвязкой."
fi

# ---------------------------------------------------------------------------
# 3. Git: разбор по настоящей подкоманде
# ---------------------------------------------------------------------------
GITLOSS="Команда безвозвратно отбрасывает изменения в git. Нужно подтверждение человека."
while IFS= read -r raw; do
  seg=$(harness_trim "$raw")
  [ -z "$seg" ] && continue
  [ "$(harness_cmdword "$seg")" = "git" ] || continue
  case "$(harness_git_subcmd "$seg")" in
    push)
      if has '[[:space:]](-f|--force|--force-with-lease(=[^[:space:]]*)?|--mirror)([[:space:]]|$)' "$seg" || has '[[:space:]][+][^[:space:]]+' "$seg"; then
        decide deny "Force push запрещён обвязкой. Если он действительно нужен, его делает человек."
      fi
      if has '[[:space:]](--delete|-d)([[:space:]]|$)' "$seg" || has '[[:space:]]:[^[:space:]]+([[:space:]]|$)' "$seg"; then
        decide ask "Команда удаляет ветку на удалённом репозитории. Нужно подтверждение человека."
      fi ;;
    reset)            has '[[:space:]]--hard([[:space:]]|$)' "$seg" && decide ask "$GITLOSS" ;;
    clean)            has '[[:space:]](-[[:alnum:]]*f[[:alnum:]]*|--force)([[:space:]]|$)' "$seg" && decide ask "$GITLOSS" ;;
    checkout|restore) has '[[:space:]](--[[:space:]]+)?[.]/?([[:space:]]|$)' "$seg" && decide ask "$GITLOSS" ;;
    branch)           hascs '[[:space:]](-D|--delete[[:space:]]+--force|--force[[:space:]]+--delete)([[:space:]]|$)' "$seg" && decide ask "Принудительное удаление ветки. Нужно подтверждение человека." ;;
    stash)            has '[[:space:]](drop|clear)([[:space:]]|$)' "$seg" && decide ask "$GITLOSS" ;;
  esac
done <<< "$segments"

# ---------------------------------------------------------------------------
# 4. Опасные, но иногда нужные команды: спросить человека
# ---------------------------------------------------------------------------
if m "${S}sudo[[:space:]]"; then
  decide ask "Команда с sudo. Нужно подтверждение человека."
fi
if m '(drop[[:space:]]+(database|schema|table)|truncate[[:space:]]+table)' \
   || m 'delete[[:space:]]+from[[:space:]]+[[:alnum:]_."]+[[:space:]]*(;|"|$)'; then
  decide ask "Разрушительная операция с базой данных. Убедись, что это не продовая база, и получи подтверждение человека."
fi
if m "${S}((npm|pnpm|yarn)[[:space:]]+publish|twine[[:space:]]+upload|cargo[[:space:]]+publish|gem[[:space:]]+push)"; then
  decide ask "Публикация пакета. Нужно подтверждение человека."
fi

exit 0
