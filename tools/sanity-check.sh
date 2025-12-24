#!/usr/bin/env bash
#
# sanity-check-program-robusto.sh
#
# Checa a “saúde técnica” de um programa recém-instalado:
#   - existência, permissões, tamanho
#   - tipo de arquivo (binário ELF, script, etc.)
#   - dependências dinâmicas (ldd/otool)
#   - shebang e sintaxe básica de scripts
#   - flags básicas (--version/--help)
#   - smoke tests específicos por tipo (cli, daemon, lib)
#   - validação de configs + diretórios
#   - validação de usuário/grupo/permissões “suspeitas”
#
# Uso simples:
#   ./sanity-check-program-robusto.sh /caminho/para/binario
#   ./sanity-check-program-robusto.sh --type=daemon --service-name=foo.service /usr/bin/foo
#
# Retorno:
#   0 = sem erros críticos
#   1 = pelo menos um erro crítico
#

set -euo pipefail
IFS=$'\n\t'

#######################################
# CONFIGURAÇÃO GLOBAL
#######################################

# Verbosidade: 0 = só erros, 1 = erros+avisos, 2 = detalhado/debug
SC_VERBOSE_LEVEL=2

# Usar cores ANSI no stderr (se for TTY)?
SC_USE_COLORS=1

# Tamanho máximo de arquivo para fins de aviso (em MB, 0 = sem limite)
SC_MAX_FILE_SIZE_MB=0

# Resolver symlinks para o alvo real?
SC_FOLLOW_SYMLINKS=1

# Diretório temporário para qualquer artefato
SC_TMP_DIR="/tmp/sanity-check-program"

# Tentar rodar --version/-V/-v?
SC_RUN_VERSION=1
SC_VERSION_ARGS=("--version" "-V" "-v")

# Tentar rodar --help/-h?
SC_RUN_HELP=1
SC_HELP_ARGS=("--help" "-h")

# Timeout (segundos) para rodar help/version/smoke-tests
SC_RUN_TIMEOUT=5

# Checagens de sintaxe para scripts (se interpretador estiver disponível)
SC_CHECK_SHELL=1    # bash -n
SC_CHECK_PYTHON=1   # python -m py_compile
SC_CHECK_PERL=1     # perl -c
SC_CHECK_PHP=1      # php -l

# Tipo padrão de programa quando nada é informado: cli, daemon, lib, auto
SC_DEFAULT_PROGRAM_TYPE="auto"

#######################################
# PERFIL DO PROGRAMA (preenchido por CLI)
#######################################

SC_PROFILE_TYPE="$SC_DEFAULT_PROGRAM_TYPE"   # cli | daemon | lib | auto

SC_PROFILE_SERVICE_NAME=""   # ex: "nginx.service"
SC_PROFILE_USER=""           # usuário esperado (para daemons, por ex.)
SC_PROFILE_GROUP=""          # grupo esperado

# Listas (serão arrays depois de parsear CLI)
SC_PROFILE_CONFIG_FILES_RAW=""    # string com caminhos separados por vírgula
SC_PROFILE_CONFIG_DIRS_RAW=""     # idem
SC_PROFILE_DATA_DIRS_RAW=""       # idem
SC_PROFILE_RUN_DIRS_RAW=""        # idem

SC_PROFILE_SMOKE_CMD=""           # string de comando (ex: "prog --self-test")

# Arrays derivados das variáveis RAW (preenchidos depois)
SC_PROFILE_CONFIG_FILES=()
SC_PROFILE_CONFIG_DIRS=()
SC_PROFILE_DATA_DIRS=()
SC_PROFILE_RUN_DIRS=()

#######################################
# ESTADO DE DIAGNÓSTICO
#######################################

SC_ERRORS=0
SC_WARNINGS=0

#######################################
# UTILITÁRIOS DE LOG
#######################################

_color() {
    local code="$1"
    if [ "$SC_USE_COLORS" -eq 1 ] && [ -t 2 ]; then
        printf '\033[%sm' "$code"
    fi
}

color_reset()   { _color "0"; }
color_red()     { _color "31"; }
color_yellow()  { _color "33"; }
color_green()   { _color "32"; }
color_cyan()    { _color "36"; }

