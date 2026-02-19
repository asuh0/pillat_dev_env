#!/usr/bin/env bash
# T026: Legacy host operations — start/stop/status/delete для хоста вне активной зоны

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(dirname "$SCRIPT_DIR")"
INFRA_DIR="$(dirname "$SCRIPTS_DIR")"
HOSTCTL="$SCRIPTS_DIR/hostctl.sh"
DOMAIN_ZONE="$SCRIPTS_DIR/domain-zone.sh"
STATE_DIR="${HOSTCTL_STATE_DIR:-$INFRA_DIR/state}"
PROJECTS_DIR="$(dirname "$INFRA_DIR")/projects"
REGISTRY="$STATE_DIR/hosts-registry.tsv"
TEMPLATES="$INFRA_DIR/templates"

PASS=0
FAIL=0
LEGACY_HOST="f010legacy$(date +%s).dev"
KEEP=0
if [ $# -gt 0 ] && [ "$1" = "--keep" ]; then KEEP=1; fi

pass() { echo "[t026] PASS: $1"; ((PASS++)) || true; }
fail() { echo "[t026] FAIL: $1"; ((FAIL++)) || true; }
skip() { echo "[t026] SKIP: $1"; }

[ -f "$DOMAIN_ZONE" ] || { echo "[t026] domain-zone.sh not found"; exit 1; }
source "$DOMAIN_ZONE"
SUFFIX="$(dz_resolve_domain_suffix "${DOMAIN_SUFFIX:-}" "$INFRA_DIR/.env.global" "$INFRA_DIR/.env.global.example" "loc")" || { echo "[t026] DOMAIN_SUFFIX required"; exit 1; }

# Ensure .dev != active zone for legacy test
if [ "$SUFFIX" = "dev" ]; then
    echo "[t026] SKIP: active zone is .dev, use another DOMAIN_SUFFIX for legacy test"
    exit 0
fi

cleanup() {
    [ "$KEEP" -eq 1 ] && return 0
    [ -d "$PROJECTS_DIR/$LEGACY_HOST" ] && rm -rf "$PROJECTS_DIR/$LEGACY_HOST"
    [ -f "$REGISTRY" ] && grep -v "^$LEGACY_HOST" "$REGISTRY" > "${REGISTRY}.tmp" 2>/dev/null && mv "${REGISTRY}.tmp" "$REGISTRY"
}
trap cleanup EXIT

echo "[t026] Creating legacy fixture: $LEGACY_HOST (active zone: .$SUFFIX)..."

mkdir -p "$PROJECTS_DIR/$LEGACY_HOST"
# Minimal docker-compose for empty preset
cat > "$PROJECTS_DIR/$LEGACY_HOST/docker-compose.yml" <<'YAML'
services:
  web:
    image: php:8.2-cli
    command: ["sleep", "3600"]
YAML

# Add to registry
mkdir -p "$STATE_DIR"
echo -e "${LEGACY_HOST}\tempty\t8.2\tmysql\t$(date -u +%Y-%m-%dT%H:%M:%SZ)\t\t" >> "$REGISTRY"

pass "Legacy fixture created"

# Status should show legacy marker
out="$("$HOSTCTL" status --host "$LEGACY_HOST" 2>&1)"
if echo "$out" | grep -q "legacy"; then
    pass "status shows legacy marker"
else
    fail "status missing legacy marker"
fi

# Start (optional, may fail if Docker not available)
if "$HOSTCTL" start "$LEGACY_HOST" 2>/dev/null; then
    pass "start succeeded"
    "$HOSTCTL" stop "$LEGACY_HOST" 2>/dev/null && pass "stop succeeded" || fail "stop failed"
else
    skip "start skipped (Docker may be unavailable)"
fi

# Delete
if "$HOSTCTL" delete "$LEGACY_HOST" --yes 2>/dev/null; then
    pass "delete succeeded (no erroneous rename)"
else
    fail "delete failed"
fi

[ -d "$PROJECTS_DIR/$LEGACY_HOST" ] && fail "Project dir still exists after delete" || pass "Project dir removed after delete"

echo ""
echo "[t026] Legacy acceptance: $PASS passed, $FAIL failed"
exit $([ "$FAIL" -eq 0 ] && exit 0 || exit 1)
