#!/usr/bin/env bash
#
# chroot-manager.sh - Gerenciador de chroot seguro/robusto
#
# Requisitos: bash, mount, umount, chroot, grep, sed, coreutils básicos.
#

set -euo pipefail
IFS=$'\n\t'

#######################################
# CONFIGURAÇÃO (TODAS AS VARIÁVEIS AQUI)
#######################################

# Diretório raiz do chroot (deve existir e ter uma base de sistema instalada)
CHROOT_ROOT="/mnt/mbuild/rootfs"

# Nome lógico do chroot (usado apenas para logs/prompt)
CHROOT_NAME="myos"

# Usuário padrão dentro do chroot (normalmente root)
CHROOT_DEFAULT_USER="root"

# Diretórios do host a serem bind-mount dentro do chroot (caminho absoluto)
# Exemplo: ("/home" "/tmp" "/var/cache/apt/archives")
CHROOT_BIND_DIRS=("/home" "/tmp")

# Montar sistemas de arquivos especiais?
CHROOT_MOUNT_PROC=1      # /proc
CHROOT_MOUNT_SYS=1       # /sys
CHROOT_MOUNT_DEV=1       # /dev
CHROOT_MOUNT_DEV_PTS=1   # /dev/pts
CHROOT_MOUNT_DEV_SHM=1   # /dev/shm (como tmpfs) – opcional e mais sensível

# Copiar /etc/resolv.conf do host para o chroot (para resolver DNS)?
CHROOT_COPY_RESOLV=1

# Diretório de logs
CHROOT_LOG_DIR="/var/log/chroot-manager"

# Diretório para locks/estado em tempo de execução
CHROOT_RUN_DIR="/run/chroot-manager"

# Nome do lockfile (um por chroot)
CHROOT_LOCK_FILE="${CHROOT_RUN_DIR}/${CHROOT_NAME}.lock"

# Prompt base dentro do chroot (apenas visual)
CHROOT_PROMPT_PREFIX="(chroot:${CHROOT_NAME}) "

# PATH padrão dentro do chroot quando rodar comandos/shell
CHROOT_DEFAULT_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

#######################################
# FUNÇÕES DE UTILIDADE
#######################################

log() {
    # log LEVEL MESSAGE...
    # LEVEL: INFO, WARN, ERROR, DEBUG
    local level="$1"; shift || true
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "unknown-time")"
    local line
    line="$(printf '%s [%s] %s\n' "$timestamp" "$level" "$*")"
    # sempre loga para stderr
    printf '%s\n' "$line" >&2
    # também tenta registrar em arquivo de log, se configurado
    if [ -n "${CHROOT_LOG_DIR:-}" ]; then
        mkdir -p -- "$CHROOT_LOG_DIR" 2>/dev/null || true
        printf '%s\n' "$line" >> "${CHROOT_LOG_DIR}/chroot-manager.log" 2>/dev/null || true
    fi
}


die() {
    # die EXIT_CODE MESSAGE...
    local code="$1"; shift || true
    log "ERROR" "$*"
    exit "$code"
}

require_cmd() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        die 127 "Comando obrigatório não encontrado: $cmd"
    fi
}

check_requirements() {
    # Valida a presença de comandos externos necessários
    require_cmd mount
    require_cmd umount
    require_cmd chroot
    require_cmd grep
    require_cmd sed
    require_cmd cp
    require_cmd bash
    require_cmd su
}


require_root() {
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
        die 1 "Este script precisa ser executado como root."
    fi
}

ensure_dirs() {
    mkdir -p -- "$CHROOT_LOG_DIR" "$CHROOT_RUN_DIR" || \
        die 1 "Falha ao criar diretórios de estado/log."
}

sanity_check_root() {
    # Valida CHROOT_ROOT para evitar diretórios perigosos do host.
    if [ -z "$CHROOT_ROOT" ]; then
        die 1 "CHROOT_ROOT não definido."
    fi
    case "$CHROOT_ROOT" in
        "/"|"")
            die 1 "CHROOT_ROOT não pode ser /"
            ;;
        "/root"|"/home"|"/tmp"|"/var"|"/usr"|"/opt")
            die 1 "CHROOT_ROOT não pode ser um diretório crítico do host: $CHROOT_ROOT"
            ;;
    esac
    if [ ! -d "$CHROOT_ROOT" ]; then
        die 1 "Diretório do chroot não existe: $CHROOT_ROOT"
    fi
}


