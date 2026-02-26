#!/bin/bash
# Update transaction library for WP01 (004-dev-tools-and-update-pipeline)
# Provides: version records, operation logs, transactional check→apply→verify→rollback.
# Reusable by WP03 (internal app update) and WP04 (preset script update).
set -eEuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"
STATE_DIR="${HOSTCTL_STATE_DIR:-$INFRA_DIR/state}"
VERSION_REGISTRY_DIR="${STATE_DIR}/version-registry"
UPDATE_OPS_DIR="${STATE_DIR}/update-operations"

# --- T001: Version Record format ---
# Fields: object_id, object_type, current_version, target_version, updated_at
# object_type: internal_app | preset_scripts
# Storage: one JSON file per object: version-registry/<object_id>.json
# Schema validation via required keys

version_record_required_keys="object_id object_type current_version updated_at"

version_record_path() {
    local object_id="$1"
    echo "$VERSION_REGISTRY_DIR/${object_id}.json"
}

# Validate version record structure (required keys present)
version_record_validate() {
    local path="$1"
    local err=0
    for key in $version_record_required_keys; do
        if ! grep -q "\"$key\"" "$path" 2>/dev/null; then
            echo "version_record_validate: missing key '$key' in $path" >&2
            err=1
        fi
    done
    return $err
}

# Read current version for object
version_record_get_current() {
    local object_id="$1"
    local path
    path="$(version_record_path "$object_id")"
    if [ -f "$path" ]; then
        if version_record_validate "$path" 2>/dev/null; then
            # Use jq if available, else grep
            if command -v jq >/dev/null 2>&1; then
                jq -r '.current_version // empty' "$path" 2>/dev/null || true
            else
                grep -o '"current_version"[[:space:]]*:[[:space:]]*"[^"]*"' "$path" 2>/dev/null | sed 's/.*: *"\([^"]*\)".*/\1/' || true
            fi
        fi
    fi
}

# Write version record
version_record_write() {
    local object_id="$1"
    local object_type="$2"
    local current_version="$3"
    local target_version="${4:-}"
    local path
    mkdir -p "$VERSION_REGISTRY_DIR"
    path="$(version_record_path "$object_id")"
    local updated_at
    updated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
    if command -v jq >/dev/null 2>&1; then
        jq -n \
            --arg oid "$object_id" \
            --arg ot "$object_type" \
            --arg cv "$current_version" \
            --arg tv "${target_version:-$current_version}" \
            --arg ua "$updated_at" \
            '{object_id: $oid, object_type: $ot, current_version: $cv, target_version: $tv, updated_at: $ua}' \
            > "$path"
    else
        cat > "$path" <<EOF
{"object_id":"$object_id","object_type":"$object_type","current_version":"$current_version","target_version":"${target_version:-$current_version}","updated_at":"$updated_at"}
EOF
    fi
    version_record_validate "$path" || return 1
}

# --- T002: Update Operation format ---
# operation_id, object_id, object_type, started_at, completed_at, status, step, step_status,
# error_code, error_message, error_debug, previous_version, target_version
# Status: pending | check_ok | applying | apply_ok | verifying | verify_ok | failed | rolled_back | completed
# Step: check | apply | verify | rollback

update_op_status_pending="pending"
update_op_status_check_ok="check_ok"
update_op_status_applying="applying"
update_op_status_apply_ok="apply_ok"
update_op_status_verifying="verifying"
update_op_status_verify_ok="verify_ok"
update_op_status_failed="failed"
update_op_status_rolled_back="rolled_back"
update_op_status_completed="completed"

# Error codes (T005 - normalized)
ERROR_CHECK_PREREQ="CHECK_PREREQ_FAILED"
ERROR_CHECK_AVAILABILITY="CHECK_AVAILABILITY_FAILED"
ERROR_APPLY_GENERIC="APPLY_FAILED"
ERROR_APPLY_WRITE="APPLY_WRITE_FAILED"
ERROR_VERIFY_HEALTH="VERIFY_HEALTH_FAILED"
ERROR_VERIFY_VERSION="VERIFY_VERSION_FAILED"
ERROR_ROLLBACK_RESTORE="ROLLBACK_RESTORE_FAILED"

update_op_path() {
    local op_id="$1"
    echo "$UPDATE_OPS_DIR/${op_id}.json"
}

update_op_create() {
    local object_id="$1"
    local object_type="$2"
    local target_version="$3"
    local previous_version="$4"
    local op_id
    op_id="op-$(date +%Y%m%dT%H%M%S)-$$"
    mkdir -p "$UPDATE_OPS_DIR"
    local path
    path="$(update_op_path "$op_id")"
    local started_at
    started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
    if command -v jq >/dev/null 2>&1; then
        jq -n \
            --arg oid "$op_id" \
            --arg obj "$object_id" \
            --arg ot "$object_type" \
            --arg tv "$target_version" \
            --arg pv "$previous_version" \
            --arg sa "$started_at" \
            '{operation_id: $oid, object_id: $obj, object_type: $ot, target_version: $tv, previous_version: $pv, started_at: $sa, completed_at: "", status: "pending", step: "check", step_status: "running", error_code: "", error_message: "", error_debug: ""}' \
            > "$path"
    else
        cat > "$path" <<EOF
{"operation_id":"$op_id","object_id":"$object_id","object_type":"$object_type","target_version":"$target_version","previous_version":"$previous_version","started_at":"$started_at","completed_at":"","status":"pending","step":"check","step_status":"running","error_code":"","error_message":"","error_debug":""}
EOF
    fi
    echo "$op_id"
}

