#!/bin/bash
# WP04: Preset scripts update via git pull
# Uses update-lib.sh transactional framework.
set -eEuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"
DEV_DIR="$(dirname "$INFRA_DIR")"
STATE_DIR="${HOSTCTL_STATE_DIR:-$INFRA_DIR/state}"
PRESETS_DIR="${PRESETS_DIR:-$DEV_DIR/presets}"
OBJECT_ID="preset_scripts"
OBJECT_TYPE="preset_scripts"

export HOSTCTL_STATE_DIR="$STATE_DIR"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/update-lib.sh"

# T019/T020: Check - preflight git status
_presets_check() {
    local object_id="$1"
    local target_version="$2"
    [ "$object_id" = "$OBJECT_ID" ] || return 1

    if [ ! -d "$DEV_DIR/.git" ] && [ ! -f "$DEV_DIR/.git" ]; then
        echo "Error: $DEV_DIR не является git-репозиторием" >&2
        return 1
    fi

    local status_out
    status_out="$(git -C "$DEV_DIR" status --porcelain 2>/dev/null)" || return 1
    if [ -n "$status_out" ]; then
        echo "Error: нечистое состояние git. Закоммитьте или отмените локальные изменения." >&2
        echo "  git status:" >&2
        git -C "$DEV_DIR" status -s 2>/dev/null | head -10 | sed 's/^/    /' >&2
        return 1
    fi

    if ! git -C "$DEV_DIR" fetch origin 2>/dev/null; then
        echo "Error: не удалось выполнить git fetch" >&2
        return 1
    fi
    return 0
}

# T019: Apply - git pull
_presets_apply() {
    local object_id="$1"
    local target_version="$2"
    local previous_version="$3"
    [ "$object_id" = "$OBJECT_ID" ] || return 1

    # Save current commit for rollback
    local prev_commit
    prev_commit="$(git -C "$DEV_DIR" rev-parse HEAD 2>/dev/null)"
    export _PRESETS_ROLLBACK_COMMIT="${previous_version:-$prev_commit}"

    if ! git -C "$DEV_DIR" pull origin 2>/dev/null; then
        echo "Error: git pull не выполнен (возможны конфликты)" >&2
        return 1
    fi
    return 0
}

# Verify: presets directory exists and has structure
_presets_verify() {
    local object_id="$1"
    local target_version="$2"
    [ "$object_id" = "$OBJECT_ID" ] || return 1

    [ -d "$PRESETS_DIR" ] || { echo "Error: presets не найден" >&2; return 1; }
    [ -f "$PRESETS_DIR/CONTRACT.md" ] || [ -d "$PRESETS_DIR/empty" ] || [ -d "$PRESETS_DIR/bitrix" ] || {
        echo "Error: presets повреждён или пуст" >&2
        return 1
    }
    return 0
}

# T021: Rollback - git reset --hard previous
_presets_rollback() {
    local object_id="$1"
    local previous_version="$2"
    [ "$object_id" = "$OBJECT_ID" ] || return 1

    local rollback_commit="${_PRESETS_ROLLBACK_COMMIT:-$previous_version}"
    [ -n "$rollback_commit" ] || { echo "Error: commit для rollback не сохранён" >&2; return 1; }

    if ! git -C "$DEV_DIR" reset --hard "$rollback_commit" 2>/dev/null; then
        echo "Error: git reset для rollback не выполнен" >&2
        return 1
    fi
    return 0
}

main() {
    mkdir -p "$STATE_DIR"
    mkdir -p "$VERSION_REGISTRY_DIR" "$UPDATE_OPS_DIR"

    git -C "$DEV_DIR" fetch origin 2>/dev/null || true
    local target_version
    target_version="$(git -C "$DEV_DIR" rev-parse origin/HEAD 2>/dev/null)" || \
    target_version="$(git -C "$DEV_DIR" rev-parse origin/main 2>/dev/null)" || \
    target_version="$(git -C "$DEV_DIR" rev-parse HEAD 2>/dev/null)"

    echo "=== Обновление скриптов пресетов ==="
    echo "Целевая версия: ${target_version:0:12}"
    run_update_transaction "$OBJECT_ID" "$OBJECT_TYPE" "$target_version" \
        _presets_check _presets_apply _presets_verify _presets_rollback
    echo "OK: Скрипты пресетов обновлены"
}

main "$@"
