# Feature 005 WP03 Acceptance Report

- Generated at: 2026-02-16T14:17:07Z
- Scope: WP03 (T013-T017 static contract checks)
- Total checks: 18
- Failed checks: 0
- Overall: PASS

## Check Results

- [x] create form includes bitrix_type select
- [x] bitrix type option kernel present
- [x] bitrix type option ext_kernel present
- [x] bitrix type option link present
- [x] create form includes core_id input
- [x] backend appends --bitrix-type to hostctl command
- [x] backend validates link requires core_id
- [x] backend appends --core for link create
- [x] backend appends --core-id for kernel/ext_kernel create
- [x] metadata computes deleteBlocked from bitrix links
- [x] card renders bitrix type field
- [x] card renders core id field
- [x] delete button disabled when deleteBlocked
- [x] delete warning message rendered for blocked core
- [x] delete handler recognizes Error\[delete_guard\]
- [x] delete handler returns warning for delete_guard
- [x] backend parses bitrix core registry
- [x] backend parses bitrix bindings registry

## Notes

- Validation source: `infra/devpanel/src/index.php`.
- Execution helper: `infra/scripts/acceptance/verify-bitrix-wp03-ui-contract.sh`.
- This report validates source-level web contract; runtime browser smoke is tracked separately.
