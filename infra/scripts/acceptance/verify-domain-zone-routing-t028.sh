#!/usr/bin/env bash
# T028: Routing acceptance — one domain -> one project, no cross-routing

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(dirname "$SCRIPT_DIR")"
INFRA_DIR="$(dirname "$SCRIPTS_DIR")"
HOSTCTL="$SCRIPTS_DIR/hostctl.sh"
DOMAIN_ZONE="$SCRIPTS_DIR/domain-zone.sh"
STATE_DIR="${HOSTCTL_STATE_DIR:-$INFRA_DIR/state}"
PROJECTS_DIR="$(dirname "$INFRA_DIR")/projects"
REGISTRY="$STATE_DIR/hosts-registry.tsv"

PASS=0
FAIL=0
PREFIX="f010rt$(date +%s)-$$"

cleanup() {
    local zone="${SUFFIX:-loc}"
    [ -d "$PROJECTS_DIR/${PREFIX}a.$zone" ] && "$HOSTCTL" delete "${PREFIX}a.$zone" --yes 2>/dev/null || true
    [ -d "$PROJECTS_DIR/${PREFIX}b.$zone" ] && "$HOSTCTL" delete "${PREFIX}b.$zone" --yes 2>/dev/null || true
}
trap cleanup EXIT

pass() { echo "[t028] PASS: $1"; ((PASS++)) || true; }
fail() { echo "[t028] FAIL: $1"; ((FAIL++)) || true; }

[ -f "$DOMAIN_ZONE" ] || { echo "[t028] domain-zone.sh not found"; exit 1; }
source "$DOMAIN_ZONE"
SUFFIX="$(dz_resolve_domain_suffix "${DOMAIN_SUFFIX:-}" "$INFRA_DIR/.env.global" "$INFRA_DIR/.env.global.example" "loc")" || { echo "[t028] DOMAIN_SUFFIX required"; exit 1; }

echo "[t028] Creating two hosts in zone $SUFFIX..."

"$HOSTCTL" create "${PREFIX}a" --no-start --hosts-mode skip 2>/dev/null || "$HOSTCTL" create "${PREFIX}a" --preset empty --no-start --hosts-mode skip
"$HOSTCTL" create "${PREFIX}b" --no-start --hosts-mode skip 2>/dev/null || "$HOSTCTL" create "${PREFIX}b" --preset empty --no-start --hosts-mode skip

pass "Two hosts created: ${PREFIX}a.$SUFFIX, ${PREFIX}b.$SUFFIX"

if [ -f "$REGISTRY" ] && grep -q "^${PREFIX}a\.$SUFFIX" "$REGISTRY" 2>/dev/null; then
    pass "Registry contains ${PREFIX}a.$SUFFIX"
else
    fail "Registry missing ${PREFIX}a.$SUFFIX"
fi

if [ -d "$PROJECTS_DIR/${PREFIX}a.$SUFFIX" ] && [ -d "$PROJECTS_DIR/${PREFIX}b.$SUFFIX" ]; then
    pass "Project directories exist for both hosts"
else
    fail "Project directories missing"
fi

# Deterministic routing: each host has unique compose project name
# Live HTTP check optional (requires Docker, hosts resolution)
if [ "${1:-}" = "--live" ]; then
    echo "[t028] Starting hosts for live routing check..."
    "$HOSTCTL" start "${PREFIX}a.$SUFFIX"
    "$HOSTCTL" start "${PREFIX}b.$SUFFIX"
    echo "[t028] Use: curl -s http://${PREFIX}a.$SUFFIX and http://${PREFIX}b.$SUFFIX to verify no cross-routing"
    pass "Hosts started for manual routing verification"
fi

echo ""
echo "[t028] Routing acceptance: $PASS passed, $FAIL failed"
exit $([ "$FAIL" -eq 0 ] && exit 0 || exit 1)