log_raw() {
    local level="$1"; shift || true
    local msg="$*"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "unknown-time")"

    case "$level" in
        ERROR)
            color_red;   printf '%s [ERROR] %s\n' "$ts" "$msg" >&2; color_reset;;
        WARN)
            color_yellow; printf '%s [WARN ] %s\n' "$ts" "$msg" >&2; color_reset;;
        INFO)
            color_cyan;  printf '%s [INFO ] %s\n' "$ts" "$msg" >&2; color_reset;;
        DEBUG)
            printf '%s [DEBUG] %s\n' "$ts" "$msg" >&2;;
        *)
            printf '%s [%s] %s\n' "$ts" "$level" "$msg" >&2;;
    esac
}

log() {
    local level="$1"; shift || true
    case "$level" in
        ERROR) log_raw "$level" "$@";;
        WARN)  [ "$SC_VERBOSE_LEVEL" -ge 1 ] && log_raw "$level" "$@";;
        INFO)  [ "$SC_VERBOSE_LEVEL" -ge 1 ] && log_raw "$level" "$@";;
        DEBUG) [ "$SC_VERBOSE_LEVEL" -ge 2 ] && log_raw "$level" "$@";;
        *)     log_raw "$level" "$@";;
    esac
}

die() {
    local code="$1"; shift || true
    log "ERROR" "$*"
    exit "$code"
}

add_error()   { SC_ERRORS=$((SC_ERRORS + 1)); }
add_warning() { SC_WARNINGS=$((SC_WARNINGS + 1)); }

require_cmd() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        die 127 "Comando obrigatório não encontrado: $cmd"
    fi
}

ensure_dirs() {
    mkdir -p -- "$SC_TMP_DIR" || die 1 "Falha ao criar diretório temporário: $SC_TMP_DIR"
}

run_with_timeout() {
    # run_with_timeout TIMEOUT CMD...
    local timeout="$1"; shift
    local cmd=( "$@" )

    if command -v timeout >/dev/null 2>&1; then
        timeout "$timeout" "${cmd[@]}"
    else
        log "WARN" "timeout(1) não encontrado; executando sem limite: ${cmd[*]}"
        "${cmd[@]}"
    fi
}

#######################################
# PARSE DE CLI / PERFIL
#######################################

parse_list_to_array() {
    # parse_list_to_array "a,b,c" arrname
    local raw="$1"
    local arrname="$2"
    local old_ifs="$IFS"
    IFS=',' read -r -a tmp_arr <<< "$raw"
    IFS="$old_ifs"

    # shellcheck disable=SC2034,SC2178
    eval "$arrname=(\"\${tmp_arr[@]}\")"
}

parse_cli() {
    local arg
    while [ "$#" -gt 0 ]; do
        arg="$1"
        case "$arg" in
            --type=*)
                SC_PROFILE_TYPE="${arg#*=}";;
            --type)
                shift || true
                SC_PROFILE_TYPE="${1:-$SC_DEFAULT_PROGRAM_TYPE}";;
            --service-name=*)
                SC_PROFILE_SERVICE_NAME="${arg#*=}";;
            --service-name)
                shift || true
                SC_PROFILE_SERVICE_NAME="${1:-}";;
            --user=*)
                SC_PROFILE_USER="${arg#*=}";;
            --user)
                shift || true
                SC_PROFILE_USER="${1:-}";;
            --group=*)
                SC_PROFILE_GROUP="${arg#*=}";;
            --group)
                shift || true
                SC_PROFILE_GROUP="${1:-}";;
            --config-files=*)
                SC_PROFILE_CONFIG_FILES_RAW="${arg#*=}";;
            --config-dirs=*)
                SC_PROFILE_CONFIG_DIRS_RAW="${arg#*=}";;
            --data-dirs=*)
                SC_PROFILE_DATA_DIRS_RAW="${arg#*=}";;
            --run-dirs=*)
                SC_PROFILE_RUN_DIRS_RAW="${arg#*=}";;
            --smoke-cmd=*)
                SC_PROFILE_SMOKE_CMD="${arg#*=}";;
            --smoke-cmd)
                shift || true
                SC_PROFILE_SMOKE_CMD="${1:-}";;
            --)
                shift
                break;;
            -*)
                die 1 "Opção desconhecida: $arg";;
            *)
                break;;
        esac
        shift || true
    done

    if [ "$#" -lt 1 ]; then
        die 1 "Uso: $0 [opções] <programa>\nTente: $0 --help"
    fi

    # Processar listas em arrays
    [ -n "$SC_PROFILE_CONFIG_FILES_RAW" ] && parse_list_to_array "$SC_PROFILE_CONFIG_FILES_RAW" "SC_PROFILE_CONFIG_FILES"
    [ -n "$SC_PROFILE_CONFIG_DIRS_RAW" ]  && parse_list_to_array "$SC_PROFILE_CONFIG_DIRS_RAW"  "SC_PROFILE_CONFIG_DIRS"
    [ -n "$SC_PROFILE_DATA_DIRS_RAW" ]    && parse_list_to_array "$SC_PROFILE_DATA_DIRS_RAW"    "SC_PROFILE_DATA_DIRS"
    [ -n "$SC_PROFILE_RUN_DIRS_RAW" ]     && parse_list_to_array "$SC_PROFILE_RUN_DIRS_RAW"     "SC_PROFILE_RUN_DIRS"

    printf '%s\n' "$1"
}

