# Инструкция по обновлению

## Обновление продукта (git pull)

Пользователь выполняет вручную:

```bash
git pull origin main
```

Структура ядра неизменяема; настройки в `.gitignore` не затрагиваются.

## Обновление скриптов пресетов

```bash
./infra/scripts/hostctl.sh update-presets
```

**Preflight:** при нечистом состоянии git (локальные изменения, конфликты) обновление блокируется.

**Rollback:** при сбое verify выполняется `git reset --hard` к предыдущему коммиту.

## Обновление компонентов (Adminer)

```bash
./infra/scripts/hostctl.sh update-component-adminer
```

## Troubleshooting

### Конфликты merge при git pull

1. Разрешите конфликты вручную.
2. `git add` изменённые файлы.
3. `git commit` или повторите `update-presets`.

### Presets повреждён после обновления

```bash
git -C . checkout HEAD -- presets/
```

### Откат к предыдущей версии

Для preset_scripts: см. журнал в `infra/state/update-operations/`.
