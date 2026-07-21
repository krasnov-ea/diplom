#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'
umask 027

readonly SCRIPT_NAME="${0##*/}"
readonly REQUIRED_OS_ID="ubuntu"
readonly REQUIRED_OS_VERSION="24.04"

readonly DEFAULT_LOCAL_DIR="/home/administrator/distr"
readonly DEFAULT_DUMP_FILE="/root/backup.sql"
readonly REPLICATION_CONFIG="/etc/mysql/mysql.conf.d/99-replication.cnf"
readonly MYSQLD_CONFIG="/etc/mysql/mysql.conf.d/mysqld.cnf"

INSTALL_MODE=""
INSTALL_SOURCE=""
LOCAL_DIR="${LOCAL_DIR:-$DEFAULT_LOCAL_DIR}"
MYSQL_ROLE=""
SECURE_INSTALLATION_MODE=""
ASSUME_YES=0
OFFLINE_MODE=0
SKIP_SECURE_INSTALLATION=0
SKIP_DUMP_TRANSFER=0

SLAVE_SSH_HOST=""
SLAVE_SSH_USER=""
SOURCE_HOST=""
SOURCE_PORT="3306"
DUMP_FILE="${MYSQL_DUMP_FILE:-$DEFAULT_DUMP_FILE}"
REPLICATION_USER="${MYSQL_REPL_USER:-repl}"
REPLICATION_PASSWORD="${MYSQL_REPL_PASSWORD:-Zxcv#1234}"

SUDO=()
SUDO_KEEPALIVE_PID=""
TEMP_MYSQL_CNF=""
MYSQL_ADMIN_MODE=""

COLOR_RESET=""
COLOR_BOLD=""
COLOR_RED=""
COLOR_GREEN=""
COLOR_YELLOW=""
COLOR_CYAN=""

init_colors() {
    if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
        COLOR_RESET="$(tput sgr0)"
        COLOR_BOLD="$(tput bold)"
        COLOR_RED="$(tput setaf 1)"
        COLOR_GREEN="$(tput setaf 2)"
        COLOR_YELLOW="$(tput setaf 3)"
        COLOR_CYAN="$(tput setaf 6)"
    fi
}

show_banner() {
    clear 2>/dev/null || true

    printf '%s\n' "${COLOR_CYAN}══════════════════════════════════════════════════════════════════════${COLOR_RESET}"
    printf '%s\n' "${COLOR_BOLD}${COLOR_CYAN}  АВТОМАТИЧЕСКОЕ РАЗВЕРТЫВАНИЕ MYSQL И GTID-РЕПЛИКАЦИИ${COLOR_RESET}"
    printf '%s\n' "${COLOR_CYAN}══════════════════════════════════════════════════════════════════════${COLOR_RESET}"
    printf '  Установка:        установить MySQL или использовать существующий\n'
    printf '  Безопасность:     запуск или пропуск mysql_secure_installation\n'
    printf '  Роли:             Master / Slave / без репликации\n'
    printf '  Дамп Master:      %s\n' "$DUMP_FILE"
    printf '  Дамп на Slave:    /tmp/backup.sql\n'
    printf '  Репликация:       GTID, ROW, SOURCE_AUTO_POSITION\n'
    printf '%s\n' "${COLOR_CYAN}══════════════════════════════════════════════════════════════════════${COLOR_RESET}"

    if ((ASSUME_YES == 0)) && [[ -t 0 ]]; then
        printf '\n%sНажмите любую клавишу для продолжения...%s' \
            "$COLOR_BOLD" "$COLOR_RESET"
        read -r -n 1 -s
        printf '\n\n'
    else
        printf '\n'
    fi
}

log() {
    printf '[%(%Y-%m-%d %H:%M:%S)T] %b\n' -1 "$*"
}

warn() {
    printf '[%(%Y-%m-%d %H:%M:%S)T] %bПРЕДУПРЕЖДЕНИЕ:%b %s\n' \
        -1 "$COLOR_YELLOW" "$COLOR_RESET" "$*" >&2
}

