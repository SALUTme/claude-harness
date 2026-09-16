#!/usr/bin/env bash
# harness-setup | идемпотентное слияние шаблона прав и хуков в существующий settings.json.
# Печатает результат в stdout и не меняет исходные файлы.
# Пользовательские правила и хуки сохраняются в своём порядке.
# Плагины шаблона добавляются, если их нет; отключённый пользователем плагин остаётся отключённым.
# Маркетплейс с тем же репозиторием, что в шаблоне, берётся из шаблона вместе с закреплённой версией. Маркетплейс с другим репозиторием считается осознанным форком и сохраняется.
# Правила прошлых версий шаблона удаляются, хуки обвязки заменяются текущей версией.
# При ошибке ничего не печатает и возвращает ненулевой код.
# Использование: merge-settings.sh <settings.json> <settings.template.json>
set -u

target="${1:?укажи settings.json}"
template="${2:?укажи шаблон}"
command -v jq >/dev/null 2>&1 || { echo "merge-settings: нужен jq" >&2; exit 1; }
jq -e . "$template" >/dev/null 2>&1 || { echo "merge-settings: шаблон $template не валидный JSON" >&2; exit 1; }

if [ ! -f "$target" ]; then
  jq . "$template"
  exit $?
fi
jq -e . "$target" >/dev/null 2>&1 || { echo "merge-settings: $target не валидный JSON, слияние остановлено" >&2; exit 1; }

out=$(jq -s '
  def obsolete: [
    "Read(./.env)", "Read(./.env.local)", "Read(./.env.production)", "Read(./.env.development)",
    "Edit(./.claude/hooks/**)", "Write(./.claude/hooks/**)",
    "Edit(./.claude/settings.json)", "Write(./.claude/settings.json)",
    "Edit(./.claude/harness.env)", "Write(./.claude/harness.env)"
  ];
  def moved_to_ask: ["Edit(/.claude/hooks/**)", "Edit(/.claude/settings.json)", "Edit(/.claude/harness.env)"];
  def harness_handler:
    (.command // "") | test("[.]claude/hooks/(block-dangerous|secret-guard|after-edit-check|commit-gate|stop-gate|harness-status|env-setup)[.]sh");
  def clean_rules($xs): [ ($xs // [])[] | . as $r | select(any(obsolete[]; . == $r) | not) ];
  def append_new($xs; $ys): reduce ($ys // [])[] as $y ($xs; if any(.[]; . == $y) then . else . + [$y] end);

  .[0] as $a | .[1] as $b
  | $a
  | .permissions = (($a.permissions // {}) + (($b.permissions // {}) | del(.allow, .ask, .deny)) + {
        allow: append_new(clean_rules($a.permissions.allow); $b.permissions.allow),
        ask:   append_new([ clean_rules($a.permissions.ask)[] | . as $r | select(any(($b.permissions.deny // [])[]; . == $r) | not) ]; $b.permissions.ask),
        deny:  append_new([ clean_rules($a.permissions.deny)[] | . as $r | select(any(moved_to_ask[]; . == $r) | not) ]; $b.permissions.deny)
      })
  | (if ($b | has("disableAllHooks")) then .disableAllHooks = $b.disableAllHooks else . end)
  | (if (($b.enabledPlugins // {}) | length) > 0 then .enabledPlugins = (($b.enabledPlugins // {}) + ($a.enabledPlugins // {})) else . end)
  | (if (($b.extraKnownMarketplaces // {}) | length) > 0 then
      ($a.extraKnownMarketplaces // {}) as $am
      | def src: (.source.url // .source.repo // null);
      .extraKnownMarketplaces = ($am + (($b.extraKnownMarketplaces) | with_entries(select(($am[.key] == null) or (($am[.key] | src) == (.value | src))))))
    else . end)
  | .hooks = (
      (($a.hooks // {})
        | with_entries(.value |= [ .[] | .hooks |= map(select(harness_handler | not)) | select((.hooks | length) > 0) ]))
      | reduce (($b.hooks // {}) | to_entries[]) as $ev (.; .[$ev.key] = ((.[$ev.key] // []) + $ev.value))
      | with_entries(select((.value | length) > 0))
    )
' "$target" "$template") || { echo "merge-settings: ошибка jq, слияние остановлено" >&2; exit 1; }

printf '%s\n' "$out"
