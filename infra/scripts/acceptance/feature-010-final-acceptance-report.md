# Feature 010 — Final Acceptance Evidence

**Фича:** Настраиваемая локальная доменная зона  
**Дата:** 2026-02-19

## Success Criteria (SC)

| ID | Критерий | Статус |
|----|----------|--------|
| SC-001 | Новые хосты в формате `<host>.<active-zone>` | ✅ WP01–WP04 |
| SC-002 | Невалидная зона / чужой суффикс блокируются | ✅ WP01, WP04 |
| SC-003 | Детерминированная маршрутизация (one domain → one project) | ✅ T028 |
| SC-004 | Каноническое имя совпадает в CLI и web | ✅ WP03, WP04 |
| SC-005 | Развёртывание с кастомной зоной ≤ 10 мин | ✅ README, migration runbook |

## Work Package Evidence

| WP | Артефакты |
|----|------------|
| WP01 | `verify-domain-zone-wp01.sh`, canonicalize/resolve_domain_suffix |
| WP02 | compose labels `${DOMAIN_SUFFIX}`, `generate-ssl.sh` SAN/CN |
| WP03 | `verify-domain-zone-wp03.sh`, manage-hosts, create/delete |
| WP04 | `verify-domain-zone-wp04.sh`, DevPanel dynamic links |
| WP05 | `verify-domain-zone-routing-t028.sh`, `verify-domain-zone-tls-t029.sh`, `DOMAIN_SUFFIX-MIGRATION.md`, legacy marker |

## Проверенные сценарии

- Short-host create → canonical FQDN
- Foreign suffix block (create)
- Legacy host marker в `hostctl status` и DevPanel
- Migration runbook (preflight, steps, post-check)
- TLS CN/SAN для активной зоны
- Routing: два хоста в одной зоне, уникальная привязка

## Негативные сценарии

- create с `.dev` при активной зоне `loc` → блокируется
- Смена зоны при непустом registry → блокируется (FR-013)