#######################################
# RESOLUÇÃO DO ALVO
#######################################

resolve_target() {
    local arg="$1"
    local path=

    if [ -x "$arg" ] || [ -f "$arg" ] || [ -L "$arg" ]; then
        path="$arg"
    else
        if path="$(command -v -- "$arg" 2>/dev/null || true)"; then
            :
        else
            die 1 "Programa não encontrado no PATH nem como caminho absoluto: $arg"
        fi
    fi

    if [ "$SC_FOLLOW_SYMLINKS" -eq 1 ] && command -v readlink >/dev/null 2>&1; then
        local real
        real="$(readlink -f -- "$path" 2>/dev/null || echo "$path")"
        printf '%s\n' "$real"
    else
        printf '%s\n' "$path"
    fi
}

#######################################
# CHECKS BÁSICOS DE ARQUIVO
#######################################

get_file_size_bytes() {
    local target="$1"
    local size="0"
    if command -v stat >/dev/null 2>&1; then
        size=$(stat -c '%s' "$target" 2>/dev/null || stat -f '%z' "$target" 2>/dev/null || echo 0)
    fi
    printf '%s\n' "$size"
}

get_file_mode_string() {
    local target="$1"
    local mode=""
    if command -v stat >/dev/null 2>&1; then
        mode=$(stat -c '%A' "$target" 2>/dev/null || stat -f '%Sp' "$target" 2>/dev/null || echo "")
    fi
    printf '%s\n' "$mode"
}

check_basic_file_props() {
    local target="$1"

    if [ ! -e "$target" ]; then
        log "ERROR" "Arquivo não existe: $target"
        add_error
        return
    fi

    if [ -d "$target" ]; then
        log "ERROR" "Alvo é um diretório, não um executável: $target"
        add_error
    fi

    if [ ! -x "$target" ]; then
        log "WARN" "Arquivo não tem permissão de execução: $target"
        add_warning
    fi

    if [ ! -r "$target" ]; then
        log "WARN" "Arquivo não é legível: $target"
        add_warning
    fi

    if [ -f "$target" ]; then
        local size
        size="$(get_file_size_bytes "$target")"
        if [ "$size" -eq 0 ]; then
            log "ERROR" "Arquivo tem tamanho 0 (provável instalação quebrada): $target"
            add_error
        elif [ "$SC_MAX_FILE_SIZE_MB" -gt 0 ]; then
            local max_bytes=$(( SC_MAX_FILE_SIZE_MB * 1024 * 1024 ))
            if [ "$size" -gt "$max_bytes" ]; then
                log "DEBUG" "Arquivo > ${SC_MAX_FILE_SIZE_MB}MB (size=${size} bytes)."
            fi
        fi
    fi
}

#######################################
# DETECÇÃO DE TIPO DE ARQUIVO
#######################################