die() {
    printf '[%(%Y-%m-%d %H:%M:%S)T] %bОШИБКА:%b %s\n' \
        -1 "$COLOR_RED" "$COLOR_RESET" "$*" >&2
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

Установка:
  --install-mysql         установить или доустановить MySQL
  --skip-mysql-installation
                          пропустить установку и использовать существующий MySQL
  --source repository|local
                          источник установки
  --local-dir PATH        каталог локальных .deb
                          по умолчанию: ${LOCAL_DIR}
  --offline               не скачивать зависимости при локальной установке

Репликация:
  --role master|slave|none
                          роль сервера
  --slave-host HOST       IP или DNS-имя Slave при настройке Master
  --slave-user USER       SSH-пользователь Slave
  --source-host HOST      IP или DNS-имя Master при настройке Slave
  --source-port PORT      порт MySQL Master; по умолчанию: ${SOURCE_PORT}
  --dump-file PATH        путь дампа на Master; по умолчанию: ${DUMP_FILE}
  --skip-dump-transfer    создать дамп, но не передавать его на Slave

Безопасность:
  --run-secure-installation
                          запустить mysql_secure_installation
  --skip-secure-installation
                          не запускать mysql_secure_installation
  --skip-hardening        совместимый псевдоним предыдущего параметра

Общее:
  -y, --yes               подтверждать безопасные запросы автоматически
  -h, --help              показать справку

Переменные окружения:
  MYSQL_REPL_USER         пользователь репликации; по умолчанию: repl
  MYSQL_REPL_PASSWORD     пароль репликации; по умолчанию: Zxcv#1234
  MYSQL_DUMP_FILE         путь файла дампа

Примеры:
  ${SCRIPT_NAME}
  ${SCRIPT_NAME} --skip-mysql-installation --skip-secure-installation --role master
  ${SCRIPT_NAME} --source repository --role master
  ${SCRIPT_NAME} --source repository --role slave --source-host 10.10.93.10
  ${SCRIPT_NAME} --source local --local-dir ${DEFAULT_LOCAL_DIR} --offline
  MYSQL_REPL_PASSWORD='СложныйПароль' ${SCRIPT_NAME} --role master
EOF
}

normalize_install_mode() {
    case "${1,,}" in
        install|установить|1)
            printf 'install'
            ;;
        skip|пропустить|existing|существующий|2)
            printf 'skip'
            ;;
        *)
            return 1
            ;;
    esac
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

normalize_role() {
    case "${1,,}" in
        master|source|мастер|1)
            printf 'master'
            ;;
        slave|replica|реплика|слэйв|слейв|2)
            printf 'slave'
            ;;
        none|нет|без|3)
            printf 'none'
            ;;
        *)
            return 1
            ;;
    esac
}

