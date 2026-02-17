#!/bin/bash

# Генерация локального CA и TLS-сертификата для Traefik.
# Важно: для домена .dev wildcard (*.dev) не считается надежным решением,
# поэтому сертификат генерируется с явным SAN-списком всех используемых хостов.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"
DEV_DIR="$(dirname "$INFRA_DIR")"
PROJECTS_DIR="$DEV_DIR/projects"
STATE_DIR="$INFRA_DIR/state"
SSL_DIR="$INFRA_DIR/ssl"
REGISTRY_FILE="$STATE_DIR/hosts-registry.tsv"
LEGACY_REGISTRY_FILE="$PROJECTS_DIR/.hosts-registry.tsv"

CA_KEY="$SSL_DIR/ca-key.pem"
CA_CERT="$SSL_DIR/ca.pem"
CA_SERIAL="$SSL_DIR/ca.srl"
TRAEFIK_KEY="$SSL_DIR/traefik-key.pem"
TRAEFIK_CERT="$SSL_DIR/traefik-cert.pem"
TRAEFIK_CSR="$SSL_DIR/traefik.csr"
TRAEFIK_EXT="$SSL_DIR/traefik.ext"
DOMAINS_FILE="$STATE_DIR/traefik-domains.txt"
DOMAINS_HASH_FILE="$STATE_DIR/traefik-domains.sha256"
LEGACY_DOMAINS_FILE="$SSL_DIR/.traefik-domains.txt"
LEGACY_DOMAINS_HASH_FILE="$SSL_DIR/.traefik-domains.sha256"
CA_CN="Docker Env Asuho Dev CA"

STATIC_DOMAINS=(
    "docker.dev"
    "traefik.dev"
    "adminer.dev"
    "grafana.dev"
)

FORCE_REGENERATE=0
SKIP_TRUST_INSTALL=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --force|-f)
            FORCE_REGENERATE=1
            shift
            ;;
        --skip-trust)
            SKIP_TRUST_INSTALL=1
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--force] [--skip-trust]"
            exit 1
            ;;
    esac
done

ensure_ca() {
    mkdir -p "$SSL_DIR"
    mkdir -p "$STATE_DIR"

    if [ -f "$CA_KEY" ] && [ -f "$CA_CERT" ]; then
        return 0
    fi

    echo "📝 Создание локального CA..."
    openssl genrsa -out "$CA_KEY" 4096
    openssl req -new -x509 -days 3650 -key "$CA_KEY" \
        -out "$CA_CERT" \
        -subj "/C=RU/ST=Moscow/L=Moscow/O=Docker Env Asuho/CN=$CA_CN"
    echo "✅ Локальный CA создан: $CA_CERT"
}

