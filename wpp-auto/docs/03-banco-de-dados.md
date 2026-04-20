# 03 — Banco de dados

## PostgreSQL

Database: `wpp_bot` (separado do `n8n` e `evolution` internos).

Credenciais no `.env` do stack:
- User: `wpp_admin`
- Password: `<ver .env>`

Acesso CLI:
```bash
docker exec -it -e PGPASSWORD='<senha>' wpp-postgres psql -U wpp_admin -d wpp_bot
```

### Schema

**Tabela `wpp_messages`** — histórico completo de mensagens entrando e saindo.

```sql
CREATE TABLE wpp_messages (
  id SERIAL PRIMARY KEY,
  message_id TEXT UNIQUE,          -- ID da mensagem no WhatsApp
  contact_number TEXT NOT NULL,    -- número sem @s.whatsapp.net
  direction TEXT NOT NULL CHECK (direction IN ('in', 'out_bot', 'out_human')),
  content TEXT,                     -- conteúdo da mensagem
  raw_payload JSONB,                -- payload completo (opcional, pra debug)
  created_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_wpp_messages_contact ON wpp_messages(contact_number, created_at DESC);
CREATE INDEX idx_wpp_messages_direction ON wpp_messages(direction, created_at DESC);
```

**Direções:**
- `in` — cliente mandou pra gente
- `out_bot` — bot respondeu
- `out_human` — atendente humano (você) respondeu manualmente

**Tabela `wpp_handoff_log`** — registro de quando bot foi pausado/retomado.

```sql
CREATE TABLE wpp_handoff_log (
  id SERIAL PRIMARY KEY,
  contact_number TEXT NOT NULL,
  action TEXT NOT NULL CHECK (action IN ('pause', 'resume', 'expire')),
  triggered_by TEXT,                -- 'human_message', 'bot_flow_complete', 'manual'
  ttl_seconds INTEGER,
  created_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_wpp_handoff_contact ON wpp_handoff_log(contact_number, created_at DESC);
```

**Valores de `triggered_by`:**
- `human_message` — atendente escreveu manualmente pelo WhatsApp
- `bot_flow_complete` — bot finalizou fluxo e pausou pra humano assumir
- `manual` — reservado pra pausa via comando (não implementado)

### Queries úteis

**Conversa completa de um contato:**
```sql
SELECT id, direction, content, created_at 
FROM wpp_messages 
WHERE contact_number = '5566XXXXXXXXX' 
ORDER BY id ASC;
```

**Clientes que conversaram nas últimas 24h:**
```sql
SELECT DISTINCT contact_number, COUNT(*) as msgs, MAX(created_at) as ultima 
FROM wpp_messages 
WHERE created_at > NOW() - INTERVAL '24 hours' 
GROUP BY contact_number 
ORDER BY ultima DESC;
```

**Volume por dia (últimos 7 dias):**
```sql
SELECT DATE(created_at) as dia, direction, COUNT(*) 
FROM wpp_messages 
WHERE created_at > NOW() - INTERVAL '7 days' 
GROUP BY dia, direction 
ORDER BY dia DESC, direction;
```

**Clientes que iniciaram fluxo mas não completaram:**
```sql
-- Contatos com msg 'in' sem msg 'out_bot' subsequente com "Passando para"
SELECT DISTINCT m.contact_number 
FROM wpp_messages m 
WHERE m.direction = 'in' 
  AND NOT EXISTS (
    SELECT 1 FROM wpp_messages m2 
    WHERE m2.contact_number = m.contact_number 
      AND m2.direction = 'out_bot' 
      AND m2.content LIKE '%Passando para%'
      AND m2.created_at > m.created_at - INTERVAL '1 hour'
  )
  AND m.created_at > NOW() - INTERVAL '1 day';
```

**Histórico de handoffs do dia:**
```sql
SELECT contact_number, action, triggered_by, created_at 
FROM wpp_handoff_log 
WHERE created_at > NOW() - INTERVAL '1 day' 
ORDER BY created_at DESC;
```

## Redis

Host: `wpp-redis:6379`, password no `.env`.

Acesso CLI:
```bash
docker exec -it wpp-redis redis-cli -a '<senha>'
```

### Namespace de chaves

Todas as chaves do sistema usam prefixos claros:

| Padrão | TTL | Finalidade |
|---|---|---|
| `bot:ignore:<numero>` | sem TTL | Números que bot **nunca** processa |
| `bot:paused:<numero>` | 24h | Bot temporariamente pausado pra esse contato |
| `bot:state:<numero>` | 1h | Estado do fluxo conversacional (JSON) |
| `bot:sent_msg:<message_id>` | 5min | Marca anti-eco (mensagens enviadas pelo bot) |
| `buffer:msgs:<numero>` | 30s | Buffer de debounce (lista de mensagens) |
| `buffer:last:<numero>` | 30s | ID da última mensagem do buffer |

### Formato de valores

**`bot:ignore:<numero>` = `"1"`** — presença é o que importa.

**`bot:paused:<numero>` = `"1"`** — idem.

**`bot:state:<numero>` = JSON:**
```json
{"step":"menu","set_at":"2026-04-19T20:07:34.722Z"}
{"step":"aguardando_doc","set_at":"..."}
{"step":"aguardando_problema_tecnico","set_at":"..."}
```

**`bot:sent_msg:<message_id>` = `"1"`** — correlação de eco.

**`buffer:msgs:<numero>`** — lista Redis (LPUSH/LRANGE) com mensagens da rajada.

**`buffer:last:<numero>`** — string com o último message_id recebido pro contato.

### Comandos exploratórios

```bash
# Listar todas as chaves do sistema
docker exec -it wpp-redis redis-cli -a 'SENHA' KEYS 'bot:*'
docker exec -it wpp-redis redis-cli -a 'SENHA' KEYS 'buffer:*'

# Inspecionar um estado
docker exec -it wpp-redis redis-cli -a 'SENHA' GET 'bot:state:5566XXXXXXXXX'

# Ver TTL restante de uma chave (em segundos)
docker exec -it wpp-redis redis-cli -a 'SENHA' TTL 'bot:paused:5566XXXXXXXXX'

# Contar clientes com bot pausado
docker exec -it wpp-redis redis-cli -a 'SENHA' --scan --pattern 'bot:paused:*' | wc -l
```

### Coisas que NÃO mexer

A Evolution API também usa o Redis pra armazenar estado da sessão WhatsApp (Baileys). Essas chaves começam com `evolution:*`. **Nunca deletar**, elas são críticas pro funcionamento da conexão com WhatsApp.

```bash
# NÃO FAZER:
docker exec -it wpp-redis redis-cli -a 'SENHA' FLUSHALL
docker exec -it wpp-redis redis-cli -a 'SENHA' --scan | xargs DEL
```

Se precisar limpar estado do bot, sempre filtrar por prefixo:
```bash
# SEGURO - só o que é nosso
docker exec -it wpp-redis redis-cli -a 'SENHA' --scan --pattern 'bot:*' | \
  xargs -r docker exec -i wpp-redis redis-cli -a 'SENHA' DEL
```