detect_file_type() {
    local target="$1"
    if ! command -v file >/dev/null 2>&1; then
        log "WARN" "Comando 'file' não encontrado; detecção limitada."
        echo "unknown"
        return
    fi

    local desc
    desc="$(file -b -- "$target" 2>/dev/null || echo "unknown")"
    log "DEBUG" "file(1): $desc"

    if echo "$desc" | grep -qiE 'ELF.*(executable|shared object)'; then
        echo "elf"
    elif echo "$desc" | grep -qiE 'Mach-O.*(executable|dynamically linked)'; then
        echo "mach-o"
    elif echo "$desc" | grep -qiE 'PE32 executable'; then
        echo "pe"
    elif echo "$desc" | grep -qiE 'shell script|POSIX shell script|Bourne-Again shell script'; then
        echo "shell-script"
    elif echo "$desc" | grep -qiE 'Python script'; then
        echo "python-script"
    elif echo "$desc" | grep -qiE 'Perl script'; then
        echo "perl-script"
    elif echo "$desc" | grep -qiE 'PHP script'; then
        echo "php-script"
    elif echo "$desc" | grep -qiE 'text'; then
        echo "text"
    elif echo "$desc" | grep -qiE 'current ar archive|static library'; then
        echo "static-lib"
    else
        echo "unknown"
    fi
}

#######################################
# CHECKS DE SHEBANG E SINTAXE
#######################################

check_shebang() {
    local target="$1"

    if ! [ -f "$target" ]; then
        return 0
    fi

    local first
    first="$(head -n 1 -- "$target" 2>/dev/null || true)"
    if ! printf '%s\n' "$first" | grep -q '^#!'; then
        log "WARN" "Script sem shebang explícito (#!) na primeira linha: $target"
        add_warning
        return 0
    fi

    local interp bin
    interp="$(printf '%s\n' "$first" | sed 's/^#![[:space:]]*//')"
    bin="$(printf '%s\n' "$interp" | awk '{print $1}')"

    if ! command -v "$bin" >/dev/null 2>&1 && [ ! -x "$bin" ]; then
        log "ERROR" "Shebang aponta para interpretador inexistente ou não executivo: $bin (linha: $first)"
        add_error
    else
        log "DEBUG" "Shebang OK: $first"
    fi
}

check_script_syntax() {
    local target="$1"
    local ftype="$2"

    case "$ftype" in
        shell-script)
            if [ "$SC_CHECK_SHELL" -eq 1 ] && command -v bash >/dev/null 2>&1; then
                log "INFO" "Checando sintaxe de shell script com 'bash -n'..."
                if ! bash -n "$target" >/dev/null 2>&1; then
                    log "ERROR" "Erro de sintaxe em shell script: $target"
                    add_error
                else
                    log "DEBUG" "Sintaxe shell OK."
                fi
            fi
            ;;
        python-script)
            if [ "$SC_CHECK_PYTHON" -eq 1 ] && command -v python >/dev/null 2>&1; then
                log "INFO" "Checando sintaxe Python com 'python -m py_compile'..."
                if ! python -m py_compile "$target" >/dev/null 2>&1; then
                    log "ERROR" "Erro de sintaxe em Python script: $target"
                    add_error
                else
                    log "DEBUG" "Sintaxe Python OK."
                fi
            fi
            ;;
        perl-script)
            if [ "$SC_CHECK_PERL" -eq 1 ] && command -v perl >/dev/null 2>&1; then
                log "INFO" "Checando sintaxe Perl com 'perl -c'..."
                if ! perl -c "$target" >/dev/null 2>&1; then
                    log "ERROR" "Erro de sintaxe em Perl script: $target"
                    add_error
                else
                    log "DEBUG" "Sintaxe Perl OK."
                fi
            fi
            ;;
        php-script)
            if [ "$SC_CHECK_PHP" -eq 1 ] && command -v php >/dev/null 2>&1; then
                log "INFO" "Checando sintaxe PHP com 'php -l'..."
                if ! php -l "$target" >/dev/null 2>&1; then
                    log "ERROR" "Erro de sintaxe em PHP script: $target"
                    add_error
                else
                    log "DEBUG" "Sintaxe PHP OK."
                fi
            fi
            ;;
        *)
            ;;
    esac
}

#######################################
# CHECKS DE BIBLIOTECAS DINÂMICAS
#######################################

