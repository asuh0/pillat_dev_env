#!/bin/bash
# WP01 smoke verification: runs success, idempotent, failure paths.
# Exit 0 if all pass, 1 otherwise.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

passed=0
failed=0

for mode in success idempotent failure; do
    if ./update-demo.sh "$mode" >/dev/null 2>&1; then
        echo "PASS: $mode"
        ((passed++)) || true
    else
        echo "FAIL: $mode"
        ((failed++)) || true
    fi
done

echo "---"
echo "Passed: $passed, Failed: $failed"
[ "$failed" -eq 0 ]