parse_args() {
    while (($# > 0)); do
        case "$1" in
            --install-mysql)
                INSTALL_MODE="install"
                shift
                ;;
            --skip-mysql-installation|--skip-install)
                INSTALL_MODE="skip"
                shift
                ;;
            --source)
                (($# >= 2)) || die "Для --source требуется значение."
                INSTALL_SOURCE="$(normalize_source "$2")" ||
                    die "Используйте repository или local."
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
            --role)
                (($# >= 2)) || die "Для --role требуется значение."
                MYSQL_ROLE="$(normalize_role "$2")" ||
                    die "Используйте master, slave или none."
                shift 2
                ;;
            --slave-host)
                (($# >= 2)) || die "Для --slave-host требуется адрес."
                SLAVE_SSH_HOST="$2"
                shift 2
                ;;
            --slave-user)
                (($# >= 2)) || die "Для --slave-user требуется имя."
                SLAVE_SSH_USER="$2"
                shift 2
                ;;
            --source-host)
                (($# >= 2)) || die "Для --source-host требуется адрес."
                SOURCE_HOST="$2"
                shift 2
                ;;
            --source-port)
                (($# >= 2)) || die "Для --source-port требуется порт."
                SOURCE_PORT="$2"
                shift 2
                ;;
            --dump-file)
                (($# >= 2)) || die "Для --dump-file требуется путь."
                DUMP_FILE="$2"
                shift 2
                ;;
            --skip-dump-transfer)
                SKIP_DUMP_TRANSFER=1
                shift
                ;;
            --run-secure-installation)
                SECURE_INSTALLATION_MODE="run"
                SKIP_SECURE_INSTALLATION=0
                shift
                ;;
            --skip-secure-installation|--skip-hardening)
                SECURE_INSTALLATION_MODE="skip"
                SKIP_SECURE_INSTALLATION=1
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

confirm() {
    local prompt="$1"
    local answer=""

    if ((ASSUME_YES == 1)); then
        return 0
    fi

    [[ -t 0 ]] ||
        die "Требуется подтверждение в терминале. Используйте --yes."

    read -r -p "${prompt} [y/N]: " answer
    [[ "$answer" =~ ^([yY]|[дД])$ ]]
}

prompt_required() {
    local variable_name="$1"
    local prompt="$2"
    local value=""

    [[ -t 0 ]] ||
        die "Не задан параметр: ${variable_name}"

    while [[ -z "$value" ]]; do
        read -r -p "$prompt" value
    done

    printf -v "$variable_name" '%s' "$value"
}

validate_host() {
    local host="$1"
    [[ "$host" =~ ^[A-Za-z0-9._-]+$ ]] ||
        die "Недопустимый IP/DNS-адрес: ${host}"
}

validate_username() {
    local user="$1"
    [[ "$user" =~ ^[A-Za-z0-9._-]+$ ]] ||
        die "Недопустимое имя пользователя: ${user}"
}

validate_port() {
    [[ "$SOURCE_PORT" =~ ^[0-9]+$ ]] ||
        die "Порт должен быть числом: ${SOURCE_PORT}"
    ((SOURCE_PORT >= 1 && SOURCE_PORT <= 65535)) ||
        die "Недопустимый порт: ${SOURCE_PORT}"
}

sql_escape() {
    local value="$1"
    value="${value//\'/\'\'}"
    printf '%s' "$value"
}

check_prerequisites() {
    [[ -r /etc/os-release ]] || die "Не найден /etc/os-release."
    # shellcheck disable=SC1091
    source /etc/os-release

    [[ "${ID:-}" == "$REQUIRED_OS_ID" ]] ||
        die "Требуется Ubuntu, обнаружено: ${ID:-неизвестно}."
    [[ "${VERSION_ID:-}" == "$REQUIRED_OS_VERSION" ]] ||
        die "Требуется Ubuntu 24.04, обнаружено: ${VERSION_ID:-неизвестно}."

    local command_name
    for command_name in bash systemctl dpkg dpkg-query dpkg-deb apt-get find sort; do
        command -v "$command_name" >/dev/null 2>&1 ||
            die "Не найдена обязательная команда: ${command_name}"
    done

    if dpkg-query -W -f='${Status}\n' mariadb-server 2>/dev/null |
        grep -q '^install ok installed$'; then
        die "Обнаружен mariadb-server. Автоматическая замена на MySQL отменена."
    fi

    validate_port
}

acquire_privileges() {
    if ((EUID == 0)); then
        SUDO=()
        log "Скрипт запущен от root; sudo не требуется."
        return
    fi

    command -v sudo >/dev/null 2>&1 ||
        die "Для запуска не от root требуется sudo."

    log "Для установки требуются административные права."
    log "sudo может запросить локальный пароль пользователя."
    sudo -v || die "Не удалось получить права sudo."
    SUDO=(sudo)

    (
        while kill -0 "$$" 2>/dev/null; do
            sudo -n true 2>/dev/null || exit
            sleep 50
        done
    ) &
    SUDO_KEEPALIVE_PID=$!
}

choose_install_mode() {
    [[ -n "$INSTALL_MODE" ]] && return

    while true; do
        cat <<'EOF'

Установка MySQL:
  1) Установить или доустановить MySQL
  2) Пропустить установку и использовать уже установленный MySQL
EOF
        local choice=""
        read -r -p "Ваш выбор [1/2]: " choice

        if INSTALL_MODE="$(normalize_install_mode "$choice")"; then
            return
        fi

        warn "Введите 1 или 2."
    done
}

choose_secure_installation_mode() {
    [[ -n "$SECURE_INSTALLATION_MODE" ]] && return

    while true; do
        cat <<'EOF'

Запуск mysql_secure_installation:
  1) Запустить интерактивную настройку безопасности
  2) Пропустить mysql_secure_installation
EOF
        local choice=""
        read -r -p "Ваш выбор [1/2]: " choice

        case "$choice" in
            1|run|запустить)
                SECURE_INSTALLATION_MODE="run"
                SKIP_SECURE_INSTALLATION=0
                return
                ;;
            2|skip|пропустить)
                SECURE_INSTALLATION_MODE="skip"
                SKIP_SECURE_INSTALLATION=1
                return
                ;;
            *)
                warn "Введите 1 или 2."
                ;;
        esac
    done
}

choose_source() {
    [[ -n "$INSTALL_SOURCE" ]] && return

    while true; do
        cat <<'EOF'

Выберите источник установки MySQL:
  1) Репозитории Ubuntu
  2) Локальные .deb из /home/administrator/distr/
EOF
        local choice=""
        read -r -p "Ваш выбор [1/2]: " choice

        if INSTALL_SOURCE="$(normalize_source "$choice")"; then
            return
        fi

        warn "Введите 1 или 2."
    done
}

choose_role() {
    [[ -n "$MYSQL_ROLE" ]] && return

    while true; do
        cat <<'EOF'

Выберите роль MySQL:
  1) Master — источник репликации
  2) Slave  — реплика
  3) Без настройки репликации
EOF
        local choice=""
        read -r -p "Ваш выбор [1/2/3]: " choice

        if MYSQL_ROLE="$(normalize_role "$choice")"; then
            return
        fi

        warn "Введите 1, 2 или 3."
    done
}

show_existing_mysql() {
    local candidate
    for candidate in mysql-server mysql-community-server mysql-server-8.0 mysql-server-8.4; do
        if dpkg-query -W -f='${Status}' "$candidate" 2>/dev/null |
            grep -q 'install ok installed'; then
            log "MySQL уже установлен: ${candidate} $(dpkg-query -W -f='${Version}' "$candidate")"
            return
        fi
    done
}

install_from_repository() {
    ((OFFLINE_MODE == 0)) ||
        die "--offline применим только вместе с --source local."

    log "Обновление индекса пакетов Ubuntu..."
    "${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive apt-get update

    log "Установка mysql-server..."
    "${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive \
        apt-get install -y mysql-server
}

