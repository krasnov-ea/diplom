#!/bin/bash

BACKUP_SERVER="10.10.93.239"
BACKUP_USER="ubackup"

SOURCE_SCRIPT="/home/administrator/diplom/BackupSQL_to_uchebabkp.sh"
BACKUP_SCRIPT="/usr/local/bin/BackupSQL_to_uchebabkp.sh"

# Проверка запуска от root
if [ "$EUID" -ne 0 ]; then
    echo "Запустите через sudo"
    exit 1
fi

# Проверяем файл
if [ ! -f "$SOURCE_SCRIPT" ]; then
    echo "Файл не найден: $SOURCE_SCRIPT"
    exit 1
fi

# Копируем скрипт
cp "$SOURCE_SCRIPT" "$BACKUP_SCRIPT"

# Делаем исполняемым
chmod +x "$BACKUP_SCRIPT"

echo "Скрипт скопирован в $BACKUP_SCRIPT"

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

echo "Пароль MySQL сохранён"

# Создаём SSH-ключ
if [ ! -f /root/.ssh/id_ed25519 ]; then
    ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519 -N ""
fi

# Копируем ключ на backup-сервер
echo "Введите пароль пользователя $BACKUP_USER:"
ssh-copy-id "$BACKUP_USER@$BACKUP_SERVER"

# Добавляем задание в cron
CRON="0 2 * * * $BACKUP_SCRIPT >> /var/log/mysql_backup.log 2>&1"

(crontab -l 2>/dev/null | grep -v "$BACKUP_SCRIPT"; echo "$CRON") | crontab -

echo
echo "Настройка завершена"
echo "Backup будет запускаться каждый день в 02:00"
echo
echo "Проверить cron:"
echo "sudo crontab -l"
echo
echo "Запустить вручную:"
