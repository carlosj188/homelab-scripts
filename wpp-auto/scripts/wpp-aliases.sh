# Aliases e funções úteis pra operar o wpp-auto
# Colocar no ~/.bashrc da VM whats-auto e substituir as senhas

# ============================================
# CONFIGURAR antes de usar:
# ============================================
export WPP_REDIS_PASS=""          # copiar de /opt/wpp-auto/.env
export WPP_PG_PASS=""             # copiar de /opt/wpp-auto/.env
export WPP_EVO_KEY=""             # copiar de /opt/wpp-auto/.env

# ============================================
# Aliases base
# ============================================

alias wpp-redis='docker exec -it wpp-redis redis-cli -a "$WPP_REDIS_PASS"'
alias wpp-pg='docker exec -it -e PGPASSWORD="$WPP_PG_PASS" wpp-postgres psql -U wpp_admin -d wpp_bot'

# ============================================
# Funções de controle do bot
# ============================================

# Adicionar número à ignore list
wpp-ignore-add() {
  if [ -z "$1" ]; then
    echo "Uso: wpp-ignore-add <numero>"
    echo "Ex:  wpp-ignore-add 5566XXXXXXXXX"
    return 1
  fi
  wpp-redis SET "bot:ignore:$1" "1"
}

# Remover da ignore list
wpp-ignore-remove() {
  if [ -z "$1" ]; then
    echo "Uso: wpp-ignore-remove <numero>"
    return 1
  fi
  wpp-redis DEL "bot:ignore:$1"
}

# Listar números ignorados
wpp-ignore-list() {
  wpp-redis KEYS 'bot:ignore:*'
}

# Pausar bot pra um contato
wpp-pause() {
  if [ -z "$1" ]; then
    echo "Uso: wpp-pause <numero> [segundos]"
    echo "     segundos default = 86400 (24h)"
    return 1
  fi
  local ttl=${2:-86400}
  wpp-redis SET "bot:paused:$1" "1" EX "$ttl"
}

# Retomar bot pra um contato
wpp-resume() {
  if [ -z "$1" ]; then
    echo "Uso: wpp-resume <numero>"
    return 1
  fi
  wpp-redis DEL "bot:paused:$1"
}

# Listar contatos com bot pausado
wpp-paused-list() {
  wpp-redis KEYS 'bot:paused:*'
}

# Reset completo do estado de um contato
wpp-reset() {
  if [ -z "$1" ]; then
    echo "Uso: wpp-reset <numero>"
    return 1
  fi
  wpp-redis DEL \
    "bot:state:$1" \
    "bot:paused:$1" \
    "buffer:msgs:$1" \
    "buffer:last:$1"
}

# Inspecionar todas chaves de um contato
wpp-inspect() {
  if [ -z "$1" ]; then
    echo "Uso: wpp-inspect <numero>"
    return 1
  fi
  echo "=== IGNORE ==="
  wpp-redis GET "bot:ignore:$1"
  echo ""
  echo "=== PAUSED ==="
  wpp-redis GET "bot:paused:$1"
  echo "TTL (s):"
  wpp-redis TTL "bot:paused:$1"
  echo ""
  echo "=== STATE ==="
  wpp-redis GET "bot:state:$1"
  echo ""
  echo "=== BUFFER ==="
  wpp-redis LRANGE "buffer:msgs:$1" 0 -1
  wpp-redis GET "buffer:last:$1"
}

# ============================================
# Funções de histórico
# ============================================

# Conversa com um contato
wpp-history() {
  if [ -z "$1" ]; then
    echo "Uso: wpp-history <numero> [limite]"
    return 1
  fi
  local limit=${2:-50}
  wpp-pg -c "SELECT direction, LEFT(content, 80) as preview, created_at 
             FROM wpp_messages 
             WHERE contact_number='$1' 
             ORDER BY id ASC 
             LIMIT $limit;"
}

# Últimas mensagens do sistema
wpp-recent() {
  local limit=${1:-20}
  wpp-pg -c "SELECT contact_number, direction, LEFT(content, 60) as preview, created_at 
             FROM wpp_messages 
             ORDER BY id DESC 
             LIMIT $limit;"
}

# Handoffs recentes
wpp-handoffs() {
  local limit=${1:-10}
  wpp-pg -c "SELECT contact_number, action, triggered_by, created_at 
             FROM wpp_handoff_log 
             ORDER BY id DESC 
             LIMIT $limit;"
}

# Resumo de atendimentos do dia
wpp-today() {
  wpp-pg -c "SELECT contact_number, 
                    COUNT(*) FILTER (WHERE direction='in') as recebidas,
                    COUNT(*) FILTER (WHERE direction='out_bot') as bot,
                    COUNT(*) FILTER (WHERE direction='out_human') as humano
             FROM wpp_messages 
             WHERE created_at > CURRENT_DATE 
             GROUP BY contact_number 
             ORDER BY recebidas DESC;"
}

# ============================================
# Funções de diagnóstico
# ============================================

# Status da Evolution
wpp-status() {
  curl -s -X GET 'http://localhost:8080/instance/fetchInstances' \
    -H "apikey: $WPP_EVO_KEY" | python3 -m json.tool
}

# Status do webhook
wpp-webhook() {
  curl -s -X GET 'http://localhost:8080/webhook/find/powerup-main' \
    -H "apikey: $WPP_EVO_KEY" | python3 -m json.tool
}

# Status dos containers
wpp-containers() {
  docker ps --format "table {{.Names}}\t{{.Status}}" | grep -E "wpp-|evolution"
}
