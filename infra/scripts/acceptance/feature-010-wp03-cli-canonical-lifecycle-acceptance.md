# Feature 010 WP03 Acceptance Report

- Generated at: 2026-02-19T18:38:27Z
- Scope: WP03 (T013-T018)
- Total checks: 20
- Failed checks: 3
- Overall: FAIL

## Check Results

- [x] DOMAIN_SUFFIX валиден: loc
- [x] manage-hosts add принимает short-host и нормализует его
- [x] manage-hosts check видит канонический домен
- [x] manage-hosts list выводит канонический домен
- [x] manage-hosts remove принимает short-host
- [x] manage-hosts check корректно сообщает об отсутствии после remove
- [x] hostctl create short-host succeeds: f010wp03-1771526297-1938 -> f010wp03-1771526297-1938.loc
- [x] создан каталог проекта с каноническим именем
- [x] реестр содержит канонический host
- [x] status --host short-host показывает канонический host
- [ ] start short-host failed
- [ ] status не отражает running после start
- [ ] stop canonical-host failed
- [x] create full-host в активной зоне succeeds
- [x] collision guard срабатывает для канонического имени
- [x] foreign suffix отклоняется с Error[foreign_suffix]
- [x] delete short-host resolves to canonical и succeeds
- [x] delete full-host succeeds
- [x] каталоги проектов удалены после delete
- [x] реестр очищен после delete

## Notes

- Validation sources: `infra/scripts/hostctl.sh`, `infra/scripts/create-project.sh`, `infra/scripts/manage-hosts.sh`.
- Execution helper: `infra/scripts/acceptance/verify-domain-zone-wp03.sh`.
- manage-hosts проверяется на временном hosts-файле через `HOSTS_FILE=<tmp>`.
