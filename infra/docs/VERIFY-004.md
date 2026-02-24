# Проверка фичи 004: Инструменты разработки и обновления

## Быстрая проверка (без Docker)

```bash
# WP01: smoke-тесты update-lib
./infra/scripts/verify-update-wp01.sh
# Ожидание: PASS success, idempotent, failure

# WP02: status с версией и DEV_TOOLS
./infra/scripts/hostctl.sh status
# Ожидание: строка "Product: <hash> | Update available: yes|no", колонка DEV_TOOLS

# WP02: enable/disable dev-tools (нужен существующий хост)
./infra/scripts/hostctl.sh enable-dev-tools <host>
./infra/scripts/hostctl.sh disable-dev-tools <host>

# WP04: update-presets блокируется при нечистом git
./infra/scripts/update-presets.sh
# Ожидание при uncommitted: "Error: нечистое состояние git"
```

## Полная проверка (с Docker)

### WP01
```bash
./infra/scripts/verify-update-wp01.sh
```

### WP02
```bash
./infra/scripts/hostctl.sh status
./infra/scripts/hostctl.sh enable-dev-tools test.loc
./infra/scripts/hostctl.sh status  # DEV_TOOLS: xdebug,adminer
./infra/scripts/hostctl.sh disable-dev-tools test.loc
```

### WP03 (Adminer)
```bash
./infra/scripts/verify-update-wp03-adminer.sh
# или вручную:
./infra/scripts/hostctl.sh update-component-adminer
./infra/scripts/hostctl.sh update-component-adminer --simulate-verify-failure  # rollback
```

### WP04 (Presets)
```bash
# 1. Убедитесь, что git чист
git status

# 2. Обновление пресетов
./infra/scripts/hostctl.sh update-presets

# 3. Snapshot: create использует копию presets на момент старта
./infra/scripts/hostctl.sh create test-new --preset empty --no-start
```

## Чеклисты

- [ ] `infra/docs/update-wp01-smoke-checklist.md`
- [ ] `infra/docs/update-wp03-adminer-checklist.md`
- [ ] `infra/docs/UPDATE-FLOW.md`
