#!/usr/bin/env bash
# Автоматическое развертывание MySQL на Ubuntu 24.04 LTS.
#
# Режимы:
#   1) repository — пакет mysql-server из настроенных репозиториев Ubuntu
#   2) local      — установка всех .deb из /home/administrator/distr/
#
# Примеры:
#   ./deploy-mysql-ubuntu2404.sh
#   ./deploy-mysql-ubuntu2404.sh --source repository --yes
#   ./deploy-mysql-ubuntu2404.sh --source local --local-dir /home/administrator/distr
#   ./deploy-mysql-ubuntu2404.sh --source local --offline --yes
#   ./deploy-mysql-ubuntu2404.sh --source repository --bind-address 10.10.93.223
#
# Переменные окружения:
#   LOCAL_DIR             каталог с локальными .deb
#   MYSQL_BIND_ADDRESS    адрес прослушивания MySQL (если не задан — конфиг не меняется)
#
# Важно:
#   --offline запрещает APT скачивать недостающие зависимости. В этом случае
#   все необходимые .deb должны находиться локально или уже быть в кэше APT.

set -Eeuo pipefail
IFS=$'\n\t'
umask 027

readonly SCRIPT_NAME="${0##*/}"
readonly REQUIRED_OS_ID="ubuntu"
readonly REQUIRED_OS_VERSION="24.04"

INSTALL_SOURCE=""
LOCAL_DIR="${LOCAL_DIR:-/home/administrator/distr}"
MYSQL_BIND_ADDRESS="${MYSQL_BIND_ADDRESS:-}"
ASSUME_YES=0
OFFLINE_MODE=0
SKIP_HARDENING=0

SUDO=()
SUDO_KEEPALIVE_PID=""
TEMP_MYSQL_CNF=""

log() {
    printf '[%(%Y-%m-%d %H:%M:%S)T] %s\n' -1 "$*"
}

warn() {
    printf '[%(%Y-%m-%d %H:%M:%S)T] ПРЕДУПРЕЖДЕНИЕ: %s\n' -1 "$*" >&2
}

die() {
    printf '[%(%Y-%m-%d %H:%M:%S)T] ОШИБКА: %s\n' -1 "$*" >&2
    exit 1
}

cleanup() {
    if [[ -n "${SUDO_KEEPALIVE_PID:-}" ]]; then
        kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    fi
    if [[ -n "${TEMP_MYSQL_CNF:-}" && -f "$TEMP_MYSQL_CNF" ]]; then
        rm -f -- "$TEMP_MYSQL_CNF"
    fi
}

on_error() {
    local exit_code=$?
    warn "Команда завершилась с кодом ${exit_code}: ${BASH_COMMAND}"
    exit "$exit_code"
}

trap cleanup EXIT
trap on_error ERR
trap 'die "Выполнение прервано пользователем."' INT TERM

usage() {
    cat <<EOF
Использование:
  ${SCRIPT_NAME} [параметры]

Параметры:
  --source repository|local
                          источник установки; без параметра появится меню
  --local-dir PATH        каталог с локальными .deb
                          по умолчанию: ${LOCAL_DIR}
  --offline               не скачивать зависимости при локальной установке
  --bind-address ADDRESS  создать отдельный конфиг bind-address
                          пример: 127.0.0.1, 0.0.0.0 или IP сервера
  --skip-hardening        не удалять anonymous users и тестовую БД
  -y, --yes               автоматически подтверждать безопасные запросы
  -h, --help              показать справку

Примеры:
  ${SCRIPT_NAME}
  ${SCRIPT_NAME} --source repository --yes
  ${SCRIPT_NAME} --source local --local-dir /home/administrator/distr
  ${SCRIPT_NAME} --source local --offline --yes
EOF
}

normalize_source() {
    case "${1,,}" in
        repository|repo|репозиторий|1)
            printf 'repository'
            ;;
        local|локально|локальный|2)
            printf 'local'
            ;;
        *)
            return 1
            ;;
    esac
}