is_mounted() {
    # is_mounted PATH -> true/false
    local path="$1"
    # mountpoint -q é mais direto se disponível
    if command -v mountpoint >/dev/null 2>&1; then
        mountpoint -q -- "$path"
        return $?
    fi
    # fallback: checar em /proc/mounts
    grep -qE "[[:space:]]$(printf '%s' "$path" | sed 's,/,\\/,g')[[:space:]]" /proc/mounts
}

CHROOT_EPHEMERAL=0

lock_chroot() {
    # Implementa um lock simples baseado em arquivo com PID
    if [ -e "$CHROOT_LOCK_FILE" ]; then
        local existing_pid
        existing_pid="$(cat "$CHROOT_LOCK_FILE" 2>/dev/null || echo "")"
        if [ -n "$existing_pid" ] && [ -d "/proc/$existing_pid" ] && [ "$existing_pid" != "$$" ]; then
            die 1 "Chroot já está em uso por outro processo (PID $existing_pid)."
        else
            log "WARN" "Lockfile obsoleto encontrado em $CHROOT_LOCK_FILE; sobrescrevendo."
        fi
    fi
    echo "$$" > "$CHROOT_LOCK_FILE" || die 1 "Não foi possível criar lockfile $CHROOT_LOCK_FILE"
}

unlock_chroot() {
    if [ -f "$CHROOT_LOCK_FILE" ]; then
        local owner_pid
        owner_pid="$(cat "$CHROOT_LOCK_FILE" 2>/dev/null || echo "")"
        if [ -n "$owner_pid" ] && [ "$owner_pid" != "$$" ] && [ -d "/proc/$owner_pid" ]; then
            log "WARN" "Lock em $CHROOT_LOCK_FILE pertence a outro processo (PID $owner_pid); não será removido."
            return 0
        fi
        rm -f -- "$CHROOT_LOCK_FILE" 2>/dev/null || log "WARN" "Falha ao remover lockfile $CHROOT_LOCK_FILE"
    fi
}

cleanup() {
    # Rotina de limpeza automática usada em traps
    if [ "${CHROOT_EPHEMERAL:-0}" -eq 1 ]; then
        log "DEBUG" "Executando cleanup automático (teardown_chroot_mounts + unlock_chroot)."
        teardown_chroot_mounts || true
        unlock_chroot || true
    fi
}

trap cleanup EXIT INT TERM


#######################################
# MONTAGENS
#######################################

mount_proc() {
    [ "$CHROOT_MOUNT_PROC" -eq 1 ] || return 0
    local target="${CHROOT_ROOT}/proc"
    mkdir -p -- "$target"
    if ! is_mounted "$target"; then
        log "INFO" "Montando /proc em $target"
        mount -t proc proc "$target"
    fi
}

mount_sys() {
    [ "$CHROOT_MOUNT_SYS" -eq 1 ] || return 0
    local target="${CHROOT_ROOT}/sys"
    mkdir -p -- "$target"
    if ! is_mounted "$target"; then
        log "INFO" "Montando /sys em $target"
        mount -t sysfs sys "$target"
    fi
}

mount_dev() {
    [ "$CHROOT_MOUNT_DEV" -eq 1 ] || return 0
    local target="${CHROOT_ROOT}/dev"
    mkdir -p -- "$target"
    if ! is_mounted "$target"; then
        log "INFO" "Bind-mount /dev -> $target"
        mount --bind /dev "$target"
    fi
}

mount_dev_pts() {
    [ "$CHROOT_MOUNT_DEV_PTS" -eq 1 ] || return 0
    local target="${CHROOT_ROOT}/dev/pts"
    mkdir -p -- "$target"
    if ! is_mounted "$target"; then
        log "INFO" "Montando devpts em $target"
        mount -t devpts devpts "$target"
    fi
}

