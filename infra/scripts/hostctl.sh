#!/bin/bash

# Unified host lifecycle CLI for MVP:
# - create
# - delete
# - status
#
# This script composes existing tooling:
# - create-project.sh
# - manage-hosts.sh

set -eEuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"
DEV_DIR="$(dirname "$INFRA_DIR")"
PROJECTS_DIR="${DEV_DIR}/projects"
PROJECTS_DIR="${PROJECTS_DIR//\/\//\/}"
STATE_DIR_DEFAULT="$INFRA_DIR/state"
if [ "$PROJECTS_DIR" = "/projects" ] && [ -d "/state" ]; then
    STATE_DIR_DEFAULT="/state"
fi
STATE_DIR="${HOSTCTL_STATE_DIR:-$STATE_DIR_DEFAULT}"
STATE_DIR="${STATE_DIR//\/\//\/}"
CREATE_SCRIPT="$SCRIPT_DIR/create-project.sh"
HOSTS_SCRIPT="$SCRIPT_DIR/manage-hosts.sh"
GENERATE_SSL_SCRIPT="$SCRIPT_DIR/generate-ssl.sh"
REGISTRY_FILE="$STATE_DIR/hosts-registry.tsv"
BITRIX_CORE_REGISTRY_FILE="$STATE_DIR/bitrix-core-registry.tsv"
BITRIX_BINDINGS_FILE="$STATE_DIR/bitrix-bindings.tsv"
BITRIX_BINDINGS_LOCK_DIR="$STATE_DIR/bitrix-bindings.lock"
INFRA_COMPOSE_FILE="$INFRA_DIR/docker-compose.shared.yml"
INFRA_DEVPANEL_FALLBACK_COMPOSE_FILE="$INFRA_DIR/docker-compose.devpanel-fallback.yml"
INFRA_DEVPANEL_FALLBACK_SERVICE="devpanel_fallback"
INFRA_DEVPANEL_FALLBACK_TLS_VOLUME="infra_traefik_tls_fallback"
INFRA_ENV_FILE="$INFRA_DIR/.env.global"
INFRA_RUNTIME_MODE_FILE="$STATE_DIR/infra-runtime-mode"
HOSTCTL_LOG_FILE="$STATE_DIR/hostctl.log"
HOSTCTL_CURRENT_COMMAND=""
HOSTCTL_CURRENT_ARGS=""
HOST_PROJECTS_DIR_CACHE=""
DOMAIN_ZONE_HELPER="$SCRIPT_DIR/domain-zone.sh"

if [ -f "$DOMAIN_ZONE_HELPER" ]; then
    # shellcheck source=/dev/null
    source "$DOMAIN_ZONE_HELPER"
fi

HOSTCTL_STATE_DIR="$STATE_DIR"
DEV_TOOLS_LIB="$SCRIPT_DIR/dev-tools-lib.sh"
if [ -f "$DEV_TOOLS_LIB" ]; then
    # shellcheck source=/dev/null
    source "$DEV_TOOLS_LIB"
fi

usage() {
    cat <<'EOF'
Usage:
  hostctl.sh create <host> [--php <version>] [--db <mysql|postgres>] [--preset <empty|bitrix>] [--bitrix-type <kernel|ext_kernel|link>] [--core <core_id>] [--core-id <core_id>] [--tz <timezone>] [--db-name <name>] [--db-user <user>] [--db-password <pass>] [--db-root-password <pass>] [--db-port <port>] [--hosts-mode <auto|skip>] [--interactive|--no-interactive] [--no-start]
  hostctl.sh start <host>
  hostctl.sh stop <host>
  hostctl.sh infra-start
  hostctl.sh infra-stop
  hostctl.sh infra-restart
  hostctl.sh delete <host> [--yes]
  hostctl.sh status [--host <host>]
  hostctl.sh enable-dev-tools <host> [--xdebug] [--adminer]
  hostctl.sh disable-dev-tools <host> [--xdebug] [--adminer]
  hostctl.sh update-component-adminer
  hostctl.sh update-presets
  hostctl.sh logs [--tail <lines>]
  hostctl.sh logs-review [--dry-run]

Notes:
  create <host> in interactive terminal automatically starts dialog mode
  if php/db/preset were not provided explicitly.
  create uses '--hosts-mode auto' by default: it updates /etc/hosts only
  when possible without sudo password prompt.
  status without --host prints all discovered hosts and all applications with their states.
  status --host <host> prints only the selected host and its applications.

Examples:
  hostctl.sh create my-project --php 8.2 --db mysql --preset bitrix --bitrix-type kernel --core-id core-main
  hostctl.sh create my-link --preset bitrix --bitrix-type link --core core-main
  hostctl.sh create my-project --hosts-mode skip
  hostctl.sh create my-project --interactive
  hostctl.sh start my-project.<zone>
  hostctl.sh stop my-project.<zone>
  hostctl.sh infra-start
  hostctl.sh infra-stop
  hostctl.sh infra-restart
  hostctl.sh create sandbox --preset empty
  hostctl.sh delete my-project.<zone> --yes
  hostctl.sh status
  hostctl.sh logs --tail 200
  hostctl.sh logs-review
EOF
}

to_lower() {
    echo "$1" | tr '[:upper:]' '[:lower:]'
}

normalize_token() {
    local raw="$1"
    printf "%s" "$raw" | tr '[:upper:]' '[:lower:]' | sed -E "s/^[[:space:]\"']+//; s/[[:space:]\"']+$//"
}

is_valid_domain_suffix() {
    local value="$1"
    [[ "$value" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]]
}

is_valid_host_label() {
    local value="$1"
    [[ "$value" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]]
}

resolve_domain_suffix() {
    local raw="${DOMAIN_SUFFIX:-}"
    local suffix=""
    local fallback_example="$INFRA_DIR/.env.global.example"

    if [ -z "$raw" ] && [ -f "$INFRA_ENV_FILE" ]; then
        raw="$(env_get_key "$INFRA_ENV_FILE" "DOMAIN_SUFFIX")"
    fi

    if [ -z "$raw" ] && [ -f "$fallback_example" ]; then
        raw="$(env_get_key "$fallback_example" "DOMAIN_SUFFIX")"
    fi

    suffix="$(normalize_token "$raw")"

    if [ -z "$suffix" ]; then
        fail_with_code "invalid_domain_suffix" "Не задан DOMAIN_SUFFIX. Укажите DOMAIN_SUFFIX в 'infra/.env.global' (например, 'pillat')."
        return 1
    fi

    if ! is_valid_domain_suffix "$suffix"; then
        fail_with_code "invalid_domain_suffix" "Некорректный DOMAIN_SUFFIX '$suffix'. Допустимо: [a-z0-9-], первый символ [a-z0-9], длина до 31."
        return 1
    fi

    echo "$suffix"
}

canonicalize_host_name() {
    local raw_host="$1"
    local domain_suffix="$2"
    local mode="${3:-existing}"
    local normalized=""
    local host_label=""
    local host_suffix=""

    normalized="$(normalize_token "$raw_host")"

    if is_valid_host_label "$normalized"; then
        echo "${normalized}.${domain_suffix}"
        return 0
    fi

    if [[ "$normalized" =~ ^([a-z0-9][a-z0-9-]{0,62})\.([a-z0-9][a-z0-9-]{0,30})$ ]]; then
        host_label="${BASH_REMATCH[1]}"
        host_suffix="${BASH_REMATCH[2]}"

        if [ "$host_suffix" = "$domain_suffix" ]; then
            echo "${host_label}.${domain_suffix}"
            return 0
        fi

        if [ "$mode" = "create" ]; then
            fail_with_code "foreign_suffix" "Хост '$raw_host' использует суффикс '$host_suffix'. Активный суффикс: '$domain_suffix'. Используйте '<name>' или '<name>.$domain_suffix'."
            return 1
        fi

        # Для уже существующих legacy-хостов допускаем явный домен с другим suffix.
        echo "${host_label}.${host_suffix}"
        return 0
    fi

    fail_with_code "invalid_host" "Некорректное имя хоста '$raw_host'. Допустимо: '<name>' или '<name>.$domain_suffix', где name соответствует [a-z0-9-]."
    return 1
}

# T025: Legacy host = domain with suffix different from active zone. Informational marker only.
is_legacy_host() {
    local host="$1"
    local domain_suffix="$2"
    if [[ "$host" =~ \.([a-z0-9][a-z0-9-]{0,30})$ ]]; then
        local host_suffix="${BASH_REMATCH[1]}"
        [ "$host_suffix" != "$domain_suffix" ]
        return
    fi
    # No dot or invalid format — treat as legacy/unknown
    return 0
}

infra_fallback_enabled() {
    local raw="${INFRA_FALLBACK_ENABLED:-}"
    local normalized

    if [ -z "$raw" ] && [ -f "$INFRA_ENV_FILE" ]; then
        raw="$(awk '
            index($0, "INFRA_FALLBACK_ENABLED=") == 1 {
                sub("^INFRA_FALLBACK_ENABLED=", "", $0)
                gsub(/^[[:space:]]+/, "", $0)
                gsub(/[[:space:]]+$/, "", $0)
                print $0
                exit
            }
        ' "$INFRA_ENV_FILE" 2>/dev/null || true)"
    fi

    [ -n "$raw" ] || raw="1"
    normalized="$(to_lower "$raw")"

    case "$normalized" in
        ""|1|true|yes|on|enabled)
            return 0
            ;;
        0|false|no|off|disabled)
            return 1
            ;;
        *)
            # Be permissive for unknown values to preserve current behavior.
            return 0
            ;;
    esac
}

normalize_container_state() {
    local raw="${1:-}"
    local state
    state="$(to_lower "$raw")"

    case "$state" in
        running|up)
            echo "running"
            ;;
        exited|stopped|created)
            echo "stopped"
            ;;
        "")
            echo "stopped"
            ;;
        *)
            echo "error"
            ;;
    esac
}

is_valid_port() {
    local port="$1"
    case "$port" in
        ''|*[!0-9]*)
            return 1
            ;;
    esac

    [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

prompt_with_default() {
    local label="$1"
    local default="$2"
    local value=""

    printf "%s [%s]: " "$label" "$default" >&2
    read -r value || true

    if [ -z "$value" ]; then
        echo "$default"
    else
        echo "$value"
    fi
}

prompt_choice_with_default() {
    local label="$1"
    local default="$2"
    shift 2
    local choices=("$@")
    local answer=""
    local normalized=""
    local choice=""

    while true; do
        answer="$(prompt_with_default "$label" "$default")"
        normalized="$(to_lower "$answer")"

        for choice in "${choices[@]}"; do
            if [ "$normalized" = "$choice" ]; then
                echo "$normalized"
                return 0
            fi
        done

        echo "Allowed values: ${choices[*]}" >&2
    done
}

prompt_yes_no_default() {
    local label="$1"
    local default="$2"
    local answer=""
    local normalized=""

    while true; do
        printf "%s [%s]: " "$label" "$default" >&2
        read -r answer || true
        answer="${answer:-$default}"
        normalized="$(to_lower "$answer")"

        case "$normalized" in
            y|yes)
                echo "yes"
                return 0
                ;;
            n|no)
                echo "no"
                return 0
                ;;
        esac

        echo "Please answer yes/y or no/n." >&2
    done
}

prompt_port_with_default() {
    local label="$1"
    local default="$2"
    local value=""

    while true; do
        value="$(prompt_with_default "$label" "$default")"
        if is_valid_port "$value"; then
            echo "$value"
            return 0
        fi
        echo "Port must be an integer between 1 and 65535." >&2
    done
}

ensure_state_dir() {
    mkdir -p "$STATE_DIR" >/dev/null 2>&1 || true
    chmod 0775 "$STATE_DIR" >/dev/null 2>&1 || true
}

set_infra_runtime_mode() {
    local mode="$1"
    ensure_state_dir
    printf "%s\n" "$mode" > "$INFRA_RUNTIME_MODE_FILE" 2>/dev/null || true
}

get_infra_runtime_mode() {
    if command -v docker >/dev/null 2>&1; then
        if docker ps --format '{{.Names}}' | awk '$1=="devpanel-fallback"{found=1} END{exit !found}'; then
            echo "fallback"
            return 0
        fi
        if docker ps --format '{{.Names}}' | awk '$1=="devpanel"{found=1} END{exit !found}'; then
            echo "primary"
            return 0
        fi
    fi

    [ -f "$INFRA_RUNTIME_MODE_FILE" ] || { echo ""; return 0; }
    awk 'NR==1 {print; exit}' "$INFRA_RUNTIME_MODE_FILE" 2>/dev/null || true
}

clear_infra_runtime_mode() {
    rm -f "$INFRA_RUNTIME_MODE_FILE" >/dev/null 2>&1 || true
}

migrate_legacy_state_file() {
    local legacy_path="$1"
    local target_path="$2"

    [ -e "$legacy_path" ] || return 0
    if [ -e "$target_path" ]; then
        if [ -d "$legacy_path" ] && [ -d "$target_path" ]; then
            cp -R "$legacy_path"/. "$target_path"/ >/dev/null 2>&1 || true
            rm -rf "$legacy_path" >/dev/null 2>&1 || true
            return 0
        fi
        if [ -f "$legacy_path" ] && [ -f "$target_path" ]; then
            cat "$legacy_path" >> "$target_path" 2>/dev/null || true
            rm -f "$legacy_path" >/dev/null 2>&1 || true
        fi
        return 0
    fi

    mkdir -p "$(dirname "$target_path")" >/dev/null 2>&1 || true
    if mv "$legacy_path" "$target_path" >/dev/null 2>&1; then
        return 0
    fi

    if [ -d "$legacy_path" ]; then
        cp -R "$legacy_path" "$target_path" >/dev/null 2>&1 || return 0
        rm -rf "$legacy_path" >/dev/null 2>&1 || true
        return 0
    fi

    cp "$legacy_path" "$target_path" >/dev/null 2>&1 || return 0
    rm -f "$legacy_path" >/dev/null 2>&1 || true
}

migrate_legacy_state_layout() {
    # Переносим legacy-файлы состояния из projects/ и dot-формата в централизованный state-каталог.
    migrate_legacy_state_file "$PROJECTS_DIR/.hosts-registry.tsv" "$REGISTRY_FILE"
    migrate_legacy_state_file "$PROJECTS_DIR/.bitrix-core-registry.tsv" "$BITRIX_CORE_REGISTRY_FILE"
    migrate_legacy_state_file "$PROJECTS_DIR/.bitrix-bindings.tsv" "$BITRIX_BINDINGS_FILE"
    migrate_legacy_state_file "$PROJECTS_DIR/.bitrix-bindings.lock" "$BITRIX_BINDINGS_LOCK_DIR"
    migrate_legacy_state_file "$PROJECTS_DIR/.hostctl.log" "$HOSTCTL_LOG_FILE"

    migrate_legacy_state_file "$STATE_DIR/.hosts-registry.tsv" "$REGISTRY_FILE"
    migrate_legacy_state_file "$STATE_DIR/.bitrix-core-registry.tsv" "$BITRIX_CORE_REGISTRY_FILE"
    migrate_legacy_state_file "$STATE_DIR/.bitrix-bindings.tsv" "$BITRIX_BINDINGS_FILE"
    migrate_legacy_state_file "$STATE_DIR/.bitrix-bindings.lock" "$BITRIX_BINDINGS_LOCK_DIR"
    migrate_legacy_state_file "$STATE_DIR/.hostctl.log" "$HOSTCTL_LOG_FILE"
}

cleanup_state_appledouble_files() {
    local candidate=""
    for candidate in "$STATE_DIR"/._*; do
        [ -e "$candidate" ] || continue
        rm -f "$candidate" >/dev/null 2>&1 || true
    done
}

ensure_log_file_ready() {
    ensure_state_dir
    [ -f "$HOSTCTL_LOG_FILE" ] || touch "$HOSTCTL_LOG_FILE" >/dev/null 2>&1 || true
}

log_event() {
    local level="$1"
    shift || true
    local message="$*"
    local timestamp
    timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

    ensure_log_file_ready
    printf "%s\t%s\tpid=%s\tcommand=%s\targs=%s\tmessage=%s\n" \
        "$timestamp" \
        "$level" \
        "$$" \
        "${HOSTCTL_CURRENT_COMMAND:-unknown}" \
        "${HOSTCTL_CURRENT_ARGS:-}" \
        "$message" >> "$HOSTCTL_LOG_FILE" 2>/dev/null || true
}

handle_error_trap() {
    local exit_code="$?"
    local line_no="${1:-unknown}"
    log_event "ERROR" "exit_code=$exit_code line=$line_no"
}

trap 'handle_error_trap "$LINENO"' ERR

fail_with_code() {
    local code="$1"
    local message="$2"
    log_event "ERROR" "code=$code message=$message"
    echo "Error[$code]: $message" >&2
    return 1
}

print_help_hint() {
    echo "Hint: run './hostctl.sh --help' to see available commands and options."
}

print_status_hint() {
    echo "Hint: run './hostctl.sh status' to list available hosts and their states."
}

print_host_compose_hint() {
    local project_dir="$1"
    local subcommand="$2"
    echo "  cd \"$project_dir\" && COPYFILE_DISABLE=1 docker compose $subcommand"
}

can_sync_hosts_without_prompt() {
    if [ -w "/etc/hosts" ]; then
        return 0
    fi

    if ! command -v sudo >/dev/null 2>&1; then
        return 1
    fi

    sudo -n true >/dev/null 2>&1
}

