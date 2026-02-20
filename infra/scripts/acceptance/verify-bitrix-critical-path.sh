#!/usr/bin/env bash
# T025: Critical-path autotest: core -> link -> status -> delete-link -> delete-core
# FR-018: обязательный тест для фичи 005

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(dirname "$SCRIPT_DIR")"
INFRA_DIR="$(dirname "$SCRIPTS_DIR")"
ROOT_DIR="$(dirname "$INFRA_DIR")"
HOSTCTL_SCRIPT="$SCRIPTS_DIR/hostctl.sh"

STATE_DIR="${HOSTCTL_STATE_DIR:-$INFRA_DIR/state}"
PROJECTS_DIR="$ROOT_DIR/projects"
REPORT_FILE="$SCRIPT_DIR/feature-005-critical-path-acceptance.md"
KEEP_HOSTS=0

CHECK_COUNT=0
FAIL_COUNT=0
declare -a CREATED_HOSTS=()
declare -a RESULT_LINES=()

RUN_PREFIX="f005cp-$(date +%s)-$RANDOM"
CORE_SLUG="${RUN_PREFIX//[^a-z0-9]/-}"
CORE_SLUG="${CORE_SLUG:0:20}"
CORE_SLUG="${CORE_SLUG%-}"

CORE_ID="core-$CORE_SLUG"
CORE_HOST="${RUN_PREFIX}-core.dev"
LINK_HOST="${RUN_PREFIX}-link.dev"

say() { echo "[f005-critical-path] $*"; }
record_pass() { CHECK_COUNT=$((CHECK_COUNT+1)); RESULT_LINES+=("PASS|$1"); say "PASS: $1"; }
record_fail() { CHECK_COUNT=$((CHECK_COUNT+1)); FAIL_COUNT=$((FAIL_COUNT+1)); RESULT_LINES+=("FAIL|$1"); say "FAIL: $1"; }
add_created_host() { CREATED_HOSTS+=("$1"); }
host_exists() { [ -d "$PROJECTS_DIR/$1" ]; }

cleanup_hosts() {
    if [ "$KEEP_HOSTS" -eq 1 ]; then return 0; fi
    local idx host
    for ((idx=${#CREATED_HOSTS[@]}-1; idx>=0; idx--)); do
        host="${CREATED_HOSTS[$idx]}"
        host_exists "$host" && HOSTCTL_HOSTS_MODE=skip HOSTCTL_STATE_DIR="$STATE_DIR" "$HOSTCTL_SCRIPT" delete "$host" --yes >/dev/null 2>&1 || true
    done
}
trap cleanup_hosts EXIT

expect_fail_with_code() {
    local expected="$1"; shift
    local output="" rc=0
    set +e; output="$("$@" 2>&1)"; rc=$?; set -e
    if [ "$rc" -eq 0 ]; then record_fail "expected Error[$expected]"; return 1; fi
    [[ "$output" == *"Error[$expected]"* ]] && record_pass "delete core blocked with Error[$expected]" || { record_fail "wrong error"; echo "$output" | head -20 >&2; return 1; }
}

status_shows_type() {
    local host="$1" expected_type="$2"
    local out=""
    out="$(HOSTCTL_HOSTS_MODE=skip HOSTCTL_STATE_DIR="$STATE_DIR" "$HOSTCTL_SCRIPT" status --host "$host" 2>/dev/null || true)"
    if printf '%s\n' "$out" | grep -q "$expected_type"; then
        record_pass "status shows $expected_type for $host"
    else
        record_fail "status missing $expected_type for $host"
    fi
}

run_critical_path() {
    mkdir -p "$STATE_DIR"
    touch "$STATE_DIR/hosts-registry.tsv" "$STATE_DIR/bitrix-core-registry.tsv" "$STATE_DIR/bitrix-bindings.tsv"
    export HOSTCTL_HOSTS_MODE=skip
    export HOSTCTL_STATE_DIR="$STATE_DIR"

    say "Critical path: core -> link -> status -> delete-link -> delete-core"

    # 1. create core
    if ! "$HOSTCTL_SCRIPT" create "$CORE_HOST" --preset bitrix --bitrix-type kernel --core-id "$CORE_ID" --php 8.2 --db mysql --no-start; then
        record_fail "core create failed"; return 1
    fi
    add_created_host "$CORE_HOST"
    record_pass "core create succeeds"

    # 2. create link
    if ! "$HOSTCTL_SCRIPT" create "$LINK_HOST" --preset bitrix --bitrix-type link --core "$CORE_ID" --no-start; then
        record_fail "link create failed"; return 1
    fi
    add_created_host "$LINK_HOST"
    record_pass "link create succeeds"

    # 3. status for both
    status_shows_type "$CORE_HOST" "kernel"
    status_shows_type "$LINK_HOST" "link"

    # 4. delete core (must fail — guard)
    expect_fail_with_code "delete_guard" "$HOSTCTL_SCRIPT" delete "$CORE_HOST" --yes

    # 5. delete link
    if "$HOSTCTL_SCRIPT" delete "$LINK_HOST" --yes; then
        record_pass "delete link succeeds"
    else
        record_fail "delete link failed"; return 1
    fi

    # 6. delete core (now allowed)
    if "$HOSTCTL_SCRIPT" delete "$CORE_HOST" --yes; then
        record_pass "delete core succeeds after link removal"
    else
        record_fail "delete core failed"; return 1
    fi

    say "Critical path completed."
}

write_report() {
    local ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")" overall="PASS" line=""
    [ "$FAIL_COUNT" -gt 0 ] && overall="FAIL"
    {
        echo "# Feature 005 Critical Path Acceptance"
        echo "- Generated: $ts | Checks: $CHECK_COUNT | Failures: $FAIL_COUNT | Overall: $overall"
        echo ""
        for line in "${RESULT_LINES[@]:-}"; do
            [[ "$line" == PASS\|* ]] && echo "- [x] ${line#PASS|}" || echo "- [ ] ${line#FAIL|}"
        done
    } > "$REPORT_FILE"
    say "Report: $REPORT_FILE"
}

while [ "$#" -gt 0 ]; do
    case "$1" in --report) REPORT_FILE="$2"; shift 2 ;; --keep-hosts) KEEP_HOSTS=1; shift ;; *) shift ;; esac
done

[ -x "$HOSTCTL_SCRIPT" ] || { echo "hostctl not executable"; exit 1; }
run_critical_path || true
write_report
[ "$FAIL_COUNT" -gt 0 ] && exit 1
exit 0
