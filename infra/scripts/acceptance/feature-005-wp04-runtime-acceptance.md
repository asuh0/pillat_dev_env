# Feature 005 WP04 Runtime Acceptance

## Scope

- T019: Shared/site-specific path map (bitrix, upload, images vs local)
- T020: Symlinks in link create flow
- T021: ext_kernel HTTP restriction (traefik.enable=false)
- T022: Auto-cleanup partial artifacts on retry
- T023: Restart stability (stop/start preserves bindings)
- T024: Mixed env kernel/ext_kernel/link

## Execution

```bash
DOMAIN_SUFFIX=dev HOSTCTL_HOSTS_MODE=skip infra/scripts/acceptance/verify-bitrix-wp04.sh
```

## Notes

- Requires DOMAIN_SUFFIX in .env.global or environment (e.g. `dev`).
- Report written to `feature-005-wp04-runtime-acceptance.md` after run.