sync_hosts_entry() {
    local action="$1"
    local host="$2"
    local mode="${3:-auto}"
    local normalized_mode

    normalized_mode="$(to_lower "$mode")"

    [ -x "$HOSTS_SCRIPT" ] || return 0

    case "$normalized_mode" in
        auto)
            if can_sync_hosts_without_prompt; then
                "$HOSTS_SCRIPT" "$action" "$host" >/dev/null 2>&1 || true
            else
                echo "   ℹ️  Пропущено обновление /etc/hosts для '$host' (требуется пароль sudo)."
                echo "   💡 Выполните вручную при необходимости:"
                echo "      sudo \"$HOSTS_SCRIPT\" $action \"$host\""
            fi
            ;;
        skip)
            echo "   ℹ️  Пропущено обновление /etc/hosts для '$host' (--hosts-mode skip)."
            ;;
        *)
            echo "Error: unsupported hosts mode '$mode'. Supported: auto, skip."
            print_help_hint
            return 1
            ;;
    esac
}

normalize_bitrix_type() {
    local raw="$1"
    local lower
    lower="$(to_lower "$raw")"

    case "$lower" in
        kernel|ext_kernel|link)
            echo "$lower"
            ;;
        ext-kernel|extkernel)
            echo "ext_kernel"
            ;;
        *)
            return 1
            ;;
    esac
}

is_valid_core_id() {
    local core_id="$1"
    [[ "$core_id" =~ ^[a-z0-9][a-z0-9-]{1,62}$ ]]
}

normalize_core_id() {
    local raw="$1"
    to_lower "$raw" | sed -E 's/[^a-z0-9-]+/-/g; s/-+/-/g; s/^-+//; s/-+$//'
}

default_core_id_for_host() {
    local host="$1"
    local seed="${host%%.*}"
    seed="$(normalize_core_id "$seed")"
    [ -n "$seed" ] || seed="main"
    echo "core-$seed"
}

prompt_core_id_with_default() {
    local label="$1"
    local default="$2"
    local value=""

    while true; do
        value="$(prompt_with_default "$label" "$default")"
        value="$(normalize_core_id "$value")"
        if is_valid_core_id "$value"; then
            echo "$value"
            return 0
        fi
        echo "core_id должен соответствовать шаблону: [a-z0-9][a-z0-9-]{1,62}" >&2
    done
}

env_get_key() {
    local file="$1"
    local key="$2"
    [ -f "$file" ] || { echo ""; return 0; }
    awk -F'=' -v key="$key" '
        index($0, key "=") == 1 {
            $1 = ""
            sub(/^=/, "", $0)
            print $0
            found = 1
            exit
        }
        END {
            if (!found) print ""
        }
    ' "$file"
}

env_set_key() {
    local file="$1"
    local key="$2"
    local value="$3"
    local tmp_file="${file}.tmp.$$"

    [ -f "$file" ] || touch "$file"

    awk -v k="$key" -v v="$value" '
        BEGIN { done = 0 }
        index($0, k "=") == 1 {
            print k "=" v
            done = 1
            next
        }
        { print }
        END {
            if (!done) print k "=" v
        }
    ' "$file" > "$tmp_file"

    mv "$tmp_file" "$file"
}

require_python3() {
    local mode="${1:-required}" # required|optional
    local context="${2:-unknown}"

    if command -v python3 >/dev/null 2>&1; then
        return 0
    fi

    if [ "$mode" = "optional" ]; then
        log_event "WARN" "python3_missing context=$context mode=optional"
        return 1
    fi

    log_event "ERROR" "python3_missing context=$context mode=required"
    echo "Error: python3 is required for '$context'. Install python3 in current environment." >&2
    return 1
}

resolve_host_projects_dir() {
    if [ -n "${HOST_PROJECTS_DIR_CACHE:-}" ]; then
        echo "$HOST_PROJECTS_DIR_CACHE"
        return 0
    fi

    local resolved="$PROJECTS_DIR"
    if [ "$PROJECTS_DIR" = "/projects" ] && command -v docker >/dev/null 2>&1 && [ -n "${HOSTNAME:-}" ]; then
        local mounted_source=""
        mounted_source="$(docker inspect "$HOSTNAME" --format '{{range .Mounts}}{{printf "%s\t%s\n" .Destination .Source}}{{end}}' 2>/dev/null | awk -F'\t' '$1=="/projects"{print $2; exit}')"
        if [ -n "$mounted_source" ]; then
            resolved="$mounted_source"
        fi
    fi

    HOST_PROJECTS_DIR_CACHE="$resolved"
    echo "$resolved"
}

running_inside_devpanel_runtime() {
    [ -n "${DEVPANEL_FALLBACK_MODE:-}" ] && return 0
    [ "$SCRIPT_DIR" = "/scripts" ] && return 0
    return 1
}

fallback_runtime_container_running() {
    command -v docker >/dev/null 2>&1 || return 1
    docker ps --format '{{.Names}}' | awk '$1=="devpanel-fallback"{found=1} END{exit !found}'
}

maybe_delegate_to_fallback_runtime() {
    local cmd="$1"
    shift || true

    case "$cmd" in
        infra-start|infra-stop|infra-restart|help|-h|--help)
            return 2
            ;;
    esac

    if running_inside_devpanel_runtime; then
        return 2
    fi

    if ! fallback_runtime_container_running; then
        return 2
    fi

    echo "ℹ️  Активен fallback-режим: команда '$cmd' выполняется в контейнере devpanel-fallback."
    docker exec -u www-data devpanel-fallback /scripts/hostctl.sh "$cmd" "$@"
    return $?
}

set_compose_db_external_port() {
    local compose_file="$1"
    local db_type="$2"
    local external_port="$3"

    [ -f "$compose_file" ] || return 0
    require_python3 optional "set_compose_db_external_port" || return 0

    python3 - "$compose_file" "$db_type" "$external_port" <<'PY'
import pathlib
import re
import sys

compose_path = pathlib.Path(sys.argv[1])
db_type = sys.argv[2]
external_port = sys.argv[3]
text = compose_path.read_text(encoding="utf-8")

if db_type == "mysql":
    pattern = r'(?m)^(\s*-\s*")[^"]*:3306(")$'
    replacement = rf'\1${{DB_EXTERNAL_PORT:-{external_port}}}:3306\2'
elif db_type == "postgres":
    pattern = r'(?m)^(\s*-\s*")[^"]*:5432(")$'
    replacement = rf'\1${{DB_EXTERNAL_PORT:-{external_port}}}:5432\2'
else:
    pattern = None
    replacement = None

if pattern:
    updated, count = re.subn(pattern, replacement, text, count=1)
    if count:
        compose_path.write_text(updated, encoding="utf-8")
PY
}

apply_project_overrides() {
    local project_dir="$1"
    local db_type="$2"
    local timezone="$3"
    local db_name="$4"
    local db_user="$5"
    local db_password="$6"
    local db_root_password="$7"
    local db_external_port="$8"
    local env_example="$project_dir/.env.example"
    local env_file="$project_dir/.env"
    local target=""

    for target in "$env_example" "$env_file"; do
        if [ "$target" = "$env_file" ] && [ ! -f "$env_file" ]; then
            cp "$env_example" "$env_file"
        fi

        env_set_key "$target" "TZ" "$timezone"
        env_set_key "$target" "DB_EXTERNAL_PORT" "$db_external_port"

        if [ "$db_type" = "mysql" ]; then
            env_set_key "$target" "MYSQL_ROOT_PASSWORD" "$db_root_password"
            env_set_key "$target" "MYSQL_DATABASE" "$db_name"
            env_set_key "$target" "MYSQL_USER" "$db_user"
            env_set_key "$target" "MYSQL_PASSWORD" "$db_password"
        else
            env_set_key "$target" "POSTGRES_DB" "$db_name"
            env_set_key "$target" "POSTGRES_USER" "$db_user"
            env_set_key "$target" "POSTGRES_PASSWORD" "$db_password"
        fi
    done

    set_compose_db_external_port "$project_dir/docker-compose.yml" "$db_type" "$db_external_port"
}

rewrite_compose_paths_for_daemon() {
    local project_dir="$1"
    local host="$2"
    local compose_file="$project_dir/docker-compose.yml"
    [ -f "$compose_file" ] || return 0

    local host_projects_dir=""
    host_projects_dir="$(resolve_host_projects_dir)"
    [ -n "$host_projects_dir" ] || return 0
    log_event "INFO" "compose_path_rewrite_probe host=$host project_dir=$project_dir host_projects_dir=$host_projects_dir"

    # On host this is usually the same path and no rewrite is needed.
    if [ "$host_projects_dir" = "$PROJECTS_DIR" ] && [ "$PROJECTS_DIR" != "/projects" ]; then
        log_event "INFO" "compose_path_rewrite_skip host=$host reason=already_host_path"
        return 0
    fi
    if [ "$host_projects_dir" = "/projects" ]; then
        log_event "WARN" "compose_path_rewrite_skip host=$host reason=host_projects_unresolved"
        return 0
    fi
    
    # Если запускаемся из контейнера (/projects), не переписываем пути хоста
    # Вместо этого будем использовать --project-directory в runtime_host_compose
    if [ "$PROJECTS_DIR" = "/projects" ]; then
        log_event "INFO" "compose_path_rewrite_skip host=$host reason=running_from_container_will_use_project_directory"
        return 0
    fi

    local host_project_dir="$host_projects_dir/$host"
    local host_root_dir
    host_root_dir="$(dirname "$host_projects_dir")"
    local host_logs_dir="$host_root_dir/logs"
    local tmp_file="${compose_file}.tmp.$$"

    awk \
        -v host_project_dir="$host_project_dir" \
        -v host_logs_dir="$host_logs_dir" \
        -v host="$host" '
        {
            if ($0 ~ /^[[:space:]]*context:[[:space:]]*\.[[:space:]]*$/) {
                print "      context: \"" host_project_dir "\""
                next
            }
            if ($0 ~ /^[[:space:]]*-[[:space:]]*\.\/www:\/opt\/www[[:space:]]*$/) {
                print "      - \"" host_project_dir "/www:/opt/www\""
                next
            }
            if ($0 ~ /^[[:space:]]*-[[:space:]]*\.\/src:\/opt\/www[[:space:]]*$/) {
                print "      - \"" host_project_dir "/src:/opt/www\""
                next
            }
            if ($0 ~ /^[[:space:]]*-[[:space:]]*\.\/www:\/opt\/www:ro[[:space:]]*$/) {
                print "      - \"" host_project_dir "/www:/opt/www:ro\""
                next
            }
            if ($0 ~ /^[[:space:]]*-[[:space:]]*\.\/src:\/opt\/www:ro[[:space:]]*$/) {
                print "      - \"" host_project_dir "/src:/opt/www:ro\""
                next
            }
            if ($0 ~ /^[[:space:]]*-[[:space:]]*\.\/nginx\/site\.conf:\/etc\/nginx\/conf\.d\/default\.conf:ro[[:space:]]*$/) {
                print "      - \"" host_project_dir "/nginx/site.conf:/etc/nginx/conf.d/default.conf:ro\""
                next
            }
            if ($0 ~ /^[[:space:]]*-[[:space:]]*\.\/logs\/php:\/var\/log\/php[[:space:]]*$/) {
                print "      - \"" host_project_dir "/logs/php:/var/log/php\""
                next
            }
            if ($0 ~ /^[[:space:]]*-[[:space:]]*\.\/logs\/nginx:\/var\/log\/nginx[[:space:]]*$/) {
                print "      - \"" host_project_dir "/logs/nginx:/var/log/nginx\""
                next
            }
            # Обратная совместимость: старый формат ../../logs/php/<host>
            if ($0 ~ /^[[:space:]]*-[[:space:]]*\.\.\/\.\.\/logs\/php\/[^:]+:\/var\/log\/php[[:space:]]*$/) {
                print "      - \"" host_project_dir "/logs/php:/var/log/php\""
                next
            }
            if ($0 ~ /^[[:space:]]*-[[:space:]]*\.\.\/\.\.\/logs\/nginx\/[^:]+:\/var\/log\/nginx[[:space:]]*$/) {
                print "      - \"" host_project_dir "/logs/nginx:/var/log/nginx\""
                next
            }
            if ($0 ~ /^[[:space:]]*device:[[:space:]]*\$\{PWD\}\/db-mysql[[:space:]]*$/) {
                print "      device: \"" host_project_dir "/db-mysql\""
                next
            }
            if ($0 ~ /^[[:space:]]*device:[[:space:]]*\$\{PWD\}\/db-postgres[[:space:]]*$/) {
                print "      device: \"" host_project_dir "/db-postgres\""
                next
            }
            print
        }
    ' "$compose_file" > "$tmp_file"

    if cmp -s "$compose_file" "$tmp_file"; then
        rm -f "$tmp_file"
        log_event "INFO" "compose_path_rewrite_no_changes host=$host"
        return 0
    fi

    mv "$tmp_file" "$compose_file"
    log_event "INFO" "compose_path_rewrite_applied host=$host host_projects_dir=$host_projects_dir"
}

configure_link_compose_without_db() {
    local compose_file="$1"
    local db_type="$2"
    local db_service_name="${3:-}"
    [ -f "$compose_file" ] || return 0
    require_python3 required "configure_link_compose_without_db" || return 1

    python3 - "$compose_file" "$db_type" "$db_service_name" <<'PY'
import pathlib
import re
import sys

compose_path = pathlib.Path(sys.argv[1])
db_type = (sys.argv[2] or "").strip().lower()
db_service_name = (sys.argv[3] or "").strip().lower()
target_services = {"mysql" if db_type == "mysql" else "postgres"}
if db_service_name:
    target_services.add(db_service_name)

def should_remove_service(name: str) -> bool:
    normalized = name.strip().lower()
    if normalized in target_services:
        return True
    # Feature 008 introduced dynamic service naming db-<host_slug>.
    if normalized.startswith("db-"):
        return True
    return False

lines = compose_path.read_text(encoding="utf-8").splitlines()
result = []
i = 0

while i < len(lines):
    line = lines[i]
    service_match = re.match(r"^  ([A-Za-z0-9][A-Za-z0-9_-]*):\s*$", line)
    if service_match and should_remove_service(service_match.group(1)):
        i += 1
        while i < len(lines):
            next_line = lines[i]
            if re.match(r"^  [A-Za-z0-9][A-Za-z0-9_-]*:\s*$", next_line):
                break
            i += 1
        continue

    result.append(line)
    i += 1

compose_path.write_text("\n".join(result).rstrip() + "\n", encoding="utf-8")
PY
}

apply_ext_kernel_http_restriction() {
    local compose_file="$1"
    [ -f "$compose_file" ] || return 0
    require_python3 required "apply_ext_kernel_http_restriction" || return 1

    python3 - "$compose_file" <<'PY'
import pathlib
import re
import sys

compose_path = pathlib.Path(sys.argv[1])
text = compose_path.read_text(encoding="utf-8")
updated, _ = re.subn(
    r'(?m)^(\s*-\s*"traefik\.enable=)true(")\s*$',
    r'\1false\2',
    text,
    count=1,
)
compose_path.write_text(updated, encoding="utf-8")
PY
}

# Bitrix multisite path map (T019):
#   Shared paths (symlinks link->core): bitrix, upload, images
#   Site-specific (own dir per link):   local
#   Core: <core_host>/src/{bitrix,upload,images,local}
#   Link: <link_host>/src/{bitrix->core, upload->core, images->core, local}
prepare_link_shared_paths() {
    local core_host="$1"
    local link_host="$2"
    local core_src="$PROJECTS_DIR/$core_host/www"
    local link_src="$PROJECTS_DIR/$link_host/www"
    local shared_paths=(bitrix upload images)
    local created_symlinks=()
    local path=""
    local source_path=""
    local target_link=""

    mkdir -p "$core_src" "$link_src" "$link_src/local"

    for path in "${shared_paths[@]}"; do
        source_path="$core_src/$path"
        target_link="$link_src/$path"

        mkdir -p "$source_path"

        if [ -L "$target_link" ]; then
            rm -f "$target_link"
        elif [ -e "$target_link" ]; then
            rm -rf "$target_link"
        fi

        if ! ln -s "$source_path" "$target_link"; then
            local created_link=""
            for created_link in "${created_symlinks[@]}"; do
                rm -f "$created_link" >/dev/null 2>&1 || true
            done
            return 1
        fi
        created_symlinks+=("$target_link")
    done
}

read_core_db_values() {
    local core_host="$1"
    local core_db_type="$2"
    local core_project_dir="$PROJECTS_DIR/$core_host"
    local env_file="$core_project_dir/.env"
    local db_name=""
    local db_user=""
    local db_password=""
    local db_root_password=""
    local db_external_port=""

    if [ ! -f "$env_file" ]; then
        env_file="$core_project_dir/.env.example"
    fi

    if [ "$core_db_type" = "postgres" ]; then
        db_name="$(env_get_key "$env_file" "POSTGRES_DB")"
        db_user="$(env_get_key "$env_file" "POSTGRES_USER")"
        db_password="$(env_get_key "$env_file" "POSTGRES_PASSWORD")"
        db_external_port="$(env_get_key "$env_file" "DB_EXTERNAL_PORT")"
        [ -n "$db_name" ] || db_name="${core_host//./_}"
        [ -n "$db_user" ] || db_user="postgres"
        [ -n "$db_password" ] || db_password="postgres"
        [ -n "$db_external_port" ] || db_external_port="5432"
    else
        db_name="$(env_get_key "$env_file" "MYSQL_DATABASE")"
        db_user="$(env_get_key "$env_file" "MYSQL_USER")"
        db_password="$(env_get_key "$env_file" "MYSQL_PASSWORD")"
        db_root_password="$(env_get_key "$env_file" "MYSQL_ROOT_PASSWORD")"
        db_external_port="$(env_get_key "$env_file" "DB_EXTERNAL_PORT")"
        [ -n "$db_name" ] || db_name="${core_host//./_}"
        [ -n "$db_user" ] || db_user="user"
        [ -n "$db_password" ] || db_password="password"
        [ -n "$db_root_password" ] || db_root_password="root"
        [ -n "$db_external_port" ] || db_external_port="3306"
    fi

    printf "%s\t%s\t%s\t%s\t%s\n" "$db_name" "$db_user" "$db_password" "$db_root_password" "$db_external_port"
}

