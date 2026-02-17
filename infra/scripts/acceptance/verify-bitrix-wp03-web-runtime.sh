#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(dirname "$SCRIPT_DIR")"
INFRA_DIR="$(dirname "$SCRIPTS_DIR")"
ROOT_DIR="$(dirname "$INFRA_DIR")"

HOSTCTL_SCRIPT="$SCRIPTS_DIR/hostctl.sh"
REPORT_FILE="$SCRIPT_DIR/feature-005-wp03-web-runtime-acceptance.md"
KEEP_HOSTS=0

CHECK_COUNT=0
FAIL_COUNT=0
declare -a RESULT_LINES=()

DEVPANEL_CONTAINER=""
RUN_PREFIX="f005wp03-$(date +%s)-$RANDOM"
CORE_HOST="${RUN_PREFIX}-core.dev"
LINK_HOST="${RUN_PREFIX}-link.dev"
CORE_ID="core-${RUN_PREFIX//[^a-z0-9]/-}"
CORE_ID="${CORE_ID:0:40}"
CORE_ID="${CORE_ID%-}"

usage() {
    cat <<'EOF'
Usage:
  verify-bitrix-wp03-web-runtime.sh [--report <path>] [--keep-hosts]

Description:
  Functional web acceptance for feature 005 / WP03.
  Validates:
    - devpanel startup with external-disk fallback
    - create kernel/link via web POST
    - status projection for bitrix_type/core_id
    - delete guard for core with active bindings
    - successful delete order: link -> core
EOF
}

say() {
    echo "[f005-wp03-runtime] $*"
}

record_pass() {
    local message="$1"
    CHECK_COUNT=$((CHECK_COUNT + 1))
    RESULT_LINES+=("PASS|$message")
    say "PASS: $message"
}

record_fail() {
    local message="$1"
    CHECK_COUNT=$((CHECK_COUNT + 1))
    FAIL_COUNT=$((FAIL_COUNT + 1))
    RESULT_LINES+=("FAIL|$message")
    say "FAIL: $message"
}

cleanup_hosts() {
    [ "$KEEP_HOSTS" -eq 1 ] && return 0
    [ -n "$DEVPANEL_CONTAINER" ] || return 0
    docker exec "$DEVPANEL_CONTAINER" sh -lc "/scripts/hostctl.sh delete '$LINK_HOST' --yes >/dev/null 2>&1 || true"
    docker exec "$DEVPANEL_CONTAINER" sh -lc "/scripts/hostctl.sh delete '$CORE_HOST' --yes >/dev/null 2>&1 || true"
}

trap cleanup_hosts EXIT

ensure_infra() {
    local output=""
    if output="$(HOSTCTL_HOSTS_MODE=skip "$HOSTCTL_SCRIPT" infra-start 2>&1)"; then
        printf "%s\n" "$output" >/tmp/f005-wp03-infra-start.log
        record_pass "infra-start succeeds (native or fallback mode)"
        return 0
    fi

    printf "%s\n" "$output" >/tmp/f005-wp03-infra-start.log
    record_fail "infra-start failed"
    awk 'NR<=120 {print}' /tmp/f005-wp03-infra-start.log >&2 || true
    return 1
}

detect_devpanel_container() {
    if docker ps --format '{{.Names}}' | awk '$1=="devpanel-fallback"{found=1} END{exit !found}'; then
        DEVPANEL_CONTAINER="devpanel-fallback"
        record_pass "devpanel fallback container is running"
        return 0
    fi
    if docker ps --format '{{.Names}}' | awk '$1=="devpanel"{found=1} END{exit !found}'; then
        DEVPANEL_CONTAINER="devpanel"
        record_pass "devpanel container is running"
        return 0
    fi

    record_fail "devpanel container is not running"
    return 1
}

status_row_for_host() {
    local host="$1"
    local out=""
    out="$(docker exec "$DEVPANEL_CONTAINER" sh -lc "/scripts/hostctl.sh status --host '$host' 2>/dev/null" || true)"
    printf "%s\n" "$out" | awk -v host="$host" '$1 == host {print; found=1; exit} END { if (!found) exit 1 }'
}

project_exists_in_devpanel() {
    local host="$1"
    docker exec "$DEVPANEL_CONTAINER" sh -lc "[ -d '/projects/$host' ]"
}

web_post_create() {
    local host="$1"
    local bitrix_type="$2"
    local core_id="$3"
    local out_file="$4"

    docker exec "$DEVPANEL_CONTAINER" sh -lc "
        curl -sS -L -o '$out_file' -w '%{http_code}' -X POST http://127.0.0.1/index.php \
          --data-urlencode 'action=create' \
          --data-urlencode 'project_name=$host' \
          --data-urlencode 'php_version=8.2' \
          --data-urlencode 'db_type=mysql' \
          --data-urlencode 'preset=bitrix' \
          --data-urlencode 'bitrix_type=$bitrix_type' \
          --data-urlencode 'core_id=$core_id'
    "
}

web_post_delete() {
    local host="$1"
    local out_file="$2"

    docker exec "$DEVPANEL_CONTAINER" sh -lc "
        curl -sS -L -o '$out_file' -w '%{http_code}' -X POST http://127.0.0.1/index.php \
          --data-urlencode 'action=delete' \
          --data-urlencode 'project_name=$host'
    "
}

