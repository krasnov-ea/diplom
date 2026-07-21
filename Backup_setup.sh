#!/bin/bash

BACKUP_SERVER="10.10.93.239"
BACKUP_USER="ubackup"
BACKUP_SCRIPT="/usr/local/bin/mysql_backup.sh"

# Скрипт нужно запускать от root
if [ "$EUID" -ne 0 ]; then
    echo "Запустите скрипт через sudo:"
    echo "sudo ./setup_mysql_backup.sh"
    exit 1
fi

# Ввод пароля MySQL
read -s -p "Введите пароль MySQL root: " MYSQL_PASSWORD
echo

# Сохраняем пароль MySQL
cat > /root/.my.cnf <<EOF
[client]
user=root
password=$MYSQL_PASSWORD
EOF

chmod 600 /root/.my.cnf

echo "Пароль MySQL сохранён."

# Создаём SSH-ключ, если его ещё нет
if [ ! -f /root/.ssh/id_ed25519 ]; then
    ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519 -N ""
fi

# Копируем SSH-ключ на backup-сервер
echo
echo "Введите пароль пользователя $BACKUP_USER на backup-сервере:"
ssh-copy-id "$BACKUP_USER@$BACKUP_SERVER"

# Проверяем наличие backup-скрипта
if [ ! -f "$BACKUP_SCRIPT" ]; then
    echo "Ошибка: не найден файл $BACKUP_SCRIPT"
    exit 1
fi

chmod +x "$BACKUP_SCRIPT"

# Добавляем запуск каждый день в 02:00
CRON_COMMAND="0 2 * * * $BACKUP_SCRIPT >> /var/log/mysql_backup.log 2>&1"

(crontab -l 2>/dev/null | grep -v "$BACKUP_SCRIPT"; echo "$CRON_COMMAND") | crontab -

echo
echo "Настройка завершена."
echo "Backup будет запускаться каждый день в 02:00."
echo
echo "Проверить cron:"
echo "sudo crontab -l"
echo
echo "Запустить backup вручную:"
echo "sudo $BACKUP_SCRIPT"
