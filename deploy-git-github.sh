#!/usr/bin/env bash
show_banner() {
    local reset=""
    local bold=""
    local blue=""
    local cyan=""
    local green=""
    local yellow=""
    local gray=""

    # Включаем цвета только при выводе в терминал.
    if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
        reset="$(tput sgr0)"
        bold="$(tput bold)"
        blue="$(tput setaf 4)"
        cyan="$(tput setaf 6)"
        green="$(tput setaf 2)"
        yellow="$(tput setaf 3)"
        gray="$(tput setaf 7)"
    fi

    clear 2>/dev/null || true
    
    printf '%s\n' "${blue}${reset}       ${bold}${cyan}АВТОМАТИЧЕСКОЕ РАЗВЕРТЫВАНИЕ GIT И GITHUB${reset}              ${blue} ${reset}"
    printf '%s\n' "${blue}══════════════════════════════════════════════════════════════════════${reset}"
    printf '%s\n' "${blue} ${reset}                                                                      ${blue} ${reset}"
    printf '%s\n' "${blue} ${reset}  ${bold}Назначение:${reset}                                                        ${blue} ${reset}"
    printf '%s\n' "${blue} ${reset}  Установка Git, проверка SSH-ключа и синхронизация репозитория.   ${blue} ${reset}"
    printf '%s\n' "${blue} ${reset}                                                                      ${blue} ${reset}"
    printf '%s\n' "${blue} ${reset}  ${bold}GitHub:${reset}    ${green}krasnov-ea/diplom${reset}                                      ${blue} ${reset}"
    printf '%s\n' "${blue} ${reset}  ${bold}Каталог:${reset}   ${green}/home/administrator/diplom${reset}                            ${blue} ${reset}"
    printf '%s\n' "${blue} ${reset}                                                                      ${blue} ${reset}"
    printf '%s\n' "${blue}══════════════════════════════════════════════════════════════════════${reset}"
    printf '%s\n' "${blue} ${reset}                                                                      ${blue} ${reset}"
    printf '%s\n' "${blue} ${reset}  ${bold}${yellow}В процессе работы могут быть запрошены:${reset}                           ${blue} ${reset}"
    printf '%s\n' "${blue} ${reset}                                                                      ${blue} ${reset}"
    printf '%s\n' "${blue} ${reset}  1. Локальный sudo-пароль для получения прав администратора.      ${blue} ${reset}"
    printf '%s\n' "${blue} ${reset}  2. Парольная фраза SSH-ключа, если ключ зашифрован.              ${blue} ${reset}"
    printf '%s\n' "${blue} ${reset}                                                                      ${blue} ${reset}"
    printf '%s\n' "${blue}══════════════════════════════════════════════════════════════════════${reset}"
    printf '%s\n' "${blue} ${reset}                                                                      ${blue} ${reset}"
    printf '%s\n' "${blue} ${reset}  ${bold}Обычный запуск:${reset}                                                    ${blue} ${reset}"
    printf '%s\n' "${blue} ${reset}  ${gray}chmod +x deploy-git-github.sh${reset}                                  ${blue} ${reset}"
    printf '%s\n' "${blue} ${reset}  ${gray}./deploy-git-github.sh${reset}                                          ${blue} ${reset}"
    printf '%s\n' "${blue} ${reset}                                                                      ${blue} ${reset}"
    printf '%s\n' "${blue} ${reset}  ${bold}Принудительная синхронизация:${reset}                                    ${blue} ${reset}"
    printf '%s\n' "${blue} ${reset}  ${gray}./deploy-git-github.sh --force-sync${reset}                             ${blue} ${reset}"
    printf '%s\n' "${blue} ${reset}                                                                      ${blue} ${reset}"
    printf '%s\n' "${blue} ${reset}  ${bold}Использование указанного SSH-ключа:${reset}                              ${blue} ${reset}"
    printf '%s\n' "${blue} ${reset}  ${gray}./deploy-git-github.sh \${reset}                                        ${blue} ${reset}"
    printf '%s\n' "${blue} ${reset}  ${gray}  --key-path /home/administrator/.ssh/id_ed25519${reset}                ${blue} ${reset}"
    printf '%s\n' "${blue} ${reset}                                                                      ${blue} ${reset}"
    printf '%s\n' "${blue}══════════════════════════════════════════════════════════════════════${reset}"

    printf '\n%sНажмите любую клавишу для продолжения...%s' "$bold" "$reset"

    if [[ -t 0 ]]; then
        read -r -n 1 -s
    else
        printf ' пропущено: запуск без интерактивного терминала'
    fi

    printf '\n\n'
}
wait_for_key() {
    if [[ -t 0 ]]; then
        printf '\nНажмите любую клавишу для продолжения...'
        read -r -n 1 -s
        printf '\n\n'
    fi
}
set -Eeuo pipefail
# Цвета терминала
COLOR_RESET=""
COLOR_GREEN=""
COLOR_RED=""
COLOR_BOLD=""

