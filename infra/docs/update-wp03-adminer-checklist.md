# WP03 Checklist: Component Update (Adminer)

**Purpose**: Verify Adminer update success/failure paths and rollback  
**Feature**: 004-dev-tools-and-update-pipeline  
**WP**: WP03

## Pre-requisites

- Docker running
- `infra/scripts/update-component-adminer.sh`, `verify-update-wp03-adminer.sh` present
- `update-lib.sh` (WP01) available

## Checklist

1. **Success path**
   - [ ] Run: `hostctl.sh update-component-adminer` or `infra/scripts/update-component-adminer.sh`
   - [ ] Expect: exit 0, "OK: Adminer обновлён"
   - [ ] Verify: `infra/state/version-registry/adminer.json` exists

2. **Failure + Rollback**
   - [ ] Run: `infra/scripts/update-component-adminer.sh --simulate-verify-failure`
   - [ ] Expect: exit 1, rollback executed
   - [ ] Verify: Adminer container restored to previous state

3. **Full verification**
   - [ ] Run: `infra/scripts/verify-update-wp03-adminer.sh`
   - [ ] Expect: exit 0, both tests PASS (or SKIP if Docker unavailable)