remove_appledouble_files() {
    local project_dir="$1"
    [ -d "$project_dir" ] || { echo "0"; return 0; }

    if ! require_python3 optional "remove_appledouble_files"; then
        local removed=0
        local candidate=""
        while IFS= read -r candidate; do
            [ -e "$candidate" ] || continue
            if rm -rf "$candidate" >/dev/null 2>&1; then
                removed=$((removed + 1))
            fi
        done < <(find "$project_dir" -name '._*' -print 2>/dev/null)
        log_event "INFO" "appledouble_cleanup_fallback removed=$removed project_dir=$project_dir"
        echo "$removed"
        return 0
    fi

    python3 - "$project_dir" <<'PY'
import os
import shutil
import sys

root = sys.argv[1]
removed = 0

# bottom-up walk so directories can be safely removed
for dirpath, dirnames, filenames in os.walk(root, topdown=False):
    for name in filenames:
        if not name.startswith("._"):
            continue
        path = os.path.join(dirpath, name)
        try:
            os.remove(path)
            removed += 1
        except OSError:
            pass

    for name in dirnames:
        if not name.startswith("._"):
            continue
        path = os.path.join(dirpath, name)
        try:
            shutil.rmtree(path)
            removed += 1
        except OSError:
            pass

print(removed)
PY
}

clear_project_xattrs() {
    local project_dir="$1"

    if command -v xattr >/dev/null 2>&1; then
        xattr -cr "$project_dir" >/dev/null 2>&1 || true
    fi
}

is_bitrix_project() {
    local project_dir="$1"
    [ -d "$project_dir" ] || return 1

    if [ -d "$project_dir/www/bitrix" ]; then
        return 0
    fi

    local env_file="$project_dir/.env"
    if [ ! -f "$env_file" ]; then
        env_file="$project_dir/.env.example"
    fi

    if [ -f "$env_file" ]; then
        local bitrix_type=""
        bitrix_type="$(to_lower "$(env_get_key "$env_file" "BITRIX_TYPE")")"
        case "$bitrix_type" in
            kernel|ext_kernel|link)
                return 0
                ;;
        esac
    fi

    return 1
}

patch_project_php_ini_display_errors() {
    local project_dir="$1"
    local php_ini="$project_dir/php.ini"
    [ -f "$php_ini" ] || { echo "0"; return 0; }
    require_python3 optional "patch_project_php_ini_display_errors" || { echo "0"; return 0; }

    python3 - "$php_ini" <<'PY'
import pathlib
import re
import sys

php_ini_path = pathlib.Path(sys.argv[1])
text = php_ini_path.read_text(encoding="utf-8", errors="ignore")
original = text

line_re = re.compile(r"^\s*display_errors\s*=.*$", re.M | re.I)
if line_re.search(text):
    text = line_re.sub("display_errors = On", text)
else:
    if text and not text.endswith("\n"):
        text += "\n"
    text += "\ndisplay_errors = On\n"

max_input_vars_re = re.compile(r"^\s*max_input_vars\s*=.*$", re.M | re.I)
if max_input_vars_re.search(text):
    text = max_input_vars_re.sub("max_input_vars = 10000", text)
else:
    if text and not text.endswith("\n"):
        text += "\n"
    text += "max_input_vars = 10000\n"

if text != original:
    php_ini_path.write_text(text, encoding="utf-8")
    print(1)
else:
    print(0)
PY
}

patch_project_bitrix_php_ini() {
    local project_dir="$1"
    local php_ini="$project_dir/php.ini"
    [ -f "$php_ini" ] || { echo "0"; return 0; }
    require_python3 optional "patch_project_bitrix_php_ini" || { echo "0"; return 0; }

    python3 - "$php_ini" <<'PY'
import pathlib
import re
import sys

php_ini_path = pathlib.Path(sys.argv[1])
text = php_ini_path.read_text(encoding="utf-8", errors="ignore")
original = text

line_re = re.compile(r"^\s*opcache\.revalidate_freq\s*=.*$", re.M)
if line_re.search(text):
    text = line_re.sub("opcache.revalidate_freq=0", text)
else:
    if text and not text.endswith("\n"):
        text += "\n"
    text += "\nopcache.revalidate_freq=0\n"

if text != original:
    php_ini_path.write_text(text, encoding="utf-8")
    print(1)
else:
    print(0)
PY
}

build_project_php_upstream() {
    local host="$1"
    echo "${host//./-}-php"
}

patch_project_nginx_php_upstream() {
    local project_dir="$1"
    local host="$2"
    local nginx_conf="$project_dir/nginx/site.conf"
    [ -f "$nginx_conf" ] || { echo "0"; return 0; }
    require_python3 optional "patch_project_nginx_php_upstream" || { echo "0"; return 0; }

    local upstream=""
    upstream="$(build_project_php_upstream "$host")"

    python3 - "$nginx_conf" "$upstream" <<'PY'
import pathlib
import re
import sys

conf_path = pathlib.Path(sys.argv[1])
upstream = sys.argv[2]

text = conf_path.read_text(encoding="utf-8", errors="ignore")
pattern = re.compile(r"^(\s*fastcgi_pass\s+)([^;]+)(;\s*)$", re.M)
updated = False

def replace(match: re.Match[str]) -> str:
    global updated  # noqa: PLW0603
    prefix, current, suffix = match.groups()
    current_target = current.strip()
    desired_target = f"{upstream}:9000"

    # Preserve unix-socket setups if someone configured them manually.
    if current_target.startswith("unix:"):
        return match.group(0)

    if current_target == desired_target:
        return match.group(0)

    updated = True
    return f"{prefix}{desired_target}{suffix}"

new_text = pattern.sub(replace, text)
if updated:
    conf_path.write_text(new_text, encoding="utf-8")

print(1 if updated else 0)
PY
}

patch_project_dockerfiles_for_xdebug() {
    local project_dir="$1"
    [ -d "$project_dir" ] || { echo "0"; return 0; }
    require_python3 optional "patch_project_dockerfiles_for_xdebug" || { echo "0"; return 0; }

    python3 - "$project_dir" <<'PY'
import pathlib
import re
import sys

project_dir = pathlib.Path(sys.argv[1])
updated = 0

xdebug_block_re = re.compile(
    r"# Установка Xdebug(?:[^\n]*)?\n"
    r"RUN\s+.*?docker-php-ext-enable xdebug(?:\s*\|\|\s*true)?",
    re.S,
)

new_block = (
    "# Установка Xdebug (совместимый вариант для разных версий PHP)\n"
    "RUN set -eux; \\\n"
    "    if ! pecl install xdebug; then \\\n"
    "        case \"${PHP_VERSION}\" in \\\n"
    "            7.4) pecl install xdebug-3.1.6 ;; \\\n"
    "            8.0|8.1) pecl install xdebug-3.3.2 ;; \\\n"
    "            8.2|8.3|8.4) pecl install xdebug-3.4.2 ;; \\\n"
    "            *) pecl install xdebug ;; \\\n"
    "        esac; \\\n"
    "    fi; \\\n"
    "    docker-php-ext-enable xdebug"
)

for dockerfile in sorted(project_dir.glob("Dockerfile.php*")):
    if not dockerfile.is_file():
        continue

    text = dockerfile.read_text(encoding="utf-8", errors="ignore")
    original = text

    if "$PHPIZE_DEPS" not in text:
        text = text.replace(
            "RUN apk add --no-cache \\\n    git \\\n",
            "RUN apk add --no-cache \\\n    $PHPIZE_DEPS \\\n    linux-headers \\\n    git \\\n",
            1,
        )

    if "docker-php-ext-enable xdebug" in text and "совместимый вариант для разных версий PHP" not in text:
        text, _ = xdebug_block_re.subn(new_block, text, count=1)

    if text != original:
        dockerfile.write_text(text, encoding="utf-8")
        updated += 1

print(updated)
PY
}

patch_project_compose_for_tls_router() {
    local project_dir="$1"
    local compose_file="$project_dir/docker-compose.yml"
    [ -f "$compose_file" ] || { echo "0"; return 0; }
    require_python3 optional "patch_project_compose_for_tls_router" || { echo "0"; return 0; }

    python3 - "$compose_file" <<'PY'
import pathlib
import re
import sys

compose_path = pathlib.Path(sys.argv[1])
lines = compose_path.read_text(encoding="utf-8", errors="ignore").splitlines()
updated = False

# Remove obsolete compose schema version for Docker Compose v2 compatibility.
filtered_lines = []
for line in lines:
    if re.match(r'^\s*version:\s*["\']?[0-9.]+["\']?\s*$', line):
        updated = True
        continue
    filtered_lines.append(line)
lines = filtered_lines

tls_re = re.compile(r'^\s*-\s*"traefik\.http\.routers\.([^."]+)\.tls=true"\s*$')
entry_re = re.compile(r'^(\s*-\s*")traefik\.http\.routers\.([^."]+)\.entrypoints=([^"]+)("\s*)$')

routers_with_tls = set()
for line in lines:
    tls_match = tls_re.match(line)
    if tls_match:
        routers_with_tls.add(tls_match.group(1))

inserted_tls = set()
new_lines = []

for line in lines:
    entry_match = entry_re.match(line)
    if not entry_match:
        new_lines.append(line)
        continue

    prefix, router_name, entrypoints, suffix = entry_match.groups()
    normalized_entrypoints = ",".join(
        part.strip() for part in entrypoints.split(",") if part.strip()
    )

    if normalized_entrypoints == "web":
        line = f'{prefix}traefik.http.routers.{router_name}.entrypoints=websecure{suffix}'
        updated = True

    new_lines.append(line)

    if ".entrypoints=websecure" in line and router_name not in routers_with_tls and router_name not in inserted_tls:
        indent = line.split("-", 1)[0]
        new_lines.append(f'{indent}- "traefik.http.routers.{router_name}.tls=true"')
        inserted_tls.add(router_name)
        updated = True

if updated:
    compose_path.write_text("\n".join(new_lines).rstrip() + "\n", encoding="utf-8")

print(1 if updated else 0)
PY
}

patch_project_compose_mysql_innodb_strict_mode() {
    local project_dir="$1"
    local compose_file="$project_dir/docker-compose.yml"
    [ -f "$compose_file" ] || { echo "0"; return 0; }
    require_python3 optional "patch_project_compose_mysql_innodb_strict_mode" || { echo "0"; return 0; }

    python3 - "$compose_file" <<'PY'
import pathlib
import re
import sys

compose_path = pathlib.Path(sys.argv[1])
lines = compose_path.read_text(encoding="utf-8", errors="ignore").splitlines()
updated = False

services_start = None
for idx, line in enumerate(lines):
    if re.match(r'^\s*services:\s*$', line):
        services_start = idx
        break

if services_start is None:
    print(0)
    raise SystemExit(0)

services_end = len(lines)
for idx in range(services_start + 1, len(lines)):
    if re.match(r'^[^\s#][^:]*:\s*$', lines[idx]):
        services_end = idx
        break

service_headers = []
for idx in range(services_start + 1, services_end):
    match = re.match(r'^  ([A-Za-z0-9][A-Za-z0-9_.-]*):\s*$', lines[idx])
    if match:
        service_headers.append((idx, match.group(1)))

if not service_headers:
    print(0)
    raise SystemExit(0)

shift = 0
for i, (header_idx_orig, service_name) in enumerate(service_headers):
    header_idx = header_idx_orig + shift
    if i + 1 < len(service_headers):
        next_header_orig = service_headers[i + 1][0]
        block_end = next_header_orig + shift
    else:
        block_end = services_end + shift

    block = lines[header_idx:block_end]
    image_idx = None
    image_value = ""
    command_idx = None

    for rel_idx, line in enumerate(block):
        image_match = re.match(r'^\s{4}image:\s*(.+?)\s*$', line)
        if image_match:
            image_idx = rel_idx
            image_value = image_match.group(1).strip().strip('"\'').lower()
        command_match = re.match(r'^\s{4}command:\s*(.*?)\s*$', line)
        if command_match:
            command_idx = rel_idx

    is_mysql_service = False
    if 'mysql' in image_value or 'mariadb' in image_value:
        is_mysql_service = True
    elif service_name.lower() == 'mysql':
        is_mysql_service = True

    if not is_mysql_service:
        continue

    if command_idx is not None:
        command_line = lines[header_idx + command_idx]
        command_match = re.match(r'^(\s{4}command:\s*)(.*?)(\s*)$', command_line)
        if not command_match:
            continue

        prefix, command_value, suffix = command_match.groups()
        normalized = command_value.lower()
        if 'innodb_strict_mode' in normalized or 'innodb-strict-mode' in normalized:
            continue

        command_value = command_value.strip()
        if command_value:
            command_value += " --innodb_strict_mode=OFF"
        else:
            command_value = "--innodb_strict_mode=OFF"

        lines[header_idx + command_idx] = f"{prefix}{command_value}{suffix}"
        updated = True
        continue

    insert_at = block_end
    lines.insert(insert_at, "    command: --innodb_strict_mode=OFF")
    updated = True
    shift += 1

if updated:
    compose_path.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")

print(1 if updated else 0)
PY
}

ensure_infra_network() {
    local network_name="infra_proxy"

    if ! command -v docker >/dev/null 2>&1; then
        echo "Error: docker command not found."
        return 1
    fi

    if docker network ls --format '{{.Name}}' | grep -qx "$network_name"; then
        return 0
    fi

    if docker network create "$network_name" >/dev/null 2>&1; then
        echo "   ℹ️  Создана Docker сеть '$network_name'."
        return 0
    fi

    echo "Error: failed to create docker network '$network_name'."
    return 1
}

ensure_infra_ssl() {
    if [ ! -f "$GENERATE_SSL_SCRIPT" ]; then
        if [ -f "$INFRA_DIR/ssl/traefik-cert.pem" ] && [ -f "$INFRA_DIR/ssl/traefik-key.pem" ]; then
            return 0
        fi
        echo "Error: SSL helper script not found: $GENERATE_SSL_SCRIPT"
        return 1
    fi

    if ! bash "$GENERATE_SSL_SCRIPT" --skip-trust >/dev/null; then
        echo "Error: failed to prepare SSL certificates for Traefik."
        return 1
    fi
}

refresh_infra_tls_material() {
    if [ ! -f "$GENERATE_SSL_SCRIPT" ]; then
        return 0
    fi

    # Non-fatal refresh: host operation already succeeded, TLS refresh is best-effort.
    if ! bash "$GENERATE_SSL_SCRIPT" --skip-trust >/dev/null 2>&1; then
        echo "Warning: failed to refresh SSL certificates after host registry change."
        return 0
    fi

    # В fallback-режиме Traefik использует volume, а не bind-mount — нужно обновить сертификаты в volume.
    if [ "$(get_infra_runtime_mode)" = "fallback" ]; then
        if ! prepare_fallback_tls_assets; then
            echo "Warning: failed to update fallback TLS volume after SSL refresh."
        fi
    fi

    if docker ps --format '{{.Names}}' | awk '$1 == "traefik" {found=1} END {exit !found}'; then
        docker restart traefik >/dev/null 2>&1 || echo "Warning: failed to restart traefik after SSL refresh."
    fi
}

ensure_registry() {
    mkdir -p "$PROJECTS_DIR"
    ensure_state_dir
    migrate_legacy_state_layout
    cleanup_state_appledouble_files
    touch "$REGISTRY_FILE"
    touch "$BITRIX_CORE_REGISTRY_FILE"
    touch "$BITRIX_BINDINGS_FILE"
    touch "$HOSTCTL_LOG_FILE" >/dev/null 2>&1 || true
}

normalize_preset_for_create() {
    local raw="$1"
    local lower
    lower="$(to_lower "$raw")"

    case "$lower" in
        empty|php)
            echo "empty"
            ;;
        bitrix|1c-bitrix|1c_bitrix)
            echo "bitrix"
            ;;
        *)
            return 1
            ;;
    esac
}

display_preset() {
    local mapped="$1"
    case "$mapped" in
        php) echo "empty" ;;
        *) echo "$mapped" ;;
    esac
}

registry_has_host() {
    local host="$1"
    local normalized_host=""
    local domain_suffix=""
    local canonical_host=""
    [ -f "$REGISTRY_FILE" ] || return 1

    normalized_host="$(normalize_token "$host")"

    if is_valid_host_label "$normalized_host"; then
        if domain_suffix="$(resolve_domain_suffix 2>/dev/null)"; then
            canonical_host="${normalized_host}.${domain_suffix}"
            if awk -F'\t' -v host="$canonical_host" '$1 == host {found=1} END {exit !found}' "$REGISTRY_FILE"; then
                return 0
            fi
        fi
    fi

    awk -F'\t' -v host="$normalized_host" '$1 == host {found=1} END {exit !found}' "$REGISTRY_FILE"
}

registry_remove_host() {
    local host="$1"
    local normalized_host=""
    local domain_suffix=""
    local canonical_host=""
    [ -f "$REGISTRY_FILE" ] || return 0

    normalized_host="$(normalize_token "$host")"
    canonical_host="$normalized_host"
    if is_valid_host_label "$normalized_host"; then
        if domain_suffix="$(resolve_domain_suffix 2>/dev/null)"; then
            canonical_host="${normalized_host}.${domain_suffix}"
        fi
    fi

    awk -F'\t' -v host="$normalized_host" -v canonical="$canonical_host" '$1 != host && $1 != canonical' "$REGISTRY_FILE" > "${REGISTRY_FILE}.tmp"
    mv "${REGISTRY_FILE}.tmp" "$REGISTRY_FILE"
}

registry_upsert_host() {
    local host="$1"
    local preset="$2"
    local php_version="$3"
    local db_type="$4"
    local created_at="$5"
    local bitrix_type="${6:--}"
    local core_id="${7:--}"
    local normalized_host=""
    local domain_suffix=""

    normalized_host="$(normalize_token "$host")"
    if is_valid_host_label "$normalized_host"; then
        if domain_suffix="$(resolve_domain_suffix 2>/dev/null)"; then
            normalized_host="${normalized_host}.${domain_suffix}"
        fi
    fi

    registry_remove_host "$normalized_host"
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
        "$normalized_host" \
        "$preset" \
        "$php_version" \
        "$db_type" \
        "$created_at" \
        "$bitrix_type" \
        "$core_id" >> "$REGISTRY_FILE"
}

