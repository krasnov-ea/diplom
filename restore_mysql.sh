```bash
#!/bin/bash

set -o pipefail

BACKUP_SERVER="10.10.93.239"
BACKUP_USER="ubackup"
BACKUP_DIR="/srv/backup"

# Проверяем запуск от root
if [ "$EUID" -ne 0 ]; then
    echo "Запустите скрипт через sudo"
    exit 1
fi

# Запускаем MySQL
systemctl start mysql

# Ввод имени старого сервера
read -p "Введите имя сервера: " SERVER_NAME

echo
echo "Последние 5 резервных копий:"
echo

# Получаем последние 5 копий
BACKUPS=$(ssh "$BACKUP_USER@$BACKUP_SERVER" \
    "ls -1t $BACKUP_DIR/${SERVER_NAME}_mysql_*.sql.gz 2>/dev/null | head -n 5")

# Проверяем, найдены ли копии
if [ -z "$BACKUPS" ]; then
    echo "Резервные копии для сервера $SERVER_NAME не найдены"
    exit 1
fi

# Показываем список с номерами
echo "$BACKUPS" | nl -w2 -s") "

echo
read -p "Введите номер резервной копии: " NUMBER

# Получаем выбранный файл
BACKUP_FILE=$(echo "$BACKUPS" | sed -n "${NUMBER}p")

# Проверяем выбор
if [ -z "$BACKUP_FILE" ]; then
    echo "Неправильный номер"
    exit 1
fi

echo
echo "Выбран файл:"
echo "$BACKUP_FILE"
echo

read -p "Начать восстановление? (y/n): " ANSWER

if [ "$ANSWER" != "y" ]; then
    echo "Восстановление отменено"
    exit 0
fi

# Ввод пароля MySQL
read -s -p "Введите пароль MySQL root: " MYSQL_PASSWORD
echo

# Создаём временный файл с паролем
MYSQL_CONFIG=$(mktemp)

cat > "$MYSQL_CONFIG" <<EOF
[client]
user=root
password=$MYSQL_PASSWORD
EOF

chmod 600 "$MYSQL_CONFIG"

# Удаляем временный файл после завершения
trap 'rm -f "$MYSQL_CONFIG"' EXIT

echo
echo "Начинаю восстановление..."

# Получаем backup и восстанавливаем MySQL
ssh "$BACKUP_USER@$BACKUP_SERVER" "cat '$BACKUP_FILE'" |
gzip -dc |
mysql --defaults-extra-file="$MYSQL_CONFIG"

if [ $? -eq 0 ]; then
    echo
    echo "Восстановление завершено успешно"

    systemctl restart mysql

    echo "MySQL перезапущен"
else
    echo
    echo "Ошибка восстановления"
    exit 1
fi
```