parse_args() {
    while (($# > 0)); do
        case "$1" in
            --source)
                (($# >= 2)) || die "Для --source требуется значение."
                INSTALL_SOURCE="$(normalize_source "$2")" ||
                    die "Неизвестный источник: $2. Используйте repository или local."
                shift 2
                ;;
            --local-dir)
                (($# >= 2)) || die "Для --local-dir требуется путь."
                LOCAL_DIR="$2"
                shift 2
                ;;
            --offline)
                OFFLINE_MODE=1
                shift
                ;;
            --bind-address)
                (($# >= 2)) || die "Для --bind-address требуется адрес."
                MYSQL_BIND_ADDRESS="$2"
                shift 2
                ;;
            --skip-hardening)
                SKIP_HARDENING=1
                shift
                ;;
            -y|--yes)
                ASSUME_YES=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "Неизвестный параметр: $1"
                ;;
        esac
    done
}

check_prerequisites() {
    [[ -r /etc/os-release ]] || die "Не найден /etc/os-release."
    # shellcheck disable=SC1091
    source /etc/os-release

    [[ "${ID:-}" == "$REQUIRED_OS_ID" ]] ||
        die "Скрипт предназначен для Ubuntu, обнаружено: ${ID:-неизвестно}."
    [[ "${VERSION_ID:-}" == "$REQUIRED_OS_VERSION" ]] ||
        die "Скрипт предназначен для Ubuntu 24.04 LTS, обнаружено: ${VERSION_ID:-неизвестно}."

    local command_name
    for command_name in bash systemctl dpkg dpkg-query dpkg-deb apt-get find sort; do
        command -v "$command_name" >/dev/null 2>&1 ||
            die "Не найдена обязательная команда: $command_name"
    done

    if dpkg-query -W -f='${Status}\n' mariadb-server 2>/dev/null |
        grep -q '^install ok installed$'; then
        die "Обнаружен установленный mariadb-server. Автоматическая замена на MySQL отменена."
    fi
}

acquire_privileges() {
    if ((EUID == 0)); then
        SUDO=()
        log "Скрипт запущен от root; sudo не требуется."
        return
    fi

    command -v sudo >/dev/null 2>&1 ||
        die "Для запуска не от root требуется пакет sudo."

    log "Для установки нужны административные права. sudo может запросить пароль."
    sudo -v || die "Не удалось получить права sudo."
    SUDO=(sudo)

    # Обновляем timestamp sudo, пока работает основной скрипт.
    (
        while kill -0 "$$" 2>/dev/null; do
            sudo -n true 2>/dev/null || exit
            sleep 50
        done
    ) &
    SUDO_KEEPALIVE_PID=$!
}

confirm() {
    local prompt="$1"
    local answer=""

    if ((ASSUME_YES == 1)); then
        return 0
    fi

    read -r -p "${prompt} [y/N]: " answer
    [[ "$answer" =~ ^([yY]|[дД])$ ]]
}

choose_source() {
    [[ -n "$INSTALL_SOURCE" ]] && return

    while true; do
        cat <<'EOF'

Выберите источник установки MySQL:
  1) Репозитории Ubuntu — apt-get install mysql-server
  2) Локальные .deb — каталог /home/administrator/distr/
EOF
        read -r -p "Ваш выбор [1/2]: " choice
        if INSTALL_SOURCE="$(normalize_source "$choice")"; then
            return
        fi
        warn "Введите 1 или 2."
    done
}

show_existing_mysql() {
    if dpkg-query -W -f='${Status}' mysql-server 2>/dev/null |
        grep -q 'install ok installed'; then
        local current_version
        current_version="$(dpkg-query -W -f='${Version}' mysql-server 2>/dev/null || true)"
        log "mysql-server уже установлен, версия пакета: ${current_version:-неизвестна}."
        log "Скрипт проверит/доустановит пакеты и приведет службу в рабочее состояние."
    fi
}

install_from_repository() {
    ((OFFLINE_MODE == 0)) ||
        die "--offline применим только вместе с --source local."

    log "Обновление индекса пакетов Ubuntu..."
    "${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive apt-get update

    log "Установка mysql-server из настроенных репозиториев Ubuntu..."
    "${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive \
        apt-get install -y mysql-server
}