check_dynamic_libs() {
    local target="$1"
    local ftype="$2"

    case "$ftype" in
        elf|mach-o|pe)
            ;;
        *)
            return 0;;
    esac

    if command -v ldd >/dev/null 2>&1; then
        log "INFO" "Checando dependências dinâmicas com ldd..."
        local line
        while IFS= read -r line; do
            if printf '%s\n' "$line" | grep -q 'not found'; then
                log "ERROR" "Dependência dinâmica faltando: $line"
                add_error
            fi
        done < <(ldd "$target" 2>&1 || true)
    elif command -v otool >/dev/null 2>&1; then
        log "INFO" "Checando dependências dinâmicas com otool -L..."
        otool -L "$target" 2>/dev/null || log "WARN" "Falha ao rodar otool -L (macOS?)."
    else
        log "WARN" "Nenhuma ferramenta de checagem de libs dinâmicas encontrada (ldd/otool)."
        add_warning
    fi
}

#######################################
# PERMISSÕES, SUID/SGID
#######################################

check_permissions_bits() {
    local target="$1"
    local mode
    mode="$(get_file_mode_string "$target")"

    if [ -z "$mode" ]; then
        return 0
    fi

    if printf '%s\n' "$mode" | grep -q 's'; then
        log "WARN" "Programa com bit SUID/SGID setado: $target (permissões: $mode)"
        add_warning
    fi
}

#######################################
# RUN HELP / VERSION / SMOKE TESTS
#######################################

try_run_flags() {
    local target="$1"

    if [ "$SC_RUN_VERSION" -eq 1 ]; then
        local arg
        for arg in "${SC_VERSION_ARGS[@]}"; do
            log "INFO" "Tentando '$target $arg' (timeout=${SC_RUN_TIMEOUT}s)..."
            if run_with_timeout "$SC_RUN_TIMEOUT" "$target" "$arg" >/dev/null 2>&1; then
                log "DEBUG" "Comando '$target $arg' executado com sucesso."
                break
            fi
        done
    fi

    if [ "$SC_RUN_HELP" -eq 1 ]; then
        local arg
        for arg in "${SC_HELP_ARGS[@]}"; do
            log "INFO" "Tentando '$target $arg' (timeout=${SC_RUN_TIMEOUT}s)..."
            if run_with_timeout "$SC_RUN_TIMEOUT" "$target" "$arg" >/dev/null 2>&1; then
                log "DEBUG" "Comando '$target $arg' executado com sucesso."
                break
            fi
        done
    fi
}

#######################################
# TIPO DE PROGRAMA (cli/daemon/lib/auto)
#######################################

determine_program_type() {
    local target="$1"
    local ftype="$2"

    if [ "$SC_PROFILE_TYPE" != "auto" ]; then
        printf '%s\n' "$SC_PROFILE_TYPE"
        return 0
    fi

    # Heurística muito simples
    case "$ftype" in
        static-lib)
            echo "lib";;
        elf|mach-o|pe)
            # se nome contém "d", "daemon", "server", etc -> daemon
            local base
            base="$(basename "$target")"
            if printf '%s\n' "$base" | grep -qiE 'daemon|server|svc'; then
                echo "daemon"
            else
                echo "cli"
            fi
            ;;
        shell-script|python-script|perl-script|php-script|text)
            echo "cli";;
        *)
            echo "cli";;
    esac
}

#######################################
# VALIDAÇÃO DE USUÁRIO/GRUPO
#######################################

check_user_group() {
    if [ -n "$SC_PROFILE_USER" ]; then
        if ! id "$SC_PROFILE_USER" >/dev/null 2>&1; then
            log "ERROR" "Usuário esperado não existe no sistema: $SC_PROFILE_USER"
            add_error
        else
            log "DEBUG" "Usuário OK: $SC_PROFILE_USER"
        fi
    fi

    if [ -n "$SC_PROFILE_GROUP" ]; then
        if ! getent group "$SC_PROFILE_GROUP" >/dev/null 2>&1 && ! grep -q "^${SC_PROFILE_GROUP}:" /etc/group 2>/dev/null; then
            log "ERROR" "Grupo esperado não existe no sistema: $SC_PROFILE_GROUP"
            add_error
        else
            log "DEBUG" "Grupo OK: $SC_PROFILE_GROUP"
        fi
    fi
}

#######################################
# VALIDAÇÃO DE CONFIGS + DIRETÓRIOS
#######################################

