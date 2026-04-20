#!/bin/bash
# =============================================================================
# SSH Key Deploy - Distribuidor de chaves públicas para múltiplos servidores
# Uso: ./deploy.sh [--hardening]
#   --hardening  Também desabilita login por senha nos servidores
#
# Formato do array SERVERS:
#   "usuario@ip"           → porta 22 (padrão)
#   "usuario@ip:porta"     → porta customizada
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KEYS_FILE="$SCRIPT_DIR/authorized_keys"
HARDENING=false

# --- Cores para output ---
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# --- Lista de servidores ---
# Formato: "usuario@ip" ou "usuario@ip:porta"
SERVERS=(
    #"root@192.XXX.X.XX"        # SERVER 1 - porta 22 (padrão)
    #"root@192.XXX.X.XX:2222"   # SERVER 2 - porta customizada
)

# --- Funções ---
log_ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
log_fail() { echo -e "  ${RED}✗${NC} $1"; }
log_warn() { echo -e "  ${YELLOW}!${NC} $1"; }

show_help() {
    echo "Uso: ./deploy.sh [opções]"
    echo ""
    echo "Opções:"
    echo "  --hardening    Desabilita login por senha SSH nos servidores"
    echo "  --dry-run      Mostra o que seria feito sem executar"
    echo "  --list         Lista os servidores configurados"
    echo "  --help         Mostra esta ajuda"
    echo ""
    echo "Formato dos servidores no array SERVERS:"
    echo '  "usuario@ip"           → usa porta 22 (padrão)'
    echo '  "usuario@ip:porta"     → usa porta customizada'
    echo ""
    echo "Antes de rodar, edite o arquivo 'authorized_keys' com as chaves"
    echo "públicas de todos os seus dispositivos."
}

