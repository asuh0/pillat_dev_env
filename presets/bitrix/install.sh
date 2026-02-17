#!/bin/bash
# Установочный скрипт пресета Bitrix (идемпотентный).
# Вызывается из create-project.sh с параметрами: PROJECT_DIR, PROJECT_NAME, DB_TYPE, DB_HOST, DB_NAME, DB_USER, DB_PASSWORD
set -e

PROJECT_DIR="${1:-.}"
SRC_DIR="$PROJECT_DIR/src"

RESTORE_URL="https://www.1c-bitrix.ru/download/files/scripts/restore.php"
BITRIXSETUP_URL="https://www.1c-bitrix.ru/download/files/scripts/bitrixsetup.php"

download_script() {
    local url="$1"
    local target="$2"
    local tmp_target="${target}.tmp.$$"

    if [ -f "$target" ]; then
        echo "Bitrix preset: $(basename "$target") already exists, keep existing file."
        return 0
    fi

    if command -v curl >/dev/null 2>&1; then
        if curl -fsSL --connect-timeout 15 --max-time 180 "$url" -o "$tmp_target"; then
            mv "$tmp_target" "$target"
            chmod 0644 "$target" 2>/dev/null || true
            return 0
        fi
    elif command -v wget >/dev/null 2>&1; then
        if wget -q -T 30 -O "$tmp_target" "$url"; then
            mv "$tmp_target" "$target"
            chmod 0644 "$target" 2>/dev/null || true
            return 0
        fi
    fi

    rm -f "$tmp_target" >/dev/null 2>&1 || true
    return 1
}

mkdir -p "$SRC_DIR"/{upload,bitrix/cache,bitrix/managed_cache,bitrix/backup}
# Права для веб-сервера (в контейнере обычно www-data)
chmod -R 775 "$SRC_DIR/upload" "$SRC_DIR/bitrix/cache" "$SRC_DIR/bitrix/managed_cache" "$SRC_DIR/bitrix/backup" 2>/dev/null || true
echo "Bitrix preset: directories upload, bitrix/cache, bitrix/managed_cache, bitrix/backup created."

if download_script "$RESTORE_URL" "$SRC_DIR/restore.php"; then
    echo "Bitrix preset: restore.php downloaded to src/restore.php."
else
    echo "Bitrix preset: warning - failed to download restore.php."
    echo "Manual download: $RESTORE_URL"
fi

if download_script "$BITRIXSETUP_URL" "$SRC_DIR/bitrixsetup.php"; then
    echo "Bitrix preset: bitrixsetup.php downloaded to src/bitrixsetup.php."
else
    echo "Bitrix preset: warning - failed to download bitrixsetup.php."
    echo "Manual download: $BITRIXSETUP_URL"
fi
