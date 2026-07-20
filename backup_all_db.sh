#!/bin/bash
DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="/var/backups/mysql/full_backup_$DATE"
COUNT=0

mkdir -p "$BACKUP_DIR"

read -s -p "Введите пароль MySQL root: " MYSQL_PASSWORD
echo

MYSQL_CONFIG=$(mktemp)

cat > "$MYSQL_CONFIG" <<EOF
[client]
user=root
password=$MYSQL_PASSWORD
EOF

chmod 600 "$MYSQL_CONFIG"
trap 'rm -f "$MYSQL_CONFIG"' EXIT
DATABASES=$(mysql \
    --defaults-extra-file="$MYSQL_CONFIG" \
    -N \
    -e "SHOW DATABASES;" |
    grep -Ev "^(information_schema|performance_schema|sys)$")

for DB in $DATABASES
do
    BACKUP_FILE="$BACKUP_DIR/${DB}_${DATE}.sql"

    echo "Создаю резервную копию базы: $DB"

    if mysqldump \
        --defaults-extra-file="$MYSQL_CONFIG" \
        --single-transaction \
        --routines \
        --triggers \
        --events \
        --set-gtid-purged=OFF \
        --databases "$DB" > "$BACKUP_FILE"
    then
        echo "Готово: $BACKUP_FILE"
        COUNT=$((COUNT + 1))
    else
        echo "Ошибка резервного копирования базы: $DB"
        rm -f "$BACKUP_FILE"
    fi
done
echo
echo "Резервное копирование завершено."
echo "Каталог: $BACKUP_DIR"
