# Diplom Project
<h1>Последовательность действий для установки на новый сервер</h1>

Скрипты позволяют устанавливать все пакеты из локальной папки. Для этого необходимо поместить в папку /home/administrator/distr/ не только основные пакеты, но и все их зависимости.

<h2>Основные .deb-пакеты</h2>

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

<h2>Дополнительные системные библиотеки</h2>

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

0. Установить часовой пояс для корректного отображения времени **timedatectl set-timezone Europe/Moscow**

1. Скачиваем на "чистый" сервер скрипт установки и подключения к Git **deploy-git-github.sh**
   далее запускаем скрипт и отвечаем на несколько вопросов
   
2. В папке /home/administrator/diplom запускаем по очереди скрипты **deploy-mysql-replication.sh** и **install_apache_php83.sh**
   
   Которые установят:
   
      2.1 deploy-mysql-replication.sh - MySQL и настроят репликацию (в зависимости от выбранных параметров во время инсталяции)
         
      2.2 install_apache_php83.sh - Apache2 и создаст маленькую страницу приветствия 
4. Установка nginx и настройка балансировки.  
    _Технически его можно установить на один из серверов с Apache, но лучше выделить под nginx небольшой отдельный сервер_
