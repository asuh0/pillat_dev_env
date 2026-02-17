#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(dirname "$SCRIPT_DIR")"
INFRA_DIR="$(dirname "$SCRIPTS_DIR")"
DEV_DIR="$(dirname "$INFRA_DIR")"
PROJECTS_DIR="$DEV_DIR/projects"
HOSTCTL_SCRIPT="$SCRIPTS_DIR/hostctl.sh"

MODE="all" # all|sequential|parallel|legacy
DB_TYPE="mysql"
KEEP_HOSTS=0
REPORT_FILE=""

CHECK_COUNT=0
FAIL_COUNT=0
declare -a CREATED_HOSTS=()
declare -a RESULT_LINES=()
RAN_SEQUENTIAL=0
RAN_PARALLEL=0
RAN_LEGACY=0

RUN_PREFIX="v008chk-$(date +%s)-$RANDOM"

usage() {
    cat <<'EOF'
Usage:
  verify-db-topology-v008.sh [--mode all|sequential|parallel|legacy] [--db mysql|postgres] [--report <file>] [--keep-hosts]

Description:
  Acceptance helper for Feature 008 DB topology policy.
  Verifies:
    - sequential multi-host create without conflicts
    - parallel create stress without conflicts
    - legacy no-auto-conversion guard (strategy_mode=legacy)

Examples:
  ./infra/scripts/acceptance/verify-db-topology-v008.sh
  ./infra/scripts/acceptance/verify-db-topology-v008.sh --mode parallel --db postgres
  ./infra/scripts/acceptance/verify-db-topology-v008.sh --report infra/scripts/acceptance/feature-008-db-topology-acceptance.md
EOF
}

