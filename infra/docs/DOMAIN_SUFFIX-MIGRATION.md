# Migration Runbook: смена DOMAIN_SUFFIX

Документ описывает безопасную процедуру смены активной локальной доменной зоны (`DOMAIN_SUFFIX`).  
Смена допустима **только при пустом registry** (FR-013).

---

## Preflight (перед сменой)

1. **Проверить registry:**
   ```bash
   bash ./infra/scripts/hostctl.sh status
   ```
   Если есть хосты — смена зоны **заблокирована**. Для перехода на новую зону сначала удалите все хосты и очистите registry.

2. **Создать backup (рекомендуется):**
   ```bash
   cp infra/.env.global infra/.env.global.bak.$(date +%Y%m%d)
   cp -r infra/state infra/state.bak.$(date +%Y%m%d) 2>/dev/null || true
   ```

3. **Остановить инфраструктуру:**
   ```bash
   bash ./infra/scripts/hostctl.sh infra-stop
   ```

---

## Шаги миграции

### 1. Убедиться, что registry пуст

```bash
# Должно вывести "No hosts found" или пустой список
bash ./infra/scripts/hostctl.sh status
```

Если хосты есть — выполните `hostctl delete <host> --yes` для каждого хоста.

### 2. Изменить DOMAIN_SUFFIX

Отредактируйте `infra/.env.global`:

```bash
# Было (пример):
DOMAIN_SUFFIX=loc

# Стало (пример):
DOMAIN_SUFFIX=pillat
```

### 3. Регенерировать SSL-сертификаты

```bash
bash ./infra/scripts/generate-ssl.sh --skip-trust
```

### 4. Запустить инфраструктуру

```bash
bash ./infra/scripts/start-all.sh
```

### 5. Обновить /etc/hosts

Добавьте записи для новой зоны. Пример для `DOMAIN_SUFFIX=pillat`:

```
127.0.0.1 docker.pillat
127.0.0.1 traefik.pillat
127.0.0.1 adminer.pillat
127.0.0.1 grafana.pillat
```

DevPanel показывает актуальный список доменов в блоке «Конфигурация /etc/hosts».

**Ограничение:** `/etc/hosts` не поддерживает wildcard-записи. Запись вида `127.0.0.1 *.local` не работает — нужно указывать каждый домен отдельно. Для резолва всех `*.zone` в один IP используйте локальный DNS-резолвер (например, dnsmasq: `address=/zone/127.0.0.1`).

### 6. Проверить доступность

```bash
# Замените <zone> на ваш DOMAIN_SUFFIX
curl -k --resolve docker.<zone>:443:127.0.0.1 https://docker.<zone>
```

---

## Post-check список

- [ ] `hostctl status` показывает ожидаемые хосты (если есть)
- [ ] Сервисы доступны по `https://<service>.<zone>`
- [ ] TLS не отдаёт default cert (проверка сертификата в браузере)
- [ ] DevPanel открывается и показывает домены в новой зоне
- [ ] Создание нового хоста создаёт `<name>.<zone>`

---

## Legacy-хосты (вне активной зоны)

Хосты с суффиксом, отличным от `DOMAIN_SUFFIX`, помечаются как **legacy** в:
- `hostctl status` (колонка ZONE)
- DevPanel (badge «legacy» у карточки проекта)

Legacy-хосты остаются доступными для start/stop/delete; операции выполняются без принудительного rename. Фича не гарантирует их поддержку при смене зоны — они находятся вне scope (FR-011).
