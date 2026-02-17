# Feature 005 WP02 Acceptance Report

- Generated at: 2026-02-16T14:18:38Z
- Scope: WP02 (T007-T012)
- Total checks: 21
- Failed checks: 0
- Overall: PASS

## Check Results

- [x] command fails with Error[invalid_core]
- [x] core create with --bitrix-type/--core-id succeeds
- [x] interactive link create succeeds with core selection
- [x] BITRIX_TYPE=link persisted for link host
- [x] BITRIX_CORE_ID persisted for link host
- [x] link shared paths are symlinks (bitrix/upload/images)
- [x] link local path stays site-specific
- [x] link host has no dedicated DB data dirs
- [x] link compose contains no dedicated DB service
- [x] status shows kernel core type/core_id for core host
- [x] status shows link type/core_id for link host
- [x] hosts registry keeps bitrix_type for link
- [x] hosts registry keeps core_id for link
- [x] bindings registry contains link->core row
- [x] core registry contains owner host for core_id
- [x] command fails with Error[delete_guard]
- [x] delete link host succeeds
- [x] delete core host succeeds after link removal
- [x] hosts registry cleaned after delete flow
- [x] bindings registry cleaned after link delete
- [x] core registry cleaned after core delete

## Notes

- Validation source: `infra/scripts/hostctl.sh`.
- Execution helper: `infra/scripts/acceptance/verify-bitrix-wp02.sh`.
- Hosts are created with `--no-start` or interactive `start=n` to validate control flow deterministically.