mount_dev_shm() {
    [ "$CHROOT_MOUNT_DEV_SHM" -eq 1 ] || return 0
    local target="${CHROOT_ROOT}/dev/shm"
    mkdir -p -- "$target"
    if ! is_mounted "$target"; then
        log "INFO" "Montando tmpfs em $target (dev/shm)"
        mount -t tmpfs -o nosuid,nodev,noexec,mode=1777 tmpfs "$target"
    fi
}

mount_bind_dirs() {
    local src dst
    for src in "${CHROOT_BIND_DIRS[@]}"; do
        [ -n "$src" ] || continue
        if [ ! -d "$src" ]; then
            log "WARN" "Diretório de bind não existe no host: $src (ignorando)"
            continue
        fi
        dst="${CHROOT_ROOT}${src}"
        mkdir -p -- "$dst"
        if ! is_mounted "$dst"; then
            log "INFO" "Bind-mount $src -> $dst"
            mount --bind "$src" "$dst"
        else
            log "INFO" "Já montado: $dst (bind de $src)"
        fi
    done
}

copy_resolv_conf() {
    [ "$CHROOT_COPY_RESOLV" -eq 1 ] || return 0
    if [ ! -f /etc/resolv.conf ]; then
        log "WARN" "/etc/resolv.conf não encontrado no host; pulando cópia."
        return 0
    fi
    local target_dir="${CHROOT_ROOT}/etc"
    local target="${target_dir}/resolv.conf"
    mkdir -p -- "$target_dir"
    log "INFO" "Copiando /etc/resolv.conf para $target"
    cp -f -- /etc/resolv.conf "$target"
}

setup_chroot_mounts() {
    log "INFO" "Preparando montagens para chroot ${CHROOT_NAME} em ${CHROOT_ROOT}"
    mount_proc
    mount_sys
    mount_dev
    mount_dev_pts
    mount_dev_shm
    mount_bind_dirs
    copy_resolv_conf
}

umount_if_mounted() {
    local target="$1"
    if is_mounted "$target"; then
        log "INFO" "Desmontando $target"
        umount "$target" || log "WARN" "Falha ao desmontar $target"
    fi
}

