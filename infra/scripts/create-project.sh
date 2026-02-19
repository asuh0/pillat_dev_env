#!/bin/bash

# Скрипт создания нового проекта
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOMAIN_ZONE_HELPER="$SCRIPT_DIR/domain-zone.sh"
# Если скрипт выполняется через docker run, используем монтированные пути
if [ -d "/projects" ] && [ -w "/projects" ]; then
    # Выполняется в контейнере с монтированным /projects
    PROJECTS_DIR="/projects"
    INFRA_DIR="${INFRA_DIR:-/infra}"
    PRESETS_DIR="${PRESETS_DIR:-/presets}"
    TEMPLATES_DIR="${TEMPLATES_DIR:-/templates}"
else
    # Выполняется на хосте напрямую
    INFRA_DIR="$(dirname "$SCRIPT_DIR")"
    DEV_DIR="$(dirname "$INFRA_DIR")"
    PROJECTS_DIR="$DEV_DIR/projects"
    PRESETS_DIR="${PRESETS_DIR:-$DEV_DIR/presets}"
    TEMPLATES_DIR="${TEMPLATES_DIR:-$INFRA_DIR/templates}"
fi

if [ -f "$DOMAIN_ZONE_HELPER" ]; then
    # shellcheck source=/dev/null
    source "$DOMAIN_ZONE_HELPER"
fi

if [ -z "$1" ]; then
    echo "Использование: $0 <project-name> [php-version] [db-type] [preset]"
    echo ""
    echo "Примеры:"
    echo "  $0 my-project 8.2 mysql empty"
    echo "  $0 my-project 8.1 mysql bitrix"
    echo "  $0 my-project 8.3 postgres empty"
    exit 1
fi

resolve_project_name() {
    local raw_name="$1"
    local domain_suffix=""
    local canonical_name=""

    if ! command -v dz_resolve_domain_suffix >/dev/null 2>&1 || ! command -v dz_canonicalize_host >/dev/null 2>&1; then
        echo "$raw_name"
        return 0
    fi

    domain_suffix="$(dz_resolve_domain_suffix "${DOMAIN_SUFFIX:-}" "$INFRA_DIR/.env.global" "$INFRA_DIR/.env.global.example" "loc")" || return 1
    canonical_name="$(dz_canonicalize_host "$raw_name" "$domain_suffix" "create")" || return 1
    echo "$canonical_name"
}

PROJECT_INPUT="$1"
if ! PROJECT_NAME="$(resolve_project_name "$PROJECT_INPUT")"; then
    echo "❌ Некорректное имя проекта '$PROJECT_INPUT' для активной зоны DOMAIN_SUFFIX."
    echo "   Используйте short-host ('my-project') или canonical-host ('my-project.<zone>')."
    exit 1
fi
PHP_VERSION="${2:-8.2}"
DB_TYPE="${3:-mysql}"
PRESET_RAW="${4:-empty}"
PHP_UPSTREAM="${PROJECT_NAME//./-}-php"

if [ "$PROJECT_INPUT" != "$PROJECT_NAME" ]; then
    echo "ℹ️  Имя проекта нормализовано: '$PROJECT_INPUT' -> '$PROJECT_NAME'"
fi

normalize_preset() {
    local raw="$1"
    local lower

    lower="$(echo "$raw" | tr '[:upper:]' '[:lower:]')"
    case "$lower" in
        php|empty)
            echo "empty"
            ;;
        bitrix|1c-bitrix|1c_bitrix)
            echo "bitrix"
            ;;
        *)
            echo "$lower"
            ;;
    esac
}

normalize_host_slug() {
    local raw="$1"
    local normalized=""
    normalized="$(echo "$raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/-+/-/g; s/^-+//; s/-+$//')"
    [ -n "$normalized" ] || return 1
    normalized="${normalized:0:48}"
    normalized="$(printf "%s" "$normalized" | sed -E 's/-+$//')"
    [ -n "$normalized" ] || return 1
    echo "$normalized"
}

