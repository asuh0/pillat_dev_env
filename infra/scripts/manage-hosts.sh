#!/bin/bash

# Скрипт управления /etc/hosts
# Использование:
#   ./manage-hosts.sh add <domain>     - добавить запись
#   ./manage-hosts.sh remove <domain>  - удалить запись
#   ./manage-hosts.sh check <domain>   - проверить наличие записи
#   ./manage-hosts.sh list             - показать все записи проектов

set -e

HOSTS_FILE="/etc/hosts"
MARKER_START="# Docker DevPanel Projects - START"
MARKER_END="# Docker DevPanel Projects - END"
IP="127.0.0.1"

if [ -z "$1" ]; then
    echo "Использование: $0 <add|remove|check|list> [domain]"
    exit 1
fi

ACTION="$1"
DOMAIN="$2"

# Функция для проверки наличия маркеров
has_markers() {
    grep -q "$MARKER_START" "$HOSTS_FILE" 2>/dev/null && grep -q "$MARKER_END" "$HOSTS_FILE" 2>/dev/null
}

# Функция для добавления маркеров, если их нет
ensure_markers() {
    if ! has_markers; then
        echo "" >> "$HOSTS_FILE"
        echo "$MARKER_START" >> "$HOSTS_FILE"
        echo "$MARKER_END" >> "$HOSTS_FILE"
    fi
}

# Функция для проверки наличия записи
entry_exists() {
    local domain="$1"
    if has_markers; then
        sed -n "/$MARKER_START/,/$MARKER_END/p" "$HOSTS_FILE" | grep -q "^$IP.*$domain" 2>/dev/null
    else
        grep -q "^$IP.*$domain" "$HOSTS_FILE" 2>/dev/null
    fi
}

case "$ACTION" in
    add)
        if [ -z "$DOMAIN" ]; then
            echo "❌ Укажите домен для добавления"
            exit 1
        fi
        
        # Проверяем права доступа
        if [ ! -w "$HOSTS_FILE" ]; then
            echo "⚠️  Требуются права root для редактирования $HOSTS_FILE"
            echo "   Попытка через sudo..."
            if ! sudo -n true 2>/dev/null; then
                echo "   Запрос пароля для sudo..."
            fi
        fi
        
        # Проверяем, существует ли уже запись
        if entry_exists "$DOMAIN"; then
            echo "ℹ️  Запись для $DOMAIN уже существует в $HOSTS_FILE"
            exit 0
        fi
        
        # Убеждаемся, что маркеры есть
        if [ -w "$HOSTS_FILE" ]; then
            ensure_markers
        else
            echo "$MARKER_START" | sudo tee -a "$HOSTS_FILE" > /dev/null 2>&1 || true
            echo "$MARKER_END" | sudo tee -a "$HOSTS_FILE" > /dev/null 2>&1 || true
        fi
        
        # Добавляем запись
        ENTRY="$IP $DOMAIN"
        if [ -w "$HOSTS_FILE" ]; then
            # Вставляем перед маркером END
            if [[ "$OSTYPE" == "darwin"* ]]; then
                # macOS
                sed -i '' "/$MARKER_END/i\\
$ENTRY
" "$HOSTS_FILE"
            else
                # Linux
                sed -i "/$MARKER_END/i\\$ENTRY" "$HOSTS_FILE"
            fi
        else
            # Используем sudo
            if [[ "$OSTYPE" == "darwin"* ]]; then
                # macOS
                sudo sed -i '' "/$MARKER_END/i\\
$ENTRY
" "$HOSTS_FILE"
            else
                # Linux
                sudo sed -i "/$MARKER_END/i\\$ENTRY" "$HOSTS_FILE"
            fi
        fi
        
        echo "✅ Добавлена запись в $HOSTS_FILE: $ENTRY"
        ;;
        
    remove)
        if [ -z "$DOMAIN" ]; then
            echo "❌ Укажите домен для удаления"
            exit 1
        fi
        
        # Проверяем права доступа
        if [ ! -w "$HOSTS_FILE" ]; then
            echo "⚠️  Требуются права root для редактирования $HOSTS_FILE"
            if ! sudo -n true 2>/dev/null; then
                echo "   Запрос пароля для sudo..."
            fi
        fi
        
        # Проверяем, существует ли запись
        if ! entry_exists "$DOMAIN"; then
            echo "ℹ️  Запись для $DOMAIN не найдена в $HOSTS_FILE"
            exit 0
        fi
        
        # Удаляем запись
        if [ -w "$HOSTS_FILE" ]; then
            if [[ "$OSTYPE" == "darwin"* ]]; then
                # macOS
                sed -i '' "/^$IP.*$DOMAIN$/d" "$HOSTS_FILE"
            else
                # Linux
                sed -i "/^$IP.*$DOMAIN$/d" "$HOSTS_FILE"
            fi
        else
            # Используем sudo
            if [[ "$OSTYPE" == "darwin"* ]]; then
                # macOS
                sudo sed -i '' "/^$IP.*$DOMAIN$/d" "$HOSTS_FILE"
            else
                # Linux
                sudo sed -i "/^$IP.*$DOMAIN$/d" "$HOSTS_FILE"
            fi
        fi
        
        echo "✅ Удалена запись из $HOSTS_FILE: $IP $DOMAIN"
        ;;
        
    check)
        if [ -z "$DOMAIN" ]; then
            echo "❌ Укажите домен для проверки"
            exit 1
        fi
        
        if entry_exists "$DOMAIN"; then
            echo "✅ Запись для $DOMAIN найдена в $HOSTS_FILE"
            exit 0
        else
            echo "❌ Запись для $DOMAIN не найдена в $HOSTS_FILE"
            exit 1
        fi
        ;;
        
    list)
        if has_markers; then
            echo "📋 Записи проектов в $HOSTS_FILE:"
            sed -n "/$MARKER_START/,/$MARKER_END/p" "$HOSTS_FILE" | grep -v "^#" | grep -v "^$" | grep "$IP" || echo "   (нет записей)"
        else
            echo "ℹ️  Маркеры проектов не найдены в $HOSTS_FILE"
            echo "   Используйте 'add' для создания первой записи"
        fi
        ;;
        
    *)
        echo "❌ Неизвестное действие: $ACTION"
        echo "Использование: $0 <add|remove|check|list> [domain]"
        exit 1
        ;;
esac