list_servers() {
    echo "Servidores configurados:"
    echo ""
    for server in "${SERVERS[@]}"; do
        [[ "$server" =~ ^# ]] && continue
        local hostport="${server##*@}"
        local port="22"
        [[ "$hostport" == *:* ]] && port="${hostport##*:}"
        echo "  - $server  (porta $port)"
    done
}

# --- Extrai user, host e porta de "user@host" ou "user@host:porta" ---
parse_server() {
    local entry="$1"
    SERVER_USER="${entry%%@*}"
    local hostport="${entry##*@}"
    if [[ "$hostport" == *:* ]]; then
        SERVER_HOST="${hostport%%:*}"
        SERVER_PORT="${hostport##*:}"
    else
        SERVER_HOST="$hostport"
        SERVER_PORT="22"
    fi
    SERVER_TARGET="${SERVER_USER}@${SERVER_HOST}"
}

check_keys_file() {
    if [[ ! -f "$KEYS_FILE" ]]; then
        echo -e "${RED}Erro:${NC} Arquivo 'authorized_keys' não encontrado em $SCRIPT_DIR"
        echo "Crie o arquivo com as chaves públicas dos seus dispositivos."
        echo ""
        echo "Exemplo:"
        echo '  ssh-ed25519 AAAA... user@desktop-casa'
        echo '  ssh-ed25519 AAAA... user@notebook-shop'
        exit 1
    fi

    local key_count
    key_count=$(grep -cE '^ssh-(ed25519|rsa|ecdsa)' "$KEYS_FILE" 2>/dev/null || echo 0)

    if [[ "$key_count" -eq 0 ]]; then
        echo -e "${RED}Erro:${NC} Nenhuma chave pública encontrada no arquivo 'authorized_keys'"
        exit 1
    fi

    echo -e "Chaves encontradas: ${GREEN}${key_count}${NC}"
    echo ""
}

deploy_keys() {
    local entry="$1"
    parse_server "$entry"
    local user="$SERVER_USER"
    local SSH_OPTS="-p $SERVER_PORT"
    local ssh_dir
    local remote_auth_keys

    if [[ "$user" == "root" ]]; then
        ssh_dir="/root/.ssh"
    else
        ssh_dir="/home/$user/.ssh"
    fi
    remote_auth_keys="$ssh_dir/authorized_keys"

    # Testa conectividade (timeout de 5 segundos)
    if ! ssh $SSH_OPTS -o ConnectTimeout=5 -o BatchMode=yes "$SERVER_TARGET" "echo ok" &>/dev/null; then
        log_fail "$entry - Sem acesso SSH (offline ou sem chave configurada)"
        return 1
    fi

    # Garante que o diretório .ssh existe com permissões corretas
    ssh $SSH_OPTS "$SERVER_TARGET" "mkdir -p $ssh_dir && chmod 700 $ssh_dir"

    # Copia as chaves
    scp -q -P "$SERVER_PORT" "$KEYS_FILE" "$SERVER_TARGET:$remote_auth_keys"

    # Ajusta permissões
    ssh $SSH_OPTS "$SERVER_TARGET" "chmod 600 $remote_auth_keys && chown $user:$user $remote_auth_keys 2>/dev/null; chown ${user}:${user} $ssh_dir 2>/dev/null"

    log_ok "$entry - Chaves atualizadas"
    return 0
}

apply_hardening() {
    local entry="$1"
    parse_server "$entry"
    local user="$SERVER_USER"
    local SSH_OPTS="-p $SERVER_PORT"
    local sshd_config="/etc/ssh/sshd_config"
    local cloud_init_conf="/etc/ssh/sshd_config.d/50-cloud-init.conf"

    local SUDO=""
    [[ "$user" != "root" ]] && SUDO="sudo"

    ssh $SSH_OPTS "$SERVER_TARGET" "
        $SUDO cp $sshd_config ${sshd_config}.bak.\$(date +%Y%m%d%H%M%S)

        apply_setting() {
            local key=\"\$1\"
            local value=\"\$2\"
            if $SUDO grep -qE \"^#?\s*\${key}\b\" $sshd_config; then
                $SUDO sed -i \"s/^#*\s*\${key}.*$/\${key} \${value}/\" $sshd_config
            else
                echo \"\${key} \${value}\" | $SUDO tee -a $sshd_config > /dev/null
            fi
        }

        apply_setting PasswordAuthentication no
        apply_setting PubkeyAuthentication yes
        apply_setting ChallengeResponseAuthentication no
        apply_setting KbdInteractiveAuthentication no
        apply_setting PermitRootLogin prohibit-password

        if [[ -f $cloud_init_conf ]]; then
            $SUDO sed -i 's/PasswordAuthentication yes/PasswordAuthentication no/' $cloud_init_conf
        fi
    "

    # Testa a config antes de restartar
    if ssh $SSH_OPTS "$SERVER_TARGET" "$SUDO sshd -t" 2>/dev/null; then
        ssh $SSH_OPTS "$SERVER_TARGET" "$SUDO systemctl restart sshd 2>/dev/null || $SUDO systemctl restart ssh 2>/dev/null"
        log_ok "$entry - Hardening aplicado e SSH reiniciado"
    else
        ssh $SSH_OPTS "$SERVER_TARGET" "
            latest_bak=\$($SUDO ls -t ${sshd_config}.bak.* 2>/dev/null | head -1)
            if [[ -n \"\$latest_bak\" ]]; then
                $SUDO cp \"\$latest_bak\" $sshd_config
            fi
        "
        log_fail "$entry - Erro na config do SSH, backup restaurado"
        return 1
    fi
}

# --- Parsing de argumentos ---
DRY_RUN=false
for arg in "$@"; do
    case "$arg" in
        --hardening) HARDENING=true ;;
        --dry-run)   DRY_RUN=true ;;
        --list)      list_servers; exit 0 ;;
        --help)      show_help; exit 0 ;;
        *)           echo "Opção desconhecida: $arg"; show_help; exit 1 ;;
    esac
done

# --- Execução principal ---
echo "========================================"
echo "  SSH Key Deploy"
echo "========================================"
echo ""

check_keys_file

if [[ "$HARDENING" == true ]]; then
    echo -e "${YELLOW}ATENÇÃO:${NC} Modo hardening ativado!"
    echo "Login por senha será DESABILITADO nos servidores."
    echo "Certifique-se de que suas chaves já funcionam!"
    echo ""
    read -rp "Continuar? (s/N): " confirm
    if [[ "${confirm,,}" != "s" ]]; then
        echo "Cancelado."
        exit 0
    fi
    echo ""
fi

if [[ "$DRY_RUN" == true ]]; then
    echo "[DRY-RUN] Servidores que seriam atualizados:"
    for server in "${SERVERS[@]}"; do
        [[ "$server" =~ ^# ]] && continue
        local hostport="${server##*@}"
        local port="22"
        [[ "$hostport" == *:* ]] && port="${hostport##*:}"
        echo "  - $server  (porta $port)"
    done
    echo ""
    echo "[DRY-RUN] Chaves que seriam copiadas:"
    cat "$KEYS_FILE"
    exit 0
fi

success=0
fail=0

echo "Distribuindo chaves..."
echo ""
for server in "${SERVERS[@]}"; do
    [[ "$server" =~ ^# ]] && continue

    if deploy_keys "$server"; then
        ((success++))

        if [[ "$HARDENING" == true ]]; then
            apply_hardening "$server"
        fi
    else
        ((fail++))
    fi
done

echo ""
echo "========================================"
echo -e "  Concluído: ${GREEN}${success} ok${NC} / ${RED}${fail} falha(s)${NC}"
echo "========================================"
