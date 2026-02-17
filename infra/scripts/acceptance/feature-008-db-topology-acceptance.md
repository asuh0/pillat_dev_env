# Feature 008 Acceptance Report

- Generated at: 2026-02-16T08:32:59Z
- Mode: all
- DB type (sequential/parallel): mysql
- Total checks: 29
- Failed checks: 0
- Overall: PASS

## Check Results

- [x] create --no-start succeeds for v008chk-1771230763-15637-seq-a.dev
- [x] create --no-start succeeds for v008chk-1771230763-15637-seq-b.dev
- [x] sequential: v008chk-1771230763-15637-seq-a.dev DB_SERVICE_NAME follows db-<host_slug>
- [x] sequential: v008chk-1771230763-15637-seq-b.dev DB_SERVICE_NAME follows db-<host_slug>
- [x] sequential: DB service names are unique
- [x] sequential: v008chk-1771230763-15637-seq-a.dev DB_EXTERNAL_PORT is valid (50325)
- [x] sequential: v008chk-1771230763-15637-seq-b.dev DB_EXTERNAL_PORT is valid (50350)
- [x] sequential: DB external ports are unique
- [x] sequential: strategy_mode reported as policy_v008 for both hosts
- [x] sequential: db_meta_status=ok for both hosts
- [x] parallel: create succeeds for v008chk-1771230763-15637-par-a.dev
- [x] parallel: create succeeds for v008chk-1771230763-15637-par-b.dev
- [x] parallel: v008chk-1771230763-15637-par-a.dev DB_SERVICE_NAME follows db-<host_slug>
- [x] parallel: v008chk-1771230763-15637-par-b.dev DB_SERVICE_NAME follows db-<host_slug>
- [x] parallel: DB service names are unique
- [x] parallel: v008chk-1771230763-15637-par-a.dev DB_EXTERNAL_PORT is valid (50383)
- [x] parallel: v008chk-1771230763-15637-par-b.dev DB_EXTERNAL_PORT is valid (50391)
- [x] parallel: DB external ports are unique
- [x] parallel: strategy_mode reported as policy_v008 for both hosts
- [x] parallel: db_meta_status=ok for both hosts
- [x] create --no-start succeeds for v008chk-1771230763-15637-legacy.dev
- [x] legacy: host start succeeds after legacy-style metadata fallback
- [x] legacy: host stop succeeds after legacy-style metadata fallback
- [x] legacy: DB_SERVICE_NAME stays absent (no auto-conversion)
- [x] legacy: compose keeps mysql service name
- [x] legacy: compose remains without db-<slug> auto-conversion
- [x] legacy: strategy_mode is legacy
- [x] legacy: DB service projection remains mysql
- [x] legacy: db_meta_status remains ok

## Notes

- Legacy guard validated via simulated legacy metadata (no DB_* policy keys).
- Policy-v008 checks validate db-<host_slug>, unique DB external ports, and status projection.
- Script source: `infra/scripts/acceptance/verify-db-topology-v008.sh`.