collect_local_debs() {
    local -n result_array=$1

    [[ -d "$LOCAL_DIR" ]] ||
        die "Каталог локальных пакетов не найден: ${LOCAL_DIR}"

    mapfile -d '' -t result_array < <(
        find "$LOCAL_DIR" -maxdepth 1 -type f -name '*.deb' -print0 | sort -z
    )

    ((${#result_array[@]} > 0)) ||
        die "В ${LOCAL_DIR} не найдено файлов .deb."
}

inspect_local_debs() {
    local host_arch
    local deb package version architecture

    host_arch="$(dpkg --print-architecture)"
    log "Локальные пакеты:"

    for deb in "$@"; do
        package="$(dpkg-deb -f "$deb" Package 2>/dev/null)" ||
            die "Некорректный пакет: ${deb}"
        version="$(dpkg-deb -f "$deb" Version 2>/dev/null)" ||
            die "Не удалось прочитать версию: ${deb}"
        architecture="$(dpkg-deb -f "$deb" Architecture 2>/dev/null)" ||
            die "Не удалось прочитать архитектуру: ${deb}"

        [[ "$architecture" == "all" || "$architecture" == "$host_arch" ]] ||
            die "Архитектура ${architecture} не соответствует ${host_arch}: ${deb}"

        printf '  - %s %s [%s]\n' "$package" "$version" "$architecture"
    done
}

install_from_local_directory() {
    local -a deb_files=()
    local -a apt_options=()

    collect_local_debs deb_files
    inspect_local_debs "${deb_files[@]}"

    confirm "Установить перечисленные пакеты?" ||
        die "Локальная установка отменена."

    if ((OFFLINE_MODE == 1)); then
        apt_options+=(--no-download)
        log "Offline-режим: загрузка зависимостей запрещена."
    fi

    "${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive \
        apt-get install -y "${apt_options[@]}" "${deb_files[@]}"
}

verify_existing_mysql_installation() {
    local command_name

    for command_name in mysql mysqladmin mysqldump; do
        command -v "$command_name" >/dev/null 2>&1 ||
            die "Установка MySQL пропущена, но команда ${command_name} не найдена."
    done

    if ! systemctl list-unit-files mysql.service >/dev/null 2>&1; then
        die "Установка MySQL пропущена, но служба mysql.service не найдена."
    fi

    INSTALL_SOURCE="existing"
    log "${COLOR_GREEN}${COLOR_BOLD}✓ Используется существующая установка MySQL: $(mysql --version)${COLOR_RESET}"
}

start_and_wait_for_mysql() {
    log "Запуск службы mysql..."
    "${SUDO[@]}" systemctl daemon-reload
    "${SUDO[@]}" systemctl enable --now mysql

    local attempt
    for attempt in {1..60}; do
        if "${SUDO[@]}" systemctl is-active --quiet mysql &&
           "${SUDO[@]}" mysqladmin --protocol=socket ping --silent \
               >/dev/null 2>&1; then
            log "${COLOR_GREEN}${COLOR_BOLD}✓ MySQL работает и принимает локальные подключения.${COLOR_RESET}"
            return
        fi
        sleep 1
    done

    "${SUDO[@]}" systemctl status mysql --no-pager || true
    "${SUDO[@]}" journalctl -u mysql -n 100 --no-pager || true
    die "MySQL не перешел в рабочее состояние за 60 секунд."
}

restart_mysql() {
    log "Перезапуск MySQL..."
    if ! "${SUDO[@]}" systemctl restart mysql; then
        "${SUDO[@]}" journalctl -u mysql -n 100 --no-pager || true
        die "Не удалось перезапустить MySQL."
    fi
    start_and_wait_for_mysql
}

run_mysql_secure_installation() {
    ((SKIP_SECURE_INSTALLATION == 0)) || {
        warn "mysql_secure_installation пропущен."
        return
    }

    command -v mysql_secure_installation >/dev/null 2>&1 ||
        die "Команда mysql_secure_installation не найдена."

    [[ -t 0 ]] ||
        die "mysql_secure_installation требует интерактивный терминал."

    printf '\n'
    log "${COLOR_CYAN}${COLOR_BOLD}Запуск mysql_secure_installation.${COLOR_RESET}"
    log "Ответьте на вопросы утилиты безопасности MySQL."
    printf '\n'

    "${SUDO[@]}" mysql_secure_installation

    log "${COLOR_GREEN}${COLOR_BOLD}✓ mysql_secure_installation завершен.${COLOR_RESET}"
}

create_password_defaults_file() {
    local mysql_password="$1"
    local escaped_password

    escaped_password="${mysql_password//\\/\\\\}"
    escaped_password="${escaped_password//\"/\\\"}"

    [[ -z "$TEMP_MYSQL_CNF" ]] || rm -f -- "$TEMP_MYSQL_CNF"
    TEMP_MYSQL_CNF="$(mktemp)"
    chmod 0600 "$TEMP_MYSQL_CNF"

    cat >"$TEMP_MYSQL_CNF" <<EOF
[client]
user=root
password="${escaped_password}"
protocol=socket
EOF
}

prepare_mysql_admin_auth() {
    MYSQL_ADMIN_MODE=""

    if "${SUDO[@]}" mysql --protocol=socket --user=root \
        --batch --skip-column-names --execute='SELECT 1;' \
        >/dev/null 2>&1; then
        MYSQL_ADMIN_MODE="socket"
        log "Административный доступ MySQL: root через локальный socket."
        return
    fi

    [[ -t 0 ]] ||
        die "Не удалось подключиться к MySQL root через socket."

    local root_password=""
    printf '\n'
    read -r -s -p "Введите пароль MySQL root: " root_password
    printf '\n'

    [[ -n "$root_password" ]] ||
        die "Пароль MySQL root не указан."

    create_password_defaults_file "$root_password"

    if mysql --defaults-extra-file="$TEMP_MYSQL_CNF" \
        --batch --skip-column-names --execute='SELECT 1;' \
        >/dev/null 2>&1; then
        MYSQL_ADMIN_MODE="password"
        log "Административный доступ MySQL: root по паролю."
        return
    fi

    die "Не удалось подключиться к MySQL с указанным паролем root."
}

mysql_admin() {
    case "$MYSQL_ADMIN_MODE" in
        socket)
            "${SUDO[@]}" mysql --protocol=socket --user=root "$@"
            ;;
        password)
            mysql --defaults-extra-file="$TEMP_MYSQL_CNF" "$@"
            ;;
        *)
            die "Административная аутентификация MySQL не подготовлена."
            ;;
    esac
}

