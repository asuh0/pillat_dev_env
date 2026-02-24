# Миграция: src→www и логи в проекте

## Зачем меняли логи

**Было:** логи в `logs/php/<host>/`, `logs/nginx/<host>/` — централизованно в корне workspace. Пути в compose: `../../logs/php/<host>` — не относительные, дублировали структуру.

**Стало:** логи внутри проекта — `projects/<host>/logs/php/`, `projects/<host>/logs/nginx/`. Пути в compose: `./logs/php`, `./logs/nginx` — относительные, без дублирования.

## Миграция для проектов, созданных до изменений

1. **Переименовать src → www:**
   ```bash
   mv projects/<host>/src projects/<host>/www
   ```

2. **Создать структуру логов и обновить compose:**
   ```bash
   mkdir -p projects/<host>/logs/{php,nginx}
   ```
   В `docker-compose.yml` заменить:
   - `./src` → `./www`
   - `../../logs/php/<host>` → `./logs/php`
   - `../../logs/nginx/<host>` → `./logs/nginx`

3. **Перенести существующие логи** (опционально):
   ```bash
   cp -r logs/php/<host>/* projects/<host>/logs/php/ 2>/dev/null || true
   cp -r logs/nginx/<host>/* projects/<host>/logs/nginx/ 2>/dev/null || true
   ```

4. **Перезапустить хост:**
   ```bash
   ./infra/scripts/hostctl.sh stop <host>
   ./infra/scripts/hostctl.sh start <host>
   ```
