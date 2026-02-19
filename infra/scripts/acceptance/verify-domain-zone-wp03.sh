#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(dirname "$SCRIPT_DIR")"
INFRA_DIR="$(dirname "$SCRIPTS_DIR")"
DEV_DIR="$(dirname "$INFRA_DIR")"

HOSTCTL_SCRIPT="$SCRIPTS_DIR/hostctl.sh"
HOSTS_SCRIPT="$SCRIPTS_DIR/manage-hosts.sh"
DOMAIN_ZONE_HELPER="$SCRIPTS_DIR/domain-zone.sh"
STATE_DIR="${HOSTCTL_STATE_DIR:-$INFRA_DIR/state}"
PROJECTS_DIR="$DEV_DIR/projects"
REGISTRY_FILE="$STATE_DIR/hosts-registry.tsv"

REPORT_FILE="$SCRIPT_DIR/feature-010-wp03-cli-canonical-lifecycle-acceptance.md"
KEEP_HOSTS=0

CHECK_COUNT=0
FAIL_COUNT=0
declare -a CREATED_HOSTS=()
declare -a RESULT_LINES=()

RUN_PREFIX="f010wp03-$(date +%s)-$RANDOM"

usage() {
    cat <<'EOF'
Usage:
  verify-domain-zone-wp03.sh [--report <path>] [--keep-hosts]

Description:
  WP03 acceptance helper for feature 010 (host lifecycle + canonical domain operations).
  Validates:
    - short-host canonicalization in create/start/stop/delete/status
    - full-host scenario in active zone
    - collision and foreign suffix guards
    - manage-hosts add/remove/check/list with active DOMAIN_SUFFIX (using test hosts file)
EOF
}