mysqldump_admin() {
    case "$MYSQL_ADMIN_MODE" in
        socket)
            "${SUDO[@]}" mysqldump --protocol=socket --user=root "$@"
            ;;
        password)
            mysqldump --defaults-extra-file="$TEMP_MYSQL_CNF" "$@"
            ;;
        *)
            die "Административная аутентификация MySQL не подготовлена."
            ;;
    esac
}

configure_master_bind_address() {
    local backup
    local temp_config

    [[ -f "$MYSQLD_CONFIG" ]] ||
        die "Основной конфигурационный файл MySQL не найден: ${MYSQLD_CONFIG}"

    backup="${MYSQLD_CONFIG}.bak.$(date +%Y%m%d-%H%M%S)"
    "${SUDO[@]}" cp -a "$MYSQLD_CONFIG" "$backup"

    temp_config="$(mktemp)"

    # Удаляем все активные bind-address и добавляем единственное значение
    # непосредственно в секцию [mysqld].
    awk '
        BEGIN {
            inserted = 0
        }

        /^[[:space:]]*bind-address[[:space:]]*=/ {
            next
        }

        /^[[:space:]]*\[mysqld\][[:space:]]*$/ && inserted == 0 {
            print
            print "bind-address = 0.0.0.0"
            inserted = 1
            next
        }

        {
            print
        }

        END {
            if (inserted == 0) {
                print ""
                print "[mysqld]"
                print "bind-address = 0.0.0.0"
            }
        }
    ' "$MYSQLD_CONFIG" >"$temp_config"

    "${SUDO[@]}" install \
        -o root \
        -g root \
        -m 0644 \
        "$temp_config" \
        "$MYSQLD_CONFIG"

    rm -f -- "$temp_config"

    log "bind-address = 0.0.0.0 установлен в ${MYSQLD_CONFIG}"
    log "Резервная копия основного конфига: ${backup}"
}

backup_existing_replication_config() {
    if [[ -f "$REPLICATION_CONFIG" ]]; then
        local backup="${REPLICATION_CONFIG}.bak.$(date +%Y%m%d-%H%M%S)"
        "${SUDO[@]}" cp -a "$REPLICATION_CONFIG" "$backup"
        log "Предыдущий конфиг сохранен: ${backup}"
    fi
}

write_replication_config() {
    local role="$1"
    local server_id=""
    local temp_config

    case "$role" in
        master)
            server_id="1"
            ;;
        slave)
            server_id="2"
            ;;
        *)
            die "Неизвестная роль конфигурации: ${role}"
            ;;
    esac

    temp_config="$(mktemp)"

    {
        printf '# Создан %s\n' "$SCRIPT_NAME"
        printf '[mysqld]\n'

        printf 'server-id = %s\n' "$server_id"
        printf 'log-bin = mysql-bin\n'
        printf 'binlog-format = ROW\n'
        printf 'gtid-mode = ON\n'
        printf 'enforce-gtid-consistency = ON\n'
        printf 'log-replica-updates = ON\n'
    } >"$temp_config"

    backup_existing_replication_config

    "${SUDO[@]}" install \
        -o root \
        -g root \
        -m 0644 \
        "$temp_config" \
        "$REPLICATION_CONFIG"

    rm -f -- "$temp_config"

    log "Создан конфигурационный файл: ${REPLICATION_CONFIG}"
}

