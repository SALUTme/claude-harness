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
