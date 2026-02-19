#!/usr/bin/env bash
# Feature 010 WP01: Local domain policy and canonical hostname foundation - acceptance checks

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(dirname "$SCRIPT_DIR")"
INFRA_DIR="$(dirname "$SCRIPTS_DIR")"
DOMAIN_ZONE_HELPER="$SCRIPTS_DIR/domain-zone.sh"
HOSTCTL_SCRIPT="$SCRIPTS_DIR/hostctl.sh"

PASS=0
FAIL=0

pass() { echo "[f010-wp01] PASS: $1"; ((PASS++)) || true; }
fail() { echo "[f010-wp01] FAIL: $1"; ((FAIL++)) || true; }

# T001: Resolver + validation for DOMAIN_SUFFIX
if [ ! -f "$DOMAIN_ZONE_HELPER" ]; then
    fail "domain-zone.sh не найден"
else
    pass "domain-zone.sh существует"
fi

# shellcheck source=/dev/null
source "$DOMAIN_ZONE_HELPER"

suffix="$(dz_resolve_domain_suffix "${DOMAIN_SUFFIX:-}" "$INFRA_DIR/.env.global" "$INFRA_DIR/.env.global.example" "loc" 2>/dev/null)" || suffix=""
if [ -n "$suffix" ]; then
    pass "T001: dz_resolve_domain_suffix возвращает валидный суффикс: $suffix"
else
    fail "T001: dz_resolve_domain_suffix не вернул суффикс (проверьте infra/.env.global)"
fi

# T002: Canonicalization short -> canonical
if [ -n "$suffix" ]; then
    canon="$(dz_canonicalize_host "test" "$suffix" "create" 2>/dev/null)" || canon=""
    if [ "$canon" = "test.$suffix" ]; then
        pass "T002: short-host 'test' канонизируется в test.$suffix"
    else
        fail "T002: short-host канонизация дала: $canon"
    fi

    # T002: already canonical passes
    canon2="$(dz_canonicalize_host "test.$suffix" "$suffix" "create" 2>/dev/null)" || canon2=""
    if [ "$canon2" = "test.$suffix" ]; then
        pass "T002: полный домен test.$suffix принимается без изменений"
    else
        fail "T002: полный домен канонизация дала: $canon2"
    fi

    # T004: foreign suffix rejected in create mode
    if dz_canonicalize_host "test.dev" "$suffix" "create" 2>/dev/null; then
        fail "T004: foreign suffix test.dev не должен приниматься при create"
    else
        pass "T004: foreign suffix блокируется в create mode"
    fi
fi

# T003/T005: hostctl uses resolve and canonicalize (status без ошибки invalid_domain_suffix)
if [ -f "$HOSTCTL_SCRIPT" ] && [ -n "$suffix" ]; then
    if HOSTCTL_HOSTS_MODE=skip "$HOSTCTL_SCRIPT" status 2>&1 | grep -q "invalid_domain_suffix\|Не задан DOMAIN_SUFFIX"; then
        fail "T003: hostctl status падает с invalid_domain_suffix"
    else
        pass "T003: hostctl status использует resolve_domain_suffix без ошибки"
    fi
fi

echo ""
echo "[f010-wp01] Итого: $PASS passed, $FAIL failed"
exit $([ "$FAIL" -eq 0 ] && exit 0 || exit 1)
