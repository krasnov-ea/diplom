# Diplom Project
<h1>Последовательность действий для установки на новый сервер</h1>

Скрипты позволяют устанавливать все пакеты из локальной папки. Для этого необходимо поместить в папку /home/administrator/distr/ не только основные пакеты, но и все их зависимости.  
 Пример списка пакетов в конце данного файла      
<h3>Далее по шагам:</h3>
0. Установить часовой пояс для корректного отображения времени **timedatectl set-timezone Europe/Moscow**

1. Скачиваем на "чистый" сервер скрипт установки и подключения к Git **deploy-git-github.sh**
   далее запускаем скрипт и отвечаем на несколько вопросов
   
2. В папке /home/administrator/diplom запускаем по очереди скрипты **deploy-mysql-replication.sh** и **install_apache_php83.sh**
   
   Которые установят:
   
      2.1 deploy-mysql-replication.sh - MySQL и настроят репликацию (в зависимости от выбранных параметров во время инсталяции)
         
      2.2 install_apache_php83.sh - Apache2 и создаст маленькую страницу приветствия
   
3. Настройка резервного копирования:
   
      3.1 Резервирование баз для последующего восстановления **backup_all_db.sh**
   
      3.2 Потабличное задание резервирования **backup_tables.sh**
   
5. Установка nginx и настройка балансировки **install_nginx.sh**.  
    _Технически его можно установить на один из серверов с Apache, но лучше выделить под nginx небольшой отдельный сервер_
6. Установка zabbix-agent **install_zabbix_agent.sh**
7. Для подключения мониторинга Zabbix зайти на http://zbxsrv/zabbix и добавить станцию

<h2>План восстановления:</h2>




   
<h2> Пример Apache2 и php </h2>
<h3>Основные .deb-пакеты</h3>

      <li>apache2</li>
      <li>apache2-bin</li>
      <li>apache2-data</li>
      <li>apache2-utils</li>
      <li>php8.3</li>
      <li>php8.3-common</li>
      <li>php8.3-cli</li>
      <li>php8.3-opcache</li>
      <li>php8.3-readline</li>
      <li>libapache2-mod-php8.3</li>

<h3>Дополнительные системные библиотеки</h3>

      <li>libargon2-1</li>
      <li>libedit2</li>
      <li>libpcre2-8-0</li>
      <li>libsodium23</li>
      <li>libssl3t64</li>
      <li>libxml2</li>
      <li>media-types</li>
      <li>tzdata</li>
      <li>ucf</li>
      <li>zlib1g</li>
      <li>perl</li>
      <li>procps</li>
