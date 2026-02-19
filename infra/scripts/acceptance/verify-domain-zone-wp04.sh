#!/usr/bin/env bash
# Feature 010 WP04: DevPanel web parity for active zone - acceptance checks

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INDEX_PHP="$(dirname "$(dirname "$SCRIPT_DIR")")/devpanel/src/index.php"
REPORT_FILE="$SCRIPT_DIR/feature-010-wp04-devpanel-web-parity-acceptance.md"
PASS=0
FAIL=0
SKIP=0

pass() {
    echo "[f010-wp04] PASS: $1"
    ((PASS++)) || true
}

fail() {
    echo "[f010-wp04] FAIL: $1"
    ((FAIL++)) || true
}

skip() {
    echo "[f010-wp04] SKIP: $1"
    ((SKIP++)) || true
}

if [ ! -f "$INDEX_PHP" ]; then
    echo "[f010-wp04] ERROR: $INDEX_PHP not found" >&2
    exit 1
fi

# T020: No hardcoded .dev in service URLs
if grep -qE 'https://(traefik|adminer|grafana|docker)\.dev' "$INDEX_PHP" 2>/dev/null; then
    fail "index.php содержит hardcoded .dev в URL сервисов"
else
    pass "index.php не содержит hardcoded .dev в URL сервисов"
fi

# T019: devpanel_resolve_domain_suffix exists
if grep -q 'devpanel_resolve_domain_suffix' "$INDEX_PHP"; then
    pass "devpanel_resolve_domain_suffix реализован"
else
    fail "devpanel_resolve_domain_suffix отсутствует"
fi

# T019: serviceDomains / dynamic links
if grep -q 'serviceDomains' "$INDEX_PHP"; then
    pass "Динамические сервисные домены (serviceDomains) используются"
else
    fail "serviceDomains не найден"
fi

# T021: devpanel_canonicalize_host
if grep -q 'devpanel_canonicalize_host' "$INDEX_PHP"; then
    pass "devpanel_canonicalize_host реализован"
else
    fail "devpanel_canonicalize_host отсутствует"
fi

# T022: detectCreateErrorKind foreign_suffix
if grep -q "foreign_suffix" "$INDEX_PHP"; then
    pass "detectCreateErrorKind обрабатывает foreign_suffix"
else
    fail "foreign_suffix не обработан в detectCreateErrorKind"
fi

# T023: hostsDomains uses service domains (no hardcoded traefik.dev etc in hosts list build)
if grep -qE '\$hostsDomains\[\].*=.*\.(dev|loc)' "$INDEX_PHP" 2>/dev/null; then
    # Old style: $hostsDomains[] = 'traefik.dev'
    if grep -qE "hostsDomains\[\].*'(traefik|adminer|grafana|docker)\.dev'" "$INDEX_PHP" 2>/dev/null; then
        fail "hostsDomains строится с hardcoded .dev"
    else
        pass "hostsDomains использует динамические домены"
    fi
else
    pass "hostsDomains использует динамические домены"
fi

# Placeholder uses domainSuffix
if grep -q 'data-domain-suffix' "$INDEX_PHP"; then
    pass "Placeholder привязан к data-domain-suffix"
else
    fail "data-domain-suffix для placeholder отсутствует"
fi

# Compose: DOMAIN_SUFFIX passed to devpanel
for compose in "$SCRIPT_DIR/../../docker-compose.shared.yml" "$SCRIPT_DIR/../../docker-compose.devpanel-fallback.yml"; do
    if [ -f "$compose" ] && grep -A20 'devpanel' "$compose" | grep -q 'DOMAIN_SUFFIX'; then
        pass "DOMAIN_SUFFIX передан в devpanel ($(basename "$compose"))"
        break
    fi
done

echo ""
echo "[f010-wp04] Report written to $REPORT_FILE"
echo "[f010-wp04] Checks completed: $((PASS+FAIL+SKIP)), failures: $FAIL"

{
    echo "# Feature 010 WP04 - DevPanel Web Parity Acceptance"
    echo ""
    echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "Passed: $PASS | Failed: $FAIL | Skipped: $SKIP"
    echo ""
} > "$REPORT_FILE"

exit $([ "$FAIL" -eq 0 ] && exit 0 || exit 1)