registry_get_field() {
    local host="$1"
    local field="$2"
    local normalized_host=""
    local domain_suffix=""
    local canonical_host=""
    [ -f "$REGISTRY_FILE" ] || { echo ""; return 0; }

    normalized_host="$(normalize_token "$host")"
    canonical_host="$normalized_host"
    if is_valid_host_label "$normalized_host"; then
        if domain_suffix="$(resolve_domain_suffix 2>/dev/null)"; then
            canonical_host="${normalized_host}.${domain_suffix}"
        fi
    fi

    awk -F'\t' -v host="$normalized_host" -v canonical="$canonical_host" -v field="$field" '
        $1 == canonical {print $field; found=1; exit}
        $1 == host {fallback=$field; seen_fallback=1}
        END {
            if (!found && seen_fallback) {
                print fallback
            } else if (!found) {
                print ""
            }
        }
    ' "$REGISTRY_FILE"
}

acquire_bindings_lock() {
    local timeout_seconds="${1:-30}"
    local start_ts
    start_ts="$(date +%s)"

    while true; do
        if mkdir "$BITRIX_BINDINGS_LOCK_DIR" 2>/dev/null; then
            printf "pid=%s\nacquired_at=%s\n" "$$" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" > "$BITRIX_BINDINGS_LOCK_DIR/owner" 2>/dev/null || true
            return 0
        fi

        if [ -d "$BITRIX_BINDINGS_LOCK_DIR" ] && [ -f "$BITRIX_BINDINGS_LOCK_DIR/owner" ]; then
            local lock_pid=""
            lock_pid="$(awk -F'=' '/^pid=/{print $2; exit}' "$BITRIX_BINDINGS_LOCK_DIR/owner" 2>/dev/null || true)"
            if [ -n "$lock_pid" ] && ! kill -0 "$lock_pid" >/dev/null 2>&1; then
                rm -rf "$BITRIX_BINDINGS_LOCK_DIR" >/dev/null 2>&1 || true
                continue
            fi
        fi

        if [ $(( $(date +%s) - start_ts )) -ge "$timeout_seconds" ]; then
            fail_with_code "lock_conflict" "Не удалось получить lock реестра связей в течение ${timeout_seconds}с."
            return 1
        fi
        sleep 0.1
    done
}

release_bindings_lock() {
    [ -d "$BITRIX_BINDINGS_LOCK_DIR" ] || return 0
    rm -rf "$BITRIX_BINDINGS_LOCK_DIR" >/dev/null 2>&1 || true
}

core_registry_has_id() {
    local core_id="$1"
    awk -F'\t' -v core_id="$core_id" '$1 == core_id {found=1} END {exit !found}' "$BITRIX_CORE_REGISTRY_FILE"
}

core_registry_get_field() {
    local core_id="$1"
    local field="$2"
    awk -F'\t' -v core_id="$core_id" -v field="$field" '$1 == core_id {print $field; found=1; exit} END {if (!found) print ""}' "$BITRIX_CORE_REGISTRY_FILE"
}

core_registry_get_by_owner_host() {
    local owner_host="$1"
    awk -F'\t' -v owner="$owner_host" '$2 == owner {print $1 "|" $3; found=1; exit} END {if (!found) print ""}' "$BITRIX_CORE_REGISTRY_FILE"
}

core_registry_remove_by_owner_host() {
    local owner_host="$1"
    awk -F'\t' -v owner="$owner_host" '$2 != owner' "$BITRIX_CORE_REGISTRY_FILE" > "${BITRIX_CORE_REGISTRY_FILE}.tmp"
    mv "${BITRIX_CORE_REGISTRY_FILE}.tmp" "$BITRIX_CORE_REGISTRY_FILE"
}

core_registry_remove_core_id() {
    local core_id="$1"
    awk -F'\t' -v core_id="$core_id" '$1 != core_id' "$BITRIX_CORE_REGISTRY_FILE" > "${BITRIX_CORE_REGISTRY_FILE}.tmp"
    mv "${BITRIX_CORE_REGISTRY_FILE}.tmp" "$BITRIX_CORE_REGISTRY_FILE"
}

core_registry_upsert() {
    local core_id="$1"
    local owner_host="$2"
    local core_type="$3"
    local created_at="$4"

    core_registry_remove_core_id "$core_id"
    printf "%s\t%s\t%s\t%s\n" "$core_id" "$owner_host" "$core_type" "$created_at" >> "$BITRIX_CORE_REGISTRY_FILE"
}

bindings_registry_get_core_id_for_host() {
    local host="$1"
    awk -F'\t' -v host="$host" '$1 == host {print $2; found=1; exit} END {if (!found) print ""}' "$BITRIX_BINDINGS_FILE"
}

bindings_registry_count_for_core_id() {
    local core_id="$1"
    awk -F'\t' -v core_id="$core_id" '$2 == core_id {count+=1} END {print count+0}' "$BITRIX_BINDINGS_FILE"
}

bindings_registry_list_hosts_for_core_id() {
    local core_id="$1"
    awk -F'\t' -v core_id="$core_id" '$2 == core_id {print $1}' "$BITRIX_BINDINGS_FILE"
}

bindings_registry_remove_host() {
    local host="$1"
    awk -F'\t' -v host="$host" '$1 != host' "$BITRIX_BINDINGS_FILE" > "${BITRIX_BINDINGS_FILE}.tmp"
    mv "${BITRIX_BINDINGS_FILE}.tmp" "$BITRIX_BINDINGS_FILE"
}

bindings_registry_upsert() {
    local host="$1"
    local core_id="$2"
    local created_at="$3"
    bindings_registry_remove_host "$host"
    printf "%s\t%s\t%s\n" "$host" "$core_id" "$created_at" >> "$BITRIX_BINDINGS_FILE"
}

resolve_bitrix_profile_for_host() {
    local host="$1"
    local preset="$2"
    local bitrix_type="$3"
    local core_id="$4"
    local linked_core=""
    local owned_core=""

    if [ -z "$bitrix_type" ] || [ "$bitrix_type" = "-" ]; then
        linked_core="$(bindings_registry_get_core_id_for_host "$host")"
        if [ -n "$linked_core" ]; then
            bitrix_type="link"
            core_id="$linked_core"
        else
            owned_core="$(core_registry_get_by_owner_host "$host")"
            if [ -n "$owned_core" ]; then
                core_id="${owned_core%%|*}"
                bitrix_type="${owned_core##*|}"
            elif [ "$preset" = "bitrix" ]; then
                bitrix_type="kernel"
            fi
        fi
    fi

    if [ -z "$bitrix_type" ] || [ "$bitrix_type" = "-" ]; then
        echo "-|-"
        return 0
    fi

    [ -n "$core_id" ] || core_id="-"
    echo "${bitrix_type}|${core_id}"
}

cleanup_failed_host_create() {
    local host="$1"
    local project_dir="$2"

    if [ -d "$project_dir" ]; then
        runtime_host_down "$project_dir" >/dev/null 2>&1 || true
        rm -rf "$project_dir" >/dev/null 2>&1 || true
    fi

    registry_remove_host "$host"
    bindings_registry_remove_host "$host"
    core_registry_remove_by_owner_host "$host"
}

contains_host() {
    local needle="$1"
    shift
    local value
    for value in "$@"; do
        if [ "$value" = "$needle" ]; then
            return 0
        fi
    done
    return 1
}

# Show progress indicator for long operations
show_progress() {
    local message="$1"
    local pid="$2"
    local spinner_chars="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
    local i=0

    # Hide cursor
    printf "\033[?25l" >&2

    while kill -0 "$pid" 2>/dev/null; do
        local char="${spinner_chars:$((i % ${#spinner_chars})):1}"
        printf "\r%s %s" "$char" "$message" >&2
        i=$((i + 1))
        sleep 0.15
    done

    # Show cursor and clear line
    printf "\r\033[K" >&2
    printf "\033[?25h" >&2
}

