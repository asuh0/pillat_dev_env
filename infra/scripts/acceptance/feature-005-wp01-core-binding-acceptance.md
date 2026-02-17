# Feature 005 WP01 Acceptance Report

- Generated at: 2026-02-16T13:10:21Z
- Scope: WP01 (T001-T006)
- Total checks: 30
- Failed checks: 0
- Overall: PASS

## Check Results

- [x] create for f005wp01-1771247414-18048-invalid.dev fails with Error[invalid_core]
- [x] host 'f005wp01-1771247414-18048-invalid.dev' absent in hosts registry
- [x] kernel core host create succeeds (f005wp01-1771247414-18048-core.dev)
- [x] BITRIX_TYPE persisted as kernel
- [x] BITRIX_CORE_ID persisted for kernel host
- [x] hosts registry stores bitrix_type=kernel
- [x] hosts registry stores core_id for kernel host
- [x] core registry stores owner/type for kernel core
- [x] create for f005wp01-1771247414-18048-badlink.dev fails with Error[invalid_core]
- [x] failed link create keeps core/bindings registries unchanged
- [x] link host create succeeds (f005wp01-1771247414-18048-link.dev)
- [x] hosts registry stores bitrix_type=link
- [x] hosts registry stores core_id for link host
- [x] bindings registry stores link -> core relation
- [x] BITRIX_TYPE persisted as link
- [x] BITRIX_CORE_ID persisted for link host
- [x] link compose has no dedicated DB service
- [x] delete for f005wp01-1771247414-18048-core.dev fails with Error[delete_guard]
- [x] stale lock auto-cleanup allows ext_kernel create
- [x] bindings lock directory released after stale-lock create
- [x] delete link host succeeds
- [x] delete core host succeeds after link removal
- [x] delete ext_kernel host succeeds
- [x] host 'f005wp01-1771247414-18048-link.dev' absent in hosts registry
- [x] host 'f005wp01-1771247414-18048-core.dev' absent in hosts registry
- [x] host 'f005wp01-1771247414-18048-ext.dev' absent in hosts registry
- [x] core registry row removed after core delete
- [x] hosts registry format is tabular
- [x] core registry rows have 4 columns
- [x] bindings registry rows have 3 columns

## Notes

- Validation source: `infra/scripts/hostctl.sh`.
- Execution helper: `infra/scripts/acceptance/verify-bitrix-wp01.sh`.
- Hosts are created with `--no-start` to focus on model/registry/guard behavior.
