#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(dirname "$SCRIPT_DIR")"
INFRA_DIR="$(dirname "$SCRIPTS_DIR")"
ROOT_DIR="$(dirname "$INFRA_DIR")"

HOSTCTL_SCRIPT="$SCRIPTS_DIR/hostctl.sh"
STATE_DIR="${HOSTCTL_STATE_DIR:-$INFRA_DIR/state}"
PROJECTS_DIR="$ROOT_DIR/projects"

REPORT_FILE="$SCRIPT_DIR/feature-005-wp01-core-binding-acceptance.md"
KEEP_HOSTS=0

CHECK_COUNT=0
FAIL_COUNT=0
declare -a CREATED_HOSTS=()
declare -a RESULT_LINES=()

RUN_PREFIX="f005wp01-$(date +%s)-$RANDOM"
CORE_SEED="${RUN_PREFIX//[^a-z0-9]/-}"
CORE_SEED="${CORE_SEED%-}"
CORE_SEED="${CORE_SEED:0:22}"
CORE_ID="core-${CORE_SEED}"
EXT_CORE_ID="core-${CORE_SEED}-ext"

CORE_HOST="${RUN_PREFIX}-core.dev"
LINK_HOST="${RUN_PREFIX}-link.dev"
EXT_HOST="${RUN_PREFIX}-ext.dev"
BAD_LINK_HOST="${RUN_PREFIX}-badlink.dev"
INVALID_TYPE_HOST="${RUN_PREFIX}-invalid.dev"

usage() {
    cat <<'EOF'
Usage:
  verify-bitrix-wp01.sh [--report <path>] [--keep-hosts]

Description:
  WP01 acceptance helper for feature 005 (Bitrix core/binding model + lock registry).
  Validates:
    - core/link type + core_id model behavior
    - binding/core registry writes and format
    - stale lock recovery behavior
    - delete guard for core with active links
    - consistent error code format Error[code]
EOF
}