# Runtime adapter for host and infra docker compose operations.
# Return code contract:
#   0   operation succeeded
#   1+  docker/compose invocation failed
runtime_host_compose() {
    local project_dir="$1"
    shift

    # В контейнере devpanel /projects не является host-shared путём для Docker Desktop.
    # Поэтому:
    # 1) все относительные bind-пути резолвим через --project-directory в host-путь;
    # 2) build context оставляем контейнерным (/projects/<host>), иначе docker compose
    #    не сможет прочитать контекст при наличии пробелов в host-пути.
    if [ "$PROJECTS_DIR" = "/projects" ]; then
        local compose_file="$project_dir/docker-compose.yml"
        if [ -f "$compose_file" ]; then
            local host_projects_dir=""
            host_projects_dir="$(resolve_host_projects_dir)"
            if [ -n "$host_projects_dir" ] && [ "$host_projects_dir" != "/projects" ]; then
                local host_project_dir="$host_projects_dir/$(basename "$project_dir")"
                local host_root_dir
                host_root_dir="$(dirname "$host_projects_dir")"
                local host_logs_dir="$host_root_dir/logs"
                local tmp_compose="$project_dir/docker-compose.yml.tmp.runtime.$$"

                awk \
                    -v container_project_dir="$project_dir" \
                    -v host_project_dir="$host_project_dir" \
                    -v host_logs_dir="$host_logs_dir" '
                    {
                        # build context всегда контейнерный путь (читается docker compose CLI внутри devpanel)
                        if ($0 ~ /^[[:space:]]*context:[[:space:]]*\.[[:space:]]*$/ ||
                            $0 ~ /^[[:space:]]*context:[[:space:]]*\/projects\/[^[:space:]]+[[:space:]]*$/ ||
                            $0 ~ /^[[:space:]]*context:[[:space:]]*"\/projects\/[^"]+"[[:space:]]*$/ ||
                            $0 ~ /^[[:space:]]*context:[[:space:]]*\/Volumes\/[^[:space:]]+[[:space:]]*$/ ||
                            $0 ~ /^[[:space:]]*context:[[:space:]]*"\/Volumes\/[^"]+"[[:space:]]*$/) {
                            print "      context: \"" container_project_dir "\""
                            next
                        }

                        # db volume device должен быть host-путём, не ${PWD} контейнера.
                        if ($0 ~ /^[[:space:]]*device:[[:space:]]*\$\{PWD\}\/db-mysql[[:space:]]*$/) {
                            print "      device: \"" host_project_dir "/db-mysql\""
                            next
                        }
                        if ($0 ~ /^[[:space:]]*device:[[:space:]]*\$\{PWD\}\/db-postgres[[:space:]]*$/) {
                            print "      device: \"" host_project_dir "/db-postgres\""
                            next
                        }

                        # Поддержка файлов, где остались контейнерные абсолютные пути от старых запусков.
                        gsub(/\/projects\/[^"[:space:]]+\/www/, host_project_dir "/www")
                        gsub(/\/projects\/[^"[:space:]]+\/src/, host_project_dir "/src")
                        gsub(/\/projects\/[^"[:space:]]+\/nginx\/site\.conf/, host_project_dir "/nginx/site.conf")
                        gsub(/\/projects\/[^"[:space:]]+\/logs\/php/, host_project_dir "/logs/php")
                        gsub(/\/projects\/[^"[:space:]]+\/logs\/nginx/, host_project_dir "/logs/nginx")

                        print
                    }
                ' "$compose_file" > "$tmp_compose"

                COPYFILE_DISABLE=1 docker compose \
                    -f "$tmp_compose" \
                    --project-directory "$host_project_dir" \
                    "$@"
                local compose_exit=$?
                rm -f "$tmp_compose" 2>/dev/null || true
                return $compose_exit
            fi
        fi
    fi

    (cd "$project_dir" && COPYFILE_DISABLE=1 docker compose "$@")
}

runtime_host_up() {
    local project_dir="$1"
    local host_name="${2:-}"
    
    # Show informative message
    if [ -n "$host_name" ]; then
        echo "🚀 Запуск контейнеров для хоста '$host_name'..."
    else
        echo "🚀 Запуск контейнеров..."
    fi
    echo "   ⏳ Первый запуск может занять несколько минут (загрузка/сборка образов Docker)..."
    
    # Run docker compose - show output but filter verbose messages
    if runtime_host_compose "$project_dir" up -d --yes; then
        echo "   ✅ Контейнеры успешно запущены"
        return 0
    else
        local exit_code=$?
        echo "   ❌ Ошибка при запуске контейнеров"
        return $exit_code
    fi
}

runtime_host_stop() {
    local project_dir="$1"
    runtime_host_compose "$project_dir" stop
}

runtime_host_down() {
    local project_dir="$1"
    runtime_host_compose "$project_dir" down --remove-orphans
}

runtime_host_ps_states() {
    local project_dir="$1"
    runtime_host_compose "$project_dir" ps --all --format '{{.State}}'
}

runtime_host_ps_rows() {
    local project_dir="$1"
    runtime_host_compose "$project_dir" ps --all --format '{{.Service}}|{{.Name}}|{{.State}}'
}

runtime_host_services() {
    local project_dir="$1"
    runtime_host_compose "$project_dir" config --services
}

runtime_infra_compose_with_file() {
    local compose_file="$1"
    shift || true

    [ -f "$compose_file" ] || {
        echo "Error: infra compose file not found: $compose_file" >&2
        return 1
    }

    local compose_args=("-f" "$compose_file")
    if [ -f "$INFRA_ENV_FILE" ]; then
        (cd "$INFRA_DIR" && COPYFILE_DISABLE=1 COMPOSE_IGNORE_ORPHANS=1 docker compose "${compose_args[@]}" --env-file "$INFRA_ENV_FILE" "$@")
    else
        (cd "$INFRA_DIR" && COPYFILE_DISABLE=1 COMPOSE_IGNORE_ORPHANS=1 docker compose "${compose_args[@]}" "$@")
    fi
}

runtime_infra_compose() {
    runtime_infra_compose_with_file "$INFRA_COMPOSE_FILE" "$@"
}

runtime_infra_compose_fallback() {
    runtime_infra_compose_with_file "$INFRA_DEVPANEL_FALLBACK_COMPOSE_FILE" "$@"
}

prepare_infra_build_context() {
    local removed_total=0
    local removed=0
    local target="$DEV_DIR"

    if [ -d "$target" ]; then
        removed="$(remove_appledouble_files "$target")"
        case "${removed:-0}" in
            ''|*[!0-9]*)
                removed=0
                ;;
        esac
        removed_total=$((removed_total + removed))
        clear_project_xattrs "$target"
    fi

    if [ "$removed_total" -gt 0 ]; then
        echo "   ℹ️  Удалено $removed_total файл(ов) метаданных macOS (._*) из infra build context."
    fi
}

prepare_fallback_tls_assets() {
    local cert_src="$INFRA_DIR/ssl/traefik-cert.pem"
    local key_src="$INFRA_DIR/ssl/traefik-key.pem"
    local dynamic_tmp=""
    local helper_container=""
    local copy_failed=0

    if [ ! -f "$cert_src" ] || [ ! -f "$key_src" ]; then
        echo "Error: fallback TLS assets are missing ($cert_src, $key_src)." >&2
        return 1
    fi

    dynamic_tmp="$(mktemp "${TMPDIR:-/tmp}/traefik-fallback-dynamic.XXXXXX.yml")"
    cat > "$dynamic_tmp" <<'EOF'
tls:
  stores:
    default:
      defaultCertificate:
        certFile: /tls/traefik-cert.pem
        keyFile: /tls/traefik-key.pem

  options:
    default:
      minVersion: "VersionTLS12"
      maxVersion: "VersionTLS13"
EOF

    docker volume create "$INFRA_DEVPANEL_FALLBACK_TLS_VOLUME" >/dev/null 2>&1 || true
    helper_container="$(docker create -v "$INFRA_DEVPANEL_FALLBACK_TLS_VOLUME:/tls" traefik:v2.11 sh -c 'sleep 300' 2>/dev/null || true)"
    if [ -z "$helper_container" ]; then
        rm -f "$dynamic_tmp" >/dev/null 2>&1 || true
        echo "Error: failed to create helper container for fallback TLS volume." >&2
        return 1
    fi

    docker cp "$cert_src" "$helper_container:/tls/traefik-cert.pem" >/dev/null 2>&1 || copy_failed=1
    docker cp "$key_src" "$helper_container:/tls/traefik-key.pem" >/dev/null 2>&1 || copy_failed=1
    docker cp "$dynamic_tmp" "$helper_container:/tls/dynamic.yml" >/dev/null 2>&1 || copy_failed=1

    docker rm -f "$helper_container" >/dev/null 2>&1 || true
    rm -f "$dynamic_tmp" >/dev/null 2>&1 || true

    if [ "$copy_failed" -ne 0 ]; then
        echo "Error: failed to copy TLS assets into fallback volume '$INFRA_DEVPANEL_FALLBACK_TLS_VOLUME'." >&2
        return 1
    fi

    return 0
}

infra_mount_bind_failure_detected() {
    local output="$1"
    if [[ "$output" == *"error while creating mount source path"* ]]; then
        return 0
    fi
    if [[ "$output" == *"failed to populate volume"* ]] || [[ "$output" == *"not a directory"* ]]; then
        return 0
    fi
    if [[ "$output" == *"AH00036: access to /index.php failed"* ]] || [[ "$output" == *"AH00036: access to / failed"* ]]; then
        return 0
    fi
    return 1
}

runtime_infra_up() {
    local domain_suffix=""
    local docker_domain="docker.loc"

    if domain_suffix="$(resolve_domain_suffix 2>/dev/null)"; then
        docker_domain="docker.$domain_suffix"
    fi

    echo "🚀 Запуск инфраструктурных контейнеров..."
    echo "   ⏳ Первый запуск может занять несколько минут (загрузка образов Docker)..."
    prepare_infra_build_context

    local output=""
    if output="$(runtime_infra_compose up -d --yes --build 2>&1)"; then
        [ -n "$output" ] && printf "%s\n" "$output"
        docker rm -f devpanel-fallback >/dev/null 2>&1 || true
        set_infra_runtime_mode "primary"
        echo "   ✅ Инфраструктурные контейнеры успешно запущены"
        return 0
    fi

    local exit_code=$?
    [ -n "$output" ] && printf "%s\n" "$output"

    # Авто-fallback для окружений на внешнем диске:
    # если Docker Desktop не может создать bind-mount пути,
    # запускаем полный fallback-стек без bind-монтов исходников/config.
    if [ -f "$INFRA_DEVPANEL_FALLBACK_COMPOSE_FILE" ] && infra_mount_bind_failure_detected "$output"; then
        if ! infra_fallback_enabled; then
            echo "   ⚠️  Обнаружена ошибка bind-mount, но fallback отключен (INFRA_FALLBACK_ENABLED=0)."
            echo "   💡 Либо исправьте bind-mount/shared paths, либо включите fallback через INFRA_FALLBACK_ENABLED=1."
            return $exit_code
        fi

        echo "   ⚠️  Обнаружена ошибка bind-mount. Пробуем fallback-режим инфраструктуры..."
        echo "      (полный стек без bind-монтов: traefik/adminer/redis/loki/promtail/grafana/devpanel)"

        if ! prepare_fallback_tls_assets; then
            echo "   ❌ Не удалось подготовить TLS-сертификаты для fallback-режима."
            return 1
        fi

        local fallback_output=""
        if fallback_output="$(runtime_infra_compose_fallback up -d --yes --build 2>&1)"; then
            [ -n "$fallback_output" ] && printf "%s\n" "$fallback_output"
            docker rm -f devpanel >/dev/null 2>&1 || true
            set_infra_runtime_mode "fallback"
            echo "   ✅ Запущен fallback-режим инфраструктуры (все сервисы активированы)"
            echo "   ℹ️  DevPanel доступен через https://$docker_domain и резервно через http://localhost:8088"
            return 0
        fi

        [ -n "$fallback_output" ] && printf "%s\n" "$fallback_output"
        echo "   ❌ Fallback-режим инфраструктуры также завершился с ошибкой"
        return 1
    fi

    echo "   ❌ Ошибка при запуске инфраструктурных контейнеров"
    return $exit_code
}

runtime_infra_stop() {
    local mode=""
    mode="$(get_infra_runtime_mode)"

    if [ "$mode" = "fallback" ]; then
        if runtime_infra_compose_fallback down --remove-orphans; then
            docker rm -f devpanel >/dev/null 2>&1 || true
            clear_infra_runtime_mode
            return 0
        fi
        return 1
    fi

    if runtime_infra_compose down --remove-orphans; then
        docker rm -f devpanel-fallback >/dev/null 2>&1 || true
        clear_infra_runtime_mode
        return 0
    fi

    if runtime_infra_compose_fallback down --remove-orphans >/dev/null 2>&1; then
        docker rm -f devpanel >/dev/null 2>&1 || true
        clear_infra_runtime_mode
        return 0
    fi

    return 1
}

runtime_infra_ps_rows() {
    local mode=""
    mode="$(get_infra_runtime_mode)"
    if [ "$mode" = "fallback" ]; then
        runtime_infra_compose_fallback ps --all --format '{{.Service}}|{{.Name}}|{{.State}}'
    else
        runtime_infra_compose ps --all --format '{{.Service}}|{{.Name}}|{{.State}}'
    fi
}

runtime_infra_services() {
    local mode=""
    mode="$(get_infra_runtime_mode)"
    if [ "$mode" = "fallback" ]; then
        runtime_infra_compose_fallback config --services
    else
        runtime_infra_compose config --services
    fi
}

print_infra_compose_command_hint() {
    local subcommand="$1"
    local compose_file="$INFRA_COMPOSE_FILE"
    if [ "$(get_infra_runtime_mode)" = "fallback" ] && [ -f "$INFRA_DEVPANEL_FALLBACK_COMPOSE_FILE" ]; then
        compose_file="$INFRA_DEVPANEL_FALLBACK_COMPOSE_FILE"
    fi

    if [ -f "$INFRA_ENV_FILE" ]; then
        echo "  cd \"$INFRA_DIR\" && COPYFILE_DISABLE=1 docker compose -f \"$compose_file\" --env-file \"$INFRA_ENV_FILE\" $subcommand"
    else
        echo "  cd \"$INFRA_DIR\" && COPYFILE_DISABLE=1 docker compose -f \"$compose_file\" $subcommand"
    fi
}

ensure_infra_env_file_notice() {
    if [ ! -f "$INFRA_ENV_FILE" ]; then
        echo "Warning: infra env file not found: $INFRA_ENV_FILE"
        echo "Hint: create it with:"
        echo "  cd \"$INFRA_DIR\" && cp .env.global.example .env.global"
        echo "Hint: proceeding with compose defaults."
    fi
}

host_status_summary() {
    local host="$1"
    local project_dir="$PROJECTS_DIR/$host"
    local compose_file="$project_dir/docker-compose.yml"

    if [ ! -f "$compose_file" ]; then
        echo "error|0"
        return 0
    fi

    local states
    if ! states="$(runtime_host_ps_states "$project_dir" 2>/dev/null)"; then
        echo "error|0"
        return 0
    fi

    if [ -z "$states" ]; then
        echo "stopped|0"
        return 0
    fi

    local running=0
    local stopped=0
    local errored=0
    local total=0
    local state

    while IFS= read -r state; do
        [ -n "$state" ] || continue
        total=$((total + 1))
        state="$(normalize_container_state "$state")"

        case "$state" in
            running) running=$((running + 1)) ;;
            stopped) stopped=$((stopped + 1)) ;;
            *) errored=$((errored + 1)) ;;
        esac
    done <<EOF
$states
EOF

    local status="error"
    if [ "$total" -eq 0 ]; then
        status="stopped"
    elif [ "$errored" -gt 0 ]; then
        status="error"
    elif [ "$running" -gt 0 ] && [ "$stopped" -eq 0 ]; then
        status="running"
    elif [ "$running" -eq 0 ] && [ "$stopped" -gt 0 ]; then
        status="stopped"
    else
        status="error"
    fi

    echo "${status}|${total}"
}

print_host_app_rows() {
    local host="$1"
    local project_dir="$PROJECTS_DIR/$host"
    local compose_file="$project_dir/docker-compose.yml"
    local rows
    local services
    local service
    local container
    local state

    if [ ! -f "$compose_file" ]; then
        printf "%-10s %-32s %-20s %-36s %-10s\n" "host" "$host" "-" "-" "error"
        return 0
    fi

    if ! rows="$(runtime_host_ps_rows "$project_dir" 2>/dev/null)"; then
        printf "%-10s %-32s %-20s %-36s %-10s\n" "host" "$host" "docker-compose" "-" "error"
        return 0
    fi

    if [ -z "$rows" ]; then
        if services="$(runtime_host_services "$project_dir" 2>/dev/null)" && [ -n "$services" ]; then
            while IFS= read -r service; do
                [ -n "${service:-}" ] || continue
                printf "%-10s %-32s %-20s %-36s %-10s\n" "host" "$host" "$service" "-" "stopped"
            done <<EOF
$services
EOF
            return 0
        fi

        printf "%-10s %-32s %-20s %-36s %-10s\n" "host" "$host" "-" "-" "stopped"
        return 0
    fi

    while IFS='|' read -r service container state; do
        [ -n "${service:-}" ] || continue
        printf "%-10s %-32s %-20s %-36s %-10s\n" \
            "host" \
            "$host" \
            "${service:-unknown}" \
            "${container:-unknown}" \
            "$(normalize_container_state "${state:-}")"
    done <<EOF
$rows
EOF
}

print_infra_app_rows() {
    local rows
    local services
    local service
    local container
    local state

    [ -f "$INFRA_COMPOSE_FILE" ] || return 0

    if ! rows="$(runtime_infra_ps_rows 2>/dev/null)"; then
        printf "%-10s %-32s %-20s %-36s %-10s\n" "infra" "infra-shared" "docker-compose" "-" "error"
        return 0
    fi

    if [ -z "$rows" ]; then
        if services="$(runtime_infra_services 2>/dev/null)" && [ -n "$services" ]; then
            while IFS= read -r service; do
                [ -n "${service:-}" ] || continue
                printf "%-10s %-32s %-20s %-36s %-10s\n" "infra" "infra-shared" "$service" "-" "stopped"
            done <<EOF
$services
EOF
            return 0
        fi

        return 0
    fi

    while IFS='|' read -r service container state; do
        [ -n "${service:-}" ] || continue
        printf "%-10s %-32s %-20s %-36s %-10s\n" \
            "infra" \
            "infra-shared" \
            "${service:-unknown}" \
            "${container:-unknown}" \
            "$(normalize_container_state "${state:-}")"
    done <<EOF
$rows
EOF
}

create_host() {
    local host_input="$1"
    local host="$host_input"
    local domain_suffix=""
    shift

    if ! domain_suffix="$(resolve_domain_suffix)"; then
        exit 1
    fi

    if ! host="$(canonicalize_host_name "$host_input" "$domain_suffix" "create")"; then
        exit 1
    fi

    local php_version="8.2"
    local db_type="mysql"
    local preset="empty"
    local no_start=0
    local hosts_mode="${HOSTCTL_HOSTS_MODE:-auto}"
    local interactive_mode="auto"
    local explicit_config_flags=0
    local timezone="Europe/Moscow"
    local db_name="${host//./_}"
    local db_user=""
    local db_password=""
    local db_root_password=""
    local db_external_port=""
    local bitrix_type_raw=""
    local bitrix_type="-"
    local core_ref=""
    local core_id=""
    local lock_acquired=0
    local project_dir="$PROJECTS_DIR/$host"
    local is_bitrix=0
    local core_owner_host=""
    log_event "INFO" "create_host_begin host=$host input=$host_input domain_suffix=$domain_suffix"

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --php)
                [ "$#" -ge 2 ] || { echo "Missing value for --php"; exit 1; }
                php_version="$2"
                explicit_config_flags=1
                shift 2
                ;;
            --db)
                [ "$#" -ge 2 ] || { echo "Missing value for --db"; exit 1; }
                db_type="$2"
                explicit_config_flags=1
                shift 2
                ;;
            --preset)
                [ "$#" -ge 2 ] || { echo "Missing value for --preset"; exit 1; }
                preset="$2"
                explicit_config_flags=1
                shift 2
                ;;
            --bitrix-type)
                [ "$#" -ge 2 ] || { echo "Missing value for --bitrix-type"; exit 1; }
                bitrix_type_raw="$2"
                explicit_config_flags=1
                shift 2
                ;;
            --core)
                [ "$#" -ge 2 ] || { echo "Missing value for --core"; exit 1; }
                core_ref="$2"
                explicit_config_flags=1
                shift 2
                ;;
            --core-id)
                [ "$#" -ge 2 ] || { echo "Missing value for --core-id"; exit 1; }
                core_id="$2"
                explicit_config_flags=1
                shift 2
                ;;
            --tz)
                [ "$#" -ge 2 ] || { echo "Missing value for --tz"; exit 1; }
                timezone="$2"
                explicit_config_flags=1
                shift 2
                ;;
            --db-name)
                [ "$#" -ge 2 ] || { echo "Missing value for --db-name"; exit 1; }
                db_name="$2"
                explicit_config_flags=1
                shift 2
                ;;
            --db-user)
                [ "$#" -ge 2 ] || { echo "Missing value for --db-user"; exit 1; }
                db_user="$2"
                explicit_config_flags=1
                shift 2
                ;;
            --db-password)
                [ "$#" -ge 2 ] || { echo "Missing value for --db-password"; exit 1; }
                db_password="$2"
                explicit_config_flags=1
                shift 2
                ;;
            --db-root-password)
                [ "$#" -ge 2 ] || { echo "Missing value for --db-root-password"; exit 1; }
                db_root_password="$2"
                explicit_config_flags=1
                shift 2
                ;;
            --db-port)
                [ "$#" -ge 2 ] || { echo "Missing value for --db-port"; exit 1; }
                db_external_port="$2"
                explicit_config_flags=1
                shift 2
                ;;
            --hosts-mode|--hosts)
                [ "$#" -ge 2 ] || { echo "Missing value for --hosts-mode"; exit 1; }
                hosts_mode="$2"
                explicit_config_flags=1
                shift 2
                ;;
            --interactive)
                interactive_mode="yes"
                shift
                ;;
            --no-interactive)
                interactive_mode="no"
                shift
                ;;
            --no-start)
                no_start=1
                shift
                ;;
            *)
                echo "Unknown option for create: $1"
                print_help_hint
                usage
                exit 1
                ;;
        esac
    done

    db_type="$(to_lower "$db_type")"
    preset="$(to_lower "$preset")"
    hosts_mode="$(to_lower "$hosts_mode")"

    case "$hosts_mode" in
        auto|skip)
            ;;
        *)
            echo "Error: unsupported hosts mode '$hosts_mode'. Supported: auto, skip."
            echo "Hint: use '--hosts-mode skip' to avoid any /etc/hosts changes."
            exit 1
            ;;
    esac

    case "$db_type" in
        mysql|postgres)
            ;;
        *)
            echo "Error: unsupported db type '$db_type'. Supported: mysql, postgres."
            echo "Hint: use '--db mysql' or '--db postgres'."
            exit 1
            ;;
    esac

    if [ -z "$db_user" ]; then
        db_user="user"
        [ "$db_type" = "postgres" ] && db_user="postgres"
    fi
    if [ -z "$db_password" ]; then
        db_password="password"
        [ "$db_type" = "postgres" ] && db_password="postgres"
    fi
    if [ "$db_type" = "mysql" ] && [ -z "$db_root_password" ]; then
        db_root_password="root"
    fi
    if [ -z "$db_external_port" ]; then
        db_external_port="3306"
        [ "$db_type" = "postgres" ] && db_external_port="5432"
    fi

    if [ "$interactive_mode" = "auto" ]; then
        if [ "$explicit_config_flags" -eq 0 ] && [ -t 0 ] && [ -t 1 ]; then
            interactive_mode="yes"
        else
            interactive_mode="no"
        fi
    fi

    if [ "$interactive_mode" = "yes" ]; then
        echo "Interactive create wizard for '$host'"
        php_version="$(prompt_with_default "PHP version" "$php_version")"
        db_type="$(prompt_choice_with_default "DB type (mysql/postgres)" "$db_type" "mysql" "postgres")"
        preset="$(prompt_choice_with_default "Preset (empty/bitrix)" "$preset" "empty" "bitrix")"
        timezone="$(prompt_with_default "Timezone (TZ)" "$timezone")"
        db_name="$(prompt_with_default "Database name" "$db_name")"

        if [ "$db_type" = "mysql" ]; then
            local mysql_root_default="${db_root_password:-root}"
            local mysql_user_default="$db_user"
            local mysql_password_default="$db_password"
            local mysql_port_default="$db_external_port"
            [ -z "$mysql_user_default" ] && mysql_user_default="user"
            [ "$mysql_user_default" = "postgres" ] && mysql_user_default="user"
            [ -z "$mysql_password_default" ] && mysql_password_default="password"
            [ "$mysql_password_default" = "postgres" ] && mysql_password_default="password"
            [ -z "$mysql_port_default" ] && mysql_port_default="3306"
            [ "$mysql_port_default" = "5432" ] && mysql_port_default="3306"

            db_root_password="$(prompt_with_default "MySQL root password" "$mysql_root_default")"
            db_user="$(prompt_with_default "MySQL user" "$mysql_user_default")"
            db_password="$(prompt_with_default "MySQL user password" "$mysql_password_default")"
            db_external_port="$(prompt_port_with_default "MySQL external port" "$mysql_port_default")"
        else
            local pg_user_default="$db_user"
            local pg_password_default="$db_password"
            local pg_port_default="$db_external_port"
            [ -z "$pg_user_default" ] && pg_user_default="postgres"
            [ "$pg_user_default" = "user" ] && pg_user_default="postgres"
            [ -z "$pg_password_default" ] && pg_password_default="postgres"
            [ "$pg_password_default" = "password" ] && pg_password_default="postgres"
            [ -z "$pg_port_default" ] && pg_port_default="5432"
            [ "$pg_port_default" = "3306" ] && pg_port_default="5432"

            db_user="$(prompt_with_default "PostgreSQL user" "$pg_user_default")"
            db_password="$(prompt_with_default "PostgreSQL password" "$pg_password_default")"
            db_external_port="$(prompt_port_with_default "PostgreSQL external port" "$pg_port_default")"
            db_root_password=""
        fi

        local start_default="y"
        [ "$no_start" -eq 1 ] && start_default="n"
        if [ "$(prompt_yes_no_default "Start containers after create?" "$start_default")" = "yes" ]; then
            no_start=0
        else
            no_start=1
        fi
    fi

    if [ "$preset" = "bitrix" ]; then
        local bitrix_type_default="${bitrix_type_raw:-kernel}"
        if ! bitrix_type_default="$(normalize_bitrix_type "$bitrix_type_default" 2>/dev/null)"; then
            bitrix_type_default="kernel"
        fi

        if [ "$interactive_mode" = "yes" ]; then
            bitrix_type_raw="$(prompt_choice_with_default "Bitrix type (kernel/ext_kernel/link)" "$bitrix_type_default" "kernel" "ext_kernel" "link")"
            if [ "$bitrix_type_raw" = "link" ]; then
                local available_cores=""
                available_cores="$(awk -F'\t' 'NF > 0 && $1 != "" {print $1}' "$BITRIX_CORE_REGISTRY_FILE" 2>/dev/null | paste -sd "," -)"
                if [ -n "$available_cores" ]; then
                    echo "Available core_id: $available_cores"
                fi
                core_ref="$(prompt_with_default "Core ID for link host" "${core_ref:-}")"
            else
                local default_core_id="${core_id:-$(default_core_id_for_host "$host")}"
                core_id="$(prompt_core_id_with_default "Core ID" "$default_core_id")"
            fi
        fi
    fi

    if ! is_valid_port "$db_external_port"; then
        echo "Error: invalid --db-port '$db_external_port'. Must be 1..65535."
        echo "Hint: example '--db-port 3307' for mysql or '--db-port 5433' for postgres."
        exit 1
    fi

    ensure_registry

    if registry_has_host "$host"; then
        echo "Error: host '$host' already exists."
        print_status_hint
        echo "Hint: remove existing host with './hostctl.sh delete $host --yes' if needed."
        exit 1
    fi

    if [ -d "$project_dir" ]; then
        echo "   ⚠️  Обнаружены частичные артефакты после предыдущего сбоя — выполняю автоочистку..."
        runtime_host_down "$project_dir" >/dev/null 2>&1 || true
        rm -rf "$project_dir" >/dev/null 2>&1 || true
        registry_remove_host "$host"
        bindings_registry_remove_host "$host"
        core_registry_remove_by_owner_host "$host"
        log_event "INFO" "create_auto_cleanup_partial host=$host"
    fi

    local mapped_preset
    if ! mapped_preset="$(normalize_preset_for_create "$preset")"; then
        echo "Error: unsupported preset '$preset'. Supported presets: empty, bitrix."
        echo "Hint: use '--preset empty' for a minimal host or '--preset bitrix' for Bitrix host."
        exit 1
    fi

    if [ ! -x "$CREATE_SCRIPT" ]; then
        echo "Error: create script not executable: $CREATE_SCRIPT"
        echo "Hint: run 'chmod +x \"$CREATE_SCRIPT\"' and retry."
        exit 1
    fi

    if [ "$mapped_preset" = "bitrix" ]; then
        is_bitrix=1
        if [ -z "$bitrix_type_raw" ]; then
            bitrix_type="kernel"
        else
            if ! bitrix_type="$(normalize_bitrix_type "$bitrix_type_raw")"; then
                fail_with_code "invalid_core" "Неверный --bitrix-type '$bitrix_type_raw'. Допустимо: kernel, ext_kernel, link."
                exit 1
            fi
        fi

        if [ "$bitrix_type" = "link" ]; then
            core_ref="$(normalize_core_id "$core_ref")"
            if ! is_valid_core_id "$core_ref"; then
                fail_with_code "invalid_core" "Для link-хоста требуется валидный --core <core_id>."
                exit 1
            fi
            core_id="$core_ref"
        else
            if [ -z "$core_id" ]; then
                core_id="$(default_core_id_for_host "$host")"
            fi
            core_id="$(normalize_core_id "$core_id")"
            if ! is_valid_core_id "$core_id"; then
                fail_with_code "invalid_core" "Некорректный core_id '$core_id'."
                exit 1
            fi
        fi
    else
        if [ -n "$bitrix_type_raw" ] || [ -n "$core_ref" ] || [ -n "$core_id" ]; then
            fail_with_code "invalid_core" "Опции --bitrix-type/--core/--core-id допустимы только для --preset bitrix."
            exit 1
        fi
        bitrix_type="-"
        core_id="-"
    fi

    if [ "$is_bitrix" -eq 1 ]; then
        if ! acquire_bindings_lock 30; then
            exit 1
        fi
        lock_acquired=1

        if [ "$bitrix_type" = "link" ]; then
            if ! core_registry_has_id "$core_ref"; then
                release_bindings_lock
                lock_acquired=0
                fail_with_code "invalid_core" "core_id '$core_ref' не найден."
                exit 1
            fi

            core_owner_host="$(core_registry_get_field "$core_ref" 2)"
            if [ -z "$core_owner_host" ] || [ ! -d "$PROJECTS_DIR/$core_owner_host" ]; then
                release_bindings_lock
                lock_acquired=0
                fail_with_code "invalid_core" "Владелец core '$core_ref' недоступен."
                exit 1
            fi

            local core_db_type=""
            local core_db_values=""
            core_db_type="$(registry_get_field "$core_owner_host" 4)"
            [ -n "$core_db_type" ] || core_db_type="mysql"
            if [ "$db_type" != "$core_db_type" ]; then
                echo "Info: link-host использует тип БД core '$core_db_type' (параметр --db='$db_type' проигнорирован)."
            fi
            db_type="$core_db_type"
            core_db_values="$(read_core_db_values "$core_owner_host" "$db_type")"
            IFS=$'\t' read -r db_name db_user db_password db_root_password db_external_port <<EOF
