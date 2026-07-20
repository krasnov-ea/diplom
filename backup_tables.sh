#!/bin/bash

BACKUP_DIR="/var/backups/mysql"
DATE=$(date +%Y%m%d_%H%M%S)
count=0

mkdir -p "$BACKUP_DIR"

DATABASES=$(mysql -e "SHOW DATABASES;" -s --skip-column-names)

for DB in $DATABASES; do
    TABLES=$(mysql -D "$DB" -e "SHOW TABLES;" -s --skip-column-names)
   
    for TABLE in $TABLES; do
     BACKUP_FILE="$BACKUP_DIR/${DB}_${TABLE}_$DATE.sql"
       mysqldump "$DB" "$TABLE" > "$BACKUP_FILE"
		count=$((count+1))
    done
done

echo "Резервное копирование всех таблиц завершено, $BACKUP_DIR"
