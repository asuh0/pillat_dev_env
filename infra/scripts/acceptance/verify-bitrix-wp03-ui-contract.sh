#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(dirname "$SCRIPT_DIR")"
INFRA_DIR="$(dirname "$SCRIPTS_DIR")"
ROOT_DIR="$(dirname "$INFRA_DIR")"

INDEX_FILE="$INFRA_DIR/devpanel/src/index.php"
REPORT_FILE="$SCRIPT_DIR/feature-005-wp03-ui-contract-acceptance.md"

CHECK_COUNT=0
FAIL_COUNT=0
declare -a RESULT_LINES=()

usage() {
    cat <<'EOF'
Usage:
  verify-bitrix-wp03-ui-contract.sh [--report <path>]

Description:
  WP03 acceptance helper for feature 005 (web UI parity).
  Performs static contract checks against DevPanel source:
    - create form fields for bitrix_type/core_id
    - backend mapping to CLI args --bitrix-type/--core/--core-id
    - UI rendering of bitrix type + core links
    - UI/handler delete guard behavior
EOF
}

say() {
    echo "[f005-wp03] $*"
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

check_pattern() {
    local description="$1"
    local pattern="$2"

    if rg --version >/dev/null 2>&1; then
        if rg -n --pcre2 "$pattern" "$INDEX_FILE" >/dev/null 2>&1; then
            record_pass "$description"
        else
            record_fail "$description"
        fi
    else
        if grep -E -n "$pattern" "$INDEX_FILE" >/dev/null 2>&1; then
            record_pass "$description"
        else
            record_fail "$description"
        fi
    fi
}

run_checks() {
    if [ ! -f "$INDEX_FILE" ]; then
        record_fail "devpanel index.php must exist"
        return
    fi

    # T013/T014: create form fields for bitrix type and core_id.
    check_pattern "create form includes bitrix_type select" 'name="bitrix_type"'
    check_pattern "bitrix type option kernel present" '<option value="kernel"'
    check_pattern "bitrix type option ext_kernel present" '<option value="ext_kernel"'
    check_pattern "bitrix type option link present" '<option value="link"'
    check_pattern "create form includes core_id input" 'name="core_id"'

    # T015: backend maps web payload to CLI contract.
    check_pattern "backend appends --bitrix-type to hostctl command" '\$cmdParts\[\] = '\''--bitrix-type'\'';'
    check_pattern "backend validates link requires core_id" "Для link-хоста требуется указать core_id"
    check_pattern "backend appends --core for link create" '\$cmdParts\[\] = '\''--core'\'';'
    check_pattern "backend appends --core-id for kernel/ext_kernel create" '\$cmdParts\[\] = '\''--core-id'\'';'

    # T016/T017: UI projection + delete guard.
    check_pattern "metadata computes deleteBlocked from bitrix links" '\$deleteBlocked = count\(\$linkedHosts\) > 0;'
    check_pattern "card renders bitrix type field" "Bitrix type:"
    check_pattern "card renders core id field" "Core ID:"
    check_pattern "delete button disabled when deleteBlocked" "deleteBlocked \\? 'disabled"
    check_pattern "delete warning message rendered for blocked core" "Удаление этого core-хоста заблокировано"

    # Server-side guard propagation to UI message.
    check_pattern "delete handler recognizes Error\\[delete_guard\\]" 'Error\\\[delete_guard\\\]'
    check_pattern "delete handler returns warning for delete_guard" "'reason' => 'delete_guard'"

    # Registry integration for UI view-model.
    check_pattern "backend parses bitrix core registry" "function parseBitrixCoreRegistry"
    check_pattern "backend parses bitrix bindings registry" "function parseBitrixBindingsRegistry"
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
        echo "# Feature 005 WP03 Acceptance Report"
        echo
        echo "- Generated at: $timestamp"
        echo "- Scope: WP03 (T013-T017 static contract checks)"
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
        echo "- Validation source: \`infra/devpanel/src/index.php\`."
        echo "- Execution helper: \`infra/scripts/acceptance/verify-bitrix-wp03-ui-contract.sh\`."
        echo "- This report validates source-level web contract; runtime browser smoke is tracked separately."
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

run_checks
write_report
say "Checks completed: $CHECK_COUNT, failures: $FAIL_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
exit 0