$core_db_values
EOF
            if ! is_valid_port "$db_external_port"; then
                db_external_port="3306"
                [ "$db_type" = "postgres" ] && db_external_port="5432"
            fi
        else
            if core_registry_has_id "$core_id"; then
                release_bindings_lock
                lock_acquired=0
                fail_with_code "invalid_core" "core_id '$core_id' уже занят другим core-хостом."
                exit 1
            fi
        fi
    fi

    echo "📦 Создание хоста '$host'..."
    echo "   Конфигурация: PHP=$php_version, БД=$db_type, пресет=$(display_preset "$mapped_preset"), TZ=$timezone, порт БД=$db_external_port"
    [ "$bitrix_type" != "-" ] && echo "   Bitrix: тип=$bitrix_type, core_id=$core_id"
    local create_bitrix_type=""
    [ "$is_bitrix" -eq 1 ] && [ "$bitrix_type" != "-" ] && create_bitrix_type="$bitrix_type"
    if ! "$CREATE_SCRIPT" "$host" "$php_version" "$db_type" "$mapped_preset" "$create_bitrix_type"; then
        [ "$lock_acquired" -eq 1 ] && release_bindings_lock
        exit 1
    fi

    if ! apply_project_overrides "$project_dir" "$db_type" "$timezone" "$db_name" "$db_user" "$db_password" "$db_root_password" "$db_external_port"; then
        cleanup_failed_host_create "$host" "$project_dir"
        [ "$lock_acquired" -eq 1 ] && release_bindings_lock
        fail_with_code "host_config_apply_failed" "Не удалось применить конфигурацию проекта."
        exit 1
    fi

    if ! rewrite_compose_paths_for_daemon "$project_dir" "$host"; then
        cleanup_failed_host_create "$host" "$project_dir"
        [ "$lock_acquired" -eq 1 ] && release_bindings_lock
        fail_with_code "compose_path_rewrite_failed" "Не удалось адаптировать compose-пути для Docker daemon."
        exit 1
    fi

    if [ "$is_bitrix" -eq 1 ]; then
        local env_target=""
        for env_target in "$project_dir/.env.example" "$project_dir/.env"; do
            [ -f "$env_target" ] || continue
            env_set_key "$env_target" "BITRIX_TYPE" "$bitrix_type"
            env_set_key "$env_target" "BITRIX_CORE_ID" "$core_id"
        done

        if [ "$bitrix_type" = "link" ]; then
            if ! configure_link_compose_without_db "$project_dir/docker-compose.yml" "$db_type"; then
                cleanup_failed_host_create "$host" "$project_dir"
                [ "$lock_acquired" -eq 1 ] && release_bindings_lock
                fail_with_code "link_db_disable_failed" "Не удалось отключить DB-сервис для link-хоста."
                exit 1
            fi
            rm -rf "$project_dir/db-mysql" "$project_dir/db-postgres" >/dev/null 2>&1 || true

            if ! prepare_link_shared_paths "$core_owner_host" "$host"; then
                cleanup_failed_host_create "$host" "$project_dir"
                [ "$lock_acquired" -eq 1 ] && release_bindings_lock
                fail_with_code "link_shared_paths_failed" "Не удалось подготовить симлинки shared paths для link-хоста."
                exit 1
            fi

            # Link подключается к БД core — патчим .settings.php: host => db-<core_slug>
            local core_slug=""
            core_slug="$(echo "$core_owner_host" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/-+/-/g; s/^-+//; s/-+$//' | cut -c1-48)"
            [ -n "$core_slug" ] || core_slug="${core_owner_host//./-}"
            local core_db_service="db-$core_slug"
            local settings_file="$project_dir/www/bitrix/.settings.php"
            if [ -f "$settings_file" ]; then
                if sed "s/'host' => '[^']*'/'host' => '$core_db_service'/g" "$settings_file" > "${settings_file}.tmp" && mv "${settings_file}.tmp" "$settings_file"; then
                    log_event "INFO" "link_settings_db_host_patched host=$host core_db=$core_db_service"
                fi
            fi
        elif [ "$bitrix_type" = "ext_kernel" ]; then
            if ! apply_ext_kernel_http_restriction "$project_dir/docker-compose.yml"; then
                cleanup_failed_host_create "$host" "$project_dir"
                [ "$lock_acquired" -eq 1 ] && release_bindings_lock
                fail_with_code "ext_kernel_http_restriction_failed" "Не удалось применить HTTP-ограничение для ext_kernel."
                exit 1
            fi
        fi
    fi

    local removed_metadata_files
    removed_metadata_files="$(remove_appledouble_files "$project_dir")"
    clear_project_xattrs "$project_dir"
    local patched_dockerfiles
    patched_dockerfiles="$(patch_project_dockerfiles_for_xdebug "$project_dir")"
    local patched_php_ini_display_errors="0"
    patched_php_ini_display_errors="$(patch_project_php_ini_display_errors "$project_dir")"
    local patched_bitrix_php_ini="0"
    if is_bitrix_project "$project_dir"; then
        patched_bitrix_php_ini="$(patch_project_bitrix_php_ini "$project_dir")"
    fi
    local rebuild_php_for_bitrix="0"
    local patched_nginx_php_upstream
    patched_nginx_php_upstream="$(patch_project_nginx_php_upstream "$project_dir" "$host")"
    local patched_compose_tls_router
    patched_compose_tls_router="$(patch_project_compose_for_tls_router "$project_dir")"
    local patched_mysql_innodb_strict_mode
    patched_mysql_innodb_strict_mode="$(patch_project_compose_mysql_innodb_strict_mode "$project_dir")"
    if [ "${removed_metadata_files:-0}" -gt 0 ]; then
        echo "   ℹ️  Удалено $removed_metadata_files файл(ов) метаданных macOS (._*) в '$host'."
    fi
    if [ "${patched_dockerfiles:-0}" -gt 0 ]; then
        echo "   ℹ️  Обновлено $patched_dockerfiles Dockerfile(ов) для совместимости с Xdebug в '$host'."
    fi
    if [ "${patched_php_ini_display_errors:-0}" -gt 0 ]; then
        echo "   ℹ️  Применены базовые PHP-настройки: display_errors=On, max_input_vars=10000 для '$host'."
    fi
    if [ "${patched_bitrix_php_ini:-0}" -gt 0 ]; then
        echo "   ℹ️  Применен Bitrix-тюнинг PHP: opcache.revalidate_freq=0 для '$host'."
        rebuild_php_for_bitrix="1"
    fi
    if [ "${patched_nginx_php_upstream:-0}" -gt 0 ]; then
        echo "   ℹ️  Обновлен Nginx fastcgi upstream для изоляции PHP-контейнера хоста '$host'."
    fi
    if [ "${patched_compose_tls_router:-0}" -gt 0 ]; then
        echo "   ℹ️  Обновлены Traefik labels для HTTPS-маршрутизации в '$host'."
    fi
    if [ "${patched_mysql_innodb_strict_mode:-0}" -gt 0 ]; then
        echo "   ℹ️  Для MySQL включен совместимый режим Bitrix: innodb_strict_mode=OFF в '$host'."
    fi
    local removed_metadata_files_post_patch="0"
    removed_metadata_files_post_patch="$(remove_appledouble_files "$project_dir")"
    clear_project_xattrs "$project_dir"
    if [ "${removed_metadata_files_post_patch:-0}" -gt 0 ]; then
        echo "   ℹ️  Дополнительно удалено $removed_metadata_files_post_patch файл(ов) метаданных macOS (._*) после patch-шага в '$host'."
    fi

    local created_at
    created_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    if ! registry_upsert_host "$host" "$(display_preset "$mapped_preset")" "$php_version" "$db_type" "$created_at" "$bitrix_type" "$core_id"; then
        cleanup_failed_host_create "$host" "$project_dir"
        [ "$lock_acquired" -eq 1 ] && release_bindings_lock
        fail_with_code "host_registry_write_failed" "Не удалось обновить реестр хостов."
        exit 1
    fi

    if [ "$is_bitrix" -eq 1 ]; then
        if [ "$bitrix_type" = "link" ]; then
            if ! bindings_registry_upsert "$host" "$core_ref" "$created_at"; then
                cleanup_failed_host_create "$host" "$project_dir"
                [ "$lock_acquired" -eq 1 ] && release_bindings_lock
                fail_with_code "bindings_registry_write_failed" "Не удалось записать binding link->core."
                exit 1
            fi
        else
            if ! core_registry_upsert "$core_id" "$host" "$bitrix_type" "$created_at"; then
                cleanup_failed_host_create "$host" "$project_dir"
                [ "$lock_acquired" -eq 1 ] && release_bindings_lock
                fail_with_code "core_registry_write_failed" "Не удалось записать core в реестр."
                exit 1
            fi
        fi
    fi

    if [ "$lock_acquired" -eq 1 ]; then
        release_bindings_lock
        lock_acquired=0
    fi

    if [ "$no_start" -eq 0 ]; then
        log_event "INFO" "create_host_attempting_start host=$host"
        if ! ensure_infra_network; then
            log_event "ERROR" "create_host_network_failed host=$host"
            echo "Warning: контейнеры не были запущены для '$host' из-за ошибки настройки Docker сети."
            echo "Выполните вручную после восстановления Docker:"
            echo "  docker network create infra_proxy"
            print_host_compose_hint "$project_dir" "up -d"
            echo "Hint: хост создан и может быть запущен позже командой './hostctl.sh start $host'."
        elif ! runtime_host_up "$project_dir" "$host" 2>&1 | tee /tmp/hostctl-start-$$.log; then
            local start_log=""
            if [ -f "/tmp/hostctl-start-$$.log" ]; then
                start_log="$(awk 'NR<=20 {printf "%s; ", $0}' "/tmp/hostctl-start-$$.log" 2>/dev/null || true)"
                rm -f "/tmp/hostctl-start-$$.log" 2>/dev/null || true
            fi
            log_event "ERROR" "create_host_start_failed host=$host start_log=$start_log"
            echo "Warning: не удалось запустить контейнеры для '$host'. Хост создан с сохраненной конфигурацией."
            echo "Выполните вручную после восстановления сети/Docker:"
            print_host_compose_hint "$project_dir" "up -d"
            echo "Hint: проверьте логи контейнеров командой './hostctl.sh status --host $host', затем 'docker compose logs'."
        else
            rm -f "/tmp/hostctl-start-$$.log" 2>/dev/null || true
            log_event "INFO" "create_host_start_success host=$host"
        fi
    else
        log_event "INFO" "create_host_skipped_start host=$host reason=no_start_flag"
    fi

    if ! sync_hosts_entry "add" "$host" "$hosts_mode"; then
        echo "Warning: failed to apply /etc/hosts synchronization for '$host'."
    fi

    refresh_infra_tls_material

    log_event "INFO" "create_host_complete host=$host"
    echo "✅ Хост '$host' успешно создан."
}