if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
    COLOR_RESET="$(tput sgr0)"
    COLOR_GREEN="$(tput setaf 2)"
    COLOR_RED="$(tput setaf 1)"
    COLOR_BOLD="$(tput bold)"
fi

IFS=$'\n\t'
umask 027

readonly SCRIPT_NAME="${0##*/}"
readonly REQUIRED_OS_ID="ubuntu"
readonly REQUIRED_OS_VERSION="24.04"

readonly TARGET_USER="administrator"
readonly TARGET_HOME="/home/administrator"
readonly GITHUB_USER="krasnov-ea"
readonly REPOSITORY="diplom"
readonly REPOSITORY_URL="git@github.com:${GITHUB_USER}/${REPOSITORY}.git"

# Официальный Ed25519 host key github.com.
# Его отпечаток: SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU
readonly GITHUB_ED25519_HOST_KEY='github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl'

TARGET_DIR="${TARGET_HOME}/${REPOSITORY}"
KEY_PATH=""
BRANCH=""
ASSUME_YES=0
FORCE_SYNC=0
SKIP_SSH_TEST=0
NEW_KEY_CREATED=0
ACTIVE_KEY_FINGERPRINT=""

SUDO=()
SUDO_KEEPALIVE_PID=""
SSH_AGENT_PID_STARTED=""
SSH_AUTH_SOCK_STARTED=""
SSH_COMMAND=""

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

    if [[ -n "${SSH_AGENT_PID_STARTED:-}" ]]; then
        "${SUDO[@]}" kill "$SSH_AGENT_PID_STARTED" 2>/dev/null || true
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
  --key-path PATH    путь к закрытому SSH-ключу.
                     Без параметра используется:
                     ${TARGET_HOME}/.ssh/github_diplom
                     Если ключ отсутствует, он будет создан автоматически.
  --target-dir PATH  каталог рабочей копии.
                     По умолчанию: ${TARGET_DIR}
  --branch NAME      ветка для синхронизации.
                     По умолчанию используется default branch репозитория.
  --force-sync       удалить локальные изменения отслеживаемых файлов и
                     неотслеживаемые файлы, затем выровнять копию с GitHub.
                     Игнорируемые Git-файлы не удаляются.
  --skip-ssh-test    пропустить отдельный тест ssh -T.
  -y, --yes          автоматически подтвердить опасные действия.
  -h, --help         показать справку.

Примеры:
  ${SCRIPT_NAME}
  ${SCRIPT_NAME} --key-path ${TARGET_HOME}/.ssh/id_ed25519
  ${SCRIPT_NAME} --branch main
  ${SCRIPT_NAME} --force-sync --yes
EOF
}