teardown_chroot_mounts() {
    log "INFO" "Desmontando montagens do chroot ${CHROOT_NAME}"

    # Unmount bind dirs em ordem reversa
    local i src dst
    for (( i=${#CHROOT_BIND_DIRS[@]}-1; i>=0; i-- )); do
        src="${CHROOT_BIND_DIRS[$i]}"
        [ -n "$src" ] || continue
        dst="${CHROOT_ROOT}${src}"
        umount_if_mounted "$dst"
    done

    if [ "$CHROOT_MOUNT_DEV_SHM" -eq 1 ]; then
        umount_if_mounted "${CHROOT_ROOT}/dev/shm"
    fi

    if [ "$CHROOT_MOUNT_DEV_PTS" -eq 1 ]; then
        umount_if_mounted "${CHROOT_ROOT}/dev/pts"
    fi

    if [ "$CHROOT_MOUNT_DEV" -eq 1 ]; then
        umount_if_mounted "${CHROOT_ROOT}/dev"
    fi

    if [ "$CHROOT_MOUNT_SYS" -eq 1 ]; then
        umount_if_mounted "${CHROOT_ROOT}/sys"
    fi

    if [ "$CHROOT_MOUNT_PROC" -eq 1 ]; then
        umount_if_mounted "${CHROOT_ROOT}/proc"
    fi
}

#######################################
# EXECUÇÃO NO CHROOT
#######################################

enter_chroot_shell() {
    local user="${1:-$CHROOT_DEFAULT_USER}"

    log "INFO" "Entrando em shell interativa no chroot ${CHROOT_NAME} como usuário ${user}"

    # OBS: chroot não é isolamento total de segurança – comentário explícito
    log "WARN" "Lembre-se: chroot não oferece isolamento de segurança forte como contêiner/VM."

    if [ "$user" = "root" ]; then
        chroot "$CHROOT_ROOT" /usr/bin/env -i \
            HOME="/root" \
            TERM="${TERM:-xterm-256color}" \
            PATH="$CHROOT_DEFAULT_PATH" \
            PS1="${CHROOT_PROMPT_PREFIX}\u@\h:\w\\$ " \
            /bin/bash -l
    else
        chroot "$CHROOT_ROOT" /usr/bin/env -i \
            HOME="/home/$user" \
            TERM="${TERM:-xterm-256color}" \
            PATH="$CHROOT_DEFAULT_PATH" \
            PS1="${CHROOT_PROMPT_PREFIX}\u@\h:\w\\$ " \
            /bin/bash -lc "if id \"$user\" >/dev/null 2>&1; then exec su - \"$user\"; else echo \"Usuário '$user' não existe dentro do chroot\" >&2; exec bash -l; fi"
    fi
}
"

    log "INFO" "Entrando em shell interativa no chroot ${CHROOT_NAME} como usuário ${user}"

    # OBS: chroot não é isolamento total de segurança – comentário explícito
    log "WARN" "Lembre-se: chroot não oferece isolamento de segurança forte como contêiner/VM."

    # Ajusta variáveis de ambiente mínimas
    chroot "$CHROOT_ROOT" /usr/bin/env -i \
        HOME="/root" \
        TERM="${TERM:-xterm-256color}" \
        PATH="$CHROOT_DEFAULT_PATH" \
        PS1="${CHROOT_PROMPT_PREFIX}\u@\h:\w\\$ " \
        /bin/bash -l
}

run_in_chroot() {
    if [ "$#" -lt 2 ]; then
        die 1 "Uso interno incorreto: run_in_chroot <user> <comando...>"
    fi

    local user="$1"; shift
    if [ "$#" -lt 1 ]; then
        die 1 "Nenhum comando fornecido para execução no chroot."
    fi

    local cmd_script=""
    local part
    for part in "$@"; do
        cmd_script+=" $(printf '%q' "$part")"
    done

    log "INFO" "Executando no chroot ${CHROOT_NAME} como usuário '${user}':${cmd_script}"

    local shell_script
    if [ "$user" = "root" ]; then
        shell_script="$cmd_script"
    else
        shell_script="if id \"$user\" >/dev/null 2>&1; then exec su - \"$user\" -c $(printf '%q' "$cmd_script"); else echo \"Usuário '$user' não existe dentro do chroot\" >&2; exit 1; fi"
    fi

    chroot "$CHROOT_ROOT" /usr/bin/env -i \
        HOME="/root" \
        TERM="${TERM:-xterm-256color}" \
        PATH="$CHROOT_DEFAULT_PATH" \
        /bin/bash -c "$shell_script"
}
: ${cmd[*]}"

    chroot "$CHROOT_ROOT" /usr/bin/env -i \
        HOME="/root" \
        TERM="${TERM:-xterm-256color}" \
        PATH="$CHROOT_DEFAULT_PATH" \
        /bin/bash -c "${cmd[*]}"
}

show_status() {
    echo "Status do chroot '${CHROOT_NAME}' em '${CHROOT_ROOT}':"
    echo

    echo "  Montagens relevantes:"
    for p in /proc /sys /dev /dev/pts /dev/shm; do
        local target="${CHROOT_ROOT}${p}"
        if is_mounted "$target"; then
            printf '    [MONTADO ] %s\n' "$target"
        else
            printf '    [DESMONT.] %s\n' "$target"
        fi
    done

    echo
    echo "  Bind-mounts:"
    local src dst
    for src in "${CHROOT_BIND_DIRS[@]}"; do
        [ -n "$src" ] || continue
        dst="${CHROOT_ROOT}${src}"
        if is_mounted "$dst"; then
            printf '    [MONTADO ] %s -> %s\n' "$src" "$dst"
        else
            printf '    [DESMONT.] %s -> %s\n' "$src" "$dst"
        fi
    done

    echo
    if [ -e "$CHROOT_LOCK_FILE" ]; then
        echo "  Lockfile: $CHROOT_LOCK_FILE (existe)"
    else
        echo "  Lockfile: $CHROOT_LOCK_FILE (não existe)"
    fi
}

#######################################
# COMANDOS DE ALTO NÍVEL
#######################################

cmd_prepare() {
    lock_chroot
    setup_chroot_mounts
    copy_resolv_conf
    log "INFO" "Chroot ${CHROOT_NAME} preparado. Use '$0 shell' ou '$0 run' para utilizar e '$0 stop' para desmontar."
}
 preparado."
}