verify_master_runtime_config() {
    local values
    local bind_address
    local server_id
    local gtid_mode
    local log_bin

    values="$(
        mysql_admin --batch --skip-column-names --execute="
            SELECT
                @@GLOBAL.bind_address,
                @@GLOBAL.server_id,
                @@GLOBAL.gtid_mode,
                @@GLOBAL.log_bin;
        "
    )"

    read -r bind_address server_id gtid_mode log_bin <<<"$values"

    [[ "$bind_address" == "0.0.0.0" ]] ||
        die "MySQL применил bind-address=${bind_address}, ожидалось 0.0.0.0."

    [[ "$server_id" == "1" ]] ||
        die "MySQL применил server-id=${server_id}, ожидалось 1."

    [[ "$gtid_mode" == "ON" ]] ||
        die "MySQL применил gtid_mode=${gtid_mode}, ожидалось ON."

    [[ "$log_bin" == "1" ]] ||
        die "Бинарный журнал MySQL не включен."

    log "${COLOR_GREEN}${COLOR_BOLD}✓ Master слушает 0.0.0.0:3306; server-id=1; GTID=ON.${COLOR_RESET}"
}

create_replication_user() {
    local escaped_user escaped_password

    escaped_user="$(sql_escape "$REPLICATION_USER")"
    escaped_password="$(sql_escape "$REPLICATION_PASSWORD")"

    log "Создание пользователя репликации '${REPLICATION_USER}'@'%'..."

    mysql_admin <<SQL
CREATE USER IF NOT EXISTS '${escaped_user}'@'%'
  IDENTIFIED WITH caching_sha2_password BY '${escaped_password}';
ALTER USER '${escaped_user}'@'%'
  IDENTIFIED WITH caching_sha2_password BY '${escaped_password}';
GRANT REPLICATION SLAVE ON *.* TO '${escaped_user}'@'%';
FLUSH PRIVILEGES;
SQL

    log "${COLOR_GREEN}${COLOR_BOLD}✓ Пользователь репликации настроен.${COLOR_RESET}"
}

create_master_dump() {
    local dump_tmp
    local metadata_option

    command -v mysqldump >/dev/null 2>&1 ||
        die "Команда mysqldump не найдена."

    if mysqldump --help 2>/dev/null | grep -q -- '--source-data'; then
        metadata_option="--source-data=2"
    else
        metadata_option="--master-data=2"
    fi

    dump_tmp="$(mktemp)"

    log "Создание согласованного дампа всех баз: ${DUMP_FILE}"

    mysqldump_admin \
        --all-databases \
        --single-transaction \
        --routines \
        --events \
        --triggers \
        --hex-blob \
        --set-gtid-purged=ON \
        "$metadata_option" \
        >"$dump_tmp"

    "${SUDO[@]}" install \
        -o root \
        -g root \
        -m 0600 \
        "$dump_tmp" \
        "$DUMP_FILE"

    rm -f -- "$dump_tmp"

    log "${COLOR_GREEN}${COLOR_BOLD}✓ Дамп создан: ${DUMP_FILE}${COLOR_RESET}"
}

ensure_scp() {
    if command -v scp >/dev/null 2>&1; then
        return
    fi

    ((OFFLINE_MODE == 0)) ||
        die "Для передачи дампа нужен scp, но openssh-client не установлен."

    log "Установка openssh-client для передачи дампа..."
    "${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive \
        apt-get install -y openssh-client
}

transfer_dump_to_slave() {
    ((SKIP_DUMP_TRANSFER == 0)) || {
        warn "Передача дампа на Slave пропущена."
        return
    }

    if [[ -z "$SLAVE_SSH_HOST" ]]; then
        prompt_required SLAVE_SSH_HOST \
            "Введите IP или DNS-имя mysql_slave: "
    fi

    if [[ -z "$SLAVE_SSH_USER" ]]; then
        prompt_required SLAVE_SSH_USER \
            "Введите SSH-пользователя на mysql_slave: "
    fi

    validate_host "$SLAVE_SSH_HOST"
    validate_username "$SLAVE_SSH_USER"
    ensure_scp

    local transfer_file
    local local_user
    local local_group

    local_user="${SUDO_USER:-$(id -un)}"
    local_group="$(id -gn "$local_user")"
    transfer_file="/tmp/mysql-backup-send.$$"

    "${SUDO[@]}" install \
        -o "$local_user" \
        -g "$local_group" \
        -m 0600 \
        "$DUMP_FILE" \
        "$transfer_file"

    log "Передача дампа на ${SLAVE_SSH_USER}@${SLAVE_SSH_HOST}:/tmp/backup.sql"
    log "scp может запросить SSH-пароль или парольную фразу ключа."

    if ! scp \
        -o StrictHostKeyChecking=accept-new \
        "$transfer_file" \
        "${SLAVE_SSH_USER}@${SLAVE_SSH_HOST}:/tmp/backup.sql"; then
        rm -f -- "$transfer_file"
        die "Не удалось передать дамп на Slave."
    fi

    rm -f -- "$transfer_file"

    log "${COLOR_GREEN}${COLOR_BOLD}✓ Дамп передан на Slave.${COLOR_RESET}"
}

