# Docker Env Asuho

Локальная Docker-инфраструктура для многопроектной PHP-разработки:

- общий reverse proxy и сервисы наблюдаемости;
- создание/жизненный цикл хостов через `hostctl.sh` и DevPanel;
- пресеты проектов (`empty`, `bitrix`);
- централизованная политика структуры, состояния и логов.

![Repository layout](docs/images/repository-layout.svg)

## Ключевая структура

```text
.
├── infra/
│   ├── docker-compose.shared.yml
│   ├── scripts/              # hostctl.sh, create-project.sh, generate-ssl.sh, ...
│   ├── templates/            # централизованные шаблоны (например, Dockerfile.php*)
│   ├── devpanel/             # web UI (https://docker.dev)
│   ├── state/                # runtime state: registry/jobs/action logs
│   ├── ssl/
│   └── grafana/
├── presets/                  # пресеты и контракт пресетов
├── projects/                 # только каталоги реальных хостов
├── logs/                     # централизованные runtime-логи (не коммитятся)
├── shared-volumes/           # данные сервисов (не коммитятся)
├── kitty-specs/              # спецификации и артефакты фич
├── CONTRIBUTING.md
└── LICENSE
```

## Быстрый старт

Перед стартом убедитесь, что Docker Desktop запущен.

0) Выполните bootstrap (рекомендуется сразу после `git clone`):

```bash
bash ./infra/scripts/bootstrap.sh
```

1) Подготовьте infra-конфиг:

```bash
cp ./infra/.env.global.example ./infra/.env.global
```

Укажите `DOMAIN_SUFFIX` в `infra/.env.global` (например, `pillat` или `loc`). Все домены будут в этой зоне: `docker.<zone>`, `traefik.<zone>`, `<project>.<zone>`.

2) Сгенерируйте SSL для локальной среды:

```bash
bash ./infra/scripts/generate-ssl.sh --skip-trust
```

3) Запустите общую инфраструктуру:

```bash
bash ./infra/scripts/start-all.sh
```

Скрипт использует `hostctl.sh infra-start` и автоматически включает fallback-режим при проблемах bind-mount (например, на внешнем диске).

4) Добавьте базовые домены в `/etc/hosts`. Используйте вашу активную зону (`DOMAIN_SUFFIX` из `.env.global`, по умолчанию `loc`):

```text
127.0.0.1 docker.loc
127.0.0.1 traefik.loc
127.0.0.1 adminer.loc
127.0.0.1 grafana.loc
```

Актуальный список доменов см. в DevPanel (блок «Конфигурация /etc/hosts»).

5) Проверьте доступность DevPanel:

```bash
# Замените loc на ваш DOMAIN_SUFFIX
curl -k --resolve docker.loc:443:127.0.0.1 https://docker.loc
```

## Проверка на свежем clone

```bash
git clone <repo-url> pillat_dev_env_test
cd pillat_dev_env_test
bash ./infra/scripts/bootstrap.sh
cp ./infra/.env.global.example ./infra/.env.global
# Опционально: отключить fallback и работать только в primary режиме
# echo "INFRA_FALLBACK_ENABLED=0" >> ./infra/.env.global
bash ./infra/scripts/start-all.sh
bash ./infra/scripts/hostctl.sh status
```

## Запуск и остановка инфраструктурных пакетов (актуальный flow)

Используйте только управляющие скрипты/`hostctl`:

```bash
cd infra
bash ./scripts/start-all.sh
bash ./scripts/stop-all.sh
```

или напрямую:

```bash
cd infra/scripts
bash ./hostctl.sh infra-start
bash ./hostctl.sh infra-stop
bash ./hostctl.sh infra-restart
```

Не запускайте shared-инфраструктуру напрямую через `docker compose -f infra/docker-compose.shared.yml up -d`: это обходит внутреннюю логику fallback и runtime-mode.

## Управление хостами

### Через CLI (`hostctl`)

```bash
cd infra/scripts

bash ./hostctl.sh infra-start
bash ./hostctl.sh infra-stop
bash ./hostctl.sh infra-restart
bash ./hostctl.sh create demo --php 8.2 --db mysql --preset empty
bash ./hostctl.sh status
bash ./hostctl.sh stop demo.<zone>
bash ./hostctl.sh start demo.<zone>
bash ./hostctl.sh delete demo.<zone> --yes
```

`infra-start` автоматически переключается на fallback-compose, если Docker Desktop не может создать bind-mount на внешнем диске. В этом режиме DevPanel доступен также по `http://localhost:8088`.

Быстрая диагностика после старта:

```bash
cd infra/scripts
bash ./hostctl.sh status
bash ./hostctl.sh logs --tail 200
```

### Через DevPanel

- URL: `https://docker.<zone>` (где `<zone>` — ваш DOMAIN_SUFFIX, напр. `loc`)
- Возможности:
  - создание хоста (preset/php/db/bitrix-mode),
  - start/stop/restart/delete,
  - просмотр состояния и логов,
  - помощь по `/etc/hosts`.

## Политика состояния и логов

Служебные runtime-артефакты вынесены в `infra/state/`:

- `hosts-registry.tsv`
- `bitrix-core-registry.tsv`
- `bitrix-bindings.tsv`
- `hostctl.log`
- `devpanel-actions.log`
- `devpanel-jobs/`

Ревизия логов выполняется в диалоговом режиме:

```bash
cd infra/scripts
bash ./hostctl.sh logs-review
```

Опции:

- `--dry-run` — показать действия без удаления.

После сессии формируется отчет в `infra/state/log-review-report-*.md`.

## Пресеты

Текущий MVP-контур:

- `empty`
- `bitrix`

Контракт пресетов: `presets/CONTRACT.md`.

## Смена доменной зоны (DOMAIN_SUFFIX)

Смена `DOMAIN_SUFFIX` допустима только при **пустом registry** (без хостов). Пошаговая процедура: `infra/docs/DOMAIN_SUFFIX-MIGRATION.md`.

## Bitrix Multisite

Поддержка kernel/ext_kernel/link: общее ядро, симлинки shared paths, guard при удалении core.  
Runbook: `infra/docs/bitrix-multisite-runbook.md`  
Автотест критичного пути: `infra/scripts/acceptance/verify-bitrix-critical-path.sh`

## Карта документации

- `README.md` — основной вход.
- `infra/docs/bitrix-multisite-runbook.md` — Bitrix multisite: типы, shared paths, troubleshooting.
- `CONTRIBUTING.md` — правила вклада.
- `LICENSE` — лицензия.
- `kitty-specs/` — спецификации, планы, задачи и acceptance-артефакты.

## Важно

Эта инфраструктура предназначена для разработки, не для production.

- Не коммитьте реальные секреты (`.env`, ключи, сертификаты).
- Для ручных compose-операций на macOS используйте `COPYFILE_DISABLE=1` при необходимости.