check_required_files_and_dirs() {
    local f

    for f in "${SC_PROFILE_CONFIG_FILES[@]}"; do
        [ -z "$f" ] && continue
        if [ ! -f "$f" ]; then
            log "ERROR" "Arquivo de configuração esperado não existe: $f"
            add_error
        else
            log "DEBUG" "Config OK: $f"
        fi
    done

    local d
    for d in "${SC_PROFILE_CONFIG_DIRS[@]}"; do
        [ -z "$d" ] && continue
        if [ ! -d "$d" ]; then
            log "ERROR" "Diretório de configuração esperado não existe: $d"
            add_error
        else
            log "DEBUG" "Config dir OK: $d"
        fi
    done

    for d in "${SC_PROFILE_DATA_DIRS[@]}"; do
        [ -z "$d" ] && continue
        if [ ! -d "$d" ]; then
            log "ERROR" "Diretório de dados esperado não existe: $d"
            add_error
        else
            log "DEBUG" "Data dir OK: $d"
        fi
    done

    for d in "${SC_PROFILE_RUN_DIRS[@]}"; do
        [ -z "$d" ] && continue
        if [ ! -d "$d" ]; then
            log "ERROR" "Diretório de runtime esperado não existe: $d"
            add_error
        else
            log "DEBUG" "Run dir OK: $d"
        fi
    done
}

check_dirs_permissions() {
    local d mode
    for d in "${SC_PROFILE_CONFIG_DIRS[@]}" "${SC_PROFILE_DATA_DIRS[@]}" "${SC_PROFILE_RUN_DIRS[@]}"; do
        [ -z "$d" ] && continue
        [ -d "$d" ] || continue
        mode="$(get_file_mode_string "$d")"
        if printf '%s\n' "$mode" | grep -q 'w....w'; then
            log "WARN" "Diretório potencialmente inseguro (world-writable): $d (permissões: $mode)"
            add_warning
        fi
    done
}

#######################################
# SMOKE TESTS POR TIPO
#######################################

smoke_test_cli() {
    local target="$1"

    try_run_flags "$target"

    if [ -n "$SC_PROFILE_SMOKE_CMD" ]; then
        log "INFO" "Rodando smoke test CLI customizado: $SC_PROFILE_SMOKE_CMD"
        if ! run_with_timeout "$SC_RUN_TIMEOUT" bash -c "$SC_PROFILE_SMOKE_CMD" >/dev/null 2>&1; then
            log "ERROR" "Smoke test CLI falhou: $SC_PROFILE_SMOKE_CMD"
            add_error
        else
            log "DEBUG" "Smoke test CLI OK."
        fi
    fi
}

smoke_test_daemon() {
    local target="$1"

    # Se serviço systemd foi informado, checar status
    if [ -n "$SC_PROFILE_SERVICE_NAME" ] && command -v systemctl >/dev/null 2>&1; then
        log "INFO" "Checando status do serviço systemd: $SC_PROFILE_SERVICE_NAME"
        if ! systemctl status "$SC_PROFILE_SERVICE_NAME" --no-pager >/dev/null 2>&1; then
            log "WARN" "systemctl status indica problema ou serviço parado: $SC_PROFILE_SERVICE_NAME"
            add_warning
        else
            log "DEBUG" "Serviço systemd parece OK: $SC_PROFILE_SERVICE_NAME"
        fi
    fi

    try_run_flags "$target"

    if [ -n "$SC_PROFILE_SMOKE_CMD" ]; then
        log "INFO" "Rodando smoke test de daemon (sem manter em background): $SC_PROFILE_SMOKE_CMD"
        if ! run_with_timeout "$SC_RUN_TIMEOUT" bash -c "$SC_PROFILE_SMOKE_CMD" >/dev/null 2>&1; then
            log "WARN" "Smoke test de daemon falhou (pode exigir ambiente específico): $SC_PROFILE_SMOKE_CMD"
            add_warning
        else
            log "DEBUG" "Smoke test de daemon OK (até onde foi possível checar)."
        fi
    fi
}

smoke_test_lib() {
    local target="$1"
    # Para libs dinâmicas, já fizemos ldd/otool. Aqui é mais heurístico.
    log "INFO" "Smoke test de biblioteca: checando apenas existência e libs dinâmicas."
    # Se biblioteca tiver extensão .so, .dylib, etc., já foi coberto pelo check_dynamic_libs.
    # Poderia ser estendido com um pequeno programa compilado dinamicamente.
}

