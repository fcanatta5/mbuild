#!/usr/bin/env bash
#
# upstream-checker.sh - Verificador inteligente de novas versões upstream
#
# Requisitos:
#   - bash
#   - curl ou wget
#   - sort (idealmente com -V)
#   - notify-send (opcional, para notificações gráficas)
#

set -euo pipefail
IFS=$'\n\t'

########################################
# CONFIGURAÇÃO (EDITE AQUI)
########################################

# Diretório do seu repositório local de programas (tarballs/tar.gz/tar.xz, etc)
REPO_DIR="/caminho/para/seu/repositorio"

# Padrão de arquivos considerados "pacotes"
# Ex.: foo-1.2.3.tar.gz, bar-0.9.tar.xz, etc.
REPO_GLOB_PATTERN="*.tar.*"

# Diretório de trabalho/cache para listas e logs temporários
CACHE_DIR="/tmp/upstream-checker"

# Comando de notificação (se existir).
# notify-send é padrão em desktops Linux com libnotify.
NOTIFY_SEND_BIN="${NOTIFY_SEND_BIN:-notify-send}"

# Timeout (segundos) para requisições HTTP/HTTPS/FTP
NET_TIMEOUT=10

# Verbosidade: 0 = só erros, 1 = +infos, 2 = debug verboso
VERBOSE_LEVEL=1

########################################
# MAPEAMENTO DE PROGRAMAS -> UPSTREAM
#
# Para cada programa detectado, esta função deve setar:
#   UPSTREAM_TYPE:  "httpdir" | "github" | "gitlab" | "sourceforge" | "gnu"
#   UPSTREAM_URL:   URL base usada para descobrir a última versão
#
# VOCÊ SÓ PRECISA EDITAR ESTE CASE.
########################################
get_upstream_info() {
    local name="$1"
    UPSTREAM_TYPE=""
    UPSTREAM_URL=""

    case "$name" in
        # Exemplos (APAGUE/ALTERE):
        #
        # Programa hospedado em diretório HTTP/FTP simples:
        # mytool)
        #     UPSTREAM_TYPE="httpdir"
        #     UPSTREAM_URL="https://example.com/mytool/releases/"
        #     ;;
        #
        # Programa em GNU (ftp.gnu.org) - trata como httpdir:
        # bash)
        #     UPSTREAM_TYPE="gnu"
        #     UPSTREAM_URL="https://ftp.gnu.org/gnu/bash/"
        #     ;;
        #
        # Programa no GitHub (repo principal):
        # curl)
        #     UPSTREAM_TYPE="github"
        #     UPSTREAM_URL="https://github.com/curl/curl"
        #     ;;
        #
        # Programa no GitLab:
        # mygitlabapp)
        #     UPSTREAM_TYPE="gitlab"
        #     UPSTREAM_URL="https://gitlab.com/usuario/meuapp"
        #     ;;
        #
        # Programa no SourceForge (página de files do projeto):
        # mysfproj)
        #     UPSTREAM_TYPE="sourceforge"
        #     UPSTREAM_URL="https://sourceforge.net/projects/mysfproj/files/"
        #     ;;

        *)
            # Desconhecido: deixe vazio para ignorar ou logar aviso
            UPSTREAM_TYPE=""
            UPSTREAM_URL=""
            ;;
    esac
}

########################################
# UTILITÁRIOS DE LOG
########################################

log() {
    # log LEVEL MSG...
    local level="$1"; shift || true
    case "$level" in
        ERROR)
            printf '[ERROR] %s\n' "$*" >&2
            ;;
        WARN)
            [ "$VERBOSE_LEVEL" -ge 1 ] && printf '[WARN ] %s\n' "$*" >&2
            ;;
        INFO)
            [ "$VERBOSE_LEVEL" -ge 1 ] && printf '[INFO ] %s\n' "$*" >&2
            ;;
        DEBUG)
            [ "$VERBOSE_LEVEL" -ge 2 ] && printf '[DEBUG] %s\n' "$*" >&2
            ;;
        *)
            printf '[%s] %s\n' "$level" "$*" >&2
            ;;
    esac
}