run_checks() {
    local code=""
    local row=""

    ensure_infra || return 1
    detect_devpanel_container || return 1

    code="$(docker exec "$DEVPANEL_CONTAINER" sh -lc "curl -sS -o /tmp/f005-wp03-index.html -w '%{http_code}' http://127.0.0.1/index.php")"
    if [ "$code" = "200" ]; then
        record_pass "devpanel HTTP endpoint responds 200"
    else
        record_fail "devpanel HTTP endpoint returned $code"
        return 1
    fi

    code="$(web_post_create "$CORE_HOST" "kernel" "$CORE_ID" "/tmp/f005-wp03-core-create.html")"
    if [ "$code" = "200" ] || [ "$code" = "302" ]; then
        record_pass "web create kernel request completed"
    else
        record_fail "web create kernel request failed (HTTP $code)"
        return 1
    fi

    if project_exists_in_devpanel "$CORE_HOST"; then
        record_pass "kernel project directory created via web flow"
    else
        record_fail "kernel project directory missing after web create"
    fi

    row="$(status_row_for_host "$CORE_HOST" || true)"
    if [ -n "$row" ] && [ "$(printf "%s\n" "$row" | awk '{print $5}')" = "kernel" ] && [ "$(printf "%s\n" "$row" | awk '{print $6}')" = "$CORE_ID" ]; then
        record_pass "status shows kernel host with expected core_id"
    else
        record_fail "status mismatch for kernel host"
    fi

    code="$(web_post_create "$LINK_HOST" "link" "$CORE_ID" "/tmp/f005-wp03-link-create.html")"
    if [ "$code" = "200" ] || [ "$code" = "302" ]; then
        record_pass "web create link request completed"
    else
        record_fail "web create link request failed (HTTP $code)"
        return 1
    fi

    if project_exists_in_devpanel "$LINK_HOST"; then
        record_pass "link project directory created via web flow"
    else
        record_fail "link project directory missing after web create"
    fi

    row="$(status_row_for_host "$LINK_HOST" || true)"
    if [ -n "$row" ] && [ "$(printf "%s\n" "$row" | awk '{print $5}')" = "link" ] && [ "$(printf "%s\n" "$row" | awk '{print $6}')" = "$CORE_ID" ]; then
        record_pass "status shows link host with expected core_id"
    else
        record_fail "status mismatch for link host"
    fi

    code="$(web_post_delete "$CORE_HOST" "/tmp/f005-wp03-core-delete-guard.html")"
    if [ "$code" = "200" ] || [ "$code" = "302" ]; then
        record_pass "web delete core request returns response under active binding"
    else
        record_fail "web delete core request failed unexpectedly (HTTP $code)"
    fi

    if project_exists_in_devpanel "$CORE_HOST"; then
        record_pass "core delete guard keeps core project intact"
    else
        record_fail "core project deleted despite active link binding"
    fi

    if docker exec "$DEVPANEL_CONTAINER" sh -lc "awk 'BEGIN{IGNORECASE=1} /заблок|delete_guard/{found=1} END{exit !found}' /tmp/f005-wp03-core-delete-guard.html"; then
        record_pass "web response includes explanatory delete-guard message"
    else
        record_fail "web response lacks delete-guard explanation"
    fi

    code="$(web_post_delete "$LINK_HOST" "/tmp/f005-wp03-link-delete.html")"
    if [ "$code" = "200" ] || [ "$code" = "302" ]; then
        record_pass "web delete link request completed"
    else
        record_fail "web delete link request failed (HTTP $code)"
    fi

    if ! project_exists_in_devpanel "$LINK_HOST"; then
        record_pass "link project removed after delete"
    else
        record_fail "link project still exists after delete"
    fi

    code="$(web_post_delete "$CORE_HOST" "/tmp/f005-wp03-core-delete-final.html")"
    if [ "$code" = "200" ] || [ "$code" = "302" ]; then
        record_pass "web delete core request completed after link removal"
    else
        record_fail "web delete core request failed after link removal (HTTP $code)"
    fi

    if ! project_exists_in_devpanel "$CORE_HOST"; then
        record_pass "core project removed after link cleanup"
    else
        record_fail "core project still exists after final delete"
    fi
}

write_report() {
    local timestamp=""
    local overall="PASS"
    local line=""

    timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    if [ "$FAIL_COUNT" -gt 0 ]; then
        overall="FAIL"
    fi

    {
        echo "# Feature 005 WP03 Runtime Web Acceptance Report"
        echo
        echo "- Generated at: $timestamp"
        echo "- Scope: WP03 runtime checks (including external-disk fallback startup)"
        echo "- Total checks: $CHECK_COUNT"
        echo "- Failed checks: $FAIL_COUNT"
        echo "- Overall: $overall"
        echo
        echo "## Check Results"
        echo
        for line in "${RESULT_LINES[@]:-}"; do
            if [[ "$line" == PASS\|* ]]; then
                echo "- [x] ${line#PASS|}"
            else
                echo "- [ ] ${line#FAIL|}"
            fi
        done
        echo
        echo "## Notes"
        echo
        echo "- Web checks run via curl inside \`$DEVPANEL_CONTAINER\`."
        echo "- Infra startup executed through \`infra/scripts/hostctl.sh infra-start\`."
        echo "- Test hosts: \`$CORE_HOST\`, \`$LINK_HOST\`, core_id=\`$CORE_ID\`."
    } > "$REPORT_FILE"

    say "Report written to $REPORT_FILE"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --report)
            [ "$#" -ge 2 ] || { echo "Missing value for --report"; exit 1; }
            REPORT_FILE="$2"
            shift 2
            ;;
        --keep-hosts)
            KEEP_HOSTS=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

run_checks || true
write_report
say "Checks completed: $CHECK_COUNT, failures: $FAIL_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
exit 0