run_smoke_tests() {
    local target="$1"
    local program_type="$2"

    case "$program_type" in
        cli)
            smoke_test_cli "$target";;
        daemon)
            smoke_test_daemon "$target";;
        lib)
            smoke_test_lib "$target";;
        *)
            smoke_test_cli "$target";;
    esac
}

#######################################
# RESUMO DE SAÚDE
#######################################

print_summary() {
    echo
    echo "===== RESUMO DO SANITY-CHECK ====="
    printf 'Erros:    %d\n' "$SC_ERRORS"
    printf 'Avisos:   %d\n' "$SC_WARNINGS"

    if [ "$SC_ERRORS" -eq 0 ]; then
        color_green; echo "Diagnóstico: sem erros críticos detectados."; color_reset
        if [ "$SC_WARNINGS" -gt 0 ]; then
            echo "Existem avisos que podem indicar problemas potenciais ou ambiente incompleto."
        else
            echo "Programa parece tecnicamente saudável para rodar (sanity-check passou)."
        fi
    else
        color_red; echo "Diagnóstico: programa possivelmente quebrado / mal instalado / incompleto."; color_reset
        echo "Revise os erros acima; o programa provavelmente terá problemas para rodar."
    fi
    echo "=================================="
}

#######################################
# HELP
#######################################

print_help() {
    cat <<EOF
Uso:
  $0 [opções] <programa>

Opções:
  --type=cli|daemon|lib|auto
      Tipo lógico do programa (default: ${SC_DEFAULT_PROGRAM_TYPE})

  --service-name=NAME
      Nome de serviço systemd associado (para tipo daemon).

  --user=NAME
      Usuário esperado para rodar o programa (validação de existência).

  --group=NAME
      Grupo esperado para rodar o programa (validação de existência).

  --config-files=/etc/foo.conf,/etc/foo.d/bar.conf
      Lista de arquivos de configuração obrigatórios (separados por vírgula).

  --config-dirs=/etc/foo,/usr/share/foo
      Diretórios de configuração obrigatórios.

  --data-dirs=/var/lib/foo,/var/cache/foo
      Diretórios de dados obrigatórios.

  --run-dirs=/run/foo
      Diretórios de runtime obrigatórios.

  --smoke-cmd='comando de teste'
      Comando de smoke test extra (por exemplo, 'foo --self-test').

Exemplos:
  # Checar programa CLI simples:
  $0 /usr/bin/grep

  # Checar daemon com service e diretórios:
  $0 --type=daemon --service-name=nginx.service \\
     --user=www-data --group=www-data \\
     --config-files=/etc/nginx/nginx.conf \\
     --config-dirs=/etc/nginx,/etc/nginx/conf.d \\
     --data-dirs=/var/log/nginx,/var/cache/nginx \\
     --run-dirs=/run/nginx \\
     --smoke-cmd='nginx -t' \\
     /usr/sbin/nginx
EOF
}

#######################################
# MAIN
#######################################

main() {
    if [ "$#" -eq 1 ] && [ "$1" = "--help" ]; then
        print_help
        exit 0
    fi

    ensure_dirs

    local target_arg
    target_arg="$(parse_cli "$@")"
    shift || true  # só para alinhamento; parse_cli já pegou o alvo

    local target
    target="$(resolve_target "$target_arg")"

    log "INFO" "Alvo lógico: $target_arg"
    log "INFO" "Caminho real: $target"

    require_cmd stat

    check_basic_file_props "$target"

    local ftype
    ftype="$(detect_file_type "$target")"
    log "INFO" "Tipo de arquivo detectado: $ftype"

    case "$ftype" in
        shell-script|python-script|perl-script|php-script|text)
            check_shebang "$target"
            ;;
    esac

    check_permissions_bits "$target"
    check_dynamic_libs "$target" "$ftype"
    check_script_syntax "$target" "$ftype"

    # Tipo lógico e smoke tests
    local program_type
    program_type="$(determine_program_type "$target" "$ftype")"
    log "INFO" "Tipo lógico de programa: $program_type"

    # Valida usuário/grupo se fornecidos
    check_user_group

    # Valida configs e diretórios se fornecidos
    check_required_files_and_dirs
    check_dirs_permissions

    # Smoke tests por tipo
    run_smoke_tests "$target" "$program_type"

    # Resumo
    print_summary

    if [ "$SC_ERRORS" -gt 0 ]; then
        exit 1
    else
        exit 0
    fi
}

main "$@"
