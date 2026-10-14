#!/usr/bin/env bash
# harness-setup | общие функции хуков. Подключается через source и сам ничего не делает.

# Разбивает команду на простые команды, по одной на строку.
# Учитывает одинарные и двойные кавычки: внутри них разделители не работают.
# Тела $(...) и `...` разбираются отдельно и выводятся как самостоятельные команды, в исходной строке остаётся __SUB__.
# Тело heredoc выбрасывается, только если найден маркер конца. Иначе следующие строки разбираются как обычно.
# Разделители вне кавычек: && || ; | & и перевод строки. Перенаправления >& &> >| разделителями не считаются.
harness_segments() {
  printf '%s' "$1" | awk -v q="'" '
    function emit(t) {
      gsub(/^[ \t(){}!]+/, "", t); gsub(/[ \t)}]+$/, "", t)
      if (t != "") print t
    }
    function seg(s,    n, i, c, c2, cur, sq, dq, depth, j, k, rest, m, delim, hd, found, line, t, nextj, re, isq, idq) {
      n = length(s); cur = ""; sq = 0; dq = 0; hd = ""
      re = "^-?[ \t]*[\"" q "]?[A-Za-z_][A-Za-z0-9_]*[\"" q "]?"
      i = 1
      while (i <= n) {
        c = substr(s, i, 1); c2 = substr(s, i, 2)
        if (sq) { if (c == q) sq = 0; cur = cur (c == "\n" ? " " : c); i++; continue }
        if (c == "\\") {
          if (substr(s, i + 1, 1) == "\n") cur = cur " "; else cur = cur substr(s, i, 2)
          i += 2; continue
        }
        if (c2 == "$(" && substr(s, i + 2, 1) != "(") {
          depth = 1; j = i + 2
          isq = 0; idq = 0
          while (j <= n && depth > 0) {
            k = substr(s, j, 1)
            if (isq) { if (k == q) isq = 0 }
            else if (k == "\\") { j++ }
            else if (idq) { if (k == "\"") idq = 0; else if (k == "$" && substr(s, j + 1, 1) == "(") { depth++; j++ } else if (k == ")") depth-- }
            else if (k == q) isq = 1
            else if (k == "\"") idq = 1
            else if (k == "(") depth++
            else if (k == ")") depth--
            j++
          }
          seg(substr(s, i + 2, j - i - 3))
          cur = cur "__SUB__"; i = j; continue
        }
        if (c == "`") {
          k = index(substr(s, i + 1), "`")
          if (k > 0) { seg(substr(s, i + 1, k - 1)); cur = cur "__SUB__"; i = i + k + 1; continue }
        }
        if (dq) { if (c == "\"") dq = 0; cur = cur (c == "\n" ? " " : c); i++; continue }
        if (c == q)    { sq = 1; cur = cur c; i++; continue }
        if (c == "\"") { dq = 1; cur = cur c; i++; continue }
        if (c2 == "<<" && substr(s, i + 2, 1) != "<" && (i == 1 || substr(s, i - 1, 1) != "<")) {
          rest = substr(s, i + 2)
          if (match(rest, re)) {
            m = substr(rest, RSTART, RLENGTH)
            delim = m; sub(/^-?[ \t]*/, "", delim); gsub("[\"" q "]", "", delim)
            hd = delim; cur = cur "<<" m; i = i + 2 + RLENGTH; continue
          }
        }
        if (c == "\n") {
          emit(cur); cur = ""; i++
          if (hd != "") {
            found = 0; j = i
            while (j <= n) {
              k = index(substr(s, j), "\n")
              if (k == 0) { line = substr(s, j); nextj = n + 1 } else { line = substr(s, j, k - 1); nextj = j + k }
              t = line; gsub(/^[ \t]+/, "", t); gsub(/[ \t]+$/, "", t)
              j = nextj
              if (t == hd) { found = 1; break }
            }
            if (found) i = j
            hd = ""
          }
          continue
        }
        if (c2 == "&&" || c2 == "||") { emit(cur); cur = ""; i += 2; continue }
        if (c == ";") { emit(cur); cur = ""; i++; continue }
        if (c == "|") {
          if (substr(cur, length(cur), 1) == ">") { cur = cur c; i++; continue }
          emit(cur); cur = ""; i++; continue
        }
        if (c == "&") {
          if (substr(cur, length(cur), 1) == ">" || substr(s, i + 1, 1) == ">") { cur = cur c; i++; continue }
          emit(cur); cur = ""; i++; continue
        }
        cur = cur c; i++
      }
      emit(cur)
    }
    { all = (NR == 1 ? $0 : all "\n" $0) }
    END { seg(all) }'
}

# Убирает скобки группировки и пробелы по краям сегмента.
harness_trim() {
  printf '%s' "$1" | sed -E 's/^[[:space:](){}!]+//; s/[[:space:])}]+$//'
}

