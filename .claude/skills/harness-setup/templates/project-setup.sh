#!/usr/bin/env bash
# Подготовка окружения проекта. Копируется в .claude/hooks/project-setup.sh в фазе «Окружение».
# Запускается хуком env-setup в начале облачных сессий, на Mac при HARNESS_ENV_SETUP_LOCAL=1, и первым шагом CI.
# HARNESS_CONTEXT: cloud — облачная сессия на свежей машине; local — Mac; ci — GitHub Actions.
# Требования: идемпотентность, повторный запуск за секунды, ненулевой код только при настоящей ошибке.
# Секреты сюда не пишутся. Тяжёлые системные пакеты ставятся скриптом облачного окружения, а не здесь.
set -eu

STAMPS=.harness/runtime/stamps
mkdir -p "$STAMPS"
# changed ИМЯ ФАЙЛ...: истина, если файлы изменились с последнего mark.
changed() { local n=$1; shift; [ "$(cat "$@" 2>/dev/null | git hash-object --stdin)" != "$(cat "$STAMPS/$n" 2>/dev/null)" ]; }
mark()    { local n=$1; shift; cat "$@" 2>/dev/null | git hash-object --stdin > "$STAMPS/$n"; }

echo "context=${HARNESS_CONTEXT:-local}"

# --- Зависимости. Оставь нужное, остальное удали.
# Только по lock-файлу и без скриптов пакетов: package.json агент меняет без подтверждения.
# if [ ! -d node_modules ] || changed npm package-lock.json; then npm ci --ignore-scripts; mark npm package-lock.json; fi
# if [ ! -d node_modules ] || changed pnpm pnpm-lock.yaml; then pnpm install --frozen-lockfile --ignore-scripts; mark pnpm pnpm-lock.yaml; fi
# if [ ! -d .venv ] || changed uv uv.lock; then uv sync; mark uv uv.lock; fi

# --- Службы. В облаке машина свежая и службы не запущены. На Mac службы запускает человек.
# if [ "${HARNESS_CONTEXT:-local}" = "cloud" ]; then
#   service postgresql start
#   service redis-server start
#   docker compose up -d
# fi

# --- Переменные для сессии Claude. Изменения окружения внутри скрипта в сессию сами не попадают.
# [ -n "${CLAUDE_ENV_FILE:-}" ] && echo 'export PATH="$PWD/.venv/bin:$PATH"' >> "$CLAUDE_ENV_FILE"

# Миграции и сиды тестовой базы не запускай отсюда через npm run или make: эти цели агент меняет без подтверждения.
# Их запускает агент обычной командой, которая проходит проверки хуков.
