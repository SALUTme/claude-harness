#!/usr/bin/env bash
# harness | PreToolUse, matcher Write|Edit|MultiEdit|NotebookEdit
# Не даёт агенту писать секреты, менять локальные и глобальные настройки и выключать защиту обвязки.
# Правки settings.json и harness.env проверяются по смыслу: хук вычисляет содержимое после правки и сравнивает с текущим.
set -u

SELF_EDIT="${HARNESS_ALLOW_SELF_EDIT:-0}"
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
RUNTIME="$ROOT/.harness/runtime"
mkdir -p "$RUNTIME" 2>/dev/null

log() { printf '%s\tsecret-guard\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" >> "$RUNTIME/hooks.log" 2>/dev/null; }
decide() {
  log "$1" "$2"
  jq -n --arg d "$1" --arg r "$2" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:$d,permissionDecisionReason:$r}}'
  exit 0
}
deny() { decide deny "$1"; }
ask()  { decide ask "$1"; }

if ! command -v jq >/dev/null 2>&1; then
  echo "harness: jq не найден. Запись файлов заблокирована, пока jq не установлен." >&2
  exit 2
fi
if [ ! -f "$HOOK_DIR/_harness_lib.sh" ]; then
  echo "harness: рядом с хуком нет _harness_lib.sh. Запись файлов заблокирована." >&2
  exit 2
fi
. "$HOOK_DIR/_harness_lib.sh"
harness_load_env "$ROOT/.claude/harness.env"

input=$(cat)
tool=$(jq -r '.tool_name // ""' <<<"$input")
path=$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' <<<"$input")

# Нормализуем путь: ./ и сегменты .. не должны прятать файлы обвязки
npath="$path"
if command -v python3 >/dev/null 2>&1; then
  ROOT=$(python3 -c 'import os, sys; print(os.path.normpath(sys.argv[1]))' "$ROOT")
  [ -n "$path" ] && npath=$(python3 -c 'import os, sys; print(os.path.normpath(sys.argv[1]))' "$path")