die() {
    local code="$1"; shift || true
    log "ERROR" "$*"
    exit "$code"
}

########################################
# DESCUBRIR COMANDO DE DOWNLOAD
########################################

download_cmd() {
    if command -v curl >/dev/null 2>&1; then
        printf 'curl'
    elif command -v wget >/dev/null 2>&1; then
        printf 'wget'
    else
        die 1 "Nem curl nem wget encontrados; não consigo consultar upstream."
    fi
}

fetch_url() {
    # fetch_url URL -> imprime HTML/listagem na saída padrão
    local url="$1"
    local cmd
    cmd="$(download_cmd)"

    if [ "$cmd" = "curl" ]; then
        curl -fsSL --max-time "$NET_TIMEOUT" "$url"
    else
        wget -q -O - --timeout="$NET_TIMEOUT" "$url"
    fi
}

########################################
# COMPARAÇÃO DE VERSÕES
########################################

have_sort_version() {
    sort -V </dev/null >/dev/null 2>&1 || return 1
    return 0
}

version_le() {
    # version_le A B -> true se A <= B
    local a="$1" b="$2"
    if have_sort_version; then
        # A <= B se o maior (sort -V | tail) for B
        if [ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -n1)" = "$b" ]; then
            return 0
        else
            return 1
        fi
    else
        # Fallback tosco: comparação lexicográfica
        [ "$a" = "$b" ] && return 0
        [[ "$a" < "$b" ]] && return 0
        return 1
    fi
}

version_gt() {
    # version_gt A B -> true se A > B
    local a="$1" b="$2"
    version_le "$a" "$b" && [ "$a" != "$b" ]
}

version_max_list() {
    # version_max_list -> lê versões na stdin, devolve a maior
    if have_sort_version; then
        sort -V | tail -n1
    else
        # Fallback: pegar a "maior" lexicograficamente
        sort | tail -n1
    fi
}

########################################
# EXTRAÇÃO DE NOME E VERSÃO LOCAL
########################################

# Suporta nomes do tipo:
#   foo-1.2.3.tar.gz
#   foo-bar-2.0.tar.xz
#   pacote-1.0rc1.tar.bz2
#
# Heurística: tudo antes do último "-<algo que começa com dígito>"
# é o nome; o resto é versão.

extract_name_version_from_file() {
    local file="$1"
    local base
    base="$(basename -- "$file")"

    # Remover extensão .tar.* ou .tgz
    base="${base%.tar.gz}"
    base="${base%.tar.xz}"
    base="${base%.tar.bz2}"
    base="${base%.tar.zst}"
    base="${base%.tgz}"

    # Caso padrão: name-version
    # name = tudo até "-<versão>"; versão = pedaço final
    local name version
    name="$(printf '%s\n' "$base" | sed -E 's/-[0-9][0-9A-Za-z\.\-\+~:]*$//')"
    version="${base#$name-}"

    if [ -z "$name" ] || [ "$name" = "$base" ]; then
        # fallback: não conseguiu separar
        log "WARN" "Não consegui extrair nome/versão de: $file"
        return 1
    fi

    printf '%s|%s\n' "$name" "$version"
}

########################################
# DESCUBRIR VERSÃO UPSTREAM (GENÉRICO)
########################################

# Heurística: procurar arquivos/tag contendo "name-" + versão
# e extrair versões por regex.

extract_versions_from_listing() {
    local name="$1"
    # lê HTML/listagem da stdin
    grep -E "${name}-[0-9][0-9A-Za-z\.\-\+~:]*\.tar" \
        | sed -E "s/.*${name}-([0-9][0-9A-Za-z\.\-\+~:]*)\.tar.*/\1/" \
        | sort -u
}