parse_args() {
    while (($# > 0)); do
        case "$1" in
            --key-path)
                (($# >= 2)) || die "Для --key-path требуется путь."
                KEY_PATH="$2"
                shift 2
                ;;
            --target-dir)
                (($# >= 2)) || die "Для --target-dir требуется путь."
                TARGET_DIR="$2"
                shift 2
                ;;
            --branch)
                (($# >= 2)) || die "Для --branch требуется имя ветки."
                BRANCH="$2"
                shift 2
                ;;
            --force-sync)
                FORCE_SYNC=1
                shift
                ;;
            --skip-ssh-test)
                SKIP_SSH_TEST=1
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

    [[ -t 0 ]] || die "Требуется подтверждение, но терминал неинтерактивен. Используйте --yes."
    read -r -p "${prompt} [y/N]: " answer
    [[ "$answer" =~ ^([yY]|[дД])$ ]]
}

check_os_and_user() {
    [[ -r /etc/os-release ]] || die "Не найден /etc/os-release."
    # shellcheck disable=SC1091
    source /etc/os-release

    [[ "${ID:-}" == "$REQUIRED_OS_ID" ]] ||
        die "Скрипт предназначен для Ubuntu, обнаружено: ${ID:-неизвестно}."
    [[ "${VERSION_ID:-}" == "$REQUIRED_OS_VERSION" ]] ||
        die "Скрипт предназначен для Ubuntu 24.04, обнаружено: ${VERSION_ID:-неизвестно}."

    id "$TARGET_USER" >/dev/null 2>&1 ||
        die "Локальный пользователь ${TARGET_USER} не существует."
    [[ -d "$TARGET_HOME" ]] ||
        die "Домашний каталог не найден: ${TARGET_HOME}"

    case "$TARGET_DIR" in
        "$TARGET_HOME"|"$TARGET_HOME"/*)
            ;;
        *)
            die "Целевой каталог должен находиться внутри ${TARGET_HOME}: ${TARGET_DIR}"
            ;;
    esac
}

acquire_privileges() {
    if ((EUID == 0)); then
        SUDO=()
        log "Скрипт запущен от root; sudo-пароль не требуется."
        return
    fi

    command -v sudo >/dev/null 2>&1 ||
        die "Не найдена команда sudo."

    log "Для установки пакетов нужны административные права."
    log "Сейчас sudo может запросить ЛОКАЛЬНЫЙ пароль пользователя."
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

as_target() {
    if [[ "$(id -un)" == "$TARGET_USER" ]]; then
        env \
            HOME="$TARGET_HOME" \
            USER="$TARGET_USER" \
            LOGNAME="$TARGET_USER" \
            "$@"
    elif ((EUID == 0)); then
        command -v runuser >/dev/null 2>&1 ||
            die "Для запуска команд от ${TARGET_USER} требуется runuser."
        runuser -u "$TARGET_USER" -- env \
            HOME="$TARGET_HOME" \
            USER="$TARGET_USER" \
            LOGNAME="$TARGET_USER" \
            "$@"
    else
        sudo -u "$TARGET_USER" -H env \
            HOME="$TARGET_HOME" \
            USER="$TARGET_USER" \
            LOGNAME="$TARGET_USER" \
            "$@"
    fi
}

as_target_with_agent() {
    as_target env \
        SSH_AUTH_SOCK="$SSH_AUTH_SOCK_STARTED" \
        SSH_AGENT_PID="$SSH_AGENT_PID_STARTED" \
        "$@"
}

install_packages() {
    local packages=(git openssh-client ca-certificates)
    local missing=()
    local package

    for package in "${packages[@]}"; do
        if ! dpkg-query -W -f='${Status}' "$package" 2>/dev/null |
            grep -q '^install ok installed$'; then
            missing+=("$package")
        fi
    done

    if ((${#missing[@]} == 0)); then
        log "${COLOR_GREEN}${COLOR_BOLD} Git, OpenSSH Client и CA-сертификаты уже установлены.${COLOR_RESET}"
        return
    fi

    log "Обновление индекса APT..."
    "${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive apt-get update

    log "Установка пакетов: ${missing[*]}"
    "${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive \
        apt-get install -y "${missing[@]}"
}

prepare_ssh_directory() {
    local ssh_dir="${TARGET_HOME}/.ssh"

    "${SUDO[@]}" install -d \
        -o "$TARGET_USER" \
        -g "$TARGET_USER" \
        -m 0700 \
        "$ssh_dir"
}

fingerprint_of_public_key() {
    local public_key="$1"
    ssh-keygen -lf "$public_key" -E sha256 2>/dev/null |
        awk 'NR == 1 {print $2}'
}

verify_explicit_key() {
    local public_key="${KEY_PATH}.pub"
    local generated_public_key

    [[ -f "$KEY_PATH" ]] ||
        die "Закрытый SSH-ключ не найден: ${KEY_PATH}"

    if [[ ! -f "$public_key" ]]; then
        generated_public_key="$(mktemp)"
        log "Открытый ключ отсутствует; восстанавливаю ${public_key}."

        as_target ssh-keygen -y -f "$KEY_PATH" >"$generated_public_key"

        "${SUDO[@]}" install \
            -o "$TARGET_USER" \
            -g "$TARGET_USER" \
            -m 0644 \
            "$generated_public_key" \
            "$public_key"

        rm -f -- "$generated_public_key"
    fi

    ACTIVE_KEY_FINGERPRINT="$(
        fingerprint_of_public_key "$public_key" || true
    )"

    [[ -n "$ACTIVE_KEY_FINGERPRINT" ]] ||
        die "Не удалось определить отпечаток SSH-ключа: ${public_key}"
}

show_key_registration_instructions() {
    local public_key
    local deploy_key_url

    public_key="$(cat "${KEY_PATH}.pub")"
    deploy_key_url="https://github.com/${GITHUB_USER}/${REPOSITORY}/settings/keys"

    printf '
'
    printf '%s
' '======================================================================'
    printf ' ОТКРЫТЫЙ SSH-КЛЮЧ ДЛЯ %s/%s
' "$GITHUB_USER" "$REPOSITORY"
    printf '%s
' '======================================================================'
    printf '%s
' "$public_key"
    printf '%s
' '======================================================================'
    printf ' Отпечаток: %s

' "$ACTIVE_KEY_FINGERPRINT"

    cat <<EOF
Добавьте показанный ключ в GitHub как Deploy key:

  1. Откройте:
     ${deploy_key_url}

  2. Нажмите:
     Add deploy key

  3. В поле Title укажите:
     ${TARGET_USER}@$(hostname) — ${REPOSITORY}

  4. В поле Key вставьте ВСЮ строку открытого ключа.

  5. Параметр Allow write access:
     - не включайте для clone/pull;
     - включайте только тогда, когда сервер должен выполнять push.

  6. Нажмите Add key.

Закрытый ключ находится только на сервере:
  ${KEY_PATH}

Никогда не добавляйте содержимое закрытого ключа в GitHub.
EOF

    if ((ASSUME_YES == 1)); then
        printf '
Режим --yes: продолжение без ожидания.

'
        return
    fi

    [[ -t 0 ]] ||
        die "Добавьте Deploy key в GitHub и повторно запустите скрипт."

    printf '
После добавления Deploy key нажмите любую клавишу для продолжения...'
    read -r -n 1 -s
    printf '

'
}

select_and_secure_key() {
    local default_key="${TARGET_HOME}/.ssh/github_diplom"
    local key_comment="${TARGET_USER}@$(hostname)-${REPOSITORY}"

    if [[ -z "$KEY_PATH" ]]; then
        KEY_PATH="$default_key"
    elif [[ "$KEY_PATH" != /* ]]; then
        KEY_PATH="$(readlink -f -- "$KEY_PATH")"
    fi

    case "$KEY_PATH" in
        "${TARGET_HOME}/.ssh/"*)
            ;;
        *)
            warn "SSH-ключ находится вне ${TARGET_HOME}/.ssh: ${KEY_PATH}"
            ;;
    esac

    if [[ ! -f "$KEY_PATH" ]]; then
        log "SSH-ключ не найден: ${KEY_PATH}"
        log "Создание нового Ed25519-ключа для ${GITHUB_USER}/${REPOSITORY}..."

        as_target ssh-keygen \
            -q \
            -t ed25519 \
            -C "$key_comment" \
            -f "$KEY_PATH" \
            -N ""

        NEW_KEY_CREATED=1
    fi

    verify_explicit_key

    "${SUDO[@]}" chown \
        "$TARGET_USER:$TARGET_USER" \
        "$KEY_PATH" \
        "${KEY_PATH}.pub"

    "${SUDO[@]}" chmod 0600 "$KEY_PATH"
    "${SUDO[@]}" chmod 0644 "${KEY_PATH}.pub"

    log "Используется SSH-ключ: ${KEY_PATH}"
    log "Отпечаток ключа: ${ACTIVE_KEY_FINGERPRINT}"

    if ((NEW_KEY_CREATED == 1)); then
        show_key_registration_instructions
    fi
}

prepare_github_known_hosts() {
    local known_hosts="${TARGET_HOME}/.ssh/known_hosts_github"

    printf '%s\n' "$GITHUB_ED25519_HOST_KEY" |
        "${SUDO[@]}" tee "$known_hosts" >/dev/null

    "${SUDO[@]}" chown "$TARGET_USER:$TARGET_USER" "$known_hosts"
    "${SUDO[@]}" chmod 0600 "$known_hosts"

    printf -v SSH_COMMAND \
        'ssh -i %q -o IdentitiesOnly=yes -o HostKeyAlgorithms=ssh-ed25519 -o UserKnownHostsFile=%q -o StrictHostKeyChecking=yes' \
        "$KEY_PATH" "$known_hosts"
}

start_ssh_agent_and_add_key() {
    local agent_output

    log "Запуск временного ssh-agent..."
    agent_output="$(as_target ssh-agent -s)"

    SSH_AUTH_SOCK_STARTED="$(
        sed -n 's/^SSH_AUTH_SOCK=\([^;]*\);.*/\1/p' <<<"$agent_output" |
            head -n 1
    )"
    SSH_AGENT_PID_STARTED="$(
        sed -n 's/^SSH_AGENT_PID=\([0-9]*\);.*/\1/p' <<<"$agent_output" |
            head -n 1
    )"

    [[ -n "$SSH_AUTH_SOCK_STARTED" && -n "$SSH_AGENT_PID_STARTED" ]] ||
        die "Не удалось получить параметры ssh-agent."

    log "Добавление SSH-ключа в ssh-agent."
    log "Если ключ зашифрован, сейчас будет запрошена ПАРОЛЬНАЯ ФРАЗА SSH-КЛЮЧА."
    as_target_with_agent ssh-add "$KEY_PATH"
}

test_github_ssh() {
    local test_output
    local test_rc
    local output_file

    ((SKIP_SSH_TEST == 0)) || {
        warn "Отдельная проверка SSH пропущена (--skip-ssh-test)."
        return
    }

    output_file="$(mktemp)"
    log "Проверка SSH-аутентификации GitHub..."

    # Команда помещена в условие if. Поэтому штатный код 1 от GitHub
    # не вызывает глобальный ERR-trap и не прерывает скрипт.
    if as_target_with_agent \
        ssh \
        -i "$KEY_PATH" \
        -o IdentitiesOnly=yes \
        -o HostKeyAlgorithms=ssh-ed25519 \
        -o "UserKnownHostsFile=${TARGET_HOME}/.ssh/known_hosts_github" \
        -o StrictHostKeyChecking=yes \
        -T git@github.com >"$output_file" 2>&1
    then
        test_rc=0
    else
        test_rc=$?
    fi

    test_output="$(cat "$output_file")"
    rm -f -- "$output_file"

    printf '%s
' "$test_output"

    # GitHub штатно возвращает код 1 после успешного ssh -T,
    # поскольку не предоставляет интерактивную оболочку.
    if [[ "$test_output" != *"successfully authenticated"* ]]; then
        die "SSH-ключ не прошел аутентификацию GitHub.
Проверьте, что ${KEY_PATH}.pub добавлен как Deploy key:
https://github.com/${GITHUB_USER}/${REPOSITORY}/settings/keys"
    fi

    if [[ "$test_rc" -ne 0 && "$test_rc" -ne 1 ]]; then
        die "Неожиданный код проверки SSH: ${test_rc}"
    fi

    log "SSH-аутентификация GitHub подтверждена."
}

test_repository_access() {
    log "Проверка доступа к репозиторию ${GITHUB_USER}/${REPOSITORY}..."

    if ! as_target_with_agent env \
        GIT_SSH_COMMAND="$SSH_COMMAND" \
        git ls-remote "$REPOSITORY_URL" HEAD >/dev/null 2>&1; then
        die "SSH-аутентификация выполнена, но ключ не имеет доступа к репозиторию.
Добавьте открытый ключ как Deploy key:
https://github.com/${GITHUB_USER}/${REPOSITORY}/settings/keys"
    fi

    log "Доступ к репозиторию подтвержден."
}

ensure_target_ownership() {
    local parent_dir
    parent_dir="$(dirname "$TARGET_DIR")"

    if [[ -e "$TARGET_DIR" ]]; then
        "${SUDO[@]}" chown -R "$TARGET_USER:$TARGET_USER" "$TARGET_DIR"
    elif [[ ! -d "$parent_dir" ]]; then
        "${SUDO[@]}" install -d \
            -o "$TARGET_USER" \
            -g "$TARGET_USER" \
            -m 0750 \
            "$parent_dir"
    fi
}

repository_exists() {
    [[ -d "$TARGET_DIR/.git" ]]
}

directory_is_empty() {
    [[ -d "$1" ]] && [[ -z "$(find "$1" -mindepth 1 -maxdepth 1 -print -quit)" ]]
}

clone_repository() {
    if [[ -e "$TARGET_DIR" ]] && ! directory_is_empty "$TARGET_DIR"; then
        die "Каталог существует, не пуст и не является Git-репозиторием: ${TARGET_DIR}"
    fi

    log "Клонирование ${REPOSITORY_URL} в ${TARGET_DIR}..."
    as_target_with_agent env \
        GIT_SSH_COMMAND="$SSH_COMMAND" \
        git clone "$REPOSITORY_URL" "$TARGET_DIR"

    as_target git -C "$TARGET_DIR" config core.sshCommand "$SSH_COMMAND"
}

resolve_branch() {
    local remote_head=""
    local current_branch=""

    if [[ -n "$BRANCH" ]]; then
        printf '%s' "$BRANCH"
        return
    fi

    remote_head="$(
        as_target git -C "$TARGET_DIR" \
            symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null ||
            true
    )"
    if [[ -n "$remote_head" ]]; then
        printf '%s' "${remote_head#origin/}"
        return
    fi

    current_branch="$(
        as_target git -C "$TARGET_DIR" branch --show-current 2>/dev/null ||
            true
    )"
    if [[ -n "$current_branch" ]]; then
        printf '%s' "$current_branch"
        return
    fi

    die "Не удалось определить ветку. Укажите ее параметром --branch."
}