create_replication_test_data() {
    log "Создание тестовой базы test_replication на Master..."

    mysql_admin <<'SQL'
CREATE DATABASE IF NOT EXISTS test_replication;
USE test_replication;
CREATE TABLE IF NOT EXISTS t1 (
    id INT PRIMARY KEY,
    name VARCHAR(50)
);
INSERT INTO t1 (id, name)
VALUES (1, 'Hello Replica')
ON DUPLICATE KEY UPDATE name = 'Hello Replica';
SQL

    log "${COLOR_GREEN}${COLOR_BOLD}✓ Тестовая запись создана на Master.${COLOR_RESET}"
}

configure_master() {
    log "${COLOR_CYAN}${COLOR_BOLD}Настройка роли Master.${COLOR_RESET}"

    configure_master_bind_address
    write_replication_config master
    restart_mysql
    prepare_mysql_admin_auth
    verify_master_runtime_config
    create_replication_user
    create_master_dump
    transfer_dump_to_slave

    # Создается после дампа: транзакция должна прийти на Slave через GTID.
    create_replication_test_data

    warn "Убедитесь, что TCP/3306 Master доступен со Slave."
    log "Настройка Master завершена."
}

prepare_replica_for_import() {
    local existing_gtids

    existing_gtids="$(
        mysql_admin --batch --skip-column-names \
            --execute='SELECT @@GLOBAL.gtid_executed;' 2>/dev/null || true
    )"

    if [[ -n "$existing_gtids" ]]; then
        warn "На Slave уже существует GTID_EXECUTED: ${existing_gtids}"
        confirm "Сбросить существующие бинарные журналы и GTID перед импортом?" ||
            die "Импорт отменен, чтобы не повредить существующую репликацию."

        mysql_admin --execute='STOP REPLICA;' >/dev/null 2>&1 || true
        mysql_admin --execute='RESET REPLICA ALL;' >/dev/null 2>&1 || true

        if mysql_admin --execute='RESET BINARY LOGS AND GTIDS;' \
            >/dev/null 2>&1; then
            log "GTID очищены командой RESET BINARY LOGS AND GTIDS."
        else
            mysql_admin --execute='RESET MASTER;'
            log "GTID очищены командой RESET MASTER."
        fi
    fi
}

import_dump_on_slave() {
    local import_file="/tmp/backup.sql"

    [[ -s "$import_file" ]] ||
        die "Дамп не найден или пуст: ${import_file}"

    warn "Будет импортирован --all-databases из ${import_file}."
    confirm "Продолжить импорт на Slave?" ||
        die "Импорт отменен."

    prepare_replica_for_import

    log "Импорт дампа на Slave..."
    mysql_admin <"$import_file"

    log "${COLOR_GREEN}${COLOR_BOLD}✓ Дамп импортирован.${COLOR_RESET}"

    # Дамп mysql.* мог изменить учетную запись root — проверяем доступ заново.
    prepare_mysql_admin_auth
}

configure_replication_source() {
    local escaped_host escaped_user escaped_password

    if [[ -z "$SOURCE_HOST" ]]; then
        prompt_required SOURCE_HOST \
            "Введите IP или DNS-имя MySQL Master [например mysql-master]: "
    fi

    validate_host "$SOURCE_HOST"
    validate_port

    escaped_host="$(sql_escape "$SOURCE_HOST")"
    escaped_user="$(sql_escape "$REPLICATION_USER")"
    escaped_password="$(sql_escape "$REPLICATION_PASSWORD")"

    log "Настройка источника репликации ${SOURCE_HOST}:${SOURCE_PORT}..."

    mysql_admin --execute='STOP REPLICA;' >/dev/null 2>&1 || true
    mysql_admin --execute='RESET REPLICA ALL;' >/dev/null 2>&1 || true

    mysql_admin <<SQL
CHANGE REPLICATION SOURCE TO
    SOURCE_HOST = '${escaped_host}',
    SOURCE_PORT = ${SOURCE_PORT},
    SOURCE_USER = '${escaped_user}',
    SOURCE_PASSWORD = '${escaped_password}',
    SOURCE_AUTO_POSITION = 1,
    GET_SOURCE_PUBLIC_KEY = 1;
START REPLICA;
SQL
}

