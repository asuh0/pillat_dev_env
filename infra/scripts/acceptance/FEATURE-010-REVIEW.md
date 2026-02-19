# Feature 010 — Ревью для теста

**Ветка:** `feature/010-for-test`  
**Дата:** 2026-02-19

## Соответствие конституции

- [x] Коммиты на русском
- [x] Co-authored-by удалён из истории (filter-branch)
- [x] Правило в `.cursorrules` — для будущих коммитов отключить «Add Co-authored-by» в настройках Cursor

## Итоги acceptance

| Скрипт | Результат | Примечание |
|--------|-----------|------------|
| verify-domain-zone-wp03 | 17/20 PASS | 3 FAIL: Docker daemon не запущен (start/stop) |
| verify-domain-zone-wp04 | 8/8 PASS | |
| verify-domain-zone-routing-t028 | 3/3 PASS | |
| verify-domain-zone-tls-t029 | 6/6 PASS | Требует `generate-ssl.sh -f` перед запуском |
| verify-domain-zone-legacy-t026 | 4/4 PASS | |

*WP01 verify-domain-zone-wp01.sh отсутствует в ветке — был в feature/010-unified.*

## Чеклист для тестирования

### Перед тестом
1. Запустить Docker Desktop
2. `cp infra/.env.global.example infra/.env.global`
3. Задать `DOMAIN_SUFFIX=pillat` (или другую зону) в `infra/.env.global`
4. `bash infra/scripts/bootstrap.sh`
5. `bash infra/scripts/generate-ssl.sh --skip-trust`

### Сценарий 1: Infra + зона
```
bash infra/scripts/start-all.sh
# Добавить в /etc/hosts: 127.0.0.1 docker.<zone> traefik.<zone> adminer.<zone> grafana.<zone>
curl -k --resolve docker.<zone>:443:127.0.0.1 https://docker.<zone>
```

### Сценарий 2: CLI create
```
bash infra/scripts/hostctl.sh create demo --preset empty
bash infra/scripts/hostctl.sh status
# Ожидается: demo.<zone>, ZONE=active
```

### Сценарий 3: DevPanel
- Открыть https://docker.<zone>
- Создать хост с коротким именем
- Проверить ссылки на traefik/adminer/grafana
- Проверить блок /etc/hosts

### Сценарий 4: Legacy marker
- Создать хост вручную с суффиксом .dev (если зона не .dev)
- `hostctl status` должен показать ZONE=legacy

## Изменённые файлы

- `infra/scripts/hostctl.sh` — canonicalize, legacy marker, domain zone
- `infra/scripts/domain-zone.sh` — хелперы DOMAIN_SUFFIX
- `infra/scripts/generate-ssl.sh` — DOMAIN_SUFFIX для SAN/CN
- `infra/scripts/create-project.sh`, `manage-hosts.sh`
- `infra/devpanel/src/index.php` — DevPanel web parity
- `infra/docker-compose.shared.yml`, `infra/docker-compose.devpanel-fallback.yml`
- `README.md`, `infra/docs/DOMAIN_SUFFIX-MIGRATION.md`
- acceptance: verify-domain-zone-*.sh
