#!/bin/bash

set -e

CONFIG="/etc/zabbix/zabbix_agentd.conf"
REPO_URL="https://repo.zabbix.com/zabbix/7.0/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest_7.0+ubuntu24.04_all.deb"

echo "======================================"
echo " Установка и настройка Zabbix Agent"
echo "======================================"

if [ "$EUID" -ne 0 ]; then
    echo "Запустите скрипт через sudo:"
    echo "sudo bash $0"
    exit 1
fi

DEFAULT_HOSTNAME=$(hostname)

read -p "Введите Hostname [$DEFAULT_HOSTNAME]: " ZABBIX_HOSTNAME

if [ -z "$ZABBIX_HOSTNAME" ]; then
    ZABBIX_HOSTNAME="$DEFAULT_HOSTNAME"
fi

read -p "Введите IP-адрес Zabbix-сервера: " ZABBIX_SERVER_IP

if [ -z "$ZABBIX_SERVER_IP" ]; then
    echo "IP-адрес не указан."
    exit 1
fi

echo
echo "Hostname: $ZABBIX_HOSTNAME"
echo "Zabbix Server: $ZABBIX_SERVER_IP"
echo

read -p "Продолжить установку? [y/n]: " ANSWER

if [ "$ANSWER" != "y" ] && [ "$ANSWER" != "Y" ]; then
    echo "Установка отменена."
    exit 0
fi

apt update
apt install -y wget

wget -O /tmp/zabbix-release.deb "$REPO_URL"
dpkg -i /tmp/zabbix-release.deb
apt update

apt install -y zabbix-agent

cp "$CONFIG" "${CONFIG}.bak"

sed -i "s/^Server=.*/Server=$ZABBIX_SERVER_IP/" "$CONFIG"
sed -i "s/^ServerActive=.*/ServerActive=$ZABBIX_SERVER_IP/" "$CONFIG"
sed -i "s/^Hostname=.*/Hostname=$ZABBIX_HOSTNAME/" "$CONFIG"

grep -q "^Server=" "$CONFIG" ||
    echo "Server=$ZABBIX_SERVER_IP" >> "$CONFIG"

grep -q "^ServerActive=" "$CONFIG" ||
    echo "ServerActive=$ZABBIX_SERVER_IP" >> "$CONFIG"

grep -q "^Hostname=" "$CONFIG" ||
    echo "Hostname=$ZABBIX_HOSTNAME" >> "$CONFIG"

systemctl enable zabbix-agent
systemctl restart zabbix-agent

echo
echo "======================================"
echo " Zabbix Agent установлен и настроен"
echo "======================================"
echo "Hostname: $ZABBIX_HOSTNAME"
echo "Server: $ZABBIX_SERVER_IP"
echo
echo "Статус службы:"
systemctl --no-pager --full status zabbix-agent
