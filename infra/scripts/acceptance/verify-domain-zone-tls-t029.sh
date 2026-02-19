#!/usr/bin/env bash
# T029: TLS acceptance — no default cert in active zone
# Requires: generate-ssl.sh run with correct DOMAIN_SUFFIX (bash infra/scripts/generate-ssl.sh --skip-trust)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
SSL_DIR="$INFRA_DIR/ssl"
DOMAIN_ZONE="$(dirname "$SCRIPT_DIR")/domain-zone.sh"

PASS=0
FAIL=0

pass() { echo "[t029] PASS: $1"; ((PASS++)) || true; }
fail() { echo "[t029] FAIL: $1"; ((FAIL++)) || true; }
skip() { echo "[t029] SKIP: $1"; }

[ -f "$DOMAIN_ZONE" ] || { echo "[t029] domain-zone.sh not found"; exit 1; }
source "$DOMAIN_ZONE"
SUFFIX="$(dz_resolve_domain_suffix "${DOMAIN_SUFFIX:-}" "$INFRA_DIR/.env.global" "$INFRA_DIR/.env.global.example" "loc")" || { echo "[t029] DOMAIN_SUFFIX required"; exit 1; }

# Check traefik cert exists and has expected CN/SAN for active zone
CERT_FILE="$SSL_DIR/traefik-cert.pem"
if [ ! -f "$CERT_FILE" ]; then
    fail "Traefik cert not found at $CERT_FILE (run generate-ssl.sh)"
else
    pass "Traefik cert exists"
fi

# CN should be docker.<suffix>
CN="$(openssl x509 -in "$CERT_FILE" -noout -subject 2>/dev/null | sed -n 's/.*CN *= *\([^,]*\).*/\1/p' | tr -d ' ')"
if [[ "$CN" == docker.* ]]; then
    pass "CN matches docker.<zone> pattern: $CN"
else
    fail "CN '$CN' does not match docker.<zone>"
fi

# SAN should include service domains
SAN="$(openssl x509 -in "$CERT_FILE" -noout -text 2>/dev/null | grep -A1 "Subject Alternative Name" | tail -1 | tr ',' '\n' | sed 's/.*DNS://g;s/^ *//')"
for domain in "docker.$SUFFIX" "traefik.$SUFFIX" "adminer.$SUFFIX" "grafana.$SUFFIX"; do
    if echo "$SAN" | grep -qF "$domain"; then
        pass "SAN contains $domain"
    else
        fail "SAN missing $domain"
    fi
done

echo ""
echo "[t029] TLS acceptance: $PASS passed, $FAIL failed"
exit $([ "$FAIL" -eq 0 ] && exit 0 || exit 1)
