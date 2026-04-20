#!/bin/bash

# =============================================================================
# WireGuard Client Manager
# =============================================================================

WG_INTERFACE="wg0"
WG_CONF="/etc/wireguard/wg0.conf"
CLIENTS_DIR="/etc/wireguard/clients"
SERVER_PUBKEY="CHAVEPUBLICA_AQUI"
SERVER_ENDPOINT="IPFIXO:51820"
CLIENT_DNS="1.1.1.1, 8.8.8.8"
CLIENT_SUBNET="10.8.0" #Altere conforme necessidade
SUBNET_MASK="24"

# Cores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# =============================================================================
# Funções auxiliares
# =============================================================================

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}Execute como root!${NC}"
        exit 1
    fi
}

check_dependencies() {
    if ! command -v qrencode &> /dev/null; then
        echo -e "${YELLOW}Instalando qrencode...${NC}"
        apt-get update && apt-get install -y qrencode
    fi
}

get_next_ip() {
    local used_ips=()
    
    # Pega IPs já usados no conf (ativos e comentados)
    while IFS= read -r line; do
        if [[ $line =~ AllowedIPs.*${CLIENT_SUBNET}\.([0-9]+) ]]; then
            used_ips+=("${BASH_REMATCH[1]}")
        fi
    done < "$WG_CONF"
    
    # Encontra próximo IP livre (começando do 2, pois 1 é o servidor)
    for i in $(seq 2 254); do
        if [[ ! " ${used_ips[*]} " =~ " $i " ]]; then
            echo "$i"
            return
        fi
    done
    
    echo ""
}

client_exists() {
    local name="$1"
    [[ -d "$CLIENTS_DIR/$name" ]]
}

is_client_active() {
    local name="$1"
    # Verifica se existe um bloco [Peer] seguido de #nome ou # nome (não comentado com DISABLED)
    grep -Pzo "\\[Peer\\]\\n#[ ]?$name\\n" "$WG_CONF" 2>/dev/null | grep -v "DISABLED" &>/dev/null
}

# =============================================================================
# Comandos principais
# =============================================================================

cmd_add() {
    local name="$1"
    
    if [[ -z "$name" ]]; then
        echo -e "${RED}Uso: $0 add <nome_cliente>${NC}"
        exit 1
    fi
    
    # Valida nome (só letras, números, underscore, hífen)
    if [[ ! "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        echo -e "${RED}Nome inválido! Use apenas letras, números, _ e -${NC}"
        exit 1
    fi
    
    if client_exists "$name"; then
        echo -e "${RED}Cliente '$name' já existe!${NC}"
        exit 1
    fi
    
    local next_ip
    next_ip=$(get_next_ip)
    
    if [[ -z "$next_ip" ]]; then
        echo -e "${RED}Sem IPs disponíveis!${NC}"
        exit 1
    fi
    
    local client_ip="${CLIENT_SUBNET}.${next_ip}"
    local client_dir="$CLIENTS_DIR/$name"
    
    echo -e "${BLUE}Criando cliente '$name' com IP $client_ip...${NC}"
    
    # Cria diretório do cliente
    mkdir -p "$client_dir"
    
    # Gera chaves
    wg genkey | tee "$client_dir/private.key" | wg pubkey > "$client_dir/public.key"
    chmod 600 "$client_dir/private.key"
    
    local client_privkey
    local client_pubkey
    client_privkey=$(cat "$client_dir/private.key")
    client_pubkey=$(cat "$client_dir/public.key")
    
    # Salva IP do cliente
    echo "$client_ip" > "$client_dir/ip.txt"
    
    # Cria config do cliente
    cat > "$client_dir/$name.conf" << EOF
[Interface]
PrivateKey = $client_privkey
Address = $client_ip/$SUBNET_MASK
DNS = $CLIENT_DNS

[Peer]
PublicKey = $SERVER_PUBKEY
AllowedIPs = ${CLIENT_SUBNET}.0/${SUBNET_MASK}
Endpoint = $SERVER_ENDPOINT
PersistentKeepalive = 25
EOF
    
    # Adiciona peer no servidor (sem espaço após #)
    cat >> "$WG_CONF" << EOF

[Peer]
#$name
PublicKey = $client_pubkey
AllowedIPs = $client_ip/32
EOF
    
    # Recarrega WireGuard
    wg syncconf "$WG_INTERFACE" <(wg-quick strip "$WG_INTERFACE")
    
    echo -e "${GREEN}✓ Cliente '$name' criado com sucesso!${NC}"
    echo ""
    echo -e "${YELLOW}Configuração do cliente:${NC}"
    echo "─────────────────────────────────────────"
    cat "$client_dir/$name.conf"
    echo "─────────────────────────────────────────"
    echo ""
    echo -e "${YELLOW}QR Code:${NC}"
    qrencode -t ansiutf8 < "$client_dir/$name.conf"
    echo ""
    echo -e "${BLUE}Arquivo salvo em: $client_dir/$name.conf${NC}"
}

cmd_disable() {
    local name="$1"
    
    if [[ -z "$name" ]]; then
        echo -e "${RED}Uso: $0 disable <nome_cliente>${NC}"
        exit 1
    fi
    
    if ! client_exists "$name"; then
        echo -e "${RED}Cliente '$name' não encontrado!${NC}"
        exit 1
    fi
    
    if ! is_client_active "$name"; then
        echo -e "${YELLOW}Cliente '$name' já está desativado.${NC}"
        exit 0
    fi
    
    local pubkey
    pubkey=$(cat "$CLIENTS_DIR/$name/public.key")
    
    # Comenta o bloco do peer (aceita #nome ou # nome)
    sed -i "/^\\[Peer\\]$/{
        N
        /#[ ]*$name$/{
            N;N
            s/^/#DISABLED# /gm
        }
    }" "$WG_CONF"
    
    # Remove peer ativo
    wg set "$WG_INTERFACE" peer "$pubkey" remove 2>/dev/null
    
    echo -e "${GREEN}✓ Cliente '$name' desativado!${NC}"
}