fi
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
lpath=$(lower "$npath"); lroot=$(lower "$ROOT"); lhome=$(lower "${HOME:-/nonexistent-home}")
case "$npath" in "$ROOT"/*) rel="${npath#"$ROOT"/}" ;; *) rel="$npath" ;; esac
case "$lpath" in
  "$lroot"/*) lrel="${lpath#"$lroot"/}" ;;
  /*|~*)      lrel="" ;;
  *)          lrel="$lpath" ;;
esac
lbase=$(basename -- "${lpath:-none}")

# Смысловая проверка правки. Печатает OK, UNKNOWN, WARN:предупреждения или DENY:причины.
check_guard() { # $1 = путь к текущему файлу, $2 = settings | env
  if ! command -v python3 >/dev/null 2>&1; then
    local newtext
    newtext=$(jq -r '[.tool_input.content, .tool_input.new_string, ((.tool_input.edits // [])[] | .new_string)] | map(select(type == "string")) | join("\n")' <<<"$input")
    if printf '%s' "$newtext" | grep -Eq 'disableAllHooks|HARNESS_ALLOW_SELF_EDIT|bypassPermissions|HARNESS_GATES_ACTIVE'; then
      echo "DENY:правка затрагивает защитные настройки, а python3 для проверки недоступен"
    elif printf '%s' "$newtext" | grep -Eq 'enabledPlugins|extraKnownMarketplaces|CLAUDE_CODE_REMOTE|HARNESS_ENV_SETUP_LOCAL'; then
      echo "WARN:затрагивает плагины или автозапуск подготовки окружения, а python3 для точной проверки недоступен. Плагины и подготовка окружения запускают код без проверок хуков"
    else
      echo "UNKNOWN"
    fi
    return 0
  fi
  HOOK_INPUT="$input" python3 - "$1" "$2" <<'PY'
import json, os, re, sys
path, kind = sys.argv[1], sys.argv[2]
inp = json.loads(os.environ.get("HOOK_INPUT", "{}"))
tool = inp.get("tool_name", "")
ti = inp.get("tool_input") or {}
try:
    cur = open(path, encoding="utf-8").read()
except OSError:
    cur = None

def apply(text, old, new, all_):
    base = text if text is not None else ""
    if not old or old not in base:
        return None
    return base.replace(old, new) if all_ else base.replace(old, new, 1)

if tool == "Write":
    new = ti.get("content", "")
elif tool == "Edit":
    new = apply(cur, ti.get("old_string", ""), ti.get("new_string", ""), ti.get("replace_all", False))
elif tool == "MultiEdit":
    new = cur
    for e in ti.get("edits") or []:
        new = apply(new, e.get("old_string", ""), e.get("new_string", ""), e.get("replace_all", False))
        if new is None:
            break
else:
    new = None
if new is None:
    print("UNKNOWN")
    sys.exit(0)

reasons = []
warnings = []
if kind == "settings":
    try:
        nd = json.loads(new)
    except ValueError:
        print("DENY:settings.json после правки не является валидным JSON")
        sys.exit(0)
    if not isinstance(nd, dict):
        print("DENY:settings.json после правки не является объектом")
        sys.exit(0)
    try:
        cd = json.loads(cur) if cur else {}
    except ValueError:
        cd = {}
    if not isinstance(cd, dict):
        cd = {}
    npm = nd.get("permissions") if isinstance(nd.get("permissions"), dict) else {}
    cpm = cd.get("permissions") if isinstance(cd.get("permissions"), dict) else {}
    if nd.get("disableAllHooks") is True:
        reasons.append("disableAllHooks: true")
    if npm.get("defaultMode") == "bypassPermissions":
        reasons.append("режим bypassPermissions")
    if cpm.get("disableBypassPermissionsMode") == "disable" and npm.get("disableBypassPermissionsMode") != "disable":
        reasons.append("разрешение режима bypass")
    if isinstance(nd.get("env"), dict) and "HARNESS_ALLOW_SELF_EDIT" in nd["env"]:
        reasons.append("HARNESS_ALLOW_SELF_EDIT в env")
    if isinstance(nd.get("env"), dict) and "CLAUDE_PROJECT_DIR" in nd["env"]:
        reasons.append("CLAUDE_PROJECT_DIR в env")
    if isinstance(nd.get("env"), dict) and "CLAUDE_CODE_REMOTE" in nd["env"]:
        reasons.append("CLAUDE_CODE_REMOTE в env")
    for rule in ("Edit(/.claude/hooks/**)", "Edit(/.claude/skills/**)", "Edit(/.claude/settings.json)", "Edit(/.claude/harness.env)", "Edit(/raw/**)", "Edit(/.github/workflows/**)"):
        if rule in (cpm.get("ask") or []) and rule not in (npm.get("ask") or []) and rule not in (npm.get("deny") or []):
            reasons.append("удаление подтверждения " + rule)
    for rule in ("Read(/.env)", "Edit(/.claude/settings.local.json)"):
        if rule in (cpm.get("deny") or []) and rule not in (npm.get("deny") or []):
            reasons.append("удаление запрета " + rule)
    names = {"block-dangerous", "commit-gate", "secret-guard", "after-edit-check", "stop-gate", "harness-status"}
    def handlers(d):
        out = {}
        hooks = d.get("hooks")
        if not isinstance(hooks, dict):
            return out
        for event, groups in hooks.items():
            if not isinstance(groups, list):
                continue
            for g in groups:
                if not isinstance(g, dict):
                    continue
                matcher = g.get("matcher") or ""
                for h in g.get("hooks") or []:
                    if not isinstance(h, dict):
                        continue
                    m = re.search(r'\.claude/hooks/([a-z-]+)\.sh', str(h.get("command", "")))
                    if m and m.group(1) in names:
                        out.setdefault((m.group(1), event, matcher), []).append(h)
        return out
    def same_handler(c, n):
        if {k: v for k, v in c.items() if k != "timeout"} != {k: v for k, v in n.items() if k != "timeout"}:
            return False
        ct, nt = c.get("timeout"), n.get("timeout")
        if ct is None:
            return nt is None
        return isinstance(nt, (int, float)) and not isinstance(nt, bool) and nt >= ct
    def dict_of(d, k):
        v = d.get(k)
        return v if isinstance(v, dict) else {}
    cpl, npl = dict_of(cd, "enabledPlugins"), dict_of(nd, "enabledPlugins")
    added = sorted(k for k, v in npl.items() if v is not False and cpl.get(k) in (None, False))
    if added:
        warnings.append("включает плагины " + ", ".join(added[:5]) + ". Плагины запускают свой код в каждой сессии без проверок хуков")
    cmk, nmk = dict_of(cd, "extraKnownMarketplaces"), dict_of(nd, "extraKnownMarketplaces")
    changed = sorted(k for k, v in nmk.items() if cmk.get(k) != v)
    if changed:
        warnings.append("добавляет или меняет источники плагинов " + ", ".join(changed[:5]) + ". Плагины запускают свой код в каждой сессии без проверок хуков")
    cur_h, new_h = handlers(cd), handlers(nd)
    for key in sorted(cur_h):
        name, event, matcher = key
        for c in cur_h[key]:
            if not any(same_handler(c, n) for n in new_h.get(key, [])):
                reasons.append("хук %s в %s%s убран или изменён" % (name, event, (" " + matcher) if matcher else ""))
                break
else:
    def parse_val(v):
        v = v.strip()
        if v[:1] in ("'", '"'):
            j = v.find(v[0], 1)
            if j > 0:
                return v[1:j]
        if " #" in v:
            v = v.split(" #", 1)[0]
        return v.strip()
    def env_map(text):
        vals, bad = {}, []
        for i, line in enumerate((text or "").split("\n"), 1):
            s = line.strip()
            if not s or s.startswith("#"):
                continue
            m = re.match(r'^(HARNESS_[A-Z_]+)=(.*)$', s)
            if not m:
                bad.append(str(i))
                continue
            vals[m.group(1)] = parse_val(m.group(2))
        return vals, bad
    if "\r" in new:
        reasons.append("символы возврата каретки")
    nv, bad = env_map(new)
    cv, _ = env_map(cur)
    if bad:
        reasons.append("строки не в формате HARNESS_КЛЮЧ=ЗНАЧЕНИЕ: " + ", ".join(bad[:5]))
    if "HARNESS_ALLOW_SELF_EDIT" in nv:
        reasons.append("HARNESS_ALLOW_SELF_EDIT")
    gates = nv.get("HARNESS_GATES_ACTIVE")
    if gates is not None and gates not in ("0", "1"):
        reasons.append("HARNESS_GATES_ACTIVE должен быть 0 или 1")
    if cv.get("HARNESS_GATES_ACTIVE") == "1" and gates != "1":
        reasons.append("выключение гейтов")
    if nv.get("HARNESS_ENV_SETUP_LOCAL") == "1" and cv.get("HARNESS_ENV_SETUP_LOCAL") != "1":
        warnings.append("включает автозапуск подготовки окружения на этом компьютере. Менеджеры пакетов будут в начале каждой сессии выполнять код из файлов проекта, которые агент меняет без подтверждения")
    if gates == "1":
        noop = re.compile(r'^\s*(true|:|exit\s+0)\s*$|(\|\||;)\s*(true|:|exit\s+0)\s*$')
        for k in ("HARNESS_TEST_CMD", "HARNESS_FAST_CHECK_CMD"):
            v = nv.get(k)
            if v and noop.search(v):
                reasons.append(k + " всегда успешна")
        if cv.get("HARNESS_TEST_CMD") and not nv.get("HARNESS_TEST_CMD"):
            reasons.append("HARNESS_TEST_CMD очищена")
        # Тип проекта берём из состояния подготовки: путь до него от .claude/harness.env
        project_root = os.path.dirname(os.path.dirname(os.path.abspath(path)))
        project_kind = ""
        try:
            with open(os.path.join(project_root, ".harness", "bootstrap-state.json"), encoding="utf-8") as fh:
                project_kind = (json.load(fh) or {}).get("kind") or ""
        except Exception:
            project_kind = ""
        research = project_kind == "research"
        probes = ["wiki/page.md", "raw/material.pdf"] if research else ["src/app.ts", "app/main.py"]
        what = "материалы исследования" if research else "файлы кода"
        for key, label in (("HARNESS_CHECK_SKIP_REGEX", "пропускает"), ("HARNESS_GATE_EXCLUDE_REGEX", "исключает из ворот")):
            rx = nv.get(key)
            if rx is None:
                if cv.get(key) and research:
                    reasons.append("удаление " + key + ": вернутся значения для кода, и материалы исследования выпадут из проверок")
                continue
            if rx == cv.get(key):
                continue
            try:
                if any(re.search(rx, probe) for probe in probes):
                    reasons.append(key + " " + label + " " + what)
            except re.error:
                reasons.append(key + " не разбирается")
        mb = nv.get("HARNESS_STOP_MAX_BLOCKS")
        if mb is not None:
            try:
                if int(mb) < 1:
                    reasons.append("HARNESS_STOP_MAX_BLOCKS меньше 1")
            except ValueError:
                reasons.append("HARNESS_STOP_MAX_BLOCKS не число")
print("DENY:" + "; ".join(reasons) if reasons else ("WARN:" + "; ".join(warnings) if warnings else "OK"))
PY
}

if [ "$SELF_EDIT" != "1" ]; then
  case "$lpath" in
    "$lhome"/.claude/settings.json|"$lhome"/.claude/settings.local.json|'~/.claude/settings.json'|'~/.claude/settings.local.json')
      deny "Глобальные настройки Claude Code меняет только человек: через них можно выключить хуки проекта." ;;
  esac

  case "$lrel" in
    .claude/settings.local.json)
      deny "Файл .claude/settings.local.json агенту менять нельзя: он перекрывает настройки проекта и может выключить хуки. Если правка нужна, её делает человек." ;;
    .claude/settings.json|.claude/harness.env)
      [ "$tool" = "NotebookEdit" ] && deny "Файл $rel нельзя менять через NotebookEdit."
      kind=settings
      [ "$lrel" = ".claude/harness.env" ] && kind=env
      verdict=$(check_guard "$ROOT/$rel" "$kind")
      case "$verdict" in
        DENY:*) deny "Эта правка выключает защиту обвязки: ${verdict#DENY:}. Агенту так делать нельзя. Если это действительно нужно, человек правит $rel в веб-редакторе GitHub." ;;
        WARN:*) ask "Внимание: правка $rel ${verdict#WARN:}. Подтверждай, только если ты сам этого хочешь." ;;
      esac
      ask "Правка файла обвязки проекта: $rel. Проверь изменения перед подтверждением." ;;
    .claude/hooks/*|.claude/skills/*)
      if [ "$tool" = "Write" ] && [ -z "$(jq -r '.tool_input.content // empty' <<<"$input")" ]; then
        deny "Эта правка очищает файл обвязки $rel. Агенту так делать нельзя."
      fi
      ask "Правка файла обвязки: $rel. Это скилл или хук, он задаёт правила работы. Проверь изменения перед подтверждением." ;;
  esac
fi

fixture="${HARNESS_ENV_FIXTURE_REGEX:-^\.env\.(example|sample|template|dist|test)$}"
case "$lbase" in
  .env|.env.*|.envrc)
    if ! printf '%s' "$lbase" | grep -Eq -- "$fixture"; then
      deny "Секреты в $lbase вписывает человек. В коде используй переменные окружения, а в .env.example оставь заглушки."
    fi ;;
esac

content=$(jq -r '[.tool_input.content, .tool_input.new_string, .tool_input.new_source, ((.tool_input.edits // [])[] | .new_string)] | map(select(type == "string")) | join("\n")' <<<"$input")
[ -z "$content" ] && exit 0

has() { printf '%s' "$content" | grep -Eq -- "$1"; }
B='(^|[^A-Za-z0-9_-])'
has "${B}AKIA[0-9A-Z]{16}"                    && deny "Похоже на ключ AWS в $rel. Вынеси его в переменную окружения."
has '-----BEGIN [A-Z ]*PRIVATE KEY-----'      && deny "Похоже на приватный ключ в $rel. Храни его вне репозитория."
has "${B}gh[pousr]_[A-Za-z0-9]{36}"           && deny "Похоже на токен GitHub в $rel. Вынеси его в переменную окружения."
has "${B}github_pat_[A-Za-z0-9_]{40,}"        && deny "Похоже на токен GitHub в $rel. Вынеси его в переменную окружения."
has "${B}sk-(proj-|ant-)?[A-Za-z0-9_-]{32,}"  && deny "Похоже на API-ключ в $rel. Вынеси его в переменную окружения."
has "${B}xox[abprs]-[A-Za-z0-9-]{10,}"        && deny "Похоже на токен Slack в $rel. Вынеси его в переменную окружения."
has "${B}AIza[0-9A-Za-z_-]{35}"               && deny "Похоже на ключ Google API в $rel. Вынеси его в переменную окружения."

exit 0