get_upstream_version_httpdir() {
    local name="$1" url="$2"
    local listing
    listing="$(fetch_url "$url" || true)"

    if [ -z "$listing" ]; then
        log "WARN" "Falha ao obter listagem HTTP/FTP para $name em $url"
        return 1
    fi

    local versions
    versions="$(printf '%s\n' "$listing" | extract_versions_from_listing "$name" || true)"

    if [ -z "$versions" ]; then
        log "WARN" "Nenhuma versão encontrada na listagem para $name em $url"
        return 1
    fi

    local maxv
    maxv="$(printf '%s\n' "$versions" | version_max_list)"
    printf '%s\n' "$maxv"
}

get_upstream_version_github() {
    local name="$1" url="$2"
    # Exemplo de url: https://github.com/user/proj
    # Estratégia:
    #   1) tentar releases/latest (HTML) -> pega "releases/tag/<tag>"
    #   2) fallback: /tags

    local base="$url"
    local html tag_line tag version

    # Tentativa: /releases/latest
    html="$(fetch_url "${base}/releases/latest" || true)"
    if [ -n "$html" ]; then
        tag_line="$(printf '%s\n' "$html" | grep -Eo 'releases/tag/[^"]+' | head -n1 || true)"
        if [ -n "$tag_line" ]; then
            tag="${tag_line##*/}"   # último segmento da URL
            version="${tag#v}"      # remove v inicial, se tiver
            if [ -n "$version" ]; then
                printf '%s\n' "$version"
                return 0
            fi
        fi
    fi

    # Fallback: /tags (HTML simples)
    html="$(fetch_url "${base}/tags" || true)"
    if [ -n "$html" ]; then
        # pega tags com padrão "refs/tags/<tag>" ou "tags/<tag>"
        version="$(
            printf '%s\n' "$html" \
            | grep -Eo 'tags/[vV]?[0-9][0-9A-Za-z\.\-\+~:]+' \
            | sed -E 's#.*/##' \
            | sed -E 's/^[vV]//' \
            | version_max_list || true
        )"
        if [ -n "$version" ]; then
            printf '%s\n' "$version"
            return 0
        fi
    fi

    log "WARN" "Não consegui descobrir versão upstream no GitHub para $name em $url"
    return 1
}

get_upstream_version_gitlab() {
    local name="$1" url="$2"
    # Exemplo: https://gitlab.com/usuario/projeto
    # Tentar HTML de /-/tags
    local html version
    html="$(fetch_url "${url}/-/tags" || true)"
    if [ -n "$html" ]; then
        version="$(
            printf '%s\n' "$html" \
            | grep -Eo '/tags/[vV]?[0-9][0-9A-Za-z\.\-\+~:]+' \
            | sed -E 's#.*/##' \
            | sed -E 's/^[vV]//' \
            | version_max_list || true
        )"
        if [ -n "$version" ]; then
            printf '%s\n' "$version"
            return 0
        fi
    fi
    log "WARN" "Não consegui descobrir versão upstream no GitLab para $name em $url"
    return 1
}

get_upstream_version_sourceforge() {
    # Na prática, tratamos como um httpdir/HTML, como o httpdir genérico
    get_upstream_version_httpdir "$1" "$2"
}

get_upstream_version_gnu() {
    # Diretórios do GNU normalmente são listagens; usamos o httpdir
    get_upstream_version_httpdir "$1" "$2"
}

get_upstream_version() {
    local name="$1" type="$2" url="$3"
    case "$type" in
        httpdir)
            get_upstream_version_httpdir "$name" "$url"
            ;;
        github)
            get_upstream_version_github "$name" "$url"
            ;;
        gitlab)
            get_upstream_version_gitlab "$name" "$url"
            ;;
        sourceforge)
            get_upstream_version_sourceforge "$name" "$url"
            ;;
        gnu)
            get_upstream_version_gnu "$name" "$url"
            ;;
        *)
            log "WARN" "Tipo de upstream desconhecido '$type' para $name"
            return 1
            ;;
    esac
}

########################################
# SCAN DO REPOSITÓRIO LOCAL
########################################

