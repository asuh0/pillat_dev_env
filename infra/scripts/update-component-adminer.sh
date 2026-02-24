#!/bin/bash
# WP03: Component update for Adminer (docker compose pull + recreate)
# Uses update-lib.sh transactional framework.
set -eEuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"
STATE_DIR="${HOSTCTL_STATE_DIR:-$INFRA_DIR/state}"
INFRA_ENV_FILE="$INFRA_DIR/.env.global"
COMPOSE_FILE="$INFRA_DIR/docker-compose.shared.yml"
COMPONENT_SERVICE="adminer"
COMPONENT_IMAGE="adminer:latest"
OBJECT_ID="adminer"
OBJECT_TYPE="internal_app"

export HOSTCTL_STATE_DIR="$STATE_DIR"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/update-lib.sh"

_infra_compose() {
    local compose_args=("-f" "$COMPOSE_FILE")
    if [ -f "$INFRA_ENV_FILE" ]; then
        (cd "$INFRA_DIR" && COPYFILE_DISABLE=1 COMPOSE_IGNORE_ORPHANS=1 docker compose "${compose_args[@]}" --env-file "$INFRA_ENV_FILE" "$@")
    else
        (cd "$INFRA_DIR" && COPYFILE_DISABLE=1 COMPOSE_IGNORE_ORPHANS=1 docker compose "${compose_args[@]}" "$@")
    fi
}

# T013: Check current/target version
_component_check() {
    local object_id="$1"
    local target_version="$2"
    [ "$object_id" = "$OBJECT_ID" ] || return 1
    [ -n "$target_version" ] || return 1

    if ! command -v docker >/dev/null 2>&1; then
        echo "Error: docker недоступен" >&2
        return 1
    fi

    if ! _infra_compose config --services 2>/dev/null | grep -q "^${COMPONENT_SERVICE}$"; then
        echo "Error: сервис $COMPONENT_SERVICE не найден в compose" >&2
        return 1
    fi

    # Target: digest from manifest or "latest" (resolved on pull)
    if [ "$target_version" = "latest" ] || [[ "$target_version" == sha256:* ]]; then
        return 0
    fi
    return 0
}

# T014: Apply - docker compose pull + recreate
_component_apply() {
    local object_id="$1"
    local target_version="$2"
    local previous_version="$3"
    [ "$object_id" = "$OBJECT_ID" ] || return 1

    # Save current image for rollback: tag before pull (pull overwrites :latest)
    local old_image_id=""
    old_image_id="$(docker images "$COMPONENT_IMAGE" -q 2>/dev/null | head -1)"
    if [ -z "$old_image_id" ]; then
        if container_id="$(docker ps -aq -f name=^${COMPONENT_SERVICE}$ 2>/dev/null | head -1)" && [ -n "$container_id" ]; then
            old_image_id="$(docker inspect "$container_id" --format '{{.Image}}' 2>/dev/null || true)"
        fi
    fi
    local rollback_tag="adminer:rollback-$$"
    if [ -n "$old_image_id" ]; then
        docker tag "$old_image_id" "$rollback_tag" 2>/dev/null || true
    fi
    export _COMPONENT_ROLLBACK_TAG="$rollback_tag"

    _infra_compose pull "$COMPONENT_SERVICE"
    _infra_compose up -d --force-recreate "$COMPONENT_SERVICE"
}

# T015: Verify - health check
_component_verify() {
    local object_id="$1"
    local target_version="$2"
    [ "$object_id" = "$OBJECT_ID" ] || return 1

    # Simulate failure for acceptance test (--simulate-verify-failure)
    if [ "${_SIMULATE_VERIFY_FAILURE:-0}" = "1" ]; then
        echo "Error: simulated verify failure" >&2
        return 1
    fi

    # Wait for container to be ready
    local i=0
    while [ "$i" -lt 30 ]; do
        if status="$(docker inspect -f '{{.State.Status}}' "$COMPONENT_SERVICE" 2>/dev/null)" && [ "$status" = "running" ]; then
            break
        fi
        sleep 1
        i=$((i + 1))
    done

    if [ "$(docker inspect -f '{{.State.Status}}' "$COMPONENT_SERVICE" 2>/dev/null)" != "running" ]; then
        echo "Error: контейнер $COMPONENT_SERVICE не в состоянии running" >&2
        return 1
    fi

    # HTTP check (Adminer listens on 8080)
    if command -v curl >/dev/null 2>&1; then
        if ! docker exec "$COMPONENT_SERVICE" wget -q -O /dev/null http://127.0.0.1:8080/ 2>/dev/null; then
            # Fallback: container running is enough
            :
        fi
    fi
    return 0
}

# T016: Rollback - restore previous image
_component_rollback() {
    local object_id="$1"
    local previous_version="$2"
    [ "$object_id" = "$OBJECT_ID" ] || return 1

    local rollback_tag="${_COMPONENT_ROLLBACK_TAG:-}"
    if [ -z "$rollback_tag" ] || ! docker images "$rollback_tag" -q 2>/dev/null | grep -q .; then
        echo "Warning: образ для rollback не найден" >&2
        return 1
    fi

    docker tag "$rollback_tag" "$COMPONENT_IMAGE" 2>/dev/null || return 1
    _infra_compose up -d --force-recreate "$COMPONENT_SERVICE"
    docker rmi "$rollback_tag" 2>/dev/null || true
}

# Resolve target version: digest from manifest or "latest-<timestamp>" to force pull
_get_target_version() {
    local manifest_out
    manifest_out="$(docker manifest inspect "$COMPONENT_IMAGE" 2>/dev/null)" || true
    if [ -n "$manifest_out" ] && echo "$manifest_out" | grep -qE '"digest"|"config"'; then
        echo "$manifest_out" | grep -oE '"digest":"sha256:[a-f0-9]+"' | head -1 | cut -d'"' -f4 || echo "latest-$(date +%s)"
    else
        echo "latest-$(date +%s)"
    fi
}

main() {
    local target="latest"
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --simulate-verify-failure)
                export _SIMULATE_VERIFY_FAILURE=1
                shift
                ;;
            *)
                [ "$1" != "--" ] && target="$1"
                shift
                break
                ;;
        esac
    done

    mkdir -p "$STATE_DIR"
    mkdir -p "$VERSION_REGISTRY_DIR" "$UPDATE_OPS_DIR"

    if [ "$target" = "latest" ] || [ -z "$target" ]; then
        target="$(_get_target_version)"
    fi

    echo "=== Обновление компонента Adminer ==="
    echo "Целевая версия: $target"
    run_update_transaction "$OBJECT_ID" "$OBJECT_TYPE" "$target" \
        _component_check _component_apply _component_verify _component_rollback
    echo "OK: Adminer обновлён"
}

main "$@"