wait_for_replica() {
    local attempt status io_state sql_state

    log "Ожидание запуска потоков репликации..."

    for attempt in {1..60}; do
        status="$(mysql_admin --batch --raw --execute='SHOW REPLICA STATUS\G' 2>/dev/null || true)"
        io_state="$(awk -F': ' '/^[[:space:]]*Replica_IO_Running:/ {print $2}' <<<"$status")"
        sql_state="$(awk -F': ' '/^[[:space:]]*Replica_SQL_Running:/ {print $2}' <<<"$status")"

        if [[ "$io_state" == "Yes" && "$sql_state" == "Yes" ]]; then
            log "${COLOR_GREEN}${COLOR_BOLD}✓ Потоки репликации запущены.${COLOR_RESET}"
            return
        fi

        sleep 2
    done

    mysql_admin --execute='SHOW REPLICA STATUS\G' || true
    die "Репликация не перешла в состояние Replica_IO/SQL_Running=Yes."
}

wait_for_test_row() {
    local attempt result

    log "Ожидание тестовой записи test_replication.t1..."

    for attempt in {1..60}; do
        result="$(
            mysql_admin --batch --skip-column-names \
                --execute="SELECT name FROM test_replication.t1 WHERE id=1;" \
                2>/dev/null || true
        )"

        if [[ "$result" == "Hello Replica" ]]; then
            log "${COLOR_GREEN}${COLOR_BOLD}✓ Тестовая запись успешно реплицирована.${COLOR_RESET}"
            return
        fi

        sleep 2
    done

    warn "Тестовая запись пока не появилась. Проверьте SHOW REPLICA STATUS\\G."
}

show_replica_result() {
    printf '\n'
    mysql_admin --execute='SHOW REPLICA STATUS\G'
    printf '\n'
    mysql_admin <<'SQL'
SHOW DATABASES;
USE test_replication;
SELECT * FROM t1;
SQL
}

configure_slave() {
    log "${COLOR_CYAN}${COLOR_BOLD}Настройка роли Slave.${COLOR_RESET}"

    # GTID должен быть включен до импорта дампа с SET @@GLOBAL.GTID_PURGED.
    write_replication_config slave
    restart_mysql
    prepare_mysql_admin_auth

    import_dump_on_slave
    configure_replication_source
    wait_for_replica
    wait_for_test_row
    show_replica_result

    log "Настройка Slave завершена."
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

    command -v mysql >/dev/null 2>&1 ||
        die "Клиент mysql не найден после установки."

    package_version="$(dpkg-query -W -f='${Version}' "$server_package")"
    service_state="$("${SUDO[@]}" systemctl is-active mysql)"
    service_enabled="$("${SUDO[@]}" systemctl is-enabled mysql)"
    mysql_version="$(mysql --version)"

    [[ "$service_state" == "active" ]] ||
        die "Служба mysql имеет состояние: ${service_state}"

    printf '\n'
    log "${COLOR_GREEN}${COLOR_BOLD}✓ Развертывание MySQL завершено.${COLOR_RESET}"
    printf '  Режим установки:   %s\n' "$INSTALL_MODE"
    printf '  Источник пакетов:  %s\n' "$INSTALL_SOURCE"
    printf '  Secure install:    %s\n' "$SECURE_INSTALLATION_MODE"
    printf '  Серверный пакет:   %s %s\n' "$server_package" "$package_version"
    printf '  Клиент:             %s\n' "$mysql_version"
    printf '  Служба:            %s; автозапуск: %s\n' "$service_state" "$service_enabled"
    printf '  Роль:              %s\n' "$MYSQL_ROLE"

    if [[ "$MYSQL_ROLE" == "master" ]]; then
        printf '  Дамп:              %s\n' "$DUMP_FILE"
        printf '  Конфигурация:      %s\n' "$REPLICATION_CONFIG"
    elif [[ "$MYSQL_ROLE" == "slave" ]]; then
        printf '  Master:            %s:%s\n' "$SOURCE_HOST" "$SOURCE_PORT"
        printf '  Конфигурация:      %s\n' "$REPLICATION_CONFIG"
    fi

    printf '\nПрослушиваемые порты MySQL:\n'
    "${SUDO[@]}" ss -lntp 2>/dev/null |
        awk 'NR == 1 || $4 ~ /:3306$|:33060$/ {print}' || true
}

main() {
    init_colors
    parse_args "$@"
    show_banner
    check_prerequisites
    acquire_privileges
    choose_install_mode
    choose_secure_installation_mode

    case "$INSTALL_MODE" in
        install)
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
                    die "Неизвестный источник установки."
                    ;;
            esac
            ;;
        skip)
            verify_existing_mysql_installation
            ;;
        *)
            die "Неизвестный режим установки MySQL."
            ;;
    esac

    start_and_wait_for_mysql
    run_mysql_secure_installation
    prepare_mysql_admin_auth
    choose_role

    case "$MYSQL_ROLE" in
        master)
            configure_master
            ;;
        slave)
            configure_slave
            ;;
        none)
            log "Настройка репликации пропущена."
            ;;
        *)
            die "Неизвестная роль MySQL."
            ;;
    esac

    verify_installation
}

main "$@"