update_op_set_status() {
    local op_id="$1"
    local status="$2"
    local step="${3:-}"
    local step_status="${4:-}"
    local path
    path="$(update_op_path "$op_id")"
    [ -f "$path" ] || return 1
    if command -v jq >/dev/null 2>&1; then
        local tmp
        tmp="$(mktemp)"
        jq --arg s "$status" --arg st "$step" --arg ss "$step_status" \
            '.status = $s | if $st != "" then .step = $st else . end | if $ss != "" then .step_status = $ss else . end' \
            "$path" > "$tmp" && mv "$tmp" "$path"
    fi
}

update_op_set_error() {
    local op_id="$1"
    local error_code="$2"
    local error_message="$3"
    local error_debug="${4:-}"
    local path
    path="$(update_op_path "$op_id")"
    [ -f "$path" ] || return 1
    local completed_at
    completed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
    if command -v jq >/dev/null 2>&1; then
        local tmp
        tmp="$(mktemp)"
        jq --arg ec "$error_code" --arg em "$error_message" --arg ed "$error_debug" --arg ca "$completed_at" \
            '.error_code = $ec | .error_message = $em | .error_debug = $ed | .completed_at = $ca' \
            "$path" > "$tmp" && mv "$tmp" "$path"
    fi
}

update_op_complete() {
    local op_id="$1"
    local path
    path="$(update_op_path "$op_id")"
    [ -f "$path" ] || return 1
    local completed_at
    completed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
    if command -v jq >/dev/null 2>&1; then
        local tmp
        tmp="$(mktemp)"
        jq --arg ca "$completed_at" '.completed_at = $ca | .status = "completed" | .step_status = "ok"' "$path" > "$tmp" && mv "$tmp" "$path"
    fi
}

# User-facing error messages (T005)
update_error_user_message() {
    local code="$1"
    case "$code" in
        $ERROR_CHECK_PREREQ) echo "Проверка предварительных условий не пройдена." ;;
        $ERROR_CHECK_AVAILABILITY) echo "Источник обновления недоступен." ;;
        $ERROR_APPLY_GENERIC) echo "Ошибка применения обновления." ;;
        $ERROR_APPLY_WRITE) echo "Не удалось записать новые файлы." ;;
        $ERROR_VERIFY_HEALTH) echo "Проверка работоспособности после обновления не пройдена." ;;
        $ERROR_VERIFY_VERSION) echo "Версия после обновления не соответствует целевой." ;;
        $ERROR_ROLLBACK_RESTORE) echo "Откат к предыдущей версии не выполнен." ;;
        *) echo "Неизвестная ошибка обновления." ;;
    esac
}

# --- T003: Transactional framework ---
# Executes: check -> apply -> verify; on failure in apply/verify: rollback

run_update_transaction() {
    local object_id="$1"
    local object_type="$2"
    local target_version="$3"
    local check_fn="$4"   # fn(object_id, target_version) -> 0 or exit
    local apply_fn="$5"   # fn(object_id, target_version, previous_version) -> 0 or exit
    local verify_fn="$6"  # fn(object_id, target_version) -> 0 or exit
    local rollback_fn="$7" # fn(object_id, previous_version) -> 0 or exit

    local current_version
    current_version="$(version_record_get_current "$object_id" || true)"
    [ -z "$current_version" ] && current_version="0.0.0"

    # T004: Idempotency - already at target
    if [ "$current_version" = "$target_version" ]; then
        echo "UPDATE_IDEMPOTENT: объект $object_id уже на версии $target_version"
        return 0
    fi

    local op_id
    op_id="$(update_op_create "$object_id" "$object_type" "$target_version" "$current_version")"

    _run_update_do_rollback() {
        local err=$?
        set +e
        update_op_set_status "$op_id" "$update_op_status_verifying" "rollback" "running"
        if $rollback_fn "$object_id" "$current_version"; then
            update_op_set_status "$op_id" "$update_op_status_rolled_back" "rollback" "ok"
        else
            update_op_set_error "$op_id" "$ERROR_ROLLBACK_RESTORE" "$(update_error_user_message "$ERROR_ROLLBACK_RESTORE")" "rollback_fn failed"
            update_op_set_status "$op_id" "$update_op_status_failed" "rollback" "failed"
        fi
        exit "$err"
    }

    # CHECK
    update_op_set_status "$op_id" "$update_op_status_pending" "check" "running"
    if ! $check_fn "$object_id" "$target_version"; then
        update_op_set_error "$op_id" "$ERROR_CHECK_PREREQ" "$(update_error_user_message "$ERROR_CHECK_PREREQ")" "check_fn failed"
        update_op_set_status "$op_id" "$update_op_status_failed" "check" "failed"
        return 1
    fi
    update_op_set_status "$op_id" "$update_op_status_check_ok" "check" "ok"

    # APPLY (trap rollback on failure)
    update_op_set_status "$op_id" "$update_op_status_applying" "apply" "running"
    trap _run_update_do_rollback ERR
    $apply_fn "$object_id" "$target_version" "$current_version"
    update_op_set_status "$op_id" "$update_op_status_apply_ok" "apply" "ok"

    # VERIFY
    update_op_set_status "$op_id" "$update_op_status_verifying" "verify" "running"
    if ! $verify_fn "$object_id" "$target_version"; then
        update_op_set_error "$op_id" "$ERROR_VERIFY_HEALTH" "$(update_error_user_message "$ERROR_VERIFY_HEALTH")" "verify_fn failed"
        $rollback_fn "$object_id" "$current_version" || true
        update_op_set_status "$op_id" "$update_op_status_rolled_back" "rollback" "ok"
        trap - ERR
        return 1
    fi
    trap - ERR
    update_op_set_status "$op_id" "$update_op_status_verify_ok" "verify" "ok"

    version_record_write "$object_id" "$object_type" "$target_version" ""
    update_op_complete "$op_id"
    return 0
}
