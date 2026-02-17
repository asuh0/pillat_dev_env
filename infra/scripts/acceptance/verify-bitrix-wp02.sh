#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(dirname "$SCRIPT_DIR")"
INFRA_DIR="$(dirname "$SCRIPTS_DIR")"
ROOT_DIR="$(dirname "$INFRA_DIR")"
HOSTCTL_SCRIPT="$SCRIPTS_DIR/hostctl.sh"

STATE_DIR="${HOSTCTL_STATE_DIR:-$INFRA_DIR/state}"
PROJECTS_DIR="$ROOT_DIR/projects"
REPORT_FILE="$SCRIPT_DIR/feature-005-wp02-cli-flow-acceptance.md"
KEEP_HOSTS=0

CHECK_COUNT=0
FAIL_COUNT=0
declare -a CREATED_HOSTS=()
declare -a RESULT_LINES=()

RUN_PREFIX="f005wp02-$(date +%s)-$RANDOM"
CORE_SLUG="${RUN_PREFIX//[^a-z0-9]/-}"
CORE_SLUG="${CORE_SLUG:0:24}"
CORE_SLUG="${CORE_SLUG%-}"

CORE_ID="core-$CORE_SLUG"
CORE_HOST="${RUN_PREFIX}-core.dev"
LINK_HOST="${RUN_PREFIX}-link.dev"
INVALID_HOST="${RUN_PREFIX}-invalid.dev"

usage() {
    cat <<'EOF'
Usage:
  verify-bitrix-wp02.sh [--report <path>] [--keep-hosts]

Description:
  WP02 acceptance helper for feature 005.
  Validates CLI flow:
    - create args --bitrix-type/--core
    - interactive link creation
    - link flow symlinks + no dedicated DB
    - delete guards core/link
    - status projection for bitrix type and core_id
EOF
}

