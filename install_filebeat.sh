#!/bin/bash

# Скрипт запускать через sudo
if [ "$EUID" -ne 0 ]; then
    echo "Запустите скрипт через sudo:"
    echo "sudo ./install_filebeat.sh"
    exit 1
fi

# Папка, где лежит deb-пакет Filebeat
DEB_FILE=$(find /home/administrator/distr -maxdepth 1 -name "filebeat*.deb" | head -n 1)

# Проверяем, найден ли пакет
if [ -z "$DEB_FILE" ]; then
    echo "Файл filebeat*.deb не найден в /home/administrator/distr"
    exit 1
fi

echo "Найден пакет:"
echo "$DEB_FILE"

# Устанавливаем Filebeat
dpkg -i "$DEB_FILE"

# Исправляем зависимости, если они нужны
apt --fix-broken install -y

# Создаём конфигурацию Filebeat
cat > /etc/filebeat/filebeat.yml <<EOF
filebeat.inputs:
  - type: filestream
    id: ubuntu-logs
    enabled: true

    paths:
      - /var/log/syslog
      - /var/log/*.log

output.logstash:
  hosts: ["10.10.92.1:5044"]
EOF

# Проверяем конфигурацию
filebeat test config -e

if [ $? -ne 0 ]; then
    echo "Ошибка в конфигурации Filebeat"
    exit 1
fi

# Включаем автозапуск и запускаем Filebeat
systemctl enable filebeat
systemctl restart filebeat

echo
echo "Установка завершена"
echo