checkout_branch() {
    local branch="$1"

    if as_target git -C "$TARGET_DIR" show-ref \
        --verify --quiet "refs/heads/${branch}"; then
        as_target git -C "$TARGET_DIR" checkout "$branch"
    elif as_target git -C "$TARGET_DIR" show-ref \
        --verify --quiet "refs/remotes/origin/${branch}"; then
        as_target git -C "$TARGET_DIR" checkout \
            --track -b "$branch" "origin/${branch}"
    else
        die "Ветка не найдена в origin: ${branch}"
    fi
}

sync_existing_repository() {
    local branch
    local status_output

    as_target git -C "$TARGET_DIR" remote set-url origin "$REPOSITORY_URL"
    as_target git -C "$TARGET_DIR" config core.sshCommand "$SSH_COMMAND"

    log "Получение изменений из GitHub..."
    as_target_with_agent env \
        GIT_SSH_COMMAND="$SSH_COMMAND" \
        git -C "$TARGET_DIR" fetch origin --prune

    as_target git -C "$TARGET_DIR" remote set-head origin -a >/dev/null 2>&1 || true
    branch="$(resolve_branch)"

    status_output="$(
        as_target git -C "$TARGET_DIR" status --porcelain=v1 --untracked-files=all
    )"

    if ((FORCE_SYNC == 1)); then
        warn "Будут удалены локальные изменения и неотслеживаемые файлы в ${TARGET_DIR}."
        confirm "Продолжить принудительную синхронизацию?" ||
            die "Принудительная синхронизация отменена."

        # Сначала очищаем текущую ветку, чтобы локальные файлы не блокировали checkout.
        as_target git -C "$TARGET_DIR" reset --hard
        as_target git -C "$TARGET_DIR" clean -fd
        checkout_branch "$branch"
        as_target git -C "$TARGET_DIR" reset --hard "origin/${branch}"
        as_target git -C "$TARGET_DIR" clean -fd
    else
        if [[ -n "$status_output" ]]; then
            printf '\nЛокальные изменения:\n%s\n\n' "$status_output"
            die "Рабочая копия содержит локальные изменения.
