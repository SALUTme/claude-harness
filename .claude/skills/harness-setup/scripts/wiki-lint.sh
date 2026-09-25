#!/usr/bin/env bash
# harness-setup | проверка вики. В режиме «исследование» играет роль тестов: её запускают гейты коммита и конца хода.
# Проверяет то, что делает знания пригодными к использованию: источники, живые ссылки, журнал, связность.
# Источник страницы это список sources в заголовке файла по схеме wiki/SCHEMA.md или непустой раздел «Источники».
# Кириллицы в шаблонах awk нет намеренно: на macOS awk с ней не работает.
# Использование: wiki-lint.sh [папка_проекта]
# Код выхода: 0 без проблем, 1 если есть хотя бы одна.
set -u

cd "${1:-.}" 2>/dev/null || { echo "ПРОБЛЕМА  папка проекта не найдена: ${1:-.}"; exit 1; }

problems=0
bad() { problems=$((problems + 1)); printf 'ПРОБЛЕМА  %s\n' "$1"; }
info() { printf 'ЗАМЕТКА   %s\n' "$1"; }

[ -d wiki ] || { echo "ПРОБЛЕМА  нет папки wiki"; exit 1; }
for f in wiki/SCHEMA.md wiki/index.md wiki/log.md; do
  [ -f "$f" ] || bad "нет файла $f"
done

# Страницы вики: всё, кроме служебных файлов
# Имена файлов с переводом строки не поддерживаются: в вики таких не бывает.
pagelist=$(find wiki -type f -name '*.md' ! -name 'index.md' ! -name 'log.md' ! -name 'SCHEMA.md' 2>/dev/null | sort)
page_names=$(printf '%s\n' "$pagelist" | sed -E 's#^wiki/##; s#\.md$##')