say() {
    echo "[f005-wp02] $*"
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

registry_field_for_host() {
    local host="$1"
    local field="$2"
    local file="$STATE_DIR/hosts-registry.tsv"
    [ -f "$file" ] || { echo ""; return 0; }
    awk -F'\t' -v host="$host" -v field="$field" '
        $1 == host { print $field; found=1; exit }
        END { if (!found) print "" }
    ' "$file"
}

binding_core_for_host() {
    local host="$1"
    local file="$STATE_DIR/bitrix-bindings.tsv"
    [ -f "$file" ] || { echo ""; return 0; }
    awk -F'\t' -v host="$host" '
        $1 == host { print $2; found=1; exit }
        END { if (!found) print "" }
    ' "$file"
}

core_owner_for_core_id() {
    local core_id="$1"
    local file="$STATE_DIR/bitrix-core-registry.tsv"
    [ -f "$file" ] || { echo ""; return 0; }
    awk -F'\t' -v core="$core_id" '
        $1 == core { print $2; found=1; exit }
        END { if (!found) print "" }
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

expect_fail_with_code() {
    local expected_code="$1"
    shift

    local output=""
    local rc=0
    set +e
    output="$("$@" 2>&1)"
    rc=$?
    set -e

    if [ "$rc" -eq 0 ]; then
        record_fail "command should fail with Error[$expected_code]"
        return 1
    fi

    if [[ "$output" == *"Error[$expected_code]"* ]]; then
        record_pass "command fails with Error[$expected_code]"
        return 0
    fi

    record_fail "command failed without expected Error[$expected_code]"
    printf "%s\n" "$output" | awk 'NR<=80 {print}' >&2 || true
    return 1
}

extract_status_row() {
    local host="$1"
    local status_out=""
    status_out="$(HOSTCTL_HOSTS_MODE=skip "$HOSTCTL_SCRIPT" status --host "$host" 2>/dev/null || true)"
    printf "%s\n" "$status_out" | awk -v host="$host" '$1 == host {print; found=1; exit} END {if (!found) exit 1}'
}

validate_link_compose_without_db() {
    local compose_file="$1"

    if awk '/^  (mysql|postgres|db-[a-z0-9-]+):[[:space:]]*$/{found=1} END{exit found ? 1 : 0}' "$compose_file"; then
        record_pass "link compose contains no dedicated DB service"
    else
        record_fail "link compose still contains dedicated DB service"
    fi
}

run_checks() {
    local env_file=""
    local value=""
    local row=""
    local compose_file=""
    local link_src="$PROJECTS_DIR/$LINK_HOST/src"

    mkdir -p "$STATE_DIR"
    touch "$STATE_DIR/hosts-registry.tsv" "$STATE_DIR/bitrix-core-registry.tsv" "$STATE_DIR/bitrix-bindings.tsv"

    say "Running WP02 CLI flow validation..."

    # T007: args compatibility/validation
    expect_fail_with_code "invalid_core" \
        env HOSTCTL_HOSTS_MODE=skip "$HOSTCTL_SCRIPT" create "$INVALID_HOST" \
            --preset empty --core "$CORE_ID" --no-start --hosts-mode skip

    # T007 + T009 baseline: create core via explicit args
    if HOSTCTL_HOSTS_MODE=skip "$HOSTCTL_SCRIPT" create "$CORE_HOST" \
        --preset bitrix --bitrix-type kernel --core-id "$CORE_ID" \
        --php 8.2 --db mysql --no-start --hosts-mode skip; then
        add_created_host "$CORE_HOST"
        record_pass "core create with --bitrix-type/--core-id succeeds"
    else
        record_fail "core create with explicit args failed"
        return 1
    fi

    # T008: interactive flow for link + core selection.
    if printf '\n\nbitrix\n\n\n\n\n\n\nn\nlink\n%s\n' "$CORE_ID" | \
       HOSTCTL_HOSTS_MODE=skip "$HOSTCTL_SCRIPT" create "$LINK_HOST" --interactive --hosts-mode skip >/tmp/f005-wp02-link.log 2>&1; then
        add_created_host "$LINK_HOST"
        record_pass "interactive link create succeeds with core selection"
    else
        record_fail "interactive link create failed"
        awk 'NR<=120 {print}' /tmp/f005-wp02-link.log >&2 || true
        rm -f /tmp/f005-wp02-link.log
        return 1
    fi
    rm -f /tmp/f005-wp02-link.log

    # T009/T010: link flow artifacts.
    env_file="$(project_env_file "$LINK_HOST")"
    if [ -n "$env_file" ]; then
        value="$(env_get_key "$env_file" "BITRIX_TYPE")"
        [ "$value" = "link" ] && record_pass "BITRIX_TYPE=link persisted for link host" || record_fail "BITRIX_TYPE mismatch for link host"
        value="$(env_get_key "$env_file" "BITRIX_CORE_ID")"
        [ "$value" = "$CORE_ID" ] && record_pass "BITRIX_CORE_ID persisted for link host" || record_fail "BITRIX_CORE_ID mismatch for link host"
    else
        record_fail "env file missing for link host"
    fi

    if [ -L "$link_src/bitrix" ] && [ -L "$link_src/upload" ] && [ -L "$link_src/images" ]; then
        record_pass "link shared paths are symlinks (bitrix/upload/images)"
    else
        record_fail "link shared paths symlink set is incomplete"
    fi

    if [ -d "$link_src/local" ] && [ ! -L "$link_src/local" ]; then
        record_pass "link local path stays site-specific"
    else
        record_fail "link local path is not site-specific directory"
    fi

    if [ ! -d "$PROJECTS_DIR/$LINK_HOST/db-mysql" ] && [ ! -d "$PROJECTS_DIR/$LINK_HOST/db-postgres" ]; then
        record_pass "link host has no dedicated DB data dirs"
    else
        record_fail "link host still has dedicated DB data dirs"
    fi

    compose_file="$PROJECTS_DIR/$LINK_HOST/docker-compose.yml"
    validate_link_compose_without_db "$compose_file"

    # T012: status projection.
    row="$(extract_status_row "$CORE_HOST" || true)"
    if [ -n "$row" ] && [ "$(printf "%s\n" "$row" | awk '{print $5}')" = "kernel" ] && [ "$(printf "%s\n" "$row" | awk '{print $6}')" = "$CORE_ID" ]; then
        record_pass "status shows kernel core type/core_id for core host"
    else
        record_fail "status projection mismatch for core host"
    fi

    row="$(extract_status_row "$LINK_HOST" || true)"
    if [ -n "$row" ] && [ "$(printf "%s\n" "$row" | awk '{print $5}')" = "link" ] && [ "$(printf "%s\n" "$row" | awk '{print $6}')" = "$CORE_ID" ]; then
        record_pass "status shows link type/core_id for link host"
    else
        record_fail "status projection mismatch for link host"
    fi

    # Registry checks support T009/T010/T012.
    value="$(registry_field_for_host "$LINK_HOST" 6)"
    [ "$value" = "link" ] && record_pass "hosts registry keeps bitrix_type for link" || record_fail "hosts registry type mismatch for link"
    value="$(registry_field_for_host "$LINK_HOST" 7)"
    [ "$value" = "$CORE_ID" ] && record_pass "hosts registry keeps core_id for link" || record_fail "hosts registry core_id mismatch for link"

    value="$(binding_core_for_host "$LINK_HOST")"
    [ "$value" = "$CORE_ID" ] && record_pass "bindings registry contains link->core row" || record_fail "bindings registry row missing for link"

    value="$(core_owner_for_core_id "$CORE_ID")"
    [ "$value" = "$CORE_HOST" ] && record_pass "core registry contains owner host for core_id" || record_fail "core registry owner mismatch"

    # T011: delete guards.
    expect_fail_with_code "delete_guard" \
        env HOSTCTL_HOSTS_MODE=skip "$HOSTCTL_SCRIPT" delete "$CORE_HOST" --yes

    if HOSTCTL_HOSTS_MODE=skip "$HOSTCTL_SCRIPT" delete "$LINK_HOST" --yes; then
        record_pass "delete link host succeeds"
    else
        record_fail "delete link host failed"
    fi

    if HOSTCTL_HOSTS_MODE=skip "$HOSTCTL_SCRIPT" delete "$CORE_HOST" --yes; then
        record_pass "delete core host succeeds after link removal"
    else
        record_fail "delete core host failed after link removal"
    fi

    if [ -z "$(registry_field_for_host "$LINK_HOST" 1)" ] && [ -z "$(registry_field_for_host "$CORE_HOST" 1)" ]; then
        record_pass "hosts registry cleaned after delete flow"
    else
        record_fail "hosts registry still has deleted hosts"
    fi

    if [ -z "$(binding_core_for_host "$LINK_HOST")" ]; then
        record_pass "bindings registry cleaned after link delete"
    else
        record_fail "bindings registry still contains deleted link"
    fi

    if [ -z "$(core_owner_for_core_id "$CORE_ID")" ]; then
        record_pass "core registry cleaned after core delete"
    else
        record_fail "core registry still contains deleted core_id"
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
        echo "# Feature 005 WP02 Acceptance Report"
        echo
        echo "- Generated at: $timestamp"
        echo "- Scope: WP02 (T007-T012)"
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
        echo "- Validation source: \`infra/scripts/hostctl.sh\`."
        echo "- Execution helper: \`infra/scripts/acceptance/verify-bitrix-wp02.sh\`."
        echo "- Hosts are created with \`--no-start\` or interactive \`start=n\` to validate control flow deterministically."
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
