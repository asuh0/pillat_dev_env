#!/bin/bash
# Dev tools state and helpers for WP02 (004-dev-tools-and-update-pipeline)
# MVP: xdebug, adminer
set -euo pipefail

DEV_TOOLS_STATE_FILE="${HOSTCTL_STATE_DIR:-${STATE_DIR:-}}/dev-tools.json"
DEV_TOOLS_MVP="xdebug adminer"

dev_tools_get() {
    local host="$1"
    local tool="${2:-}"
    [ -f "$DEV_TOOLS_STATE_FILE" ] || { [ -z "$tool" ] && echo "{}" || echo "false"; return 0; }
    if command -v jq >/dev/null 2>&1; then
        if [ -n "$tool" ]; then
            jq -r --arg h "$host" --arg t "$tool" '.[$h][$t] // "false"' "$DEV_TOOLS_STATE_FILE" 2>/dev/null || echo "false"
        else
            jq -c --arg h "$host" '.[$h] // {}' "$DEV_TOOLS_STATE_FILE" 2>/dev/null || echo "{}"
        fi
    else
        [ -z "$tool" ] && echo "{}" || { grep -o "\"$host\"[^}]*" "$DEV_TOOLS_STATE_FILE" 2>/dev/null | grep -o "\"$tool\"[^,]*" | grep -o 'true\|false' | head -1 || echo "false"; }
    fi
}

dev_tools_set() {
    local host="$1"
    local tool="$2"
    local value="$3"
    mkdir -p "$(dirname "$DEV_TOOLS_STATE_FILE")"
    [ -f "$DEV_TOOLS_STATE_FILE" ] || echo "{}" > "$DEV_TOOLS_STATE_FILE"
    if command -v jq >/dev/null 2>&1; then
        local tmp
        tmp="$(mktemp)"
        jq --arg h "$host" --arg t "$tool" --arg v "$value" '.[$h] = (.[$h] // {} | .[$t] = ($v == "true"))' "$DEV_TOOLS_STATE_FILE" > "$tmp" && mv "$tmp" "$DEV_TOOLS_STATE_FILE"
    fi
}

dev_tools_format_for_status() {
    local host="$1"
    local out=""
    for t in $DEV_TOOLS_MVP; do
        if [ "$(dev_tools_get "$host" "$t")" = "true" ]; then
            [ -n "$out" ] && out="$out,"
            out="${out}${t}"
        fi
    done
    [ -n "$out" ] || out="-"
    echo "$out"
}