say() {
    echo "[v008-acceptance] $*"
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

host_exists() {
    local host="$1"
    [ -d "$PROJECTS_DIR/$host" ]
}

add_created_host() {
    local host="$1"
    local candidate=""
    for candidate in "${CREATED_HOSTS[@]:-}"; do
        if [ "$candidate" = "$host" ]; then
            return 0
        fi
    done
    CREATED_HOSTS+=("$host")
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

project_env_file() {
    local host="$1"
    local project_dir="$PROJECTS_DIR/$host"
    if [ -f "$project_dir/.env" ]; then
        echo "$project_dir/.env"
        return 0
    fi
    if [ -f "$project_dir/.env.example" ]; then
        echo "$project_dir/.env.example"
        return 0
    fi
    echo ""
}

projection_row_for_host() {
    local host="$1"
    local status_out=""
    local row=""

    status_out="$(HOSTCTL_HOSTS_MODE=skip "$HOSTCTL_SCRIPT" status --host "$host" 2>/dev/null || true)"
    row="$(printf "%s\n" "$status_out" | awk -v host="$host" '
        /^DB Projection:/ {in_block=1; next}
        in_block && $1 == host { print; found=1; exit }
        END { if (!found) exit 1 }
    ' 2>/dev/null || true)"
    echo "$row"
}

create_host_no_start() {
    local host="$1"
    local db_type="$2"
    local log_file=""
    log_file="$(mktemp)"

    if HOSTCTL_HOSTS_MODE=skip "$HOSTCTL_SCRIPT" create "$host" --preset empty --db "$db_type" --no-start --hosts-mode skip >"$log_file" 2>&1; then
        add_created_host "$host"
        record_pass "create --no-start succeeds for $host"
        rm -f "$log_file"
        return 0
    fi

    record_fail "create --no-start failed for $host"
    awk 'NR<=120 { print }' "$log_file" >&2 || true
    rm -f "$log_file"
    return 1
}

validate_policy_v008_for_hosts() {
    local host_a="$1"
    local host_b="$2"
    local label="$3"
    local env_a=""
    local env_b=""
    local service_a=""
    local service_b=""
    local port_a=""
    local port_b=""
    local row_a=""
    local row_b=""
    local strategy_a=""
    local strategy_b=""
    local meta_status_a=""
    local meta_status_b=""

    env_a="$(project_env_file "$host_a")"
    env_b="$(project_env_file "$host_b")"

    if [ -z "$env_a" ] || [ -z "$env_b" ]; then
        record_fail "$label: env files must exist for both hosts"
        return 1
    fi

    service_a="$(env_get_key "$env_a" "DB_SERVICE_NAME")"
    service_b="$(env_get_key "$env_b" "DB_SERVICE_NAME")"
    port_a="$(env_get_key "$env_a" "DB_EXTERNAL_PORT")"
    port_b="$(env_get_key "$env_b" "DB_EXTERNAL_PORT")"

    if [[ "$service_a" =~ ^db-[a-z0-9-]+$ ]]; then
        record_pass "$label: $host_a DB_SERVICE_NAME follows db-<host_slug>"
    else
        record_fail "$label: $host_a DB_SERVICE_NAME invalid ('$service_a')"
    fi
    if [[ "$service_b" =~ ^db-[a-z0-9-]+$ ]]; then
        record_pass "$label: $host_b DB_SERVICE_NAME follows db-<host_slug>"
    else
        record_fail "$label: $host_b DB_SERVICE_NAME invalid ('$service_b')"
    fi

    if [ -n "$service_a" ] && [ "$service_a" != "$service_b" ]; then
        record_pass "$label: DB service names are unique"
    else
        record_fail "$label: DB service names conflict ($service_a vs $service_b)"
    fi

    if [[ "$port_a" =~ ^[0-9]+$ ]] && [ "$port_a" -ge 1 ] && [ "$port_a" -le 65535 ]; then
        record_pass "$label: $host_a DB_EXTERNAL_PORT is valid ($port_a)"
    else
        record_fail "$label: $host_a DB_EXTERNAL_PORT invalid ('$port_a')"
    fi
    if [[ "$port_b" =~ ^[0-9]+$ ]] && [ "$port_b" -ge 1 ] && [ "$port_b" -le 65535 ]; then
        record_pass "$label: $host_b DB_EXTERNAL_PORT is valid ($port_b)"
    else
        record_fail "$label: $host_b DB_EXTERNAL_PORT invalid ('$port_b')"
    fi

    if [ -n "$port_a" ] && [ "$port_a" != "$port_b" ]; then
        record_pass "$label: DB external ports are unique"
    else
        record_fail "$label: DB external ports conflict ($port_a vs $port_b)"
    fi

    row_a="$(projection_row_for_host "$host_a")"
    row_b="$(projection_row_for_host "$host_b")"
    if [ -z "$row_a" ] || [ -z "$row_b" ]; then
        record_fail "$label: status DB Projection rows must be present for both hosts"
        return 1
    fi

    strategy_a="$(printf "%s\n" "$row_a" | awk '{print $NF}')"
    strategy_b="$(printf "%s\n" "$row_b" | awk '{print $NF}')"
    meta_status_a="$(printf "%s\n" "$row_a" | awk '{print $(NF-2)}')"
    meta_status_b="$(printf "%s\n" "$row_b" | awk '{print $(NF-2)}')"

    if [ "$strategy_a" = "policy_v008" ] && [ "$strategy_b" = "policy_v008" ]; then
        record_pass "$label: strategy_mode reported as policy_v008 for both hosts"
    else
        record_fail "$label: strategy_mode mismatch ($strategy_a, $strategy_b)"
    fi

    if [ "$meta_status_a" = "ok" ] && [ "$meta_status_b" = "ok" ]; then
        record_pass "$label: db_meta_status=ok for both hosts"
    else
        record_fail "$label: db_meta_status expected ok (got $meta_status_a, $meta_status_b)"
    fi

    return 0
}

run_sequential_smoke() {
    local host_a="${RUN_PREFIX}-seq-a.dev"
    local host_b="${RUN_PREFIX}-seq-b.dev"

    say "Running sequential smoke scenario..."
    create_host_no_start "$host_a" "$DB_TYPE" || return 1
    create_host_no_start "$host_b" "$DB_TYPE" || return 1
    validate_policy_v008_for_hosts "$host_a" "$host_b" "sequential"
}

run_parallel_stress() {
    local host_a="${RUN_PREFIX}-par-a.dev"
    local host_b="${RUN_PREFIX}-par-b.dev"
    local log_a=""
    local log_b=""
    local pid_a=""
    local pid_b=""
    local rc_a=1
    local rc_b=1

    say "Running parallel create stress scenario..."
    log_a="$(mktemp)"
    log_b="$(mktemp)"

    set +e
    HOSTCTL_HOSTS_MODE=skip "$HOSTCTL_SCRIPT" create "$host_a" --preset empty --db "$DB_TYPE" --no-start --hosts-mode skip >"$log_a" 2>&1 &
    pid_a=$!
    HOSTCTL_HOSTS_MODE=skip "$HOSTCTL_SCRIPT" create "$host_b" --preset empty --db "$DB_TYPE" --no-start --hosts-mode skip >"$log_b" 2>&1 &
    pid_b=$!

    wait "$pid_a"; rc_a=$?
    wait "$pid_b"; rc_b=$?
    set -e

    if host_exists "$host_a"; then add_created_host "$host_a"; fi
    if host_exists "$host_b"; then add_created_host "$host_b"; fi

    if [ "$rc_a" -eq 0 ]; then
        record_pass "parallel: create succeeds for $host_a"
    else
        record_fail "parallel: create failed for $host_a"
        awk 'NR<=120 { print }' "$log_a" >&2 || true
    fi

    if [ "$rc_b" -eq 0 ]; then
        record_pass "parallel: create succeeds for $host_b"
    else
        record_fail "parallel: create failed for $host_b"
        awk 'NR<=120 { print }' "$log_b" >&2 || true
    fi

    rm -f "$log_a" "$log_b"

    if [ "$rc_a" -ne 0 ] || [ "$rc_b" -ne 0 ]; then
        return 1
    fi

    validate_policy_v008_for_hosts "$host_a" "$host_b" "parallel"
}

run_legacy_guard_check() {
    local host="${RUN_PREFIX}-legacy.dev"
    local project_dir="$PROJECTS_DIR/$host"
    local env_file=""
    local compose_file=""
    local value=""
    local row=""
    local strategy=""
    local meta_status=""
    local service_name=""
    local log_start=""
    local log_stop=""

    say "Running legacy no-auto-conversion guard check..."
    create_host_no_start "$host" "mysql" || return 1

    python3 - "$project_dir" <<'PY'
import pathlib
import re
import sys

project_dir = pathlib.Path(sys.argv[1])
legacy_port = "3306"

primary_env = project_dir / ".env"
if primary_env.exists():
    for raw in primary_env.read_text(encoding="utf-8").splitlines():
        if raw.startswith("DB_EXTERNAL_PORT="):
            candidate = raw.split("=", 1)[1].strip()
            if candidate.isdigit():
                legacy_port = candidate
            break

for env_name in (".env", ".env.example"):
    env_path = project_dir / env_name
    if not env_path.exists():
        continue
    lines = env_path.read_text(encoding="utf-8").splitlines()
    filtered = []
    for line in lines:
        if line.startswith("DB_BIND_ADDRESS="):
            continue
        if line.startswith("DB_EXTERNAL_PORT="):
            continue
        if line.startswith("DB_SERVICE_NAME="):
            continue
        if line.startswith("DB_NAME="):
            continue
        filtered.append(line)
    env_path.write_text("\n".join(filtered).rstrip() + "\n", encoding="utf-8")

compose_path = project_dir / "docker-compose.yml"
if compose_path.exists():
    text = compose_path.read_text(encoding="utf-8")
    text = re.sub(r"(?m)^  db-[a-z0-9-]+:\s*$", "  mysql:", text, count=1)
    text = re.sub(
        r'(?m)^(\s*-\s*")[^"]*:3306(")\s*$',
        lambda m: f'{m.group(1)}{legacy_port}:3306{m.group(2)}',
        text,
        count=1
    )
    compose_path.write_text(text, encoding="utf-8")
PY

    log_start="$(mktemp)"
    log_stop="$(mktemp)"

    if HOSTCTL_HOSTS_MODE=skip "$HOSTCTL_SCRIPT" start "$host" >"$log_start" 2>&1; then
        record_pass "legacy: host start succeeds after legacy-style metadata fallback"
    else
        record_fail "legacy: host start failed"
        awk 'NR<=120 { print }' "$log_start" >&2 || true
        rm -f "$log_start" "$log_stop"
        return 1
    fi

    if HOSTCTL_HOSTS_MODE=skip "$HOSTCTL_SCRIPT" stop "$host" >"$log_stop" 2>&1; then
        record_pass "legacy: host stop succeeds after legacy-style metadata fallback"
    else
        record_fail "legacy: host stop failed"
        awk 'NR<=120 { print }' "$log_stop" >&2 || true
        rm -f "$log_start" "$log_stop"
        return 1
    fi

    rm -f "$log_start" "$log_stop"

    env_file="$(project_env_file "$host")"
    compose_file="$project_dir/docker-compose.yml"

    value="$(env_get_key "$env_file" "DB_SERVICE_NAME")"
    if [ -z "$value" ]; then
        record_pass "legacy: DB_SERVICE_NAME stays absent (no auto-conversion)"
    else
        record_fail "legacy: DB_SERVICE_NAME unexpectedly restored ('$value')"
    fi

    if awk '/^  mysql:[[:space:]]*$/{found=1} END{exit !found}' "$compose_file"; then
        record_pass "legacy: compose keeps mysql service name"
    else
        record_fail "legacy: compose mysql service name is missing after start/stop"
    fi

    if awk '/^  db-[a-z0-9-]+:[[:space:]]*$/{found=1} END{exit !found}' "$compose_file"; then
        record_fail "legacy: compose unexpectedly converted back to db-<slug>"
    else
        record_pass "legacy: compose remains without db-<slug> auto-conversion"
    fi

    row="$(projection_row_for_host "$host")"
    if [ -z "$row" ]; then
        record_fail "legacy: DB projection row must exist"
        return 1
    fi

    strategy="$(printf "%s\n" "$row" | awk '{print $NF}')"
    meta_status="$(printf "%s\n" "$row" | awk '{print $(NF-2)}')"
    service_name="$(printf "%s\n" "$row" | awk '{print $3}')"

    if [ "$strategy" = "legacy" ]; then
        record_pass "legacy: strategy_mode is legacy"
    else
        record_fail "legacy: strategy_mode expected legacy, got '$strategy'"
    fi

    if [ "$service_name" = "mysql" ]; then
        record_pass "legacy: DB service projection remains mysql"
    else
        record_fail "legacy: DB service projection expected mysql, got '$service_name'"
    fi

    if [ "$meta_status" = "ok" ]; then
        record_pass "legacy: db_meta_status remains ok"
    else
        record_fail "legacy: db_meta_status expected ok, got '$meta_status'"
    fi

    return 0
}

write_report() {
    local target="$1"
    local timestamp=""
    local mode_text=""
    local db_text=""
    local summary_status="PASS"
    local line=""

    [ -n "$target" ] || return 0

    timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    mode_text="$MODE"
    db_text="$DB_TYPE"
    if [ "$FAIL_COUNT" -gt 0 ]; then
        summary_status="FAIL"
    fi

    {
        echo "# Feature 008 Acceptance Report"
        echo
        echo "- Generated at: $timestamp"
        echo "- Mode: $mode_text"
        echo "- DB type (sequential/parallel): $db_text"
        echo "- Total checks: $CHECK_COUNT"
        echo "- Failed checks: $FAIL_COUNT"
        echo "- Overall: $summary_status"
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
        if [ "$RAN_LEGACY" -eq 1 ]; then
            echo "- Legacy guard validated via simulated legacy metadata (no DB_* policy keys)."
        else
            echo "- Legacy guard scenario was not executed in this run mode."
        fi
        if [ "$RAN_SEQUENTIAL" -eq 1 ] || [ "$RAN_PARALLEL" -eq 1 ]; then
            echo "- Policy-v008 checks validate db-<host_slug>, unique DB external ports, and status projection."
        else
            echo "- Sequential/parallel policy-v008 scenarios were not executed in this run mode."
        fi
        echo "- Script source: \`infra/scripts/acceptance/verify-db-topology-v008.sh\`."
    } > "$target"

    say "Report written to $target"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --mode)
            [ "$#" -ge 2 ] || { echo "Missing value for --mode"; exit 1; }
            MODE="$2"
            shift 2
            ;;
        --db)
            [ "$#" -ge 2 ] || { echo "Missing value for --db"; exit 1; }
            DB_TYPE="$2"
            shift 2
            ;;
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

case "$MODE" in
    all|sequential|parallel|legacy) ;;
    *)
        echo "Unsupported --mode '$MODE'. Allowed: all, sequential, parallel, legacy."
        exit 1
        ;;
esac

case "$DB_TYPE" in
    mysql|postgres) ;;
    *)
        echo "Unsupported --db '$DB_TYPE'. Allowed: mysql, postgres."
        exit 1
        ;;
esac

if [ ! -x "$HOSTCTL_SCRIPT" ]; then
    echo "hostctl script not executable or not found: $HOSTCTL_SCRIPT"
    exit 1
fi

if [ "$MODE" = "all" ] || [ "$MODE" = "sequential" ]; then
    RAN_SEQUENTIAL=1
    run_sequential_smoke || true
fi

if [ "$MODE" = "all" ] || [ "$MODE" = "parallel" ]; then
    RAN_PARALLEL=1
    run_parallel_stress || true
fi

if [ "$MODE" = "all" ] || [ "$MODE" = "legacy" ]; then
    RAN_LEGACY=1
    run_legacy_guard_check || true
fi

write_report "$REPORT_FILE"

say "Checks completed: $CHECK_COUNT, failures: $FAIL_COUNT"
if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi

exit 0
