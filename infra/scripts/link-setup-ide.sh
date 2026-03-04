#!/bin/bash
# Создание /var/core-<id> на хосте для IDE (bitrix, upload, images в link-проектах).
# На macOS требуется sudo.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"
DEV_DIR="$(dirname "$INFRA_DIR")"
PROJECTS_DIR="${DEV_DIR}/projects"

if [ -z "${1:-}" ]; then
    echo "Использование: $0 <core_id>"
    echo ""
    echo "Создаёт /var/core-<core_id> -> projects/<core_host> для IDE (чтобы /var/core-<id>/www = core/www)."
    echo "core_id: core-shintyre, shintyre или host ядра (shintyre.pillat)."
    echo ""
    echo "Пример: sudo $0 core-shintyre"
    exit 1
fi

core_id="$1"
core_path_id="${core_id#core-}"
core_path_id="$(echo "$core_path_id" | tr '.' '-')"
target="/var/core-${core_path_id}"

# Разрешить core_id в путь к ядру
core_host=""
if [ -d "$PROJECTS_DIR/$core_id" ] && [ -d "$PROJECTS_DIR/$core_id/www" ]; then
    core_host="$core_id"
elif [ -d "$PROJECTS_DIR/${core_id#core-}" ] && [ -d "$PROJECTS_DIR/${core_id#core-}/www" ]; then
    core_host="${core_id#core-}"
else
    # Попробовать core-shintyre -> shintyre
    short="${core_id#core-}"
    short="${short%%.*}"
    for d in "$PROJECTS_DIR"/*/; do
        [ -d "$d" ] || continue
        d="${d%/}"
        d="${d##*/}"
        if [ -d "$PROJECTS_DIR/$d/www" ] && { [ "$d" = "$short" ] || [ "$d" = "$core_id" ]; }; then
            core_host="$d"
            break
        fi
    done
fi

if [ -z "$core_host" ]; then
    echo "Ошибка: ядро для '$core_id' не найдено в $PROJECTS_DIR"
    exit 1
fi

source_path="$(realpath "$PROJECTS_DIR/$core_host")"
echo "Создание: $target -> $source_path"
ln -sf "$source_path" "$target"
echo "Готово. IDE теперь видит bitrix/upload/images в link-проектах."
