# Bitrix Multisite Runbook

## Типы хостов

| Тип | Описание | HTTP | БД |
|-----|----------|------|-----|
| `kernel` | Core-хост, основной сайт | ✅ | Собственная |
| `ext_kernel` | Core без HTTP (только shared) | ❌ | Собственная |
| `link` | Подключён к core | ✅ | Использует core |

## Shared vs site-specific пути

Для `link`-хостов:
- **Shared** (симлинки на core): `src/bitrix`, `src/upload`, `src/images`
- **Site-specific**: `src/local` — своя директория у каждого link

## Создание

```bash
# Core (kernel)
./infra/scripts/hostctl.sh create my-core.dev --preset bitrix --bitrix-type kernel --core-id core-main --no-start

# Core (ext_kernel, без HTTP)
./infra/scripts/hostctl.sh create my-ext.dev --preset bitrix --bitrix-type ext_kernel --core-id core-ext --no-start

# Link
./infra/scripts/hostctl.sh create my-link.dev --preset bitrix --bitrix-type link --core core-main --no-start
```

## Ограничения

- Нельзя удалить core, пока есть привязанные link-хосты.
- Порядок удаления: сначала link, потом core.
- `ext_kernel` не маршрутизируется Traefik (traefik.enable=false).

## Типовые ошибки

| Ошибка | Причина | Решение |
|--------|---------|---------|
| Error[invalid_core] | core_id не найден | Создайте core или проверьте имя |
| Error[delete_guard] | Есть link-хосты | Удалите link перед core |
| link_shared_paths_failed | Симлинки не созданы | Проверьте права, перезапустите create |

## Автотест критичного пути

```bash
DOMAIN_SUFFIX=dev infra/scripts/acceptance/verify-bitrix-critical-path.sh
```
