#!/bin/bash

# Остановить скрипт, если произошла ошибка
set -e

LOCAL_DIR="/home/administrator/distr"

# Запрашиваем пароль sudo в начале скрипта
if [ "$EUID" -ne 0 ]; then
    echo "Для установки нужны права администратора."
    sudo -v
fi

echo "Выберите способ установки:"
echo "1 - из репозитория"
echo "2 - из папки $LOCAL_DIR"
read -p "Введите 1 или 2: " choice

if [ "$choice" = "1" ]; then
    echo "Установка из репозитория..."

    sudo apt update
    sudo apt install -y apache2 php8.3 libapache2-mod-php8.3 php8.3-cli

elif [ "$choice" = "2" ]; then
    echo "Установка из локальной папки..."

    if [ ! -d "$LOCAL_DIR" ]; then
        echo "Ошибка: папка $LOCAL_DIR не найдена."
        exit 1
    fi

    if ! ls "$LOCAL_DIR"/*.deb >/dev/null 2>&1; then
        echo "Ошибка: в папке нет deb-пакетов."
        exit 1
    fi

    sudo apt install -y "$LOCAL_DIR"/*.deb

else
    echo "Неправильный выбор."
    exit 1
fi

# Настройка порта Apache
if grep -q "^Listen 80$" /etc/apache2/ports.conf; then
    sudo sed -i 's/^Listen 80$/Listen 8080/' /etc/apache2/ports.conf
elif ! grep -q "^Listen 8080$" /etc/apache2/ports.conf; then
    echo "Listen 8080" | sudo tee -a /etc/apache2/ports.conf >/dev/null
fi

# Настройка виртуального хоста
sudo sed -i 's/<VirtualHost \*:80>/<VirtualHost *:8080>/' \
    /etc/apache2/sites-enabled/000-default.conf

# Включение PHP для Apache
sudo a2enmod php8.3

# Создание главной страницы
sudo tee /var/www/html/index.php >/dev/null <<'PHP'
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<title>Apache Backend Server 1</title>
</head>
<body>
    <h1>Привет от Apache Server!</h1>

    <p>Это backend сервер Apache с IP: <?php echo $_SERVER['SERVER_ADDR']; ?></p>

    <p>Порт: <?php echo $_SERVER['SERVER_PORT']; ?></p>

    <hr>
    
</body>
</html>
PHP

# Удаляем стандартную страницу Apache
sudo rm -f /var/www/html/index.html

# Проверка настроек и перезапуск Apache
sudo apache2ctl configtest
sudo systemctl enable apache2
sudo systemctl restart apache2

echo ""
echo "Apache и PHP установлены."
echo "Откройте в браузере: http://localhost:8080/"
