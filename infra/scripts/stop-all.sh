#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "⏹️  Остановка общей инфраструктуры..."
"$SCRIPT_DIR/hostctl.sh" infra-stop

echo "✅ Инфраструктура остановлена."