collect_domains() {
    local tmp_file
    tmp_file="$(mktemp)"

    for domain in "${STATIC_DOMAINS[@]}"; do
        echo "$domain" >> "$tmp_file"
    done

    if [ -f "$REGISTRY_FILE" ]; then
        awk -F'\t' 'NF > 0 && $1 != "" {print $1}' "$REGISTRY_FILE" >> "$tmp_file"
    elif [ -f "$LEGACY_REGISTRY_FILE" ]; then
        awk -F'\t' 'NF > 0 && $1 != "" {print $1}' "$LEGACY_REGISTRY_FILE" >> "$tmp_file"
    fi

    local compose_file=""
    local host=""
    for compose_file in "$PROJECTS_DIR"/*/docker-compose.yml; do
        [ -f "$compose_file" ] || continue
        host="$(basename "$(dirname "$compose_file")")"
        [ -n "$host" ] && echo "$host" >> "$tmp_file"
    done

    awk 'NF > 0 {print tolower($0)}' "$tmp_file" | awk '!seen[$0]++'
    rm -f "$tmp_file"
}

build_extensions_file() {
    local domains_list_file="$1"

    cat > "$TRAEFIK_EXT" <<EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
EOF

    local idx=1
    local domain=""
    while IFS= read -r domain; do
        [ -n "$domain" ] || continue
        printf "DNS.%s = %s\n" "$idx" "$domain" >> "$TRAEFIK_EXT"
        idx=$((idx + 1))
    done < "$domains_list_file"
}

install_ca_hint() {
    echo ""
    echo "📋 Установка CA сертификата ($CA_CERT):"
    echo ""
    echo "macOS:"
    echo "  security add-trusted-cert -d -r trustRoot -k \"$HOME/Library/Keychains/login.keychain-db\" \"$CA_CERT\""
    echo ""
    echo "Linux:"
    echo "  sudo cp \"$CA_CERT\" /usr/local/share/ca-certificates/docker-env-asuho-dev-ca.crt"
    echo "  sudo update-ca-certificates"
    echo ""
    echo "Windows:"
    echo "  Import \"$CA_CERT\" into 'Trusted Root Certification Authorities'"
    echo ""
}

maybe_install_ca_macos() {
    [ "$(uname -s)" = "Darwin" ] || return 0
    if ! command -v security >/dev/null 2>&1; then
        return 0
    fi

    # Нефатально: если установка не удалась, просто покажем инструкции.
    if security add-trusted-cert -d -r trustRoot -k "$HOME/Library/Keychains/login.keychain-db" "$CA_CERT" >/dev/null 2>&1; then
        echo "✅ CA добавлен в macOS login keychain."
    else
        echo "⚠️  Не удалось автоматически добавить CA в keychain. Выполните команду вручную:"
        echo "   security add-trusted-cert -d -r trustRoot -k \"$HOME/Library/Keychains/login.keychain-db\" \"$CA_CERT\""
    fi
}

ensure_traefik_certificate() {
    local domains
    domains="$(collect_domains)"

    if [ -z "$domains" ]; then
        echo "Error: список доменов для сертификата пуст."
        exit 1
    fi

    printf "%s\n" "$domains" > "$DOMAINS_FILE"
    local new_hash
    new_hash="$(printf "%s\n" "$domains" | shasum -a 256 | awk '{print $1}')"
    local old_hash=""
    if [ -f "$DOMAINS_HASH_FILE" ]; then
        old_hash="$(awk 'NR==1{print $1}' "$DOMAINS_HASH_FILE")"
    elif [ -f "$LEGACY_DOMAINS_HASH_FILE" ]; then
        old_hash="$(awk 'NR==1{print $1}' "$LEGACY_DOMAINS_HASH_FILE")"
    fi

    if [ "$FORCE_REGENERATE" -eq 0 ] && [ -f "$TRAEFIK_CERT" ] && [ -f "$TRAEFIK_KEY" ] && [ "$new_hash" = "$old_hash" ]; then
        echo "⏭️  TLS-сертификат Traefik актуален (список доменов не изменился)."
        return 0
    fi

    echo "📝 Генерация сертификата Traefik для доменов:"
    awk '{print "   - " $0}' "$DOMAINS_FILE"

    build_extensions_file "$DOMAINS_FILE"
    openssl genrsa -out "$TRAEFIK_KEY" 2048
    openssl req -new -key "$TRAEFIK_KEY" \
        -out "$TRAEFIK_CSR" \
        -subj "/C=RU/ST=Moscow/L=Moscow/O=Docker Env Asuho/CN=docker.dev"

    local leaf_cert="$SSL_DIR/traefik-leaf.pem"
    openssl x509 -req -in "$TRAEFIK_CSR" \
        -CA "$CA_CERT" \
        -CAkey "$CA_KEY" \
        -CAcreateserial \
        -CAserial "$CA_SERIAL" \
        -out "$leaf_cert" \
        -days 825 \
        -extfile "$TRAEFIK_EXT"

    # Traefik ожидает cert + chain в одном файле.
    cat "$leaf_cert" "$CA_CERT" > "$TRAEFIK_CERT"
    rm -f "$leaf_cert" "$TRAEFIK_CSR" "$TRAEFIK_EXT"

    echo "$new_hash" > "$DOMAINS_HASH_FILE"
    echo "✅ TLS-сертификат Traefik обновлен: $TRAEFIK_CERT"
}

echo "🔐 Подготовка SSL-сертификатов..."
ensure_ca
ensure_traefik_certificate
if [ "$SKIP_TRUST_INSTALL" -eq 0 ]; then
    maybe_install_ca_macos
fi
install_ca_hint
echo "✅ SSL-настройка завершена."
