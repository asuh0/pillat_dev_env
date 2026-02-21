# WP01 Smoke Checklist: Version Registry and Update Transaction

**Purpose**: Verify success/failure paths and rollback correctness  
**Feature**: 004-dev-tools-and-update-pipeline  
**WP**: WP01

## Pre-requisites

- `jq` installed (optional; fallback to grep/sed for JSON)
- `infra/scripts/update-lib.sh`, `update-demo.sh`, `verify-update-wp01.sh` present

## Checklist

1. **Success path**
   - [ ] Run: `infra/scripts/update-demo.sh success`
   - [ ] Expect: exit 0, "OK: success path passed"
   - [ ] Verify: `infra/state/version-registry/demo-counter.json` exists (when using real state)

2. **Idempotency**
   - [ ] Run: `infra/scripts/update-demo.sh idempotent`
   - [ ] Expect: exit 0, "UPDATE_IDEMPOTENT: объект demo-counter уже на версии 1.0.0" on second run
   - [ ] Expect: no duplicate apply

3. **Failure + Rollback**
   - [ ] Run: `infra/scripts/update-demo.sh failure`
   - [ ] Expect: exit 0 (script handles failure), "OK: failure path triggered rollback"
   - [ ] Verify: update operation log shows status `rolled_back`

4. **Full verification**
   - [ ] Run: `infra/scripts/verify-update-wp01.sh`
   - [ ] Expect: exit 0, all three modes PASS

## Results

- 2026-02-21: All scenarios passed (success, idempotent, failure)