is_valid_service_name() {
    local value="$1"
    [[ "$value" =~ ^[a-z0-9][a-z0-9-]*$ ]]
}

validate_preset_contract() {
    local preset_dir="$1"
    local preset_slug="$2"
    local validation_output

    if [ ! -d "$preset_dir" ]; then
        echo "❌ Пресет '$preset_slug' не найден: $preset_dir"
        echo "   Поддерживаемые пресеты MVP: empty, bitrix"
        return 1
    fi

    if ! validation_output="$(python3 - "$preset_dir" "$preset_slug" <<'PY'
import json
import pathlib
import sys

preset_dir = pathlib.Path(sys.argv[1])
expected_slug = sys.argv[2]
meta_path = preset_dir / "preset.json"
errors = []

if not meta_path.is_file():
    errors.append("missing required metadata file: preset.json")
else:
    try:
        data = json.loads(meta_path.read_text(encoding="utf-8"))
    except Exception as exc:
        errors.append(f"invalid JSON in preset.json: {exc}")
        data = {}

    for field in ("name", "slug", "version"):
        value = data.get(field)
        if not isinstance(value, str) or not value.strip():
            errors.append(f"metadata field '{field}' must be a non-empty string")

    actual_slug = data.get("slug", "")
    if isinstance(actual_slug, str) and actual_slug.strip():
        if actual_slug.strip().lower() != expected_slug:
            errors.append(
                f"metadata slug mismatch: expected '{expected_slug}', got '{actual_slug.strip()}'"
            )

    templates = data.get("templates", [])
    if templates is None:
        templates = []
    if not isinstance(templates, list):
        errors.append("metadata field 'templates' must be an array")
        templates = []
    for item in templates:
        if not isinstance(item, str) or not item.strip():
            errors.append("template entry must be a non-empty string")
            continue
        if not (preset_dir / item).is_file():
            errors.append(f"template file not found: {item}")

    entrypoint = data.get("entrypoint", {})
    if entrypoint is None:
        entrypoint = {}
    if not isinstance(entrypoint, dict):
        errors.append("metadata field 'entrypoint' must be an object")
        entrypoint = {}
    install_file = entrypoint.get("install")
    if install_file is not None:
        if not isinstance(install_file, str) or not install_file.strip():
            errors.append("entrypoint.install must be a non-empty string when provided")
        elif not (preset_dir / install_file).is_file():
            errors.append(f"entrypoint install file not found: {install_file}")

if errors:
    for item in errors:
        print(item)
    sys.exit(1)
PY
)"; then
        echo "❌ Пресет '$preset_slug' поврежден или неполный:"
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            echo "   - $line"
        done <<EOF
$validation_output
EOF
        return 1
    fi
}

PRESET="$(normalize_preset "$PRESET_RAW")"
PRESET_DIR="$PRESETS_DIR/$PRESET"
OPCACHE_REVALIDATE_FREQ="2"
if [ "$PRESET" = "bitrix" ]; then
    OPCACHE_REVALIDATE_FREQ="0"
fi

PROJECT_DIR="$PROJECTS_DIR/$PROJECT_NAME"

if [ "$DB_TYPE" != "mysql" ] && [ "$DB_TYPE" != "postgres" ]; then
    echo "❌ Неподдерживаемый тип БД: '$DB_TYPE'. Допустимо: mysql, postgres."
    exit 1
fi

HOST_SLUG="$(normalize_host_slug "$PROJECT_NAME" || true)"
if [ -z "$HOST_SLUG" ]; then
    echo "❌ Не удалось сформировать host_slug из имени проекта '$PROJECT_NAME'."
    exit 1
fi

DB_SERVICE_NAME="${DB_SERVICE_NAME:-db-$HOST_SLUG}"
if ! is_valid_service_name "$DB_SERVICE_NAME"; then
    echo "❌ Некорректное имя DB-сервиса '$DB_SERVICE_NAME'."
    echo "   Разрешены: [a-z0-9-], первый символ должен быть [a-z0-9]."
    exit 1