delete_host() {
    local host_input="$1"
    local host="$host_input"
    local domain_suffix=""
    shift

    local yes=0
    local lock_acquired=0
    local hosts_mode="${HOSTCTL_HOSTS_MODE:-auto}"

    if ! domain_suffix="$(resolve_domain_suffix)"; then
        exit 1
    fi

    if ! host="$(canonicalize_host_name "$host_input" "$domain_suffix" "existing")"; then
        exit 1
    fi

    log_event "INFO" "delete_host_begin host=$host input=$host_input domain_suffix=$domain_suffix"

    hosts_mode="$(to_lower "$hosts_mode")"
    case "$hosts_mode" in
        auto|skip)
            ;;
        *)
            echo "Warning: unsupported HOSTCTL_HOSTS_MODE '$hosts_mode'. Falling back to 'auto'."
            hosts_mode="auto"
            ;;
    esac

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --yes|-y)
                yes=1
                shift
                ;;
            *)
                echo "Unknown option for delete: $1"
                print_help_hint
                usage
                exit 1
                ;;
        esac
    done

    ensure_registry

    local project_dir="$PROJECTS_DIR/$host"
    local exists=0
    if [ -d "$project_dir" ] || registry_has_host "$host"; then
        exists=1
    fi

    if [ "$exists" -eq 0 ]; then
        echo "Error: host '$host' not found."
        print_status_hint
        exit 1
    fi

    if [ "$yes" -eq 0 ]; then
        printf "Delete host '%s'? [y/N]: " "$host"
        read -r answer
        case "$(to_lower "${answer:-n}")" in
            y|yes) ;;
            *)
                echo "Cancelled."
                exit 0
                ;;
        esac
    fi

    local preset=""
    local bitrix_type=""
    local core_id=""
    local resolved_profile=""
    preset="$(registry_get_field "$host" 2)"
    bitrix_type="$(registry_get_field "$host" 6)"
    core_id="$(registry_get_field "$host" 7)"
    resolved_profile="$(resolve_bitrix_profile_for_host "$host" "$preset" "$bitrix_type" "$core_id")"
    bitrix_type="${resolved_profile%%|*}"
    core_id="${resolved_profile##*|}"

    if [ "$bitrix_type" != "-" ]; then
        if ! acquire_bindings_lock 30; then
            exit 1
        fi
        lock_acquired=1

        if [ "$bitrix_type" != "link" ] && [ "$core_id" != "-" ] && [ -n "$core_id" ]; then
            local linked_count=0
            linked_count="$(bindings_registry_count_for_core_id "$core_id")"
            if [ "$linked_count" -gt 0 ]; then
                local linked_hosts
                linked_hosts="$(bindings_registry_list_hosts_for_core_id "$core_id" | paste -sd "," -)"
                release_bindings_lock
                lock_acquired=0
                fail_with_code "delete_guard" "Удаление core '$host' запрещено: привязаны link-хосты (${linked_hosts:-unknown})."
                exit 1
            fi
        fi
    fi

    if [ -f "$project_dir/docker-compose.yml" ]; then
    echo "🗑️  Остановка и удаление контейнеров..."
    (runtime_host_down "$project_dir" >/dev/null 2>&1 || true)
    fi

    if ! sync_hosts_entry "remove" "$host" "$hosts_mode"; then
        echo "Warning: failed to apply /etc/hosts synchronization cleanup for '$host'."
    fi

    if [ -d "$project_dir" ]; then
        if ! rm -rf "$project_dir"; then
            [ "$lock_acquired" -eq 1 ] && release_bindings_lock
            fail_with_code "delete_fs_failed" "Не удалось удалить каталог проекта '$project_dir'. Проверьте права и повторите."
            exit 1
        fi
    fi

    if ! registry_remove_host "$host"; then
        [ "$lock_acquired" -eq 1 ] && release_bindings_lock
        fail_with_code "host_registry_write_failed" "Не удалось обновить реестр хостов при удалении '$host'. Проверьте '$REGISTRY_FILE'."
        exit 1
    fi

    if [ "$bitrix_type" != "-" ]; then
        if ! bindings_registry_remove_host "$host"; then
            [ "$lock_acquired" -eq 1 ] && release_bindings_lock
            fail_with_code "bindings_registry_write_failed" "Не удалось обновить реестр bindings при удалении '$host'. Проверьте '$BITRIX_BINDINGS_FILE'."
            exit 1
        fi
        if [ "$bitrix_type" = "link" ]; then
            :
        elif [ "$core_id" != "-" ] && [ -n "$core_id" ]; then
            if ! core_registry_remove_core_id "$core_id"; then
                [ "$lock_acquired" -eq 1 ] && release_bindings_lock
                fail_with_code "core_registry_write_failed" "Не удалось удалить core_id '$core_id' из реестра. Проверьте '$BITRIX_CORE_REGISTRY_FILE'."
                exit 1
            fi
        else
            if ! core_registry_remove_by_owner_host "$host"; then
                [ "$lock_acquired" -eq 1 ] && release_bindings_lock
                fail_with_code "core_registry_write_failed" "Не удалось удалить владение core для '$host'. Проверьте '$BITRIX_CORE_REGISTRY_FILE'."
                exit 1
            fi
        fi
    fi

    if [ "$lock_acquired" -eq 1 ]; then
        release_bindings_lock
        lock_acquired=0
    fi

    refresh_infra_tls_material

    log_event "INFO" "delete_host_complete host=$host"
    echo "✅ Хост '$host' успешно удален."
}

start_host() {
    local host_input="$1"
    local host="$host_input"
    local domain_suffix=""
    shift

    if ! domain_suffix="$(resolve_domain_suffix)"; then
        exit 1
    fi

    if ! host="$(canonicalize_host_name "$host_input" "$domain_suffix" "existing")"; then
        exit 1
    fi

    log_event "INFO" "start_host_begin host=$host input=$host_input domain_suffix=$domain_suffix"

    if [ "$#" -gt 0 ]; then
        echo "Unknown option(s) for start: $*"
        print_help_hint
        usage
        exit 1
    fi

    ensure_registry

    local project_dir="$PROJECTS_DIR/$host"
    local compose_file="$project_dir/docker-compose.yml"
    if [ ! -d "$project_dir" ] && ! registry_has_host "$host"; then
        echo "Error: host '$host' not found."
        print_status_hint
        exit 1
    fi

    if [ ! -f "$compose_file" ]; then
        echo "Error: compose file not found for host '$host': $compose_file"
        echo "Hint: recreate host with './hostctl.sh create $host --preset empty' or restore docker-compose.yml."
        exit 1
    fi

    if ! rewrite_compose_paths_for_daemon "$project_dir" "$host"; then
        echo "Error: failed to adapt compose bind paths for host '$host'."
        echo "Hint: inspect '$compose_file' and '$HOSTCTL_LOG_FILE' for details."
        exit 1
    fi

    local removed_metadata_files
    removed_metadata_files="$(remove_appledouble_files "$project_dir")"
    clear_project_xattrs "$project_dir"
    local patched_dockerfiles
    patched_dockerfiles="$(patch_project_dockerfiles_for_xdebug "$project_dir")"
    local patched_php_ini_display_errors="0"
    patched_php_ini_display_errors="$(patch_project_php_ini_display_errors "$project_dir")"
    local patched_bitrix_php_ini="0"
    if is_bitrix_project "$project_dir"; then
        patched_bitrix_php_ini="$(patch_project_bitrix_php_ini "$project_dir")"
    fi
    local rebuild_php_for_bitrix="0"
    local patched_nginx_php_upstream
    patched_nginx_php_upstream="$(patch_project_nginx_php_upstream "$project_dir" "$host")"
    local patched_compose_tls_router
    patched_compose_tls_router="$(patch_project_compose_for_tls_router "$project_dir")"
    local patched_mysql_innodb_strict_mode
    patched_mysql_innodb_strict_mode="$(patch_project_compose_mysql_innodb_strict_mode "$project_dir")"
    if [ "${removed_metadata_files:-0}" -gt 0 ]; then
        echo "   ℹ️  Удалено $removed_metadata_files файл(ов) метаданных macOS (._*) в '$host'."
    fi
    if [ "${patched_dockerfiles:-0}" -gt 0 ]; then
        echo "   ℹ️  Обновлено $patched_dockerfiles Dockerfile(ов) для совместимости с Xdebug в '$host'."
    fi
    if [ "${patched_php_ini_display_errors:-0}" -gt 0 ]; then
        echo "   ℹ️  Применены базовые PHP-настройки: display_errors=On, max_input_vars=10000 для '$host'."
        rebuild_php_for_bitrix="1"
    fi
    if [ "${patched_bitrix_php_ini:-0}" -gt 0 ]; then
        echo "   ℹ️  Применен Bitrix-тюнинг PHP: opcache.revalidate_freq=0 для '$host'."
        rebuild_php_for_bitrix="1"
    fi
    if [ "${patched_nginx_php_upstream:-0}" -gt 0 ]; then
        echo "   ℹ️  Обновлен Nginx fastcgi upstream для изоляции PHP-контейнера хоста '$host'."
    fi
    if [ "${patched_compose_tls_router:-0}" -gt 0 ]; then
        echo "   ℹ️  Обновлены Traefik labels для HTTPS-маршрутизации в '$host'."
    fi
    if [ "${patched_mysql_innodb_strict_mode:-0}" -gt 0 ]; then
        echo "   ℹ️  Для MySQL включен совместимый режим Bitrix: innodb_strict_mode=OFF в '$host'."
    fi
    local removed_metadata_files_post_patch="0"
    removed_metadata_files_post_patch="$(remove_appledouble_files "$project_dir")"
    clear_project_xattrs "$project_dir"
    if [ "${removed_metadata_files_post_patch:-0}" -gt 0 ]; then
        echo "   ℹ️  Дополнительно удалено $removed_metadata_files_post_patch файл(ов) метаданных macOS (._*) после patch-шага в '$host'."
    fi

    if ! ensure_infra_network; then
        echo "Error: failed to prepare infra docker network for host '$host'."
        echo "Try:"
        echo "  docker network create infra_proxy"
        echo "Hint: after network is ready, run './hostctl.sh start $host' again."
        exit 1
    fi

    if [ "$rebuild_php_for_bitrix" = "1" ]; then
        echo "   ℹ️  Пересборка PHP-образа для применения обновленных php.ini-настроек..."
        if ! runtime_host_compose "$project_dir" build php; then
            echo "Error: не удалось пересобрать PHP-образ для хоста '$host'."
            echo "Hint: выполните вручную:"
            print_host_compose_hint "$project_dir" "build php"
            exit 1
        fi
    fi

    if ! runtime_host_up "$project_dir" "$host"; then
        echo "Error: не удалось запустить хост '$host'."
        echo "Проверьте состояние Docker/сети и повторите попытку:"
        print_host_compose_hint "$project_dir" "up -d"
        echo "Hint: выполните './hostctl.sh status --host $host' для проверки состояния сервисов."
        exit 1
    fi

    echo "✅ Хост '$host' успешно запущен."
    log_event "INFO" "start_host_complete host=$host"
}

stop_host() {
    local host_input="$1"
    local host="$host_input"
    local domain_suffix=""
    shift

    if ! domain_suffix="$(resolve_domain_suffix)"; then
        exit 1
    fi

    if ! host="$(canonicalize_host_name "$host_input" "$domain_suffix" "existing")"; then
        exit 1
    fi

    log_event "INFO" "stop_host_begin host=$host input=$host_input domain_suffix=$domain_suffix"

    if [ "$#" -gt 0 ]; then
        echo "Unknown option(s) for stop: $*"
        print_help_hint
        usage
        exit 1
    fi

    ensure_registry

    local project_dir="$PROJECTS_DIR/$host"
    local compose_file="$project_dir/docker-compose.yml"
    if [ ! -d "$project_dir" ] && ! registry_has_host "$host"; then
        echo "Error: host '$host' not found."
        print_status_hint
        exit 1
    fi

    if [ ! -f "$compose_file" ]; then
        echo "Error: compose file not found for host '$host': $compose_file"
        echo "Hint: project is partially broken. Use './hostctl.sh delete $host --yes' if host is no longer needed."
        exit 1
    fi

    echo "⏹️  Остановка хоста '$host'..."
    if ! runtime_host_stop "$project_dir" >/dev/null; then
        echo "Error: не удалось остановить хост '$host'."
        echo "Проверьте состояние Docker и повторите попытку:"
        print_host_compose_hint "$project_dir" "stop"
        echo "Hint: выполните './hostctl.sh status --host $host' после повтора."
        exit 1
    fi

    echo "✅ Хост '$host' успешно остановлен."
    log_event "INFO" "stop_host_complete host=$host"
}

infra_start() {
    log_event "INFO" "infra_start_begin"
    if [ "$#" -gt 0 ]; then
        echo "Unknown option(s) for infra-start: $*"
        print_help_hint
        usage
        exit 1
    fi

    if ! ensure_infra_network; then
        echo "Error: failed to prepare infra docker network."
        echo "Try:"
        echo "  docker network create infra_proxy"
        exit 1
    fi

    if ! ensure_infra_ssl; then
        exit 1
    fi

    ensure_infra_env_file_notice

    if ! runtime_infra_up; then
        echo "Error: не удалось запустить инфраструктурные контейнеры."
        echo "Проверьте состояние Docker/сети и повторите попытку:"
        print_infra_compose_command_hint "up -d"
        echo "Hint: если загрузка образов медленная, повторите команду после стабилизации сети."
        exit 1
    fi
    log_event "INFO" "infra_start_complete"
}

infra_stop() {
    log_event "INFO" "infra_stop_begin"
    if [ "$#" -gt 0 ]; then
        echo "Unknown option(s) for infra-stop: $*"
        print_help_hint
        usage
        exit 1
    fi

    echo "Остановка инфраструктурных контейнеров..."
    if ! runtime_infra_stop; then
        echo "Error: не удалось корректно остановить инфраструктурные контейнеры."
        echo "Проверьте состояние Docker и повторите попытку:"
        print_infra_compose_command_hint "down --remove-orphans"
        exit 1
    fi

    echo "✅ Инфраструктура успешно остановлена."
    log_event "INFO" "infra_stop_complete"
}

infra_restart() {
    log_event "INFO" "infra_restart_begin"
    if [ "$#" -gt 0 ]; then
        echo "Unknown option(s) for infra-restart: $*"
        print_help_hint
        usage
        exit 1
    fi

    if ! ensure_infra_network; then
        echo "Error: failed to prepare infra docker network."
        echo "Try:"
        echo "  docker network create infra_proxy"
        exit 1
    fi

    if ! ensure_infra_ssl; then
        exit 1
    fi

    ensure_infra_env_file_notice

    echo "Перезапуск инфраструктурных контейнеров..."
    if ! runtime_infra_stop; then
        echo "Warning: не удалось остановить один или несколько инфраструктурных контейнеров перед перезапуском."
        echo "Продолжаем запуск для восстановления окружения..."
    fi

    if ! runtime_infra_up; then
        echo "Error: не удалось запустить инфраструктурные контейнеры после перезапуска."
        echo "Проверьте состояние Docker/сети и повторите попытку:"
        print_infra_compose_command_hint "up -d"
        echo "Hint: выполните './hostctl.sh status' для проверки состояния инфраструктурных сервисов после повтора."
        exit 1
    fi

    echo "✅ Инфраструктура успешно перезапущена."
    log_event "INFO" "infra_restart_complete"
}

_parse_dev_tools_flags() {
    local want_xdebug=""
    local want_adminer=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --xdebug) want_xdebug=1; shift ;;
            --adminer) want_adminer=1; shift ;;
            *) break ;;
        esac
    done
    # Default: both when no flags
    if [ -z "$want_xdebug" ] && [ -z "$want_adminer" ]; then
        want_xdebug=1
        want_adminer=1
    fi
    echo "${want_xdebug:-} ${want_adminer:-}"
}

enable_dev_tools_host() {
    local host="$1"
    shift
    local domain_suffix=""
    if ! domain_suffix="$(resolve_domain_suffix)"; then
        exit 1
    fi
    if ! host="$(canonicalize_host_name "$host" "$domain_suffix" "existing")"; then
        exit 1
    fi
    local flags
    flags="$(_parse_dev_tools_flags "$@")"
    local want_xdebug="${flags%% *}"
    local want_adminer="${flags##* }"

    local project_dir="$PROJECTS_DIR/$host"
    local compose_file="$project_dir/docker-compose.yml"
    [ -f "$compose_file" ] || { echo "Error: проект $host не найден (нет docker-compose.yml)."; exit 1; }

    if [ -n "$want_xdebug" ]; then
        if python3 "$SCRIPT_DIR/patch-compose-xdebug.py" "$compose_file" enable 2>/dev/null; then
            dev_tools_set "$host" "xdebug" "true"
            echo "✅ Xdebug включён для $host"
        else
            echo "⚠️ Не удалось применить патч Xdebug для $host"
        fi
    fi
    if [ -n "$want_adminer" ]; then
        dev_tools_set "$host" "adminer" "true"
        echo "✅ Adminer отмечен для $host (общий adminer в инфраструктуре)"
    fi

    if [ -n "$want_xdebug" ] && [ -f "$compose_file" ]; then
        if runtime_host_compose "$project_dir" ps --status running -q php 2>/dev/null | grep -q .; then
            echo "Перезапуск php-контейнера для применения Xdebug..."
            runtime_host_compose "$project_dir" up -d --force-recreate php 2>/dev/null || true
        fi
    fi
}

disable_dev_tools_host() {
    local host="$1"
    shift
    local domain_suffix=""
    if ! domain_suffix="$(resolve_domain_suffix)"; then
        exit 1
    fi
    if ! host="$(canonicalize_host_name "$host" "$domain_suffix" "existing")"; then
        exit 1
    fi
    local flags
    flags="$(_parse_dev_tools_flags "$@")"
    local want_xdebug="${flags%% *}"
    local want_adminer="${flags##* }"

    local project_dir="$PROJECTS_DIR/$host"
    local compose_file="$project_dir/docker-compose.yml"
    [ -f "$compose_file" ] || { echo "Error: проект $host не найден (нет docker-compose.yml)."; exit 1; }

    if [ -n "$want_xdebug" ]; then
        if python3 "$SCRIPT_DIR/patch-compose-xdebug.py" "$compose_file" disable 2>/dev/null; then
            dev_tools_set "$host" "xdebug" "false"
            echo "✅ Xdebug отключён для $host"
        else
            echo "⚠️ Не удалось применить патч Xdebug для $host"
        fi
    fi
    if [ -n "$want_adminer" ]; then
        dev_tools_set "$host" "adminer" "false"
        echo "✅ Adminer снят для $host"
    fi

    if [ -n "$want_xdebug" ] && [ -f "$compose_file" ]; then
        if runtime_host_compose "$project_dir" ps --status running -q php 2>/dev/null | grep -q .; then
            echo "Перезапуск php-контейнера для применения изменений..."
            runtime_host_compose "$project_dir" up -d --force-recreate php 2>/dev/null || true
        fi
    fi
}