scan_local_repo() {
    local dir="$1"
    local -A best_version=()  # requer bash >= 4
    local f nv name version

    shopt -s nullglob
    cd "$dir"

    for f in $REPO_GLOB_PATTERN; do
        nv="$(extract_name_version_from_file "$f" || true)" || true
        [ -z "$nv" ] && continue
        name="${nv%%|*}"
        version="${nv##*|}"

        if [ -z "${best_version[$name]+x}" ]; then
            best_version["$name"]="$version"
        else
            # manter a maior versão local para este nome
            if version_gt "$version" "${best_version[$name]}"; then
                best_version["$name"]="$version"
            fi
        fi
    done

    # Imprimir na forma: name|local_version
    for name in "${!best_version[@]}"; do
        printf '%s|%s\n' "$name" "${best_version[$name]}"
    done
}

########################################
# NOTIFICAÇÃO
########################################

notify_updates() {
    local count="$1"
    local list_file="$2"

    if ! command -v "$NOTIFY_SEND_BIN" >/dev/null 2>&1; then
        log "INFO" "notify-send não encontrado; número de updates: $count"
        return 0
    fi

    if [ "$count" -le 0 ]; then
        "$NOTIFY_SEND_BIN" "Upstream Checker" "Nenhuma atualização disponível."
        return 0
    fi

    "$NOTIFY_SEND_BIN" "Upstream Checker" "$count updates disponíveis (lista em $list_file)"
}

########################################
# MAIN
########################################

main() {
    local repo="${REPO_DIR}"
    [ "$#" -ge 1 ] && repo="$1"

    if [ ! -d "$repo" ]; then
        die 1 "Diretório de repositório não existe: $repo"
    fi

    mkdir -p -- "$CACHE_DIR"

    log "INFO" "Varredura do repositório local em: $repo"

    local local_list
    local_list="$CACHE_DIR/local-programs-$$.txt"
    scan_local_repo "$repo" >"$local_list"

    if [ ! -s "$local_list" ]; then
        log "WARN" "Nenhum programa encontrado em $repo com padrão '$REPO_GLOB_PATTERN'"
        notify_updates 0 "$CACHE_DIR/updatable-programs-$$.txt"
        exit 0
    fi

    local updates_list
    updates_list="$CACHE_DIR/updatable-programs-$$.txt"
    : >"$updates_list"

    local total=0 updatable=0
    local line name local_version upstream_version

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        name="${line%%|*}"
        local_version="${line##*|}"
        total=$((total + 1))

        get_upstream_info "$name"
        if [ -z "$UPSTREAM_TYPE" ] || [ -z "$UPSTREAM_URL" ]; then
            log "DEBUG" "Sem upstream configurado para $name; ignorando."
            continue
        fi

        log "INFO" "Checando upstream para $name (local=$local_version, tipo=$UPSTREAM_TYPE, url=$UPSTREAM_URL)"

        upstream_version="$(get_upstream_version "$name" "$UPSTREAM_TYPE" "$UPSTREAM_URL" || true)"

        if [ -z "$upstream_version" ]; then
            log "WARN" "Não foi possível determinar versão upstream para $name"
            continue
        fi

        if version_gt "$upstream_version" "$local_version"; then
            log "INFO" "Update disponível para $name: local=$local_version, upstream=$upstream_version"
            printf '%s|%s|%s\n' "$name" "$local_version" "$upstream_version" >>"$updates_list"
            updatable=$((updatable + 1))
        else
            log "DEBUG" "$name está atualizado (local=$local_version, upstream=$upstream_version)"
        fi
    done <"$local_list"

    log "INFO" "Total de programas verificados: $total"
    log "INFO" "Total com versão maior upstream: $updatable"

    notify_updates "$updatable" "$updates_list"

    # Saída final: também imprime no stdout a lista de updates
    if [ -s "$updates_list" ]; then
        echo "Programas com updates disponíveis (name|local|upstream):"
        cat "$updates_list"
    else
        echo "Nenhum update disponível."
    fi
}

main "$@"