# Печатает имя исполняемой команды сегмента без пути.
# Пропускает присваивания VAR=value, префиксы вроде sudo, env, nice, timeout, ключевые слова оболочки и опции перед командой.
# Снимает с имени ведущий обратный слеш и кавычки: \rm и "rm" дают rm.
harness_cmdword() {
  local tok skip=0 prev=""
  set -f
  for tok in $1; do
    tok=${tok#\(}; tok=${tok#\{}; tok=${tok#\\}
    tok=${tok#\"}; tok=${tok%\"}; tok=${tok#\'}; tok=${tok%\'}
    [ -z "$tok" ] && continue
    if [ "$skip" = 1 ]; then skip=0; continue; fi
    case "$tok" in
      -n|-u|-g|-C|-p|-s|-k|-I|-L|-P)
        case "$prev" in nice|sudo|doas|timeout|ionice|xargs|env) skip=1 ;; esac
        continue ;;
      -*) continue ;;
      *=*) continue ;;
      timeout) prev=$tok; skip=1; continue ;;
      sudo|doas|env|command|builtin|exec|nice|nohup|xargs|ionice|time|if|then|else|elif|do|while|until|!)
        prev=$tok; continue ;;
    esac
    set +f
    printf '%s' "${tok##*/}"
    return 0
  done
  set +f
}

# Печатает подкоманду git, пропуская глобальные опции git вроде -C путь и -c ключ=значение.
harness_git_subcmd() {
  local tok seen=0 skip=0
  set -f
  for tok in $1; do
    tok=${tok#\\}; tok=${tok#\"}; tok=${tok%\"}
    if [ "$seen" = 0 ]; then
      [ "${tok##*/}" = "git" ] && seen=1
      continue
    fi
    if [ "$skip" = 1 ]; then skip=0; continue; fi
    case "$tok" in
      -C|-c|--git-dir|--work-tree|--namespace|--exec-path|--super-prefix|--config-env) skip=1 ;;
      -*) ;;
      *) set +f; printf '%s' "$tok"; return 0 ;;
    esac
  done
  set +f
}

# Читает .claude/harness.env как строки HARNESS_КЛЮЧ=ЗНАЧЕНИЕ, не выполняя файл.
# Пробелы и возврат каретки по краям обрезаются. Значение в кавычках берётся до закрывающей кавычки,
# у значения без кавычек отбрасывается комментарий после « #». HARNESS_ALLOW_SELF_EDIT из файла не читается никогда.
# Этот разбор совпадает с проверкой harness.env в secret-guard.sh.
harness_load_env() {
  local f="$1" line key val rest
  [ -f "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    case "$line" in ''|'#'*) continue ;; esac
    key=${line%%=*}
    [ "$key" = "$line" ] && continue
    val=${line#*=}
    case "$key" in HARNESS_ALLOW_SELF_EDIT) continue ;; HARNESS_*) ;; *) continue ;; esac
    case "$key" in *[!A-Z_]*) continue ;; esac
    val="${val#"${val%%[![:space:]]*}"}"
    case "$val" in
      \"*) rest=${val#\"}; case "$rest" in *\"*) val=${rest%%\"*} ;; esac ;;
      \'*) rest=${val#\'}; case "$rest" in *\'*) val=${rest%%\'*} ;; esac ;;
      *)   case "$val" in *" #"*) val=${val%%" #"*} ;; esac
           val="${val%"${val##*[![:space:]]}"}" ;;
    esac
    printf -v "$key" '%s' "$val"
  done < "$f"
}

# Ищет в тексте то, что похоже на секрет. Печатает вид секрета и возвращает 0, если нашёл.
# Тестовые ключи Stripe вида sk_test_ секретом не считаются.
harness_secret_kind() { # $1 = текст
  local t="$1" B='(^|[^A-Za-z0-9_-])'
  if   printf '%s' "$t" | grep -Eq -- "${B}AKIA[0-9A-Z]{16}";                   then echo "ключ AWS"
  elif printf '%s' "$t" | grep -Eq -- '-----BEGIN [A-Z ]*PRIVATE KEY-----';     then echo "приватный ключ"
  elif printf '%s' "$t" | grep -Eq -- "${B}gh[pousr]_[A-Za-z0-9]{36}";          then echo "токен GitHub"
  elif printf '%s' "$t" | grep -Eq -- "${B}github_pat_[A-Za-z0-9_]{40,}";       then echo "токен GitHub"
  elif printf '%s' "$t" | grep -Eq -- "${B}sk-(proj-|ant-)?[A-Za-z0-9_-]{32,}"; then echo "API-ключ"
  elif printf '%s' "$t" | grep -Eq -- "${B}xox[abprs]-[A-Za-z0-9-]{10,}";       then echo "токен Slack"
  elif printf '%s' "$t" | grep -Eq -- "${B}AIza[0-9A-Za-z_-]{35}";              then echo "ключ Google API"
  elif printf '%s' "$t" | grep -Eq -- "${B}(sk|rk)_live_[A-Za-z0-9]{20,}";      then echo "боевой ключ Stripe"
  elif printf '%s' "$t" | grep -Eq -- "${B}whsec_[A-Za-z0-9]{32,}";             then echo "секрет вебхука Stripe"
  else return 1
  fi
}