collect_local_debs() {
    local -n result_array=$1

    [[ -d "$LOCAL_DIR" ]] ||
        die "Каталог локальных пакетов не найден: $LOCAL_DIR"
    [[ -r "$LOCAL_DIR" ]] ||
        die "Нет прав на чтение каталога: $LOCAL_DIR"

    mapfile -d '' -t result_array < <(
        find "$LOCAL_DIR" -maxdepth 1 -type f -name '*.deb' -print0 | sort -z
    )

    ((${#result_array[@]} > 0)) ||
        die "В каталоге $LOCAL_DIR не найдено файлов *.deb."
}

inspect_local_debs() {
    local host_arch
    local deb package version architecture

    host_arch="$(dpkg --print-architecture)"
    log "Обнаружены локальные пакеты:"

    for deb in "$@"; do
        if ! package="$(dpkg-deb -f "$deb" Package 2>/dev/null)" ||
           ! version="$(dpkg-deb -f "$deb" Version 2>/dev/null)" ||
           ! architecture="$(dpkg-deb -f "$deb" Architecture 2>/dev/null)"; then
            die "Файл не является корректным Debian-пакетом: $deb"
        fi

        if [[ "$architecture" != "all" && "$architecture" != "$host_arch" ]]; then
            die "Архитектура пакета $package ($architecture) не соответствует системе ($host_arch): $deb"
        fi

        printf '  - %s %s [%s] — %s\n' "$package" "$version" "$architecture" "$deb"
    done
}

install_from_local_directory() {
    local -a deb_files=()
    local -a apt_options=()

    collect_local_debs deb_files
    inspect_local_debs "${deb_files[@]}"

    if ! confirm "Установить ВСЕ перечисленные .deb-пакеты?"; then
        die "Локальная установка отменена."
    fi

    if ((OFFLINE_MODE == 1)); then
        apt_options+=(--no-download)
        log "Включен offline-режим: APT не будет скачивать недостающие пакеты."
    else
        log "APT сможет использовать настроенные репозитории для недостающих зависимостей."
    fi

    log "Установка локальных .deb из $LOCAL_DIR..."
    "${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive \
        apt-get install -y "${apt_options[@]}" "${deb_files[@]}"
}

apply_bind_address() {
    local config_dir config_file config_tmp

    [[ -n "$MYSQL_BIND_ADDRESS" ]] || return
    [[ "$MYSQL_BIND_ADDRESS" != *$'\n'* && "$MYSQL_BIND_ADDRESS" != *$'\r'* ]] ||
        die "Недопустимое значение bind-address."

    if [[ -d /etc/mysql/mysql.conf.d ]]; then
        config_dir="/etc/mysql/mysql.conf.d"
    elif [[ -d /etc/mysql/conf.d ]]; then
        config_dir="/etc/mysql/conf.d"
    else
        config_dir="/etc/mysql/mysql.conf.d"
        "${SUDO[@]}" install -d -m 0755 "$config_dir"
    fi

    config_file="${config_dir}/99-auto-deploy.cnf"
    config_tmp="$(mktemp)"

    cat >"$config_tmp" <<EOF
# Создан ${SCRIPT_NAME}
[mysqld]
bind-address = ${MYSQL_BIND_ADDRESS}
EOF

    "${SUDO[@]}" install -m 0644 "$config_tmp" "$config_file"
    rm -f "$config_tmp"

    log "Настроен bind-address=${MYSQL_BIND_ADDRESS} в ${config_file}."
    warn "Для удаленного доступа отдельно настройте MySQL-пользователя и сетевой экран."
}

start_and_wait_for_mysql() {
    log "Включение и запуск службы mysql..."
    "${SUDO[@]}" systemctl daemon-reload
    "${SUDO[@]}" systemctl enable --now mysql

    local attempt
    for attempt in {1..60}; do
        if "${SUDO[@]}" systemctl is-active --quiet mysql; then
            if command -v mysqladmin >/dev/null 2>&1 &&
               "${SUDO[@]}" mysqladmin --protocol=socket ping --silent >/dev/null 2>&1; then
                log "MySQL принимает подключения через локальный сокет."
                return
            fi
        fi
        sleep 1
    done

    "${SUDO[@]}" systemctl status mysql --no-pager || true
    "${SUDO[@]}" journalctl -u mysql -n 80 --no-pager || true
    die "MySQL не перешел в рабочее состояние за 60 секунд."
}

create_password_defaults_file() {
    local mysql_password="$1"
    local escaped_password

    escaped_password="${mysql_password//\\/\\\\}"
    escaped_password="${escaped_password//\"/\\\"}"

    TEMP_MYSQL_CNF="$(mktemp)"
    chmod 0600 "$TEMP_MYSQL_CNF"
    cat >"$TEMP_MYSQL_CNF" <<EOF
[client]
user=root
password="${escaped_password}"
protocol=socket
EOF
}

harden_mysql() {
    local -a mysql_command=()
    local mysql_root_password=""

    ((SKIP_HARDENING == 0)) || {
        warn "Базовое усиление безопасности пропущено (--skip-hardening)."
        return
    }

    if "${SUDO[@]}" mysql --protocol=socket --user=root \
        --batch --skip-column-names -e 'SELECT 1;' >/dev/null 2>&1; then
        mysql_command=("${SUDO[@]}" mysql --protocol=socket --user=root)
        log "Для root используется локальная socket-аутентификация."
    elif [[ -t 0 ]]; then
        printf '\n'
        read -r -s -p "Введите текущий пароль MySQL root (Enter — пропустить hardening): " \
            mysql_root_password
        printf '\n'

        if [[ -z "$mysql_root_password" ]]; then
            warn "Не удалось войти как root; базовое усиление безопасности пропущено."
            return
        fi

        create_password_defaults_file "$mysql_root_password"
        if "${SUDO[@]}" mysql --defaults-extra-file="$TEMP_MYSQL_CNF" \
            --batch --skip-column-names -e 'SELECT 1;' >/dev/null 2>&1; then
            mysql_command=("${SUDO[@]}" mysql "--defaults-extra-file=$TEMP_MYSQL_CNF")
        else
            warn "Указанный пароль root не подошел; базовое усиление безопасности пропущено."
            return
        fi
    else
        warn "Нет socket-доступа root и интерактивного терминала; hardening пропущен."
        return
    fi

    log "Удаление анонимных учетных записей и тестовой базы..."
    "${mysql_command[@]}" <<'SQL'
DELETE FROM mysql.user WHERE User = '';
DELETE FROM mysql.user
 WHERE User = 'root'
   AND Host NOT IN ('localhost');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db
 WHERE Db = 'test'
    OR Db LIKE 'test\_%';
FLUSH PRIVILEGES;
SQL

    log "Базовое усиление безопасности выполнено."
}

verify_installation() {
    local server_package=""
    local package_version service_state service_enabled mysql_version
    local candidate

    for candidate in \
        mysql-server \
        mysql-community-server \
        mysql-server-8.0 \
        mysql-server-8.4
    do
        if dpkg-query -W -f='${Status}' "$candidate" 2>/dev/null |
            grep -q 'install ok installed'; then
            server_package="$candidate"
            break
        fi
    done

    [[ -n "$server_package" ]] ||
        die "Не найден установленный серверный пакет MySQL."

    package_version="$(dpkg-query -W -f='${Version}' "$server_package" 2>/dev/null)"
    service_state="$("${SUDO[@]}" systemctl is-active mysql)"
    service_enabled="$("${SUDO[@]}" systemctl is-enabled mysql)"
    mysql_version="$(mysql --version 2>/dev/null || true)"

    [[ "$service_state" == "active" ]] ||
        die "Служба mysql имеет состояние: $service_state"

    printf '\n'
    log "Развертывание MySQL завершено успешно."
    printf '  Источник:           %s\n' "$INSTALL_SOURCE"
    printf '  Серверный пакет:    %s %s\n' "$server_package" "$package_version"
    printf '  Служба:             %s, автозапуск: %s\n' "$service_state" "$service_enabled"
    printf '  Клиент:              %s\n' "${mysql_version:-не найден}"
    if [[ -n "$MYSQL_BIND_ADDRESS" ]]; then
        printf '  bind-address:       %s\n' "$MYSQL_BIND_ADDRESS"
    else
        printf '  bind-address:       не изменялся скриптом\n'
    fi

    printf '\nПрослушиваемые MySQL-порты:\n'
    "${SUDO[@]}" ss -lntp 2>/dev/null |
        awk 'NR == 1 || $4 ~ /:3306$|:33060$/ {print}' || true

    printf '\nПроверка службы:\n'
    printf '  sudo systemctl status mysql\n'
    printf 'Подключение администратора на Ubuntu:\n'
    printf '  sudo mysql\n'
}

main() {
    parse_args "$@"
    check_prerequisites
    acquire_privileges
    choose_source
    show_existing_mysql

    case "$INSTALL_SOURCE" in
        repository)
            install_from_repository
            ;;
        local)
            install_from_local_directory
            ;;
        *)
            die "Внутренняя ошибка: неизвестный источник установки."
            ;;
    esac

    apply_bind_address
    start_and_wait_for_mysql
    harden_mysql

    # Hardening не должен останавливать сервер, но еще раз проверяем итог.
    "${SUDO[@]}" systemctl restart mysql
    start_and_wait_for_mysql
    verify_installation
}

main "$@"