show_status() {
    local filter_host="${1:-}"
    local filter_input="$filter_host"
    local domain_suffix=""
    local canonical_host=""

    if ! domain_suffix="$(resolve_domain_suffix)"; then
        exit 1
    fi

    if [ -n "$filter_host" ]; then
        if ! filter_host="$(canonicalize_host_name "$filter_host" "$domain_suffix" "existing")"; then
            exit 1
        fi
    fi

    log_event "INFO" "show_status_begin filter_host=${filter_host:-all}"

    ensure_registry

    local hosts=()
    local host

    if [ -f "$REGISTRY_FILE" ]; then
        while IFS=$'\t' read -r host _; do
            [ -n "${host:-}" ] || continue
            canonical_host="$host"
            if canonical_host="$(canonicalize_host_name "$host" "$domain_suffix" "existing" 2>/dev/null)"; then
                host="$canonical_host"
            fi
            if [ "${#hosts[@]}" -eq 0 ] || ! contains_host "$host" "${hosts[@]}"; then
                hosts+=("$host")
            fi
        done < "$REGISTRY_FILE"
    fi

    local compose_file
    for compose_file in "$PROJECTS_DIR"/*/docker-compose.yml; do
        [ -f "$compose_file" ] || continue
        host="$(basename "$(dirname "$compose_file")")"
        canonical_host="$host"
        if canonical_host="$(canonicalize_host_name "$host" "$domain_suffix" "existing" 2>/dev/null)"; then
            host="$canonical_host"
        fi
        if [ "${#hosts[@]}" -eq 0 ] || ! contains_host "$host" "${hosts[@]}"; then
            hosts+=("$host")
        fi
    done

    if [ -n "$filter_host" ]; then
        if [ "${#hosts[@]}" -gt 0 ] && contains_host "$filter_host" "${hosts[@]}"; then
            hosts=("$filter_host")
        else
            echo "Error: host '$filter_host' not found."
            if [ -n "$filter_input" ] && [ "$filter_input" != "$filter_host" ]; then
                echo "Hint: input '$filter_input' was normalized to '$filter_host'."
            fi
            print_status_hint
            exit 1
        fi
    fi

    local product_version="-"
    local update_available="-"
    if [ -e "$DEV_DIR/.git" ]; then
        product_version="$(git -C "$DEV_DIR" describe --tags --always --dirty 2>/dev/null || echo "-")"
        if git -C "$DEV_DIR" fetch origin 2>/dev/null; then
            if git -C "$DEV_DIR" status -sb 2>/dev/null | grep -q '\[.*behind'; then
                update_available="yes"
            else
                update_available="no"
            fi
        fi
    fi
    [ -n "$product_version" ] || product_version="-"
    echo "Product: $product_version | Update available: $update_available"
    echo

    if [ "${#hosts[@]}" -eq 0 ]; then
        echo "No hosts found."
        exit 0
    fi

    printf "%-32s %-7s %-10s %-7s %-10s %-12s %-20s %-10s %-10s %-12s\n" "HOST" "ZONE" "PRESET" "PHP" "DB" "BITRIX_TYPE" "CORE_ID" "STATUS" "CONTAINERS" "DEV_TOOLS"
    printf "%-32s %-7s %-10s %-7s %-10s %-12s %-20s %-10s %-10s %-12s\n" "--------------------------------" "-------" "----------" "-------" "----------" "------------" "--------------------" "----------" "----------" "------------"

    local running_count=0
    local stopped_count=0
    local error_count=0
    local preset
    local php_version
    local db_type
    local bitrix_type
    local core_id
    local bitrix_profile
    local status_info
    local status
    local containers

    for host in "${hosts[@]}"; do
        preset="$(registry_get_field "$host" 2)"
        php_version="$(registry_get_field "$host" 3)"
        db_type="$(registry_get_field "$host" 4)"

        [ -n "$preset" ] || preset="unknown"
        [ -n "$php_version" ] || php_version="-"
        [ -n "$db_type" ] || db_type="-"

        bitrix_type="$(registry_get_field "$host" 6)"
        core_id="$(registry_get_field "$host" 7)"
        bitrix_profile="$(resolve_bitrix_profile_for_host "$host" "$preset" "$bitrix_type" "$core_id")"
        bitrix_type="${bitrix_profile%%|*}"
        core_id="${bitrix_profile##*|}"

        status_info="$(host_status_summary "$host")"
        status="${status_info%%|*}"
        containers="${status_info##*|}"

        case "$status" in
            running) running_count=$((running_count + 1)) ;;
            stopped) stopped_count=$((stopped_count + 1)) ;;
            *) error_count=$((error_count + 1)) ;;
        esac

        zone_marker="active"
        if is_legacy_host "$host" "$domain_suffix"; then
            zone_marker="legacy"
        fi

        local dev_tools_str="-"
        if [ -f "$DEV_TOOLS_LIB" ]; then
            dev_tools_str="$(dev_tools_format_for_status "$host")"
        fi

        printf "%-32s %-7s %-10s %-7s %-10s %-12s %-20s %-10s %-10s %-12s\n" "$host" "$zone_marker" "$preset" "$php_version" "$db_type" "$bitrix_type" "$core_id" "$status" "$containers" "$dev_tools_str"
    done

    echo
    echo "Summary: total=${#hosts[@]} running=$running_count stopped=$stopped_count error=$error_count"

    echo
    echo "Applications:"
    printf "%-10s %-32s %-20s %-36s %-10s\n" "SCOPE" "HOST" "SERVICE" "CONTAINER" "STATE"
    printf "%-10s %-32s %-20s %-36s %-10s\n" "----------" "--------------------------------" "--------------------" "------------------------------------" "----------"

    for host in "${hosts[@]}"; do
        print_host_app_rows "$host"
    done

    if [ -z "$filter_host" ]; then
        print_infra_app_rows
    fi
}

show_logs() {
    local tail_lines="120"

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --tail)
                [ "$#" -ge 2 ] || { echo "Missing value for --tail"; exit 1; }
                tail_lines="$2"
                shift 2
                ;;
            *)
                echo "Unknown option for logs: $1"
                print_help_hint
                usage
                exit 1
                ;;
        esac
    done

    case "$tail_lines" in
        ''|*[!0-9]*)
            echo "Error: --tail must be a positive integer."
            exit 1
            ;;
    esac
    [ "$tail_lines" -gt 0 ] || { echo "Error: --tail must be > 0."; exit 1; }

    ensure_registry
    echo "Hostctl log file: $HOSTCTL_LOG_FILE"
    tail -n "$tail_lines" "$HOSTCTL_LOG_FILE"
}

get_path_size_kb() {
    local path="$1"
    [ -e "$path" ] || { echo "0"; return 0; }
    du -sk "$path" 2>/dev/null | awk '{print ($1 ~ /^[0-9]+$/) ? $1 : 0}'
}

format_size_kb() {
    local kb="${1:-0}"
    case "$kb" in
        ''|*[!0-9]*)
            kb=0
            ;;
    esac

    if [ "$kb" -ge 1048576 ]; then
        awk -v value="$kb" 'BEGIN {printf "%.2f GB", value / 1048576}'
    elif [ "$kb" -ge 1024 ]; then
        awk -v value="$kb" 'BEGIN {printf "%.2f MB", value / 1024}'
    else
        printf "%s KB" "$kb"
    fi
}

append_log_inventory_entry() {
    local inventory_file="$1"
    local category="$2"
    local path="$3"
    local kind="$4"
    local protected="$5"
    local description="$6"
    local size_kb

    [ -e "$path" ] || return 0
    size_kb="$(get_path_size_kb "$path")"
    printf "%s\t%s\t%s\t%s\t%s\t%s\n" \
        "$category" \
        "$path" \
        "$kind" \
        "$protected" \
        "$size_kb" \
        "$description" >> "$inventory_file"
}

host_is_running() {
    local host="$1"
    [ -n "$host" ] || return 1
    [ -d "$PROJECTS_DIR/$host" ] || return 1
    local status_info=""
    status_info="$(host_status_summary "$host" 2>/dev/null || true)"
    [ "${status_info%%|*}" = "running" ]
}

collect_log_inventory() {
    local inventory_file="$1"
    : > "$inventory_file"

    ensure_registry

    append_log_inventory_entry "$inventory_file" "hostctl_operation_log" "$HOSTCTL_LOG_FILE" "file" "0" "Журнал операций hostctl."
    append_log_inventory_entry "$inventory_file" "devpanel_action_log" "$STATE_DIR/devpanel-actions.log" "file" "0" "Журнал действий из DevPanel."
    append_log_inventory_entry "$inventory_file" "devpanel_job_artifacts" "$STATE_DIR/devpanel-jobs" "dir" "0" "Фоновые job-артефакты DevPanel (.log/.json/.sh/.exit)."

    append_log_inventory_entry "$inventory_file" "legacy_root_logs" "$PROJECTS_DIR/.hostctl.log" "file" "0" "Legacy hostctl log в projects/ (подлежит миграции)."
    append_log_inventory_entry "$inventory_file" "legacy_root_logs" "$PROJECTS_DIR/.devpanel-actions.log" "file" "0" "Legacy DevPanel actions log в projects/."
    append_log_inventory_entry "$inventory_file" "legacy_root_logs" "$PROJECTS_DIR/.devpanel-jobs" "dir" "0" "Legacy DevPanel jobs в projects/."

    local log_dir=""
    local host=""
    local protected="0"

    for project_dir in "$PROJECTS_DIR"/*/; do
        [ -d "$project_dir" ] || continue
        host="$(basename "$project_dir")"
        log_dir="$project_dir/logs/php"
        [ -d "$log_dir" ] || continue
        protected="0"
        if host_is_running "$host"; then
            protected="1"
        fi
        append_log_inventory_entry "$inventory_file" "project_php_logs" "$log_dir" "dir" "$protected" "Каталог PHP логов проекта $host."
    done

    for project_dir in "$PROJECTS_DIR"/*/; do
        [ -d "$project_dir" ] || continue
        host="$(basename "$project_dir")"
        log_dir="$project_dir/logs/nginx"
        [ -d "$log_dir" ] || continue
        protected="0"
        if host_is_running "$host"; then
            protected="1"
        fi
        append_log_inventory_entry "$inventory_file" "project_nginx_logs" "$log_dir" "dir" "$protected" "Каталог Nginx логов проекта $host."
    done

    for log_dir in "$DEV_DIR"/logs/db/*; do
        [ -d "$log_dir" ] || continue
        host="$(basename "$log_dir")"
        protected="0"
        if host_is_running "$host"; then
            protected="1"
        fi
        append_log_inventory_entry "$inventory_file" "project_db_logs" "$log_dir" "dir" "$protected" "Каталог DB логов проекта."
    done

    protected="0"
    if docker ps --format '{{.Names}}' 2>/dev/null | awk '$1 == "traefik" {found=1} END {exit !found}'; then
        protected="1"
    fi
    append_log_inventory_entry "$inventory_file" "infra_traefik_logs" "$DEV_DIR/logs/traefik" "dir" "$protected" "Логи Traefik."
}

prompt_log_review_decision() {
    local category="$1"
    local description="$2"
    local item_count="$3"
    local total_kb="$4"
    local protected_count="$5"
    local answer=""
    local normalized=""

    echo >&2
    echo "Category: $category" >&2
    echo "  Description : $description" >&2
    echo "  Entries     : $item_count" >&2
    echo "  Total size  : $(format_size_kb "$total_kb")" >&2
    echo "  Protected   : $protected_count" >&2

    while true; do
        printf "Decision [k=keep, d=delete, s=skip] (default: k): " >&2
        read -r answer || true
        normalized="$(to_lower "${answer:-k}")"
        case "$normalized" in
            k|keep)
                echo "keep"
                return 0
                ;;
            d|delete)
                echo "delete"
                return 0
                ;;
            s|skip)
                echo "skip"
                return 0
                ;;
            *)
                echo "Please answer with: k, d, or s." >&2
                ;;
        esac
    done
}

build_log_review_report() {
    local inventory_file="$1"
    local decisions_file="$2"
    local report_file="$3"
    local dry_run="$4"

    {
        echo "# Log Review Report"
        echo
        echo "Date (UTC): $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
        echo "Mode: $([ "$dry_run" -eq 1 ] && echo "dry-run" || echo "apply")"
        echo "State dir: \`$STATE_DIR\`"
        echo
        echo "## Decisions by Category"
        echo
        echo "| Category | Decision | Entries | Size | Protected |"
        echo "|----------|----------|---------|------|-----------|"

        local category=""
        local decision=""
        local entries="0"
        local total_kb="0"
        local protected_count="0"

        while IFS=$'\t' read -r category decision; do
            [ -n "$category" ] || continue
            entries="$(awk -F'\t' -v c="$category" '$1 == c {count++} END {print count+0}' "$inventory_file")"
            total_kb="$(awk -F'\t' -v c="$category" '$1 == c {sum += $5} END {print sum+0}' "$inventory_file")"
            protected_count="$(awk -F'\t' -v c="$category" '$1 == c && $4 == 1 {count++} END {print count+0}' "$inventory_file")"
            printf "| %s | %s | %s | %s | %s |\n" \
                "$category" \
                "$decision" \
                "$entries" \
                "$(format_size_kb "$total_kb")" \
                "$protected_count"
        done < "$decisions_file"
    } > "$report_file"
}

review_logs_dialog() {
    local dry_run=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --dry-run)
                dry_run=1
                shift
                ;;
            *)
                echo "Unknown option for logs-review: $1"
                print_help_hint
                usage
                exit 1
                ;;
        esac
    done

    ensure_registry

    local inventory_file=""
    local decisions_file=""
    inventory_file="$(mktemp)"
    decisions_file="$(mktemp)"

    collect_log_inventory "$inventory_file"
    if [ ! -s "$inventory_file" ]; then
        echo "No log artifacts found for review."
        rm -f "$inventory_file" "$decisions_file"
        return 0
    fi

    echo "🔎 Log review session"
    echo "State dir: $STATE_DIR"
    echo "Projects dir: $PROJECTS_DIR"
    echo
    echo "Примите решение по каждой категории логов."

    local category=""
    local description=""
    local item_count="0"
    local total_kb="0"
    local protected_count="0"
    local decision=""

    local categories_file=""
    categories_file="$(mktemp)"
    awk -F'\t' '{print $1}' "$inventory_file" | sort -u > "$categories_file"

    exec 3<"$categories_file"
    while IFS= read -r category <&3; do
        [ -n "$category" ] || continue
        description="$(awk -F'\t' -v c="$category" '$1 == c {print $6; exit}' "$inventory_file")"
        item_count="$(awk -F'\t' -v c="$category" '$1 == c {count++} END {print count+0}' "$inventory_file")"
        total_kb="$(awk -F'\t' -v c="$category" '$1 == c {sum += $5} END {print sum+0}' "$inventory_file")"
        protected_count="$(awk -F'\t' -v c="$category" '$1 == c && $4 == 1 {count++} END {print count+0}' "$inventory_file")"

        decision="$(prompt_log_review_decision "$category" "$description" "$item_count" "$total_kb" "$protected_count")"
        printf "%s\t%s\n" "$category" "$decision" >> "$decisions_file"
    done
    exec 3<&-
    rm -f "$categories_file"

    local deleted_count=0
    local protected_skipped_count=0
    local failed_count=0
    local path=""
    local kind=""
    local protected=""

    while IFS=$'\t' read -r category decision; do
        [ "$decision" = "delete" ] || continue

        while IFS=$'\t' read -r current_category path kind protected _size _description; do
            [ "$current_category" = "$category" ] || continue
            [ -e "$path" ] || continue

            if [ "$protected" = "1" ]; then
                echo "⚠️  Protected, skipped: $path"
                protected_skipped_count=$((protected_skipped_count + 1))
                continue
            fi

            if [ "$dry_run" -eq 1 ]; then
                echo "🧪 Dry-run delete: $path"
                deleted_count=$((deleted_count + 1))
                continue
            fi

            if [ "$kind" = "dir" ]; then
                rm -rf "$path" >/dev/null 2>&1 || true
            else
                rm -f "$path" >/dev/null 2>&1 || true
            fi

            if [ ! -e "$path" ]; then
                echo "🗑️  Deleted: $path"
                deleted_count=$((deleted_count + 1))
            else
                echo "❌ Failed to delete: $path"
                failed_count=$((failed_count + 1))
            fi
        done < "$inventory_file"
    done < "$decisions_file"

    local report_file="$STATE_DIR/log-review-report-$(date -u +%Y%m%dT%H%M%SZ).md"
    build_log_review_report "$inventory_file" "$decisions_file" "$report_file" "$dry_run"

    echo
    echo "Review summary:"
    echo "  Deleted/Planned: $deleted_count"
    echo "  Protected skip : $protected_skipped_count"
    echo "  Failed delete  : $failed_count"
    echo "  Report         : $report_file"

    rm -f "$inventory_file" "$decisions_file"
}

main() {
    [ "$#" -gt 0 ] || { usage; exit 1; }

    local command="$1"
    shift

    local delegated_rc=2
    if maybe_delegate_to_fallback_runtime "$command" "$@"; then
        delegated_rc=0
    else
        delegated_rc=$?
    fi
    if [ "$delegated_rc" -ne 2 ]; then
        exit "$delegated_rc"
    fi

    HOSTCTL_CURRENT_COMMAND="$command"
    HOSTCTL_CURRENT_ARGS="$*"
    log_event "INFO" "invoke"

    case "$command" in
        create)
            [ "$#" -ge 1 ] || { usage; exit 1; }
            create_host "$@"
            ;;
        start)
            [ "$#" -ge 1 ] || { usage; exit 1; }
            start_host "$@"
            ;;
        stop)
            [ "$#" -ge 1 ] || { usage; exit 1; }
            stop_host "$@"
            ;;
        infra-start)
            infra_start "$@"
            ;;
        infra-stop)
            infra_stop "$@"
            ;;
        infra-restart)
            infra_restart "$@"
            ;;
        delete|remove)
            [ "$#" -ge 1 ] || { usage; exit 1; }
            delete_host "$@"
            ;;
        status)
            local filter_host=""
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    --host)
                        [ "$#" -ge 2 ] || { echo "Missing value for --host"; exit 1; }
                        filter_host="$2"
                        shift 2
                        ;;
                    *)
                        echo "Unknown option for status: $1"
                        print_help_hint
                        usage
                        exit 1
                        ;;
                esac
            done
            show_status "$filter_host"
            ;;
        enable-dev-tools)
            [ "$#" -ge 1 ] || { usage; exit 1; }
            enable_dev_tools_host "$@"
            ;;
        disable-dev-tools)
            [ "$#" -ge 1 ] || { usage; exit 1; }
            disable_dev_tools_host "$@"
            ;;
        update-component-adminer)
            "$SCRIPT_DIR/update-component-adminer.sh" "$@"
            ;;
        update-presets)
            "$SCRIPT_DIR/update-presets.sh" "$@"
            ;;
        logs)
            show_logs "$@"
            ;;
        logs-review|log-review)
            review_logs_dialog "$@"
            ;;
        help|-h|--help)
            usage
            ;;
        *)
            echo "Unknown command: $command"
            print_help_hint
            usage
            exit 1
            ;;
    esac

    log_event "INFO" "completed"
}

main "$@"
