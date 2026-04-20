# 04 — Operação do dia a dia

Comandos de referência rápida pra gerenciar o bot em produção.

Antes dos exemplos: **defina uma alias** pra não repetir a senha sempre.

```bash
# Adicione no ~/.bashrc da VM whats-auto:
alias wpp-redis="docker exec -it wpp-redis redis-cli -a 'SUA_SENHA_REDIS_AQUI'"
alias wpp-pg="docker exec -it -e PGPASSWORD='SUA_SENHA_POSTGRES_AQUI' wpp-postgres psql -U wpp_admin -d wpp_bot"
```

Depois `source ~/.bashrc` e os comandos ficam assim:

```bash
wpp-redis KEYS 'bot:*'
wpp-pg -c "SELECT COUNT(*) FROM wpp_messages;"
```

A documentação abaixo usa os comandos completos pra ser portátil.

---

## Ignore list (bot nunca atende)

Bom pra: teu próprio número pessoal, família, parceiros que conversam por outro canal, etc.

**Adicionar número à lista:**
```bash
docker exec -it wpp-redis redis-cli -a 'SENHA' \
  SET 'bot:ignore:5566XXXXXXXXX' '1'
```

**Formato do número:** DDI+DDD+número, sem `+`, sem traços. Importante: muitas vezes o WhatsApp armazena sem o nono dígito — confira o JID real do contato antes:

```bash
docker exec -it -e PGPASSWORD='SENHA' wpp-postgres psql -U wpp_admin -d wpp_bot -c \
  "SELECT DISTINCT contact_number FROM wpp_messages WHERE direction='in' ORDER BY contact_number;"
```

**Remover da lista:**
```bash
docker exec -it wpp-redis redis-cli -a 'SENHA' DEL 'bot:ignore:5566XXXXXXXXX'
```

**Listar todos os ignorados:**
```bash
docker exec -it wpp-redis redis-cli -a 'SENHA' KEYS 'bot:ignore:*'
```

**Verificar se um contato específico está ignorado:**
```bash
docker exec -it wpp-redis redis-cli -a 'SENHA' GET 'bot:ignore:5566XXXXXXXXX'
# Retorna "1" se sim, (nil) se não
```

---

## Controle de pausa bot/humano

Quando o bot pausa (fluxo completo, ou atendente escreveu manual), fica pausado 24h. Pode gerenciar manualmente:

**Pausar bot pra um contato por 24h (forçar):**
```bash
docker exec -it wpp-redis redis-cli -a 'SENHA' \
  SET 'bot:paused:5566XXXXXXXXX' '1' EX 86400
```

**Retomar bot pra um contato antes das 24h:**
```bash
docker exec -it wpp-redis redis-cli -a 'SENHA' \
  DEL 'bot:paused:5566XXXXXXXXX'
```

**Listar contatos com bot pausado (em atendimento humano):**
```bash
docker exec -it wpp-redis redis-cli -a 'SENHA' KEYS 'bot:paused:*'
```

**Ver quanto tempo falta pro bot voltar:**
```bash
docker exec -it wpp-redis redis-cli -a 'SENHA' TTL 'bot:paused:5566XXXXXXXXX'
# Retorna segundos. Dividir por 3600 pra horas.
```

---

## Resetar fluxo conversacional de um cliente

Se um cliente ficou "travado" num estado do bot:

**Limpar estado (cliente volta ao menu inicial na próxima msg):**
```bash
docker exec -it wpp-redis redis-cli -a 'SENHA' DEL 'bot:state:5566XXXXXXXXX'
```

**Reset completo (estado + pausa + buffer):**
```bash
docker exec -it wpp-redis redis-cli -a 'SENHA' DEL \
  'bot:state:5566XXXXXXXXX' \
  'bot:paused:5566XXXXXXXXX' \
  'buffer:msgs:5566XXXXXXXXX' \
  'buffer:last:5566XXXXXXXXX'
```

---

## Ver histórico de conversas

**Últimas 20 mensagens no sistema:**
```bash
docker exec -it -e PGPASSWORD='SENHA' wpp-postgres psql -U wpp_admin -d wpp_bot -c \
  "SELECT contact_number, direction, LEFT(content, 60) as preview, created_at 
   FROM wpp_messages 
   ORDER BY id DESC LIMIT 20;"
```