cmd_shell() {
    CHROOT_EPHEMERAL=1
    lock_chroot
    setup_chroot_mounts
    enter_chroot_shell "${1:-$CHROOT_DEFAULT_USER}"
    teardown_chroot_mounts
    unlock_chroot
    CHROOT_EPHEMERAL=0
}
"
}

cmd_run() {
    local run_user="root"

    if [ "${1-}" = "--user" ] || [ "${1-}" = "-u" ]; then
        if [ "$#" -lt 3 ]; then
            die 1 "Uso: $0 run [-u|--user USER] comando [args...]"
        fi
        run_user="$2"
        shift 2
    fi

    if [ "$#" -lt 1 ]; then
        die 1 "Nenhum comando fornecido para execução no chroot."
    fi

    CHROOT_EPHEMERAL=1
    lock_chroot
    setup_chroot_mounts
    run_in_chroot "$run_user" "$@"
    teardown_chroot_mounts
    unlock_chroot
    CHROOT_EPHEMERAL=0
}


cmd_stop() {
    teardown_chroot_mounts
    unlock_chroot
    log "INFO" "Chroot ${CHROOT_NAME} parado (montagens desmontadas)."
}
 parado (montagens desmontadas)."
}

cmd_status() {
    show_status
}


print_help() {
    cat <<EOF
Uso: $0 <comando> [args...]

Comandos:
  prepare                    - Prepara montagens do chroot (proc, sys, dev, binds, resolv.conf).
  shell [USER]               - Prepara e entra em shell interativa dentro do chroot (default: ${CHROOT_DEFAULT_USER}).
  run [-u USER] <cmd...>     - Prepara e executa um comando dentro do chroot (default: root).
  stop                       - Desmonta todas as montagens do chroot e remove lock.
  status                     - Mostra status de montagens, bind-mounts e lock.
  help                       - Mostra este help.

Configuração:
  Todas as variáveis de configuração estão no topo do script (CHROOT_ROOT, CHROOT_NAME, etc.).
EOF
}
).
  run <cmd...>     - Prepara e executa um comando dentro do chroot.
  stop             - Desmonta todas as montagens do chroot e remove lock.
  status           - Mostra status de montagens, bind-mounts e lock.
  help             - Mostra este help.

Configuração:
  Todas as variáveis de configuração estão no topo do script (CHROOT_ROOT, CHROOT_BIND_DIRS, etc.).

ATENÇÃO:
  - Este script pressupõe que o chroot já tem um sistema base instalado em \$CHROOT_ROOT.
  - chroot NÃO é um mecanismo de segurança forte. Use com responsabilidade.

Exemplos:
  # Preparar e entrar em shell:
  sudo $0 shell

  # Executar comando dentro do chroot:
  sudo $0 run mbuild sync

  # Ver status:
  sudo $0 status

  # Parar e desmontar tudo:
  sudo $0 stop
EOF
}

#######################################
# MAIN
#######################################

main() {
    if [ "$#" -lt 1 ]; then
        print_help
        exit 1
    fi

    require_root
    ensure_dirs
    check_requirements
    sanity_check_root

    local cmd="$1"; shift || true

    case "$cmd" in
        prepare)
            # prepare não é efêmero: deixa montagens ativas até 'stop'
            CHROOT_EPHEMERAL=0
            cmd_prepare "$@"
            ;;
        shell)
            cmd_shell "$@"
            ;;
        run)
            cmd_run "$@"
            ;;
        stop)
            cmd_stop "$@"
            ;;
        status)
            cmd_status "$@"
            ;;
        help|-h|--help)
            print_help
            ;;
        *)
            die 1 "Comando desconhecido: $cmd"
            ;;
    esac
}


main "$@"
