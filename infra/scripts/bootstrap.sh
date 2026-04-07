#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"
DEV_DIR="$(dirname "$INFRA_DIR")"

echo "🧰 Bootstrap: подготовка инфраструктуры..."

# 1) Скрипты должны быть исполняемыми и в локальной рабочей копии, и после git clone.
chmod +x "$SCRIPT_DIR"/*.sh >/dev/null 2>&1 || true
if [ -d "$SCRIPT_DIR/acceptance" ]; then
    chmod +x "$SCRIPT_DIR"/acceptance/*.sh >/dev/null 2>&1 || true
fi

# 2) Базовые каталоги для primary-режима (bind mounts).
mkdir -p \
    "$DEV_DIR/projects" \
    "$INFRA_DIR/config" \
    "$DEV_DIR/logs/traefik" \
    "$DEV_DIR/shared-volumes/grafana-data" \
    "$DEV_DIR/shared-volumes/loki-data" \
    "$DEV_DIR/shared-volumes/alloy-data"

# 3) На macOS внешние диски часто оставляют sidecar-файлы (._*), которые ломают Docker/Git.
if command -v python3 >/dev/null 2>&1; then
    removed_metadata_files="$(python3 - "$DEV_DIR" <<'PY'
import os
import pathlib
import shutil
import sys

root = pathlib.Path(sys.argv[1])
removed = 0

for dirpath, dirnames, filenames in os.walk(root, topdown=False):
    # Не трогаем тяжелые зависимые каталоги.
    if "node_modules" in dirpath:
        continue

    for name in filenames:
        if not name.startswith("._"):
            continue
        path = pathlib.Path(dirpath) / name
        try:
            path.unlink()
            removed += 1
        except OSError:
            pass

    for name in dirnames:
        if not name.startswith("._"):
            continue
        path = pathlib.Path(dirpath) / name
        try:
            shutil.rmtree(path)
            removed += 1
        except OSError:
            pass

print(removed)
PY
)"
    case "${removed_metadata_files:-0}" in
        ''|*[!0-9]*)
            removed_metadata_files=0
            ;;
    esac
    if [ "$removed_metadata_files" -gt 0 ]; then
        echo "   ℹ️  Удалено $removed_metadata_files файл(ов) метаданных macOS (._*)."
    fi
fi

# 4) Проверяем доступность Docker/Compose заранее.
if ! command -v docker >/dev/null 2>&1; then
    echo "Error: docker command not found."
    echo "Hint: install Docker Desktop and ensure 'docker' is available in PATH."
    exit 1
fi

if ! docker info >/dev/null 2>&1; then
    echo "Error: Docker daemon is not available."
    echo "Hint: start Docker Desktop and retry."
    exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
    echo "Error: docker compose plugin is not available."
    echo "Hint: ensure Docker Desktop includes Compose v2 plugin."
    exit 1
fi

# 5) Docker Compose подставляет ${DOMAIN_SUFFIX} в лейблы Traefik из `infra/.env` (автозагрузка).
# Без этого при ручном `docker compose -f docker-compose.shared.yml up` суффикс остаётся «loc» → 404 на *.pillat.
if [ -f "$INFRA_DIR/.env.global" ]; then
    d_line="$(grep -E '^DOMAIN_SUFFIX=' "$INFRA_DIR/.env.global" | head -1 || true)"
    if [ -n "$d_line" ]; then
        env_local="$INFRA_DIR/.env"
        tmp="${env_local}.tmp.$$"
        if [ -f "$env_local" ]; then
            grep -v '^DOMAIN_SUFFIX=' "$env_local" > "$tmp" 2>/dev/null || : > "$tmp"
        else
            : > "$tmp"
        fi
        echo "$d_line" >> "$tmp"
        mv "$tmp" "$env_local"
    fi
fi

echo "✅ Bootstrap завершен: скрипты, каталоги и preflight Docker готовы."