say() {
    echo "[f010-wp03] $*"
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

resolve_domain_suffix() {
    if [ ! -f "$DOMAIN_ZONE_HELPER" ]; then
        echo ""
        return 1
    fi

    # shellcheck source=/dev/null
    source "$DOMAIN_ZONE_HELPER"
    dz_resolve_domain_suffix "${DOMAIN_SUFFIX:-}" "$INFRA_DIR/.env.global" "$INFRA_DIR/.env.global.example"
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

registry_has_host() {
    local host="$1"
    [ -f "$REGISTRY_FILE" ] || return 1
    awk -F'\t' -v host="$host" '$1 == host {found=1} END {exit !found}' "$REGISTRY_FILE"
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

run_checks() {
    local suffix=""
    local host_seed=""
    local short_host=""
    local canonical_short_host=""
    local full_host=""
    local foreign_host=""
    local temp_hosts_file=""
    local output=""
    local rc=0

    suffix="$(resolve_domain_suffix || true)"
    if [ -z "$suffix" ]; then
        record_fail "DOMAIN_SUFFIX отсутствует или невалиден в .env.global/.env.global.example"
        return 1
    fi
    record_pass "DOMAIN_SUFFIX валиден: $suffix"

    host_seed="$(printf "%s" "$RUN_PREFIX" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
    short_host="${host_seed:0:24}"
    [ -n "$short_host" ] || short_host="f010wp03"
    canonical_short_host="${short_host}.${suffix}"
    full_host="${short_host}-full.${suffix}"
    foreign_host="${short_host}.dev"
    if [ "$suffix" = "dev" ]; then
        foreign_host="${short_host}.legacy"
    fi

    temp_hosts_file="$(mktemp)"
    {
        echo "127.0.0.1 localhost"
        echo "::1 localhost"
    } > "$temp_hosts_file"

    if HOSTS_FILE="$temp_hosts_file" "$HOSTS_SCRIPT" add "$short_host" >/dev/null 2>&1; then
        record_pass "manage-hosts add принимает short-host и нормализует его"
    else
        record_fail "manage-hosts add short-host завершился ошибкой"
    fi

    if HOSTS_FILE="$temp_hosts_file" "$HOSTS_SCRIPT" check "$canonical_short_host" >/dev/null 2>&1; then
        record_pass "manage-hosts check видит канонический домен"
    else
        record_fail "manage-hosts check не находит канонический домен"
    fi

    if HOSTS_FILE="$temp_hosts_file" "$HOSTS_SCRIPT" list | awk -v host="$canonical_short_host" 'index($0, host) > 0 {found=1} END{exit !found}'; then
        record_pass "manage-hosts list выводит канонический домен"
    else
        record_fail "manage-hosts list не выводит канонический домен"
    fi

    if HOSTS_FILE="$temp_hosts_file" "$HOSTS_SCRIPT" remove "$short_host" >/dev/null 2>&1; then
        record_pass "manage-hosts remove принимает short-host"
    else
        record_fail "manage-hosts remove short-host завершился ошибкой"
    fi

    set +e
    HOSTS_FILE="$temp_hosts_file" "$HOSTS_SCRIPT" check "$canonical_short_host" >/dev/null 2>&1
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
        record_pass "manage-hosts check корректно сообщает об отсутствии после remove"
    else
        record_fail "manage-hosts check вернул успех после remove"
    fi
    rm -f "$temp_hosts_file"

    if HOSTCTL_HOSTS_MODE=skip "$HOSTCTL_SCRIPT" create "$short_host" --preset empty --no-start --hosts-mode skip >/tmp/f010wp03-create-short.log 2>&1; then
        add_created_host "$canonical_short_host"
        record_pass "hostctl create short-host succeeds: $short_host -> $canonical_short_host"
    else
        record_fail "hostctl create short-host failed"
        awk 'NR<=120 {print}' /tmp/f010wp03-create-short.log >&2 || true
        rm -f /tmp/f010wp03-create-short.log
        return 1
    fi
    rm -f /tmp/f010wp03-create-short.log

    if host_exists "$canonical_short_host"; then
        record_pass "создан каталог проекта с каноническим именем"
    else
        record_fail "каталог канонического проекта не найден"
    fi

    if registry_has_host "$canonical_short_host"; then
        record_pass "реестр содержит канонический host"
    else
        record_fail "реестр не содержит канонический host"
    fi

    set +e
    output="$(HOSTCTL_HOSTS_MODE=skip "$HOSTCTL_SCRIPT" status --host "$short_host" 2>&1)"
    rc=$?
    set -e
    if [ "$rc" -eq 0 ] && printf "%s\n" "$output" | awk -v host="$canonical_short_host" 'index($0, host) > 0 {found=1} END{exit !found}'; then
        record_pass "status --host short-host показывает канонический host"
    else
        record_fail "status --host short-host не показывает канонический host"
    fi

    if HOSTCTL_HOSTS_MODE=skip "$HOSTCTL_SCRIPT" start "$short_host" >/tmp/f010wp03-start.log 2>&1; then
        record_pass "start short-host succeeds"
    else
        record_fail "start short-host failed"
        awk 'NR<=120 {print}' /tmp/f010wp03-start.log >&2 || true
    fi
    rm -f /tmp/f010wp03-start.log

    set +e
    output="$(HOSTCTL_HOSTS_MODE=skip "$HOSTCTL_SCRIPT" status --host "$canonical_short_host" 2>&1)"
    rc=$?
    set -e
    if [ "$rc" -eq 0 ] && printf "%s\n" "$output" | awk -v host="$canonical_short_host" '$1 == host && index($0, "running") > 0 {found=1} END{exit !found}'; then
        record_pass "status отражает running для канонического host после start"
    else
        record_fail "status не отражает running после start"
    fi

    if HOSTCTL_HOSTS_MODE=skip "$HOSTCTL_SCRIPT" stop "$canonical_short_host" >/tmp/f010wp03-stop.log 2>&1; then
        record_pass "stop canonical-host succeeds"
    else
        record_fail "stop canonical-host failed"
        awk 'NR<=120 {print}' /tmp/f010wp03-stop.log >&2 || true
    fi
    rm -f /tmp/f010wp03-stop.log

    if HOSTCTL_HOSTS_MODE=skip "$HOSTCTL_SCRIPT" create "$full_host" --preset empty --no-start --hosts-mode skip >/tmp/f010wp03-create-full.log 2>&1; then
        add_created_host "$full_host"
        record_pass "create full-host в активной зоне succeeds"
    else
        record_fail "create full-host в активной зоне failed"
        awk 'NR<=120 {print}' /tmp/f010wp03-create-full.log >&2 || true
    fi
    rm -f /tmp/f010wp03-create-full.log

    set +e
    HOSTCTL_HOSTS_MODE=skip "$HOSTCTL_SCRIPT" create "$canonical_short_host" --preset empty --no-start --hosts-mode skip >/tmp/f010wp03-collision.log 2>&1
    rc=$?
    set -e
    if [ "$rc" -ne 0 ] && awk 'index($0, "already exists") > 0 {found=1} END{exit !found}' /tmp/f010wp03-collision.log; then
        record_pass "collision guard срабатывает для канонического имени"
    else
        record_fail "collision guard не сработал для канонического имени"
    fi
    rm -f /tmp/f010wp03-collision.log

    set +e
    HOSTCTL_HOSTS_MODE=skip "$HOSTCTL_SCRIPT" create "$foreign_host" --preset empty --no-start --hosts-mode skip >/tmp/f010wp03-foreign.log 2>&1
    rc=$?
    set -e
    if [ "$rc" -ne 0 ] && awk 'index($0, "Error[foreign_suffix]") > 0 {found=1} END{exit !found}' /tmp/f010wp03-foreign.log; then
        record_pass "foreign suffix отклоняется с Error[foreign_suffix]"
    else
        record_fail "foreign suffix не отклонен ожидаемым Error[foreign_suffix]"
    fi
    rm -f /tmp/f010wp03-foreign.log

    if HOSTCTL_HOSTS_MODE=skip "$HOSTCTL_SCRIPT" delete "$short_host" --yes >/tmp/f010wp03-delete-short.log 2>&1; then
        record_pass "delete short-host resolves to canonical и succeeds"
    else
        record_fail "delete short-host failed"
        awk 'NR<=120 {print}' /tmp/f010wp03-delete-short.log >&2 || true
    fi
    rm -f /tmp/f010wp03-delete-short.log

    if HOSTCTL_HOSTS_MODE=skip "$HOSTCTL_SCRIPT" delete "$full_host" --yes >/tmp/f010wp03-delete-full.log 2>&1; then
        record_pass "delete full-host succeeds"
    else
        record_fail "delete full-host failed"
        awk 'NR<=120 {print}' /tmp/f010wp03-delete-full.log >&2 || true
    fi
    rm -f /tmp/f010wp03-delete-full.log

    if ! host_exists "$canonical_short_host" && ! host_exists "$full_host"; then
        record_pass "каталоги проектов удалены после delete"
    else
        record_fail "после delete остались каталоги проектов"
    fi

    if ! registry_has_host "$canonical_short_host" && ! registry_has_host "$full_host"; then
        record_pass "реестр очищен после delete"
    else
        record_fail "реестр содержит host после delete"
    fi
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
        echo "# Feature 010 WP03 Acceptance Report"
        echo
        echo "- Generated at: $timestamp"
        echo "- Scope: WP03 (T013-T018)"
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
        echo "- Validation sources: \`infra/scripts/hostctl.sh\`, \`infra/scripts/create-project.sh\`, \`infra/scripts/manage-hosts.sh\`."
        echo "- Execution helper: \`infra/scripts/acceptance/verify-domain-zone-wp03.sh\`."
        echo "- manage-hosts проверяется на временном hosts-файле через \`HOSTS_FILE=<tmp>\`."
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