fi

DB_BIND_ADDRESS="${DB_BIND_ADDRESS:-0.0.0.0}"
DB_NAME="${PROJECT_NAME//./_}"
DB_PORT="3306"
[ "$DB_TYPE" = "postgres" ] && DB_PORT="5432"
DB_EXTERNAL_PORT_VALUE="${DB_EXTERNAL_PORT:-$DB_PORT}"

if [ -d "$PROJECT_DIR" ]; then
    echo "❌ Проект $PROJECT_NAME уже существует!"
    exit 1
fi

if ! validate_preset_contract "$PRESET_DIR" "$PRESET"; then
    exit 1
fi

echo "📦 Создание проекта $PROJECT_NAME..."
echo "   ⚙️  PHP версия: $PHP_VERSION"
echo "   🗄️  БД тип: $DB_TYPE"
echo "   🧩 DB сервис: $DB_SERVICE_NAME"
echo "   🔌 DB внешний порт: $DB_EXTERNAL_PORT_VALUE"
echo "   📋 Пресет: $PRESET"

# Создание структуры директорий
mkdir -p "$PROJECT_DIR"/{src,nginx,.devcontainer}
if [ "$DB_TYPE" = "mysql" ]; then
    mkdir -p "$PROJECT_DIR/db-mysql"
elif [ "$DB_TYPE" = "postgres" ]; then
    mkdir -p "$PROJECT_DIR/db-postgres"
fi

# Создание docker-compose.yml
cat > "$PROJECT_DIR/docker-compose.yml" <<EOF
networks:
  infra_proxy:
    external: true
    name: infra_proxy

volumes:
  db_data:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: \${PWD}/db-${DB_TYPE}