Сохраните их через commit/stash либо повторите запуск с --force-sync."
        fi

        checkout_branch "$branch"
        log "Обновление ветки ${branch} без merge-коммита..."
        as_target_with_agent env \
            GIT_SSH_COMMAND="$SSH_COMMAND" \
            git -C "$TARGET_DIR" pull --ff-only origin "$branch"
    fi
}

sync_repository() {
    ensure_target_ownership

    if repository_exists; then
        log "Рабочая копия уже существует: ${TARGET_DIR}"
        sync_existing_repository
    else
        clone_repository
    fi

    "${SUDO[@]}" chown -R "$TARGET_USER:$TARGET_USER" "$TARGET_DIR"
}

show_result() {
    local branch
    local commit
    local remote

    branch="$(as_target git -C "$TARGET_DIR" branch --show-current)"
    commit="$(as_target git -C "$TARGET_DIR" rev-parse --short HEAD)"
    remote="$(as_target git -C "$TARGET_DIR" remote get-url origin)"

    printf '\n'
    log "Установка и синхронизация завершены успешно."
    printf '  Git:            %s\n' "$(git --version)"
    printf '  GitHub account: %s\n' "$GITHUB_USER"
    printf '  Репозиторий:    %s\n' "$remote"
    printf '  Каталог:        %s\n' "$TARGET_DIR"
    printf '  Ветка:          %s\n' "$branch"
    printf '  Коммит:         %s\n' "$commit"
    printf '  SSH-ключ:       %s\n' "$KEY_PATH"
    printf '  Отпечаток:      %s\n' "$ACTIVE_KEY_FINGERPRINT"

    printf '\nДля повторной безопасной синхронизации запустите:\n'
    printf '  %q\n' "$0"
	printf "Нажми Enter для продолжения..."
	read -r _
}

main() {
    parse_args "$@"
    show_banner
    check_os_and_user
    acquire_privileges
    install_packages
    prepare_ssh_directory
    select_and_secure_key
    prepare_github_known_hosts
    start_ssh_agent_and_add_key
    test_github_ssh
    test_repository_access
    sync_repository
    show_result
}

main "$@"
