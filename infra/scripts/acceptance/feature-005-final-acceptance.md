# Feature 005 Bitrix Multisite — Final Acceptance

## Scope

Bitrix multisite с типами kernel/ext_kernel/link, shared core, link-hostами.

## Acceptance Scripts

| WP | Script | Scope |
|----|--------|-------|
| WP01 | verify-bitrix-wp01.sh | Core/binding model, registry, lock, delete guard |
| WP02 | verify-bitrix-wp02.sh | CLI create link, symlinks, status, delete flow |
| WP03 | verify-bitrix-wp03-web-runtime.sh | Web create kernel/link, delete guard |
| WP04 | verify-bitrix-wp04.sh | Runtime paths, ext_kernel HTTP, auto-cleanup |
| WP05 | **verify-bitrix-critical-path.sh** | Critical path: core→link→status→delete-link→delete-core |

## Critical Path (T025, FR-018)

```bash
DOMAIN_SUFFIX=dev infra/scripts/acceptance/verify-bitrix-critical-path.sh
```

## Web Smoke (T026)

```bash
# Требует запущенный DevPanel
infra/scripts/acceptance/verify-bitrix-wp03-web-runtime.sh
```

## Runbook

`infra/docs/bitrix-multisite-runbook.md`

## Остаточные ограничения

- `ext_kernel` не доступен по HTTP (по дизайну).
- Порядок удаления: link → core.
