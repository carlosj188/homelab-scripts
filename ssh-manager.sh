#!/bin/bash
# =============================================================================
# SSH Key Deploy - Distribuidor de chaves públicas para múltiplos servidores
# Uso: ./deploy.sh [--hardening]
#   --hardening  Também desabilita login por senha nos servidores
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
# Formato: usuario@ip ou usuario@hostname
SERVERS=(
    #"root@192.XXX.X.XX"     # SERVER 1
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
    echo "Antes de rodar, edite o arquivo 'authorized_keys' com as chaves"
    echo "públicas de todos os seus dispositivos."
}

list_servers() {
    echo "Servidores configurados:"
    echo ""
    for server in "${SERVERS[@]}"; do
        # Ignora linhas comentadas
        [[ "$server" =~ ^# ]] && continue
        echo "  - $server"
    done
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

    # Conta chaves válidas (ignora linhas vazias e comentários)
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
    local server="$1"
    local user="${server%%@*}"
    local host="${server##*@}"
    local ssh_dir
    local remote_auth_keys

    # Define o caminho correto do .ssh baseado no usuário
    if [[ "$user" == "root" ]]; then
        ssh_dir="/root/.ssh"
    else
        ssh_dir="/home/$user/.ssh"
    fi
    remote_auth_keys="$ssh_dir/authorized_keys"

    # Testa conectividade (timeout de 5 segundos)
    if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "$server" "echo ok" &>/dev/null; then
        log_fail "$server - Sem acesso SSH (offline ou sem chave configurada)"
        return 1
    fi

    # Garante que o diretório .ssh existe com permissões corretas
    ssh "$server" "mkdir -p $ssh_dir && chmod 700 $ssh_dir"

    # Copia as chaves
    scp -q "$KEYS_FILE" "$server:$remote_auth_keys"

    # Ajusta permissões
    ssh "$server" "chmod 600 $remote_auth_keys && chown $user:$user $remote_auth_keys 2>/dev/null; chown ${user}:${user} $ssh_dir 2>/dev/null"

    log_ok "$server - Chaves atualizadas"
    return 0
}

apply_hardening() {
    local server="$1"
    local user="${server%%@*}"
    local sshd_config="/etc/ssh/sshd_config"
    local cloud_init_conf="/etc/ssh/sshd_config.d/50-cloud-init.conf"

    # Define se precisa de sudo (usuário não-root)
    local SUDO=""
    if [[ "$user" != "root" ]]; then
        SUDO="sudo"
    fi

    # Aplica hardening no sshd_config principal
    ssh "$server" "
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

        # Corrige cloud-init se existir (sobrescreve configs do sshd_config)
        if [[ -f $cloud_init_conf ]]; then
            $SUDO sed -i 's/PasswordAuthentication yes/PasswordAuthentication no/' $cloud_init_conf
        fi
    "

    # Testa a config antes de restartar
    if ssh "$server" "$SUDO sshd -t" 2>/dev/null; then
        ssh "$server" "$SUDO systemctl restart sshd 2>/dev/null || $SUDO systemctl restart ssh 2>/dev/null"
        log_ok "$server - Hardening aplicado e SSH reiniciado"
    else
        # Se deu erro, restaura o backup
        ssh "$server" "
            latest_bak=\$($SUDO ls -t ${sshd_config}.bak.* 2>/dev/null | head -1)
            if [[ -n \"\$latest_bak\" ]]; then
                $SUDO cp \"\$latest_bak\" $sshd_config
            fi
        "
        log_fail "$server - Erro na config do SSH, restaurado backup"
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
        echo "  - $server"
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
    # Ignora linhas comentadas
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
