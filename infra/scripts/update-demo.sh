#!/bin/bash
# WP01 smoke demo: success path, failure path, idempotency.
# Uses update-lib.sh transactional framework.
set -eEuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Use temp dir for demo to avoid polluting real state
export HOSTCTL_STATE_DIR="${HOSTCTL_STATE_DIR:-/tmp/update-demo-state-$$}"
source "$SCRIPT_DIR/update-lib.sh"

DEMO_OBJECT_ID="demo-counter"
DEMO_OBJECT_TYPE="internal_app"

# Demo apply: writes version to a file
_demo_check() {
    local object_id="$1" target_version="$2"
    [ -n "$target_version" ] || return 1
    return 0
}

_demo_apply() {
    local object_id="$1" target_version="$2" _prev="$3"
    local f="$HOSTCTL_STATE_DIR/${object_id}.version"
    mkdir -p "$(dirname "$f")"
    echo "$target_version" > "$f"
    return 0
}

_demo_verify() {
    local object_id="$1" target_version="$2"
    local f="$HOSTCTL_STATE_DIR/${object_id}.version"
    [ -f "$f" ] && [ "$(cat "$f")" = "$target_version" ]
}

_demo_rollback() {
    local object_id="$1" previous_version="$2"
    local f="$HOSTCTL_STATE_DIR/${object_id}.version"
    if [ -n "$previous_version" ]; then
        echo "$previous_version" > "$f"
    else
        rm -f "$f"
    fi
    return 0
}

# Demo apply that fails (for smoke failure path)
_demo_apply_fail() {
    local object_id="$1" target_version="$2" _prev="$3"
    # Simulate failure when target is "fail-me"
    if [ "$target_version" = "fail-me" ]; then
        echo "Simulated apply failure" >&2
        return 1
    fi
    _demo_apply "$object_id" "$target_version" "$_prev"
}

main() {
    local mode="${1:-success}"
    mkdir -p "$HOSTCTL_STATE_DIR"
    mkdir -p "$VERSION_REGISTRY_DIR" "$UPDATE_OPS_DIR"

    case "$mode" in
        success)
            echo "=== Smoke: success path ==="
            run_update_transaction "$DEMO_OBJECT_ID" "$DEMO_OBJECT_TYPE" "1.0.0" \
                _demo_check _demo_apply _demo_verify _demo_rollback
            echo "OK: success path passed"
            ;;
        idempotent)
            echo "=== Smoke: idempotency ==="
            run_update_transaction "$DEMO_OBJECT_ID" "$DEMO_OBJECT_TYPE" "1.0.0" \
                _demo_check _demo_apply _demo_verify _demo_rollback
            run_update_transaction "$DEMO_OBJECT_ID" "$DEMO_OBJECT_TYPE" "1.0.0" \
                _demo_check _demo_apply _demo_verify _demo_rollback
            echo "OK: idempotency passed (second run skipped)"
            ;;
        failure)
            echo "=== Smoke: failure + rollback ==="
            if run_update_transaction "$DEMO_OBJECT_ID" "$DEMO_OBJECT_TYPE" "fail-me" \
                _demo_check _demo_apply_fail _demo_verify _demo_rollback 2>/dev/null; then
                echo "FAIL: expected transaction to fail" >&2
                exit 1
            fi
            echo "OK: failure path triggered rollback"
            ;;
        *)
            echo "Usage: $0 success|idempotent|failure"
            exit 1
            ;;
    esac
}

main "$@"
