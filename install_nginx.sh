#!/bin/bash

# Папка с локальными пакетами
DIR="/home/administrator/distr"

echo "Установка Nginx"
echo "1 - установить из репозитория"
echo "2 - установить из папки $DIR"
read -p "Выберите вариант: " VARIANT

# Запрос пароля sudo
sudo -v

# Установка Nginx
if [ "$VARIANT" = "1" ]; then
    sudo apt update
    sudo apt install -y nginx
elif [ "$VARIANT" = "2" ]; then
    sudo apt install -y --no-download $DIR/*.deb
else
    echo "Неверный вариант"
    exit 1
fi

# Ввод IP серверов Apache
read -p "Введите IP сервера Apache: " IP

SERVERS=""

while true
do
    SERVERS="$SERVERS    server $IP:8080;
"

    read -p "Введите ещё IP или нажмите 2 для продолжения установки: " IP

    if [ "$IP" = "2" ]; then
        break
    fi
done

# Резервная копия конфигурации
sudo cp /etc/nginx/sites-available/default \
/etc/nginx/sites-available/default.backup

# Создание конфигурации Nginx
{
    echo "upstream apache_backend {"
    printf "%b" "$SERVERS"
    echo "}"
    echo ""
    echo "server {"
    echo "    listen 80;"
    echo "    server_name _;"
    echo ""
    echo "    location / {"
    echo "        proxy_pass http://apache_backend;"
    echo '        proxy_set_header Host $host;'
    echo '        proxy_set_header X-Real-IP $remote_addr;'
    echo '        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;'
    echo '        proxy_set_header X-Forwarded-Proto $scheme;'
    echo "    }"
    echo "}"
} | sudo tee /etc/nginx/sites-available/default > /dev/null

# Проверка конфигурации
sudo nginx -t

# Перезапуск Nginx
sudo systemctl enable nginx
sudo systemctl restart nginx

echo "Установка завершена"
echo "Nginx работает на порту 80"
echo "Запросы отправляются на Apache порт 8080"