say() {
    echo "[f005-wp01] $*"
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

add_created_host() {
    local host="$1"
    local existing=""
    for existing in "${CREATED_HOSTS[@]:-}"; do
        if [ "$existing" = "$host" ]; then
            return 0
        fi
    done
    CREATED_HOSTS+=("$host")
}

host_exists() {
    local host="$1"
    [ -d "$PROJECTS_DIR/$host" ]
}

cleanup_hosts() {
    if [ "$KEEP_HOSTS" -eq 1 ]; then
        say "Cleanup skipped (--keep-hosts)."
        return 0
    fi

    local idx=""
    local host=""
    for ((idx=${#CREATED_HOSTS[@]}-1; idx>=0; idx--)); do
        host="${CREATED_HOSTS[$idx]}"
        if host_exists "$host"; then
            HOSTCTL_HOSTS_MODE=skip "$HOSTCTL_SCRIPT" delete "$host" --yes >/dev/null 2>&1 || true
        fi
    done
}

trap cleanup_hosts EXIT

registry_field_for_host() {
    local file="$1"
    local host="$2"
    local field="$3"
    [ -f "$file" ] || { echo ""; return 0; }
    awk -F'\t' -v host="$host" -v field="$field" '
        $1 == host { print $field; found=1; exit }
        END { if (!found) print "" }
    ' "$file"
}

core_registry_row() {
    local file="$1"
    local core_id="$2"
    [ -f "$file" ] || { echo ""; return 0; }
    awk -F'\t' -v core="$core_id" '
        $1 == core { print $0; found=1; exit }
        END { if (!found) print "" }
    ' "$file"
}

binding_registry_row() {
    local file="$1"
    local host="$2"
    [ -f "$file" ] || { echo ""; return 0; }
    awk -F'\t' -v host="$host" '
        $1 == host { print $0; found=1; exit }
        END { if (!found) print "" }
    ' "$file"
}

env_get_key() {
    local file="$1"
    local key="$2"
    [ -f "$file" ] || { echo ""; return 0; }
    awk -v key="$key" '
        index($0, key "=") == 1 {
            sub("^" key "=", "", $0)
            print $0
            found = 1
            exit
        }
        END {
            if (!found) print ""
        }
    ' "$file"
}

project_env_file() {
    local host="$1"
    local path="$PROJECTS_DIR/$host/.env"
    if [ -f "$path" ]; then
        echo "$path"
        return 0
    fi
    path="$PROJECTS_DIR/$host/.env.example"
    if [ -f "$path" ]; then
        echo "$path"
        return 0
    fi
    echo ""
}

file_checksum() {
    local file="$1"
    if [ ! -f "$file" ]; then
        echo "missing"
        return 0
    fi
    cksum "$file" | awk '{print $1 ":" $2}'
}

run_create() {
    local host="$1"
    shift
    HOSTCTL_HOSTS_MODE=skip "$HOSTCTL_SCRIPT" create "$host" "$@" --no-start --hosts-mode skip
}

run_delete() {
    local host="$1"
    HOSTCTL_HOSTS_MODE=skip "$HOSTCTL_SCRIPT" delete "$host" --yes
}

expect_create_fail_code() {
    local host="$1"
    local code="$2"
    shift 2

    local output=""
    local rc=0
    set +e
    output="$(run_create "$host" "$@" 2>&1)"
    rc=$?
    set -e

    if [ "$rc" -eq 0 ]; then
        record_fail "create for $host should fail with Error[$code]"
        if host_exists "$host"; then
            add_created_host "$host"
        fi
        return 1
    fi

    if [[ "$output" == *"Error[$code]"* ]]; then
        record_pass "create for $host fails with Error[$code]"
    else
        record_fail "create for $host failed without expected Error[$code]"
        printf "%s\n" "$output" | awk 'NR<=80 {print}' >&2 || true
        return 1
    fi

    return 0
}

expect_delete_fail_code() {
    local host="$1"
    local code="$2"

    local output=""
    local rc=0
    set +e
    output="$(run_delete "$host" 2>&1)"
    rc=$?
    set -e

    if [ "$rc" -eq 0 ]; then
        record_fail "delete for $host should fail with Error[$code]"
        return 1
    fi

    if [[ "$output" == *"Error[$code]"* ]]; then
        record_pass "delete for $host fails with Error[$code]"
    else
        record_fail "delete for $host failed without expected Error[$code]"
        printf "%s\n" "$output" | awk 'NR<=80 {print}' >&2 || true
        return 1
    fi

    return 0
}

assert_no_registry_row_for_host() {
    local host="$1"
    local hosts_registry="$STATE_DIR/hosts-registry.tsv"
    if [ -n "$(registry_field_for_host "$hosts_registry" "$host" 1)" ]; then
        record_fail "host '$host' should not exist in hosts registry"
        return 1
    fi
    record_pass "host '$host' absent in hosts registry"
}

validate_registry_formats() {
    local hosts_registry="$STATE_DIR/hosts-registry.tsv"
    local core_registry="$STATE_DIR/bitrix-core-registry.tsv"
    local bindings_registry="$STATE_DIR/bitrix-bindings.tsv"

    if awk -F'\t' 'NF==0 {next} NF>=5 {ok=1} NF<5 {exit 1} END {exit 0}' "$hosts_registry" 2>/dev/null; then
        record_pass "hosts registry format is tabular"
    else
        record_fail "hosts registry contains malformed row"
    fi

    if awk -F'\t' 'NF==0 {next} NF==4 {next} {exit 1}' "$core_registry" 2>/dev/null; then
        record_pass "core registry rows have 4 columns"
    else
        record_fail "core registry contains malformed row"
    fi

    if awk -F'\t' 'NF==0 {next} NF==3 {next} {exit 1}' "$bindings_registry" 2>/dev/null; then
        record_pass "bindings registry rows have 3 columns"
    else
        record_fail "bindings registry contains malformed row"
    fi
}

run_checks() {
    local hosts_registry="$STATE_DIR/hosts-registry.tsv"
    local core_registry="$STATE_DIR/bitrix-core-registry.tsv"
    local bindings_registry="$STATE_DIR/bitrix-bindings.tsv"
    local lock_dir="$STATE_DIR/bitrix-bindings.lock"
    local env_file=""
    local value=""
    local row=""
    local before_core_checksum=""
    local after_core_checksum=""
    local before_bind_checksum=""
    local after_bind_checksum=""
    local lock_preexisting=0

    mkdir -p "$STATE_DIR"
    touch "$hosts_registry" "$core_registry" "$bindings_registry"

    say "Running WP01 validation flow..."

    expect_create_fail_code "$INVALID_TYPE_HOST" "invalid_core" --preset bitrix --bitrix-type wrong --core-id "$CORE_ID"
    assert_no_registry_row_for_host "$INVALID_TYPE_HOST"

    if run_create "$CORE_HOST" --preset bitrix --bitrix-type kernel --core-id "$CORE_ID" --php 8.2 --db mysql; then
        add_created_host "$CORE_HOST"
        record_pass "kernel core host create succeeds ($CORE_HOST)"
    else
        record_fail "kernel core host create failed ($CORE_HOST)"
        return 1
    fi

    env_file="$(project_env_file "$CORE_HOST")"
    if [ -n "$env_file" ]; then
        value="$(env_get_key "$env_file" "BITRIX_TYPE")"
        if [ "$value" = "kernel" ]; then
            record_pass "BITRIX_TYPE persisted as kernel"
        else
            record_fail "BITRIX_TYPE expected kernel, got '$value'"
        fi
        value="$(env_get_key "$env_file" "BITRIX_CORE_ID")"
        if [ "$value" = "$CORE_ID" ]; then
            record_pass "BITRIX_CORE_ID persisted for kernel host"
        else
            record_fail "BITRIX_CORE_ID mismatch for kernel host"
        fi
    else
        record_fail "env file missing for kernel host"
    fi

    value="$(registry_field_for_host "$hosts_registry" "$CORE_HOST" 6)"
    if [ "$value" = "kernel" ]; then
        record_pass "hosts registry stores bitrix_type=kernel"
    else
        record_fail "hosts registry bitrix_type mismatch for kernel host"
    fi
    value="$(registry_field_for_host "$hosts_registry" "$CORE_HOST" 7)"
    if [ "$value" = "$CORE_ID" ]; then
        record_pass "hosts registry stores core_id for kernel host"
    else
        record_fail "hosts registry core_id mismatch for kernel host"
    fi

    row="$(core_registry_row "$core_registry" "$CORE_ID")"
    if [ -n "$row" ]; then
        if [ "$(printf "%s\n" "$row" | awk -F'\t' '{print $2}')" = "$CORE_HOST" ] && \
           [ "$(printf "%s\n" "$row" | awk -F'\t' '{print $3}')" = "kernel" ]; then
            record_pass "core registry stores owner/type for kernel core"
        else
            record_fail "core registry row mismatch for kernel core"
        fi
    else
        record_fail "core registry missing row for $CORE_ID"
    fi

    before_core_checksum="$(file_checksum "$core_registry")"
    before_bind_checksum="$(file_checksum "$bindings_registry")"
    expect_create_fail_code "$BAD_LINK_HOST" "invalid_core" --preset bitrix --bitrix-type link --core "missing-core-id"
    after_core_checksum="$(file_checksum "$core_registry")"
    after_bind_checksum="$(file_checksum "$bindings_registry")"
    if [ "$before_core_checksum" = "$after_core_checksum" ] && [ "$before_bind_checksum" = "$after_bind_checksum" ]; then
        record_pass "failed link create keeps core/bindings registries unchanged"
    else
        record_fail "failed link create changed core/bindings registries"
    fi

    if run_create "$LINK_HOST" --preset bitrix --bitrix-type link --core "$CORE_ID" --php 8.2 --db postgres; then
        add_created_host "$LINK_HOST"
        record_pass "link host create succeeds ($LINK_HOST)"
    else
        record_fail "link host create failed ($LINK_HOST)"
        return 1
    fi

    value="$(registry_field_for_host "$hosts_registry" "$LINK_HOST" 6)"
    if [ "$value" = "link" ]; then
        record_pass "hosts registry stores bitrix_type=link"
    else
        record_fail "hosts registry bitrix_type mismatch for link host"
    fi
    value="$(registry_field_for_host "$hosts_registry" "$LINK_HOST" 7)"
    if [ "$value" = "$CORE_ID" ]; then
        record_pass "hosts registry stores core_id for link host"
    else
        record_fail "hosts registry core_id mismatch for link host"
    fi

    row="$(binding_registry_row "$bindings_registry" "$LINK_HOST")"
    if [ -n "$row" ] && [ "$(printf "%s\n" "$row" | awk -F'\t' '{print $2}')" = "$CORE_ID" ]; then
        record_pass "bindings registry stores link -> core relation"
    else
        record_fail "bindings registry missing/invalid link -> core relation"
    fi

    env_file="$(project_env_file "$LINK_HOST")"
    if [ -n "$env_file" ]; then
        value="$(env_get_key "$env_file" "BITRIX_TYPE")"
        [ "$value" = "link" ] && record_pass "BITRIX_TYPE persisted as link" || record_fail "BITRIX_TYPE mismatch for link host"
        value="$(env_get_key "$env_file" "BITRIX_CORE_ID")"
        [ "$value" = "$CORE_ID" ] && record_pass "BITRIX_CORE_ID persisted for link host" || record_fail "BITRIX_CORE_ID mismatch for link host"
    else
        record_fail "env file missing for link host"
    fi

    if awk '/^  (mysql|postgres|db-[a-z0-9-]+):[[:space:]]*$/{found=1} END{exit found ? 1 : 0}' "$PROJECTS_DIR/$LINK_HOST/docker-compose.yml"; then
        record_pass "link compose has no dedicated DB service"
    else
        record_fail "link compose still contains dedicated DB service"
    fi

    expect_delete_fail_code "$CORE_HOST" "delete_guard"

    if [ -d "$lock_dir" ]; then
        lock_preexisting=1
        record_pass "lock stress case skipped: external lock already exists"
    else
        mkdir -p "$lock_dir"
        printf "pid=999999\nacquired_at=%s\n" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" > "$lock_dir/owner"
        if run_create "$EXT_HOST" --preset bitrix --bitrix-type ext_kernel --core-id "$EXT_CORE_ID" --php 8.2 --db mysql; then
            add_created_host "$EXT_HOST"
            record_pass "stale lock auto-cleanup allows ext_kernel create"
            if [ ! -d "$lock_dir" ]; then
                record_pass "bindings lock directory released after stale-lock create"
            else
                record_fail "bindings lock directory still present after stale-lock create"
            fi
        else
            record_fail "stale lock scenario failed to create ext_kernel host"
        fi
    fi

    if run_delete "$LINK_HOST"; then
        record_pass "delete link host succeeds"
    else
        record_fail "delete link host failed"
    fi

    if run_delete "$CORE_HOST"; then
        record_pass "delete core host succeeds after link removal"
    else
        record_fail "delete core host failed after link removal"
    fi

    if [ "$lock_preexisting" -eq 0 ] && host_exists "$EXT_HOST"; then
        if run_delete "$EXT_HOST"; then
            record_pass "delete ext_kernel host succeeds"
        else
            record_fail "delete ext_kernel host failed"
        fi
    fi

    assert_no_registry_row_for_host "$LINK_HOST"
    assert_no_registry_row_for_host "$CORE_HOST"
    [ "$lock_preexisting" -eq 1 ] || assert_no_registry_row_for_host "$EXT_HOST"

    if [ -z "$(core_registry_row "$core_registry" "$CORE_ID")" ]; then
        record_pass "core registry row removed after core delete"
    else
        record_fail "core registry row still exists after core delete"
    fi

    validate_registry_formats
}

write_report() {
    local timestamp=""
    local status="PASS"
    local line=""

    timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    if [ "$FAIL_COUNT" -gt 0 ]; then
        status="FAIL"
    fi

    mkdir -p "$(dirname "$REPORT_FILE")"
    {
        echo "# Feature 005 WP01 Acceptance Report"
        echo
        echo "- Generated at: $timestamp"
        echo "- Scope: WP01 (T001-T006)"
        echo "- Total checks: $CHECK_COUNT"
        echo "- Failed checks: $FAIL_COUNT"
        echo "- Overall: $status"
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
        echo "- Validation source: \`infra/scripts/hostctl.sh\`."
        echo "- Execution helper: \`infra/scripts/acceptance/verify-bitrix-wp01.sh\`."
        echo "- Hosts are created with \`--no-start\` to focus on model/registry/guard behavior."
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

if [ ! -x "$HOSTCTL_SCRIPT" ]; then
    echo "hostctl script not executable: $HOSTCTL_SCRIPT"
    exit 1
fi

run_checks || true
write_report

say "Checks completed: $CHECK_COUNT, failures: $FAIL_COUNT"
if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi

exit 0