**Conversa completa com um cliente:**
```bash
docker exec -it -e PGPASSWORD='SENHA' wpp-postgres psql -U wpp_admin -d wpp_bot -c \
  "SELECT direction, content, created_at 
   FROM wpp_messages 
   WHERE contact_number='5566XXXXXXXXX' 
   ORDER BY id ASC;"
```

**Resumo de atendimentos do dia:**
```bash
docker exec -it -e PGPASSWORD='SENHA' wpp-postgres psql -U wpp_admin -d wpp_bot -c \
  "SELECT contact_number, 
          COUNT(*) FILTER (WHERE direction='in') as recebidas,
          COUNT(*) FILTER (WHERE direction='out_bot') as bot_enviou,
          COUNT(*) FILTER (WHERE direction='out_human') as vc_enviou
   FROM wpp_messages 
   WHERE created_at > CURRENT_DATE 
   GROUP BY contact_number 
   ORDER BY recebidas DESC;"
```

**Últimos handoffs (bot pausou pra humano):**
```bash
docker exec -it -e PGPASSWORD='SENHA' wpp-postgres psql -U wpp_admin -d wpp_bot -c \
  "SELECT contact_number, action, triggered_by, created_at 
   FROM wpp_handoff_log 
   ORDER BY id DESC LIMIT 10;"
```

---

## Inspecionar estado Redis de um cliente

Pra debugar o que tá acontecendo com um contato específico:

```bash
# Ver todas as chaves relacionadas ao contato
docker exec -it wpp-redis redis-cli -a 'SENHA' --scan --pattern '*:5566XXXXXXXXX'
docker exec -it wpp-redis redis-cli -a 'SENHA' --scan --pattern '*5566XXXXXXXXX*'
```

Ou com detalhes:
```bash
NUM="5566XXXXXXXXX"
PASS="SUA_SENHA"

echo "=== IGNORE ==="
docker exec -it wpp-redis redis-cli -a "$PASS" GET "bot:ignore:$NUM"

echo "=== PAUSED ==="
docker exec -it wpp-redis redis-cli -a "$PASS" GET "bot:paused:$NUM"
docker exec -it wpp-redis redis-cli -a "$PASS" TTL "bot:paused:$NUM"

echo "=== STATE ==="
docker exec -it wpp-redis redis-cli -a "$PASS" GET "bot:state:$NUM"

echo "=== BUFFER ==="
docker exec -it wpp-redis redis-cli -a "$PASS" LRANGE "buffer:msgs:$NUM" 0 -1
docker exec -it wpp-redis redis-cli -a "$PASS" GET "buffer:last:$NUM"
```

---

## Controle da integração Evolution/Typebot legacy

Só relevante se precisar fazer rollback completo pro Typebot.

**Ver estado atual da integração Typebot:**
```bash
curl -s -X GET 'http://localhost:8080/typebot/find/powerup-main' \
  -H 'apikey: EVOLUTION_API_KEY' | python3 -m json.tool
```

Hoje deve estar `"enabled": false`.

**Ver webhook atual da Evolution:**
```bash
curl -s -X GET 'http://localhost:8080/webhook/find/powerup-main' \
  -H 'apikey: EVOLUTION_API_KEY' | python3 -m json.tool
```

Hoje deve estar apontando pra `wpp-evolution-receive-v3`.

---

## Limpeza de lixo antigo (cuidado)

**Limpar todos os buffers de debounce antigos (ok, são voláteis mesmo):**
```bash
docker exec -it wpp-redis redis-cli -a 'SENHA' --scan --pattern 'buffer:*' | \
  xargs -r docker exec -i wpp-redis redis-cli -a 'SENHA' DEL
```

**Limpar marcações de anti-eco antigas (também ok, TTL curto):**
```bash
docker exec -it wpp-redis redis-cli -a 'SENHA' --scan --pattern 'bot:sent_msg:*' | \
  xargs -r docker exec -i wpp-redis redis-cli -a 'SENHA' DEL
```

**Truncar histórico de mensagens (EVITAR — você perde o histórico):**
```sql
-- Só em ambiente de dev/teste:
TRUNCATE TABLE wpp_messages RESTART IDENTITY;
TRUNCATE TABLE wpp_handoff_log RESTART IDENTITY;
```

Em produção, o melhor é **arquivar mensagens antigas**:
```sql
-- Apagar mensagens mais antigas que 6 meses
DELETE FROM wpp_messages WHERE created_at < NOW() - INTERVAL '6 months';
DELETE FROM wpp_handoff_log WHERE created_at < NOW() - INTERVAL '6 months';
```