cmd_enable() {
    local name="$1"
    
    if [[ -z "$name" ]]; then
        echo -e "${RED}Uso: $0 enable <nome_cliente>${NC}"
        exit 1
    fi
    
    if ! client_exists "$name"; then
        echo -e "${RED}Cliente '$name' não encontrado!${NC}"
        exit 1
    fi
    
    if is_client_active "$name"; then
        echo -e "${YELLOW}Cliente '$name' já está ativo.${NC}"
        exit 0
    fi
    
    # Descomenta as linhas do peer
    sed -i "s/^#DISABLED# //g" "$WG_CONF"
    
    # Recarrega WireGuard
    wg syncconf "$WG_INTERFACE" <(wg-quick strip "$WG_INTERFACE")
    
    echo -e "${GREEN}✓ Cliente '$name' reativado!${NC}"
}

cmd_remove() {
    local name="$1"
    
    if [[ -z "$name" ]]; then
        echo -e "${RED}Uso: $0 remove <nome_cliente>${NC}"
        exit 1
    fi
    
    if ! client_exists "$name"; then
        echo -e "${RED}Cliente '$name' não encontrado!${NC}"
        exit 1
    fi
    
    echo -e "${YELLOW}Tem certeza que deseja REMOVER permanentemente '$name'? [s/N]${NC}"
    read -r confirm
    
    if [[ ! "$confirm" =~ ^[sS]$ ]]; then
        echo "Cancelado."
        exit 0
    fi
    
    local pubkey
    pubkey=$(cat "$CLIENTS_DIR/$name/public.key")
    
    # Remove peer do WireGuard ativo
    wg set "$WG_INTERFACE" peer "$pubkey" remove 2>/dev/null
    
    # Remove bloco do peer do conf (aceita #nome ou # nome, ativo ou comentado)
    sed -i "/^#\\?DISABLED#\\? \\?\\[Peer\\]$/{
        N
        /#\\?DISABLED#\\? \\?#[ ]*$name$/{
            N;N
            d
        }
    }" "$WG_CONF"
    
    # Remove linhas vazias extras
    sed -i '/^$/N;/^\n$/d' "$WG_CONF"
    
    # Remove diretório do cliente
    rm -rf "$CLIENTS_DIR/$name"
    
    echo -e "${GREEN}✓ Cliente '$name' removido permanentemente!${NC}"
}

cmd_list() {
    echo -e "${BLUE}════════════════════════════════════════════${NC}"
    echo -e "${BLUE}           CLIENTES WIREGUARD${NC}"
    echo -e "${BLUE}════════════════════════════════════════════${NC}"
    
    if [[ ! -d "$CLIENTS_DIR" ]] || [[ -z "$(ls -A "$CLIENTS_DIR" 2>/dev/null)" ]]; then
        echo -e "${YELLOW}Nenhum cliente cadastrado.${NC}"
        return
    fi
    
    printf "%-20s %-15s %-10s\n" "NOME" "IP" "STATUS"
    echo "────────────────────────────────────────────"
    
    for client_dir in "$CLIENTS_DIR"/*/; do
        [[ ! -d "$client_dir" ]] && continue
        
        local name
        name=$(basename "$client_dir")
        local ip
        ip=$(cat "$client_dir/ip.txt" 2>/dev/null || echo "N/A")
        local status
        
        if is_client_active "$name"; then
            status="${GREEN}ATIVO${NC}"
        else
            status="${RED}INATIVO${NC}"
        fi
        
        printf "%-20s %-15s " "$name" "$ip"
        echo -e "$status"
    done
    
    echo ""
}

cmd_show() {
    local name="$1"
    
    if [[ -z "$name" ]]; then
        echo -e "${RED}Uso: $0 show <nome_cliente>${NC}"
        exit 1
    fi
    
    if ! client_exists "$name"; then
        echo -e "${RED}Cliente '$name' não encontrado!${NC}"
        exit 1
    fi
    
    local client_dir="$CLIENTS_DIR/$name"
    
    echo -e "${YELLOW}Configuração de '$name':${NC}"
    echo "─────────────────────────────────────────"
    cat "$client_dir/$name.conf"
    echo "─────────────────────────────────────────"
    echo ""
    echo -e "${YELLOW}QR Code:${NC}"
    qrencode -t ansiutf8 < "$client_dir/$name.conf"
}

cmd_help() {
    echo -e "${BLUE}WireGuard Client Manager${NC}"
    echo ""
    echo "Uso: $0 <comando> [argumentos]"
    echo ""
    echo "Comandos:"
    echo "  add <nome>      Adiciona novo cliente"
    echo "  disable <nome>  Desativa cliente (comenta no conf)"
    echo "  enable <nome>   Reativa cliente desativado"
    echo "  remove <nome>   Remove cliente permanentemente"
    echo "  list            Lista todos os clientes"
    echo "  show <nome>     Mostra config e QR do cliente"
    echo "  help            Mostra esta ajuda"
    echo ""
}

# =============================================================================
# Main
# =============================================================================

check_root
check_dependencies

# Cria diretório de clientes se não existir
mkdir -p "$CLIENTS_DIR"

case "${1:-}" in
    add)     cmd_add "$2" ;;
    disable) cmd_disable "$2" ;;
    enable)  cmd_enable "$2" ;;
    remove)  cmd_remove "$2" ;;
    list)    cmd_list ;;
    show)    cmd_show "$2" ;;
    help|*)  cmd_help ;;
esac
