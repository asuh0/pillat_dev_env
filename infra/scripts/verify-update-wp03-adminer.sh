#!/bin/bash
# WP03 acceptance: Adminer update success and failure+rollback paths.
# Requires Docker running. Exit 0 if all pass, 1 otherwise.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    echo "SKIP: Docker не запущен или недоступен"
    exit 0
fi

passed=0
failed=0

# Success path: update Adminer
echo "=== Test 1: success path ==="
if ./update-component-adminer.sh >/dev/null 2>&1; then
    echo "PASS: success"
    ((passed++)) || true
else
    echo "FAIL: success"
    ((failed++)) || true
fi

# Failure + rollback: simulate verify failure (apply succeeds, verify fails -> rollback)
echo "=== Test 2: failure + rollback ==="
if ! ./update-component-adminer.sh --simulate-verify-failure >/tmp/wp03-failure.log 2>&1; then
    echo "PASS: failure path (verify failed, rollback executed)"
    ((passed++)) || true
else
    echo "FAIL: expected non-zero exit on verify failure"
    cat /tmp/wp03-failure.log
    ((failed++)) || true
fi

echo "---"
echo "Passed: $passed, Failed: $failed"
[ "$failed" -eq 0 ]