# --- Страницы: источники, заглушки, ссылки
pages=0
while IFS= read -r f; do
  [ -z "$f" ] && continue
  pages=$((pages + 1))

  # Источники: список sources в заголовке файла или раздел «Источники» с содержимым.
  has_sources=0
  # Заголовок файла читаем только между парой ---, и только если вторая --- есть.
  if awk '{ sub(/\r$/, ""); if (NR == 1) sub(/^\357\273\277/, "") }
          NR == 1 { if ($0 != "---") exit 1; next }
          /^---[[:space:]]*$/ { closed = 1; exit !found }
          inlist && /^[[:space:]]*-[[:space:]]*[^[:space:]#]/ { found = 1; next }
          /^[^[:space:]]/ { inlist = 0 }
          /^sources:[[:space:]]*/ { rest = $0
            sub(/^sources:[[:space:]]*/, "", rest)
            sub(/[[:space:]]*#.*$/, "", rest)
            gsub(/[][[:space:]]/, "", rest)
            if (rest == "null" || rest == "~") rest = ""
            if (rest != "") { found = 1; next }
            inlist = 1 }
          END { exit !(found && closed) }' "$f" 2>/dev/null; then
    has_sources=1
  fi
  head_line=$(grep -nEi '^##+[[:space:]]*Источники' "$f" | head -n 1 | cut -d: -f1)
  if [ -n "$head_line" ]; then
    if tail -n "+$((head_line + 1))" "$f" | awk '/^#+[[:space:]]/{exit} /[^[:space:]]/{found=1} END{exit !found}'; then
      has_sources=1
    elif [ "$has_sources" = "0" ]; then
      bad "$f: раздел «Источники» пустой"
      has_sources=2
    fi
  fi
  if [ "$has_sources" = "0" ]; then
    bad "$f: нет источника. Заполни sources в заголовке файла по схеме или добавь раздел «Источники»"
  fi

  grep -q '{{' "$f" && bad "$f: остались заглушки шаблона {{...}}"

  # Ссылки и картинки на файлы проекта: путь считается от папки страницы, как его читает любой просмотрщик
  dir=$(dirname "$f")
  while IFS= read -r target; do
    [ -z "$target" ] && continue
    link=${target#<}; link=${link%>}
    link=${link%%#*}
    link=${link%%\?*}
    [ -z "$link" ] && continue
    # Адрес в сети пропускаем: это либо схема со слешами, либо известная схема без них.
    scheme=$(printf '%s' "${link%%:*}" | tr '[:upper:]' '[:lower:]')
    case "$link" in
      '//'*) continue ;;                                  # протокол по умолчанию
      *://*) case "$scheme" in *[!a-z0-9+.-]*) : ;; *) continue ;; esac ;;
    esac
    case "$scheme:" in
      mailto:|tel:|data:|urn:|sms:|callto:) continue ;;
    esac
    case "$link" in
      /*) bad "$f: ссылка от корня файловой системы $link, в репозитории так не работает"; continue ;;
    esac
    # Скобки внутри имени файла ломают разбор, такие ссылки пропускаем
    case "$link" in *'('*) continue ;; esac
    plain=$(printf '%s' "$link" | sed 's/%20/ /g')
    [ -e "$dir/$link" ] || [ -e "$dir/$plain" ] || bad "$f: ссылка на несуществующий файл $link"
  done <<EOF
$(grep -Eo '\]\([^)]+\)' "$f" | sed -E 's/^\]\(//; s/\)$//' | sed -E 's/[[:space:]]+"[^"]*"$//')
EOF

  # Ссылки на другие страницы вики в формате [[имя-страницы]]
  while IFS= read -r wl; do
    [ -z "$wl" ] && continue
    printf '%s\n' "$page_names" | grep -qxF -- "$wl" && continue
    printf '%s\n' "$page_names" | sed -E 's#.*/##' | grep -qxF -- "$wl" && continue
    bad "$f: ссылка [[$wl]] ведёт на несуществующую страницу"
  done <<EOF
$(grep -o '\[\[[^]]*\]\]' "$f" | sed 's/^\[\[//; s/\]\]$//')
EOF
done <<EOF
$pagelist
EOF

[ "$pages" -eq 0 ] && info "в вики пока нет страниц, кроме index, log и SCHEMA"

# --- Связность: страница должна быть достижима из index.md
if [ -f wiki/index.md ] && [ "$pages" -gt 0 ]; then
  while IFS= read -r rel; do
    [ -z "$rel" ] && continue
    grep -qF -- "$rel.md" wiki/index.md && continue
    grep -qF -- "[[$rel]]" wiki/index.md && continue
    base=${rel##*/}
    grep -qF -- "$base.md" wiki/index.md && continue
    grep -qF -- "[[$base]]" wiki/index.md && continue
    bad "wiki/$rel.md: страница не упомянута в wiki/index.md"
  done <<EOF
$page_names
EOF
fi

# --- Журнал операций
if [ -f wiki/log.md ]; then
  entries=$(grep -c '^## \[' wiki/log.md 2>/dev/null); entries=${entries:-0}
  if [ "$entries" -eq 0 ]; then
    if [ "$pages" -gt 0 ]; then
      bad "wiki/log.md: нет записей в формате ## [дата] операция | название, хотя страницы есть"
    else
      info "wiki/log.md пока пуст: первая запись появится после первой операции"
    fi
  fi
  badfmt=$(grep '^## \[' wiki/log.md | grep -Evc '^## \[[0-9]{4}-[0-9]{2}-[0-9]{2}\] +[^|]+ \| +.+' 2>/dev/null); badfmt=${badfmt:-0}
  [ "$badfmt" -gt 0 ] && bad "wiki/log.md: записей не по формату ## [ГГГГ-ММ-ДД] операция | название: $badfmt"
fi

# --- Материалы из raw/, которых ещё нет в журнале: это работа, а не брак
raw_new=0
if [ -d raw ] && [ -f wiki/log.md ]; then
  raw_new=$( { cat wiki/log.md; printf '\n__HARNESS_RAW_FILES__\n'
               find raw -type f ! -name '.*' ! -path 'raw/private/*' ! -path 'raw/assets/*' 2>/dev/null | head -n 2000; } |
             awk '/^__HARNESS_RAW_FILES__$/ { files = 1; next }
                  !files { logtext = logtext "\n" $0; next }
                  { b = $0; sub(/.*\//, "", b); if (index(logtext, b) == 0) c++ }
                  END { print c + 0 }')
  [ "$raw_new" -gt 0 ] && info "необработанных материалов в raw/: $raw_new. Это задача, а не ошибка"
fi

printf 'Итог: проблем %s, страниц %s, необработанных материалов %s\n' "$problems" "$pages" "$raw_new"
[ "$problems" -eq 0 ]
