FROM php:8.2-apache

# Устанавливаем Docker CLI и Docker Compose plugin
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        lsb-release \
        python3 && \
    install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg && \
    chmod a+r /etc/apt/keyrings/docker.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null && \
    apt-get update && \
    apt-get install -y --no-install-recommends docker-ce-cli docker-compose-plugin && \
    rm -rf /var/lib/apt/lists/*

# Оставляем non-root Apache worker (www-data), чтобы избежать BIG_SECURITY_HOLE.
RUN sed -i 's/: ${APACHE_RUN_USER:=.*/: ${APACHE_RUN_USER:=www-data}/' /etc/apache2/envvars && \
    sed -i 's/: ${APACHE_RUN_GROUP:=.*/: ${APACHE_RUN_GROUP:=www-data}/' /etc/apache2/envvars

# Таймаут 10 минут для долгих запросов (создание проекта + docker compose)
RUN echo 'Timeout 600' >> /etc/apache2/apache2.conf

# Создаем скрипт для настройки прав на docker.sock и runtime-тома при запуске.
# chown/chmod по /state и /projects выполняем в фоне, иначе они блокируют запуск Apache
# (на больших деревьях проектов скрипт никогда не завершался → 502 Bad Gateway).
RUN echo '#!/bin/bash\nchmod 666 /var/run/docker.sock 2>/dev/null || true\nmkdir -p /state /projects\n( chown -R www-data:www-data /state /projects 2>/dev/null; chmod -R ug+rwX /state /projects 2>/dev/null; ) &\ntrue' > /usr/local/bin/fix-docker-sock.sh && \
    chmod +x /usr/local/bin/fix-docker-sock.sh

# Включаем модуль rewrite
RUN a2enmod rewrite

# Встраиваем runtime-артефакты в образ.
# Это позволяет запускать devpanel без bind-монтов (fallback mode),
# когда Docker Desktop не может смонтировать внешний диск.
COPY infra/devpanel/src/ /var/www/html/
COPY infra/scripts/ /scripts/
COPY infra/templates/ /templates/
COPY presets/ /presets/
COPY infra/docker-compose.shared.yml /docker-compose.shared.yml
COPY infra/docker-compose.devpanel-fallback.yml /docker-compose.devpanel-fallback.yml

RUN chmod -R a+rX /var/www/html /scripts /templates /presets && \
    chmod +x /scripts/*.sh
