#!/bin/bash

# Скрипт запуска всей инфраструктуры
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"

cd "$INFRA_DIR"

echo "🚀 Запуск общей инфраструктуры..."

# Проверка наличия .env.global
if [ ! -f .env.global ]; then
    echo "⚠️  Файл .env.global не найден. Копирую из примера..."
    cp .env.global.example .env.global
    echo "📝 Отредактируйте .env.global и запустите скрипт снова"
    exit 1
fi

# Bootstrap окружения (права скриптов, каталоги, preflight Docker).
echo "🧰 Подготовка окружения (bootstrap)..."
bash "$SCRIPT_DIR/bootstrap.sh"

# Проверка/обновление SSL-сертификатов
echo "🔐 Проверка SSL-сертификатов..."
bash ./scripts/generate-ssl.sh --skip-trust

# Запуск общей инфраструктуры через hostctl (включая fallback-режим для внешнего диска)
echo "🐳 Запуск инфраструктуры через hostctl..."
bash "$SCRIPT_DIR/hostctl.sh" infra-start

echo "✅ Инфраструктура запущена!"
echo ""
echo "Доступные сервисы:"
echo "  - DevPanel: https://docker.dev (fallback: http://localhost:8088)"
echo "  - Traefik Dashboard: https://traefik.dev/dashboard/ (или http://localhost:8080)"
echo "  - Adminer: https://adminer.dev"
echo "  - Grafana: https://grafana.dev"
if docker ps --format '{{.Names}}' | awk '$1=="devpanel-fallback"{found=1} END{exit !found}'; then
    echo ""
    echo "ℹ️  Активирован fallback-режим инфраструктуры (внешний диск / bind-mount недоступен)."
    echo "   Сервисы работают из fallback-compose без bind-монтов исходников."
fi
echo ""
echo "⚠️  Для работы HTTPS убедитесь, что CA из infra/ssl/ca.pem установлен в доверенные"
echo "   Повторная настройка: bash ./scripts/generate-ssl.sh"
echo ""
echo "Для запуска проектов перейдите в projects/<project-name> и выполните:"
echo "  docker compose up -d"
