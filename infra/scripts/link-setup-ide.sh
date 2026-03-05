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
    echo "Создаёт /var/core-<core_id> -> projects/<core_host>/www для IDE (Bitrix Docker: /var/core-<id>/bitrix = core/www/bitrix)."
    echo "core_id: core-<id>, <short_name> или host ядра (<host>.<zone>)."
    echo ""
    echo "Пример: sudo $0 core-main"
    exit 1
fi

core_id="$1"
core_path_id="${core_id#core-}"
core_path_id="$(echo "$core_path_id" | tr '.' '-')"
target="/var/core-${core_path_id}"

# Разрешить core_id в путь к ЯДРУ (не link-проекту). Ядро = проект с реальным bitrix.
core_host=""
for candidate in "$core_id" "${core_id#core-}" "${core_id%.*}"; do
    candidate="${candidate#core-}"
    candidate="$(echo "$candidate" | tr '.' '-')"
    # Ищем директорию по короткому имени (ядро, не link-хост)
    for d in "$PROJECTS_DIR"/*/; do
        [ -d "$d" ] || continue
        d="${d%/}"
        d="${d##*/}"
        if [ "$d" = "$candidate" ] || [ "$d" = "${candidate%-*}" ]; then
            bitrix_path="$PROJECTS_DIR/$d/www/bitrix"
            # Ядро = bitrix существует и это НЕ симлинк (не link-проект)
            if [ -d "$bitrix_path" ] && [ ! -L "$bitrix_path" ] && [ -d "$bitrix_path/modules" ]; then
                core_host="$d"
                break 2
            fi
        fi
    done
done
# Fallback: первый проект с www и bitrix
if [ -z "$core_host" ]; then
    short="${core_id#core-}"
    short="${short%%.*}"
    short="${short//./-}"
    for d in "$PROJECTS_DIR"/*/; do
        [ -d "$d" ] || continue
        d="${d%/}"
        d="${d##*/}"
        if [ -d "$PROJECTS_DIR/$d/www/bitrix" ] && [ ! -L "$PROJECTS_DIR/$d/www/bitrix" ] && \
           { [ "$d" = "$short" ] || [ "$d" = "${core_id#core-}" ]; }; then
            core_host="$d"
            break
        fi
    done
fi

if [ -z "$core_host" ]; then
    echo "Ошибка: ядро для '$core_id' не найдено в $PROJECTS_DIR"
    exit 1
fi

# Bitrix Docker: /var/core-<id>/bitrix = core/www/bitrix, значит /var/core-<id> -> projects/<core>/www
source_path="$(cd "$PROJECTS_DIR/$core_host/www" && pwd)"

echo "Создание: $target -> $source_path"
if ! ln -sf "$source_path" "$target" 2>/dev/null; then
    echo "Ошибка: не удалось создать симлинк. Запустите с sudo:"
    echo "  sudo $0 $core_id"
    exit 1
fi

actual="$(readlink "$target" 2>/dev/null)"
if [ -z "$actual" ]; then
    echo "Ошибка: симлинк не создан (нужен sudo?)."
    exit 1
fi
actual_target="$(readlink "$target")"
if [ -d "$target/bitrix" ]; then
    echo "Готово. IDE теперь видит bitrix/upload/images в link-проектах."
else
    echo "Предупреждение: $target/bitrix не найден."
    echo "Проверьте: readlink $target (должен указывать на projects/<core_host>/www)"
fi