services:
  php:
    build:
      context: .
      dockerfile: Dockerfile.php${PHP_VERSION//./}
      args:
        PHP_VERSION: ${PHP_VERSION}
    container_name: ${PROJECT_NAME//./-}-php
    volumes:
      - ./src:/opt/www
      - ../../logs/php/${PROJECT_NAME}:/var/log/php
    environment:
      - PHP_IDE_CONFIG=serverName=${PROJECT_NAME}
      - XDEBUG_CONFIG=client_host=host.docker.internal
      - TZ=\${TZ:-Europe/Moscow}
    networks:
      - infra_proxy
    labels:
      - "traefik.enable=false"

  nginx:
    image: nginx:alpine
    container_name: ${PROJECT_NAME//./-}-nginx
    volumes:
      - ./src:/opt/www:ro
      - ./nginx/site.conf:/etc/nginx/conf.d/default.conf:ro
      - ../../logs/nginx/${PROJECT_NAME}:/var/log/nginx
    depends_on:
      - php
    networks:
      - infra_proxy
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.${PROJECT_NAME//./-}.rule=Host(\`${PROJECT_NAME}\`)"
      - "traefik.http.routers.${PROJECT_NAME//./-}.entrypoints=websecure"
      - "traefik.http.routers.${PROJECT_NAME//./-}.tls=true"
      - "traefik.http.services.${PROJECT_NAME//./-}.loadbalancer.server.port=80"
      - "traefik.http.routers.${PROJECT_NAME//./-}.service=${PROJECT_NAME//./-}"

EOF

# Добавление БД в зависимости от типа
if [ "$DB_TYPE" = "mysql" ]; then
    cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF

  ${DB_SERVICE_NAME}:
    image: mysql:8.0
    container_name: ${PROJECT_NAME//./-}-mysql
    volumes:
      - db_data:/var/lib/mysql
    ports:
      - "\${DB_BIND_ADDRESS:-0.0.0.0}:\${DB_EXTERNAL_PORT:-3306}:3306"
    environment:
      MYSQL_ROOT_PASSWORD: \${MYSQL_ROOT_PASSWORD:-root}
      MYSQL_DATABASE: \${MYSQL_DATABASE:-${PROJECT_NAME//./_}}
      MYSQL_USER: \${MYSQL_USER:-user}
      MYSQL_PASSWORD: \${MYSQL_PASSWORD:-password}
      TZ: \${TZ:-Europe/Moscow}
    networks:
      - infra_proxy
    labels:
      - "traefik.enable=false"
    command: --general-log=1 --general-log-file=/var/lib/mysql/general.log --innodb_strict_mode=OFF
EOF
elif [ "$DB_TYPE" = "postgres" ]; then
    cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF

  ${DB_SERVICE_NAME}:
    image: postgres:15-alpine
    container_name: ${PROJECT_NAME//./-}-postgres
    volumes:
      - db_data:/var/lib/postgresql/data
    ports:
      - "\${DB_BIND_ADDRESS:-0.0.0.0}:\${DB_EXTERNAL_PORT:-5432}:5432"
    environment:
      POSTGRES_DB: \${POSTGRES_DB:-${PROJECT_NAME//./_}}
      POSTGRES_USER: \${POSTGRES_USER:-postgres}
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD:-postgres}
      TZ: \${TZ:-Europe/Moscow}
    networks:
      - infra_proxy
    labels:
      - "traefik.enable=false"
EOF
fi

# Создание Dockerfile
DOCKERFILE_TARGET="$PROJECT_DIR/Dockerfile.php${PHP_VERSION//./}"
DOCKERFILE_TEMPLATE="$TEMPLATES_DIR/php/Dockerfile.php${PHP_VERSION//./}"
if [ -f "$DOCKERFILE_TEMPLATE" ]; then
    cp "$DOCKERFILE_TEMPLATE" "$DOCKERFILE_TARGET"
else
    cat > "$DOCKERFILE_TARGET" <<EOF
ARG PHP_VERSION=${PHP_VERSION}
FROM php:\${PHP_VERSION}-fpm-alpine

# Установка зависимостей
RUN apk add --no-cache \\
    \$PHPIZE_DEPS \\
    linux-headers \\
    git \\
    curl \\
    libpng-dev \\
    libjpeg-turbo-dev \\
    freetype-dev \\
    oniguruma-dev \\
    libzip-dev \\
    postgresql-dev \\
    mysql-client \\
    && docker-php-ext-configure gd --with-freetype --with-jpeg \\
    && docker-php-ext-install -j\$(nproc) \\
        gd \\
        mysqli \\
        pdo_mysql \\
        pdo_pgsql \\
        zip \\
        mbstring \\
        opcache

# Установка Xdebug (совместимый вариант для разных версий PHP)
RUN set -eux; \\
    if ! pecl install xdebug; then \\
        case "\${PHP_VERSION}" in \\
            7.4) pecl install xdebug-3.1.6 ;; \\
            8.0|8.1) pecl install xdebug-3.3.2 ;; \\
            *) pecl install xdebug ;; \\
        esac; \\
    fi; \\
    docker-php-ext-enable xdebug

# Конфигурация PHP
COPY php.ini /usr/local/etc/php/conf.d/custom.ini
COPY xdebug.ini /usr/local/etc/php/conf.d/xdebug.ini

# Рабочая директория
WORKDIR /opt/www

# Права доступа
RUN chown -R www-data:www-data /opt/www

EOF
fi

# Создание php.ini
cat > "$PROJECT_DIR/php.ini" <<EOF
[PHP]
memory_limit = 256M
upload_max_filesize = 64M
post_max_size = 64M
max_execution_time = 300
date.timezone = Europe/Moscow
display_errors = On
max_input_vars = 10000

[opcache]
opcache.enable=1
opcache.memory_consumption=128
opcache.interned_strings_buffer=8
opcache.max_accelerated_files=10000
opcache.revalidate_freq=${OPCACHE_REVALIDATE_FREQ}

EOF

# Создание xdebug.ini
cat > "$PROJECT_DIR/xdebug.ini" <<EOF
[xdebug]
xdebug.mode=debug,develop
xdebug.start_with_request=yes
xdebug.client_host=host.docker.internal
xdebug.client_port=9003
xdebug.log=/var/log/php/xdebug.log
xdebug.idekey=PHPSTORM

EOF

# Создание nginx конфигурации
cat > "$PROJECT_DIR/nginx/site.conf" <<EOF
server {
    listen 80;
    server_name ${PROJECT_NAME};
    root /opt/www;
    index index.php index.html index.htm;

    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        fastcgi_pass ${PHP_UPSTREAM}:9000;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\. {
        deny all;
    }
}

EOF

# Создание .devcontainer
cat > "$PROJECT_DIR/.devcontainer/devcontainer.json" <<EOF
{
  "name": "${PROJECT_NAME}",
  "dockerComposeFile": "../docker-compose.yml",
  "service": "php",
  "workspaceFolder": "/opt/www",
  "shutdownAction": "none",
  "customizations": {
    "vscode": {
      "extensions": [
        "xdebug.php-debug",
        "bmewburn.vscode-intelephense-client"
      ],
      "settings": {
        "php.validate.executablePath": "/usr/local/bin/php"
      }
    }
  },
  "forwardPorts": [9003],
  "postCreateCommand": "chmod -R 777 /opt/www"
}

EOF

# Создание launch.json для Xdebug
mkdir -p "$PROJECT_DIR/.devcontainer/.vscode"
cat > "$PROJECT_DIR/.devcontainer/.vscode/launch.json" <<EOF
{
  "version": "0.2.0",
  "configurations": [
    {
      "name": "Listen for Xdebug",
      "type": "php",
      "request": "launch",
      "port": 9003,
      "pathMappings": {
        "/opt/www": "\${workspaceFolder}/src"
      },
      "log": true
    }
  ]
}

EOF

# Создание .gitignore
cat > "$PROJECT_DIR/.gitignore" <<EOF
.env
db-${DB_TYPE}/
src/vendor/
src/node_modules/
*.log

EOF

# Переменные для подстановки в шаблонах пресета
DB_HOST="$DB_SERVICE_NAME"
DB_USER="user"
DB_PASSWORD="password"
[ "$DB_TYPE" = "postgres" ] && DB_USER="postgres" && DB_PASSWORD="postgres"

# Пресет: копирование файлов, выполнение install.sh, генерация конфигов из шаблонов
echo "📂 Применение пресета '$PRESET'..."

# Проверяем, есть ли .env.template в пресете
has_env_template=0
shopt -s nullglob
for tpl in "$PRESET_DIR"/.env.template; do
    [ -f "$tpl" ] && has_env_template=1
    break
done
shopt -u nullglob

# Создаем базовый .env.example только если в пресете нет .env.template
if [ "$has_env_template" -eq 0 ]; then
    cat > "$PROJECT_DIR/.env.example" <<EOF
# Настройки проекта ${PROJECT_NAME}
TZ=Europe/Moscow
DB_BIND_ADDRESS=${DB_BIND_ADDRESS}
DB_EXTERNAL_PORT=${DB_EXTERNAL_PORT_VALUE}
DB_SERVICE_NAME=${DB_SERVICE_NAME}
DB_NAME=${DB_NAME}

# База данных
EOF

    if [ "$DB_TYPE" = "mysql" ]; then
        cat >> "$PROJECT_DIR/.env.example" <<EOF
MYSQL_ROOT_PASSWORD=root
MYSQL_DATABASE=${PROJECT_NAME//./_}
MYSQL_USER=user
MYSQL_PASSWORD=password
EOF
    elif [ "$DB_TYPE" = "postgres" ]; then
        cat >> "$PROJECT_DIR/.env.example" <<EOF
POSTGRES_DB=${PROJECT_NAME//./_}
POSTGRES_USER=postgres
POSTGRES_PASSWORD=postgres
EOF
    fi
fi

# Выполнение install.sh пресета
if [ -x "$PRESET_DIR/install.sh" ]; then
    "$PRESET_DIR/install.sh" "$PROJECT_DIR" "$PROJECT_NAME" "$DB_TYPE" "$DB_HOST" "$DB_NAME" "$DB_USER" "$DB_PASSWORD" || true
elif [ -f "$PRESET_DIR/install.sh" ]; then
    bash "$PRESET_DIR/install.sh" "$PROJECT_DIR" "$PROJECT_NAME" "$DB_TYPE" "$DB_HOST" "$DB_NAME" "$DB_USER" "$DB_PASSWORD" || true
fi

# Генерация конфигов из шаблонов (*.template).
# nullglob гарантирует, что непустые шаблоны обрабатываются корректно,
# а отсутствие шаблонов не приводит к синтаксическим ошибкам цикла.
shopt -s nullglob
for tpl in "$PRESET_DIR"/*.template "$PRESET_DIR"/.*.template; do
    [ -f "$tpl" ] || continue
    base="$(basename "$tpl" .template)"
    case "$base" in
        .settings.php)
            mkdir -p "$PROJECT_DIR/src/bitrix"
            out="$PROJECT_DIR/src/bitrix/.settings.php"
            ;;
        nginx.conf)
            out="$PROJECT_DIR/nginx/site.conf"
            ;;
        .env)
            out="$PROJECT_DIR/.env.example"
            sed -e "s|{{DB_HOST}}|$DB_HOST|g" -e "s|{{DB_NAME}}|$DB_NAME|g" \
                -e "s|{{DB_USER}}|$DB_USER|g" -e "s|{{DB_PASSWORD}}|$DB_PASSWORD|g" \
                -e "s|{{DB_TYPE}}|$DB_TYPE|g" -e "s|{{DB_PORT}}|$DB_PORT|g" \
                -e "s|{{PROJECT_NAME}}|$PROJECT_NAME|g" -e "s|{{PHP_UPSTREAM}}|$PHP_UPSTREAM|g" "$tpl" > "$out"
            continue
            ;;
        *)
            out="$PROJECT_DIR/$base"
            ;;
    esac
    sed -e "s|{{DB_HOST}}|$DB_HOST|g" -e "s|{{DB_NAME}}|$DB_NAME|g" \
        -e "s|{{DB_USER}}|$DB_USER|g" -e "s|{{DB_PASSWORD}}|$DB_PASSWORD|g" \
        -e "s|{{PROJECT_NAME}}|$PROJECT_NAME|g" -e "s|{{PHP_UPSTREAM}}|$PHP_UPSTREAM|g" "$tpl" > "$out"
done
shopt -u nullglob

# Создание README для проекта
cat > "$PROJECT_DIR/README.md" <<EOF
# ${PROJECT_NAME}

## Стек

- Пресет: ${PRESET}
- PHP: PHP ${PHP_VERSION}
- БД: ${DB_TYPE}

## Управление

Управление хостом осуществляется через \`hostctl.sh\`:

\`\`\`bash
# Запуск хоста
./hostctl.sh start ${PROJECT_NAME}

# Остановка хоста
./hostctl.sh stop ${PROJECT_NAME}

# Статус хоста
./hostctl.sh status --host ${PROJECT_NAME}
\`\`\`

## Доступ

- Сайт: http://${PROJECT_NAME}

## Xdebug

Настройте IDE для прослушивания порта 9003.

EOF

# Стартовый индекс в зависимости от пресета
case "$PRESET" in
  bitrix)
    cat > "$PROJECT_DIR/src/index.php" <<'EOF'
<?php
$hasSetup = file_exists(__DIR__ . '/bitrixsetup.php');
$hasRestore = file_exists(__DIR__ . '/restore.php');
?>
<!doctype html>
<html lang="ru">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Bitrix preset</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; margin: 2rem; line-height: 1.5; color: #1f2937; }
        .card { max-width: 880px; border: 1px solid #e5e7eb; border-radius: 12px; padding: 1.25rem; background: #fff; }
        h1 { margin-top: 0; font-size: 1.5rem; }
        .actions { display: flex; gap: 0.75rem; flex-wrap: wrap; margin: 1rem 0 1.25rem; }
        .btn { display: inline-block; padding: 0.65rem 0.9rem; border-radius: 8px; text-decoration: none; border: 1px solid #2563eb; color: #fff; background: #2563eb; }
        .btn.secondary { border-color: #4b5563; background: #4b5563; }
        .btn.disabled { border-color: #9ca3af; background: #d1d5db; color: #374151; cursor: not-allowed; pointer-events: none; }
        code { background: #f3f4f6; border-radius: 6px; padding: 0.15rem 0.35rem; }
        .warn { color: #92400e; background: #fffbeb; border: 1px solid #fcd34d; border-radius: 8px; padding: 0.75rem; }
        ul { margin-top: 0.5rem; }
    </style>
</head>
<body>
    <div class="card">
        <h1>Bitrix preset</h1>
        <p>Хост создан. Выберите сценарий: установка новой копии или восстановление из резервной копии.</p>

        <div class="actions">
            <?php if ($hasSetup): ?>
                <a class="btn" href="/bitrixsetup.php">Установка Битрикс (bitrixsetup.php)</a>
            <?php else: ?>
                <span class="btn disabled">bitrixsetup.php не найден</span>
            <?php endif; ?>

            <?php if ($hasRestore): ?>
                <a class="btn secondary" href="/restore.php">Восстановление (restore.php)</a>
            <?php else: ?>
                <span class="btn disabled">restore.php не найден</span>
            <?php endif; ?>
        </div>

        <?php if (!$hasSetup || !$hasRestore): ?>
            <div class="warn">
                Не найдены один или оба установочных скрипта. Пересоздайте хост или скачайте вручную:
                <ul>
                    <li><code>https://www.1c-bitrix.ru/download/files/scripts/bitrixsetup.php</code></li>
                    <li><code>https://www.1c-bitrix.ru/download/files/scripts/restore.php</code></li>
                </ul>
            </div>
        <?php endif; ?>

        <h3>Что проверить перед запуском</h3>
        <ul>
            <li>Домен прописан в <code>/etc/hosts</code>.</li>
            <li>Контейнеры хоста запущены через <code>hostctl.sh start &lt;host&gt;</code>.</li>
            <li>Параметры БД в <code>src/bitrix/.settings.php</code> актуальны для этого хоста.</li>
        </ul>
    </div>
</body>
</html>
EOF
    ;;
  empty|*)
    cat > "$PROJECT_DIR/src/index.php" <<'EOF'
<?php
if (isset($_GET['phpinfo']) && $_GET['phpinfo'] === '1') {
    phpinfo();
    exit;
}
?>
<!doctype html>
<html lang="ru">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Empty preset</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; margin: 2rem; line-height: 1.5; color: #1f2937; }
        .card { max-width: 820px; border: 1px solid #e5e7eb; border-radius: 12px; padding: 1.25rem; background: #fff; }
        h1 { margin-top: 0; font-size: 1.45rem; }
        code { background: #f3f4f6; border-radius: 6px; padding: 0.15rem 0.35rem; }
        a { color: #2563eb; }
    </style>
</head>
<body>
    <div class="card">
        <h1>Empty preset</h1>
        <p>Хост работает. Это стартовая страница для пустого пресета.</p>

        <h3>Следующие шаги</h3>
        <ul>
            <li>Добавьте код проекта в директорию <code>src/</code>.</li>
            <li>Установите зависимости вашего приложения (composer/npm).</li>
            <li>Проверьте состояние контейнеров: <code>./hostctl.sh status --host &lt;host&gt;</code>.</li>
        </ul>

        <p>
            Для диагностики окружения откройте
            <a href="/index.php?phpinfo=1">phpinfo()</a>.
        </p>
    </div>
</body>
</html>
EOF
    ;;
esac

echo "✅ Проект $PROJECT_NAME создан!"
echo ""
echo "Проект готов к использованию. Конфигурация (.env) и запуск контейнеров выполняются автоматически через hostctl.sh."
