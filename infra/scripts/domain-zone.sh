#!/usr/bin/env bash

# Shared helpers for DOMAIN_SUFFIX policy and host canonicalization.

dz_normalize_token() {
    local raw="${1:-}"
    printf "%s" "$raw" | tr '[:upper:]' '[:lower:]' | sed -E "s/^[[:space:]\"']+//; s/[[:space:]\"']+$//"
}

dz_read_env_key() {
    local file="$1"
    local key="$2"
    [ -f "$file" ] || { echo ""; return 0; }

    awk -F'=' -v key="$key" '
        index($0, key "=") == 1 {
            $1 = ""
            sub(/^=/, "", $0)
            print $0
            found = 1
            exit
        }
        END {
            if (!found) print ""
        }
    ' "$file"
}

dz_is_valid_domain_suffix() {
    local value="$1"
    [[ "$value" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]]
}

dz_is_valid_host_label() {
    local value="$1"
    [[ "$value" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]]
}

dz_resolve_domain_suffix() {
    local explicit_value="${1:-}"
    local env_file="${2:-}"
    local fallback_file="${3:-}"
    local default_value="${4:-}"
    local value="$explicit_value"

    if [ -z "$value" ] && [ -n "$env_file" ] && [ -f "$env_file" ]; then
        value="$(dz_read_env_key "$env_file" "DOMAIN_SUFFIX")"
    fi

    if [ -z "$value" ] && [ -n "$fallback_file" ] && [ -f "$fallback_file" ]; then
        value="$(dz_read_env_key "$fallback_file" "DOMAIN_SUFFIX")"
    fi

    if [ -z "$value" ] && [ -n "$default_value" ]; then
        value="$default_value"
    fi

    value="$(dz_normalize_token "$value")"
    if [ -z "$value" ]; then
        echo "Error: DOMAIN_SUFFIX is not set. Configure DOMAIN_SUFFIX in infra/.env.global." >&2
        return 1
    fi

    if ! dz_is_valid_domain_suffix "$value"; then
        echo "Error: invalid DOMAIN_SUFFIX '$value'. Allowed pattern: [a-z0-9][a-z0-9-]{0,30}." >&2
        return 1
    fi

    printf "%s\n" "$value"
}

dz_canonicalize_host() {
    local raw_host="$1"
    local domain_suffix="$2"
    local mode="${3:-existing}"
    local normalized=""
    local host_label=""
    local host_suffix=""

    normalized="$(dz_normalize_token "$raw_host")"

    if dz_is_valid_host_label "$normalized"; then
        echo "${normalized}.${domain_suffix}"
        return 0
    fi

    if [[ "$normalized" =~ ^([a-z0-9][a-z0-9-]{0,62})\.([a-z0-9][a-z0-9-]{0,30})$ ]]; then
        host_label="${BASH_REMATCH[1]}"
        host_suffix="${BASH_REMATCH[2]}"

        if [ "$host_suffix" = "$domain_suffix" ]; then
            echo "${host_label}.${domain_suffix}"
            return 0
        fi

        if [ "$mode" = "create" ]; then
            echo "Error: host '$raw_host' uses foreign suffix '$host_suffix'. Active suffix is '$domain_suffix'." >&2
            return 2
        fi

        # Existing/legacy mode allows explicit foreign suffix.
        echo "${host_label}.${host_suffix}"
        return 0
    fi

    echo "Error: invalid host '$raw_host'. Allowed format: '<name>' or '<name>.$domain_suffix'." >&2
    return 3
}
