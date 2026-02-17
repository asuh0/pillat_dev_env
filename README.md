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

1) Подготовьте infra-конфиг:

```bash
cd infra
cp .env.global.example .env.global
```

2) Сгенерируйте SSL для локальной среды:

```bash
cd infra/scripts
bash ./generate-ssl.sh
```

3) Запустите общую инфраструктуру:

```bash
cd infra
bash ./scripts/start-all.sh
```

Скрипт использует `hostctl.sh infra-start` и автоматически включает fallback-режим при проблемах bind-mount (например, на внешнем диске).

4) Добавьте базовые домены в `/etc/hosts`:

```text
127.0.0.1 docker.dev
127.0.0.1 traefik.dev
127.0.0.1 adminer.dev
127.0.0.1 grafana.dev
```

5) Проверьте доступность DevPanel:

```bash
curl -k --resolve docker.dev:443:127.0.0.1 https://docker.dev
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
bash ./hostctl.sh create demo.dev --php 8.2 --db mysql --preset empty
bash ./hostctl.sh status
bash ./hostctl.sh stop demo.dev
bash ./hostctl.sh start demo.dev
bash ./hostctl.sh delete demo.dev --yes
```

`infra-start` автоматически переключается на fallback-compose, если Docker Desktop не может создать bind-mount на внешнем диске. В этом режиме DevPanel доступен также по `http://localhost:8088`.

Быстрая диагностика после старта:

```bash
cd infra/scripts
bash ./hostctl.sh status
bash ./hostctl.sh logs --tail 200
```

### Через DevPanel

- URL: `https://docker.dev`
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

## Карта документации

- `README.md` — основной вход.
- `CONTRIBUTING.md` — правила вклада.
- `LICENSE` — лицензия.
- `kitty-specs/` — спецификации, планы, задачи и acceptance-артефакты.

## Важно

Эта инфраструктура предназначена для разработки, не для production.

- Не коммитьте реальные секреты (`.env`, ключи, сертификаты).
- Для ручных compose-операций на macOS используйте `COPYFILE_DISABLE=1` при необходимости.
