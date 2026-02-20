# Feature 010 WP05 — Legacy Compatibility, Migration Runbook, Final Acceptance

Date: 2026-02-19
Scope: WP05 (T025–T030)
Passed: 18 | Failed: 0 | Skipped: 0

## Check Results

### T025 — Legacy compatibility mode marker
- [x] Legacy-host defined (domain outside active zone)
- [x] `hostctl status` shows ZONE=legacy for legacy hosts
- [x] DevPanel shows «(legacy)» badge for projects outside active zone
- [x] Documented in DOMAIN_SUFFIX-MIGRATION.md

### T026 — Legacy host operations verification
- [x] verify-domain-zone-legacy-t026.sh: 6/6 PASS
- [x] start/stop/status/delete succeed for legacy host
- [x] No erroneous rename on canonicalization

### T027 — Migration runbook
- [x] DOMAIN_SUFFIX-MIGRATION.md: preflight, steps, post-check
- [x] Procedure suitable for fresh clone

### T028 — Routing acceptance
- [x] verify-domain-zone-routing-t028.sh: 3/3 PASS
- [x] Two hosts in active zone, no cross-routing

### T029 — TLS acceptance
- [x] verify-domain-zone-tls-t029.sh: 6/6 PASS
- [x] CN/SAN match docker.\<zone\> for active zone

### T030 — Final evidence
- [x] feature-010-final-acceptance-report.md
- [x] SC-001..SC-005 confirmed
- [x] Negative scenarios documented

## Artifacts

| Artifact | Purpose |
|----------|---------|
| verify-domain-zone-routing-t028.sh | T028 routing |
| verify-domain-zone-tls-t029.sh | T029 TLS |
| verify-domain-zone-legacy-t026.sh | T026 legacy ops |
| DOMAIN_SUFFIX-MIGRATION.md | T027 runbook |
| hostctl status ZONE=legacy, DevPanel badge | T025 marker |