# Возвращает 0, если в тексте есть похожее на JWT: три части base64url через точку, первые две начинаются с eyJ.
harness_jwt_like() { # $1 = текст
  printf '%s' "$1" | grep -Eq -- '(^|[^A-Za-z0-9_-])eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'
}

# Изменённые пути относительно HEAD по одному на строку: правки, индекс и новые файлы.
# Вывод -z устойчив к пробелам и кавычкам. В репозитории без коммитов сравнивает с пустым деревом,
# чтобы видеть проиндексированные файлы. Вызывается из папки проекта. Если проект лежит в подпапке
# репозитория, пути считаются от неё и изменения вне её не попадают: --relative у diff, ls-files так и работает.
harness_changed_paths() {
  local base
  if git rev-parse --verify -q HEAD >/dev/null 2>&1; then
    base=HEAD
  else
    base=$(git hash-object -t tree /dev/null)
  fi
  { git diff --name-only --relative -z "$base" -- 2>/dev/null
    git diff --name-only --relative -z --cached "$base" -- 2>/dev/null
    git ls-files -o --exclude-standard -z 2>/dev/null
  } | tr '\0' '\n' | grep -v '^$' | grep -v '^\.harness/runtime/' | sort -u
}

# Оставляет из списка путей те, что проверяются воротами: без HARNESS_CHECK_SKIP_REGEX и HARNESS_GATE_EXCLUDE_REGEX.
# Негодное выражение не должно молча отключать ворота: тогда оно не исключает ничего.
harness_code_paths() { # $1 = пути по одному на строку
  local skip exclude code
  skip="${HARNESS_CHECK_SKIP_REGEX:-\.(md|mdx|txt|rst)$}"
  if [ -n "$skip" ]; then
    printf 'x\n' | grep -Eq -- "$skip" 2>/dev/null
    [ "$?" -gt 1 ] && skip=''
  fi
  # В режиме «исследование» вики и материалы как раз проверяются: там их проверяет wiki-lint.
  exclude="${HARNESS_GATE_EXCLUDE_REGEX-__HARNESS_UNSET__}"
  [ "$exclude" = "__HARNESS_UNSET__" ] && exclude='^(docs|wiki|raw|\.harness|\.claude)/'
  if [ -n "$exclude" ]; then
    printf 'x\n' | grep -Eq -- "$exclude" 2>/dev/null
    [ "$?" -gt 1 ] && exclude=''
  fi
  code=$(printf '%s\n' "$1" | grep -v '^$' || true)
  [ -n "$skip" ] && code=$(printf '%s\n' "$code" | grep -v '^$' | grep -Ev -- "$skip" || true)
  [ -n "$exclude" ] && code=$(printf '%s\n' "$code" | grep -v '^$' | grep -Ev -- "$exclude" || true)
  printf '%s' "$code"
}

# Отпечаток для кэша зелёного прогона: команда тестов, дерево HEAD, список и содержимое файлов. Хеши считаются одним процессом.
# Гейт конца хода сравнивает отпечаток файлов кода с last-green. Гейт коммита строже: сравнивает отпечаток
# всех изменённых файлов с last-green-all, потому что тесты могут читать и исключённые файлы, например эталоны в .txt.
# Зелёный прогон любого из гейтов записывает оба отпечатка.
harness_fingerprint() { # $1 = пути по одному на строку
  local f existing="" deleted="" prefix
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    if [ -f "$f" ]; then existing="$existing$f"$'\n'; else deleted="${deleted}deleted:$f"$'\n'; fi
  done <<< "$1"
  # hash-object --stdin-paths читает пути от корня репозитория, а не от папки проекта: добавляем путь подпапки.
  prefix=$(git rev-parse --show-prefix 2>/dev/null)
  { printf 'cmd:%s\n' "${HARNESS_TEST_CMD:-}"
    printf 'head:%s\n' "$(git rev-parse -q --verify 'HEAD^{tree}' 2>/dev/null || echo none)"
    printf '%s' "$existing"
    [ -n "$existing" ] && printf '%s' "$existing" | while IFS= read -r f; do printf '%s%s\n' "$prefix" "$f"; done | git hash-object --stdin-paths
    printf '%s' "$deleted"
  } | git hash-object --stdin
}
