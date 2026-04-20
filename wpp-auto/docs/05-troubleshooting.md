# 05 — Troubleshooting

## Bot não está respondendo a um cliente

Investigação ordenada, parar no primeiro "sim":

### 1. Evolution está conectada?
```bash
curl -s -X GET 'http://localhost:8080/instance/fetchInstances' \
  -H 'apikey: EVOLUTION_API_KEY' | python3 -m json.tool | grep -E 'name|connectionStatus'
```

`connectionStatus` deve ser `"open"`. Se for `"close"` ou `"connecting"`, a conexão WhatsApp caiu — reconectar via QR code.

### 2. Webhook está apontado pro lugar certo?
```bash
curl -s -X GET 'http://localhost:8080/webhook/find/powerup-main' \
  -H 'apikey: EVOLUTION_API_KEY' | python3 -m json.tool
```

URL deve ser `https://n8n.seudominio.com/webhook/wpp-evolution-receive-v3` e `enabled: true`.

### 3. Workflow n8n está ativo?
- https://n8n.seudominio.com → abre `wpp-receiver-v3`
- Toggle no canto superior direito deve estar **ligado** (verde/laranja)
- Deve ter ícone "Published" ao lado

### 4. Número está na ignore list?
```bash
docker exec -it wpp-redis redis-cli -a 'SENHA' GET 'bot:ignore:NUMERO'
```

Se retornar `"1"`, está ignorado. Remover com `DEL` se quiser que bot atenda.

### 5. Bot está pausado pra esse cliente?
```bash
docker exec -it wpp-redis redis-cli -a 'SENHA' GET 'bot:paused:NUMERO'
```

Se retornar `"1"`, está pausado (provavelmente pelo próprio fluxo completar, ou porque você escreveu manual). Remover com:
```bash
docker exec -it wpp-redis redis-cli -a 'SENHA' DEL 'bot:paused:NUMERO'
```

### 6. Número correto?
Lembrete: o WhatsApp Brasil às vezes guarda números **sem** o nono dígito. Se você está olhando `556699XXXXXXX` mas o JID real é `5566XXXXXXX` (sem o 9), ele não vai achar.

Descobrir o JID real que chegou:
```bash
docker exec -it -e PGPASSWORD='SENHA' wpp-postgres psql -U wpp_admin -d wpp_bot -c \
  "SELECT DISTINCT contact_number FROM wpp_messages ORDER BY contact_number;"
```

### 7. Olhar execuções do n8n
Se chegou até aqui, o problema é mais sutil. Ver o que aconteceu:

1. Abre `wpp-receiver-v3` no n8n → aba **Executions**
2. Ordenado por mais recente — procura a execução perto do horário da mensagem
3. Clica pra abrir — mostra o fluxo com ticks verdes ✅ ou vermelhos ❌
4. Clica em cada node verde pra ver INPUT/OUTPUT
5. Se tem node vermelho, clica nele e olha a aba **Error** pra mensagem

**Checklist de execução esperada** (mensagem de cliente normal):
```
✅ Webhook Evolution
✅ É messages.upsert? (branch true)
✅ Normalizar campos
✅ Redis: está na ignore list?
✅ Está na ignore list? (branch false)
✅ fromMe = true? (branch false — cliente)
✅ Redis: bot pausado?
✅ Está pausado? (branch false — livre)
✅ Postgres: log msg recebida
✅ Preparar buffer keys
✅ Redis: append buffer
✅ Redis: marcar ultimo
⏸ Wait 8s (debounce)
✅ Redis: ler ultimo
✅ Sou a ultima msg? (branch true — última da rajada)
✅ Redis: ler buffer
✅ Redis: limpar buffer
✅ Filtrar input inteligente
✅ Chamar bot engine
```

Se parar em algum desses, foi ali que deu problema.

---

## Bot respondeu mas mensagem não chegou no WhatsApp

### 1. Sender executou com sucesso?
No n8n, abre `wpp-sender` → aba Executions → verifica última execução.

Se o node **"Enviar via Evolution"** estiver **vermelho**, abre a aba Error. Causas comuns:
- `Instance does not exist` — nome da instância errado no payload
- `Invalid phone number` — formato do número ruim
- `401 Unauthorized` — credencial Evolution expirada ou key errada

### 2. Evolution aceitou mas WhatsApp não entregou?
Verificar mensagem na Evolution:
```bash
MESSAGE_ID="3EB0XXXXXXXXX"  # ID que o sender retornou
curl -s -X POST 'http://localhost:8080/chat/findMessages/powerup-main' \
  -H 'apikey: EVOLUTION_API_KEY' \
  -H 'Content-Type: application/json' \
  -d "{\"where\": {\"key\": {\"id\": \"$MESSAGE_ID\"}}}"
```

Campo `status` na resposta:
- `PENDING` — ainda não enviou
- `SERVER_ACK` — Evolution confirmou envio
- `DELIVERY_ACK` — chegou no WhatsApp do destinatário
- `READ` — destinatário leu

### 3. Número destino é inválido?
Número precisa existir como conta WhatsApp ativa. Se o JID não tiver WhatsApp, a Evolution aceita mas não entrega. Validar:

```bash
curl -s -X POST 'http://localhost:8080/chat/whatsappNumbers/powerup-main' \
  -H 'apikey: EVOLUTION_API_KEY' \
  -H 'Content-Type: application/json' \
  -d '{"numbers": ["5566XXXXXXXXX"]}'
```

Retorna `exists: true/false` pra cada número.

### 4. Problema específico do Brasil — nono dígito
Se o teu celular mostra `+55 66 98XXX-XXXX` mas a Evolution guardou `556684XXXXXX` (sem o 9), mandar pra um número com 9 não entrega.

Pra testar um número novo, manda primeiro **sem o 9**. Se não entregar, tenta com 9.

---

## Bot está respondendo várias vezes seguidas (spam)

Causa provável: **debounce não está funcionando**, mensagens não estão sendo agrupadas.

**1. Verificar se v3 está ativo e é o webhook atual:**
```bash
curl -s -X GET 'http://localhost:8080/webhook/find/powerup-main' \
  -H 'apikey: EVOLUTION_API_KEY' | grep url
```

Deve apontar pra `wpp-evolution-receive-v3`. Se está apontando pra `wpp-evolution-receive` ou `wpp-evolution-receive-v2`, tá usando versão antiga sem debounce inteligente.

**2. Buffer do Redis está acumulando?**
Durante uma rajada, deveria ver chaves aparecendo:
```bash
# Enquanto cliente está mandando mensagens, em outro terminal:
watch -n 1 'docker exec -it wpp-redis redis-cli -a SENHA KEYS "buffer:*"'
```

Se as chaves **não aparecem** durante a rajada, o append ao buffer não está rolando. Verificar execuções do receiver pra achar o erro.

**3. Aborto do debounce está funcionando?**
Se 3 mensagens chegam em sequência rápida, 2 execuções do receiver devem **abortar** no node "Sou a última msg?" e só 1 deve ir adiante. No n8n:

- `wpp-receiver-v3` → Executions
- Das 3 execuções da rajada, 2 devem ter caminho curto (parou no IF) e 1 deve ter caminho longo (seguiu pro engine)

Se as 3 seguiram pro engine → debounce quebrado. Provavelmente problema na comparação `message_id` do node "Sou a última msg?".

---

## Workflow n8n quebrou / nunca mais executou

### 1. Container n8n está up?
```bash
docker ps --filter "name=wpp-n8n" --format "{{.Status}}"
```

Se não está `Up`, reiniciar:
```bash
cd /opt/wpp-auto
docker compose restart wpp-n8n
```

### 2. Postgres está up?
```bash
docker ps --filter "name=wpp-postgres" --format "{{.Status}}"
```

Se o Postgres cair, o n8n também para (usa Postgres pra guardar workflow state).

### 3. Espaço em disco?
```bash
df -h /
```

Se `/` está cheio (> 90%), Docker pode ter parado containers. Limpar imagens órfãs:
```bash
docker system prune -a --volumes
```

**Cuidado:** isso apaga imagens não usadas. Confirma que a resolução das imagens no compose ainda pega do registry.

### 4. Logs do n8n pra debugar:
```bash
docker logs --tail 200 wpp-n8n
```

Procurar por `ERROR`, `crash`, stacktraces.

---

## Rollback completo pro Typebot

Situação: bug grave no sistema novo, preciso voltar pro Typebot imediatamente.

**1. Trocar webhook da Evolution de volta:**

A Evolution original não usava webhook pro Typebot (era integração direta). Pode desligar o webhook ou deixar apontando pra lugar nenhum:

```bash
curl -X POST 'http://localhost:8080/webhook/set/powerup-main' \
  -H 'apikey: EVOLUTION_API_KEY' \
  -H 'Content-Type: application/json' \
  -d '{"webhook": {"enabled": false, "url": "https://n8n.seudominio.com/webhook/wpp-evolution-receive-v3", "events": ["MESSAGES_UPSERT"]}}'
```

**2. Reativar integração Typebot:**
```bash
curl -X PUT 'http://localhost:8080/typebot/update/<TYPEBOT_BINDING_ID>/powerup-main' \
  -H 'apikey: EVOLUTION_API_KEY' \
  -H 'Content-Type: application/json' \
  -d '{
    "enabled": true,
    "description": "wpp-auto",
    "url": "http://typebot-viewer:3000",
    "typebot": "my-typebot-otdk3bq",
    "expire": 30,
    "keywordFinish": "#sair",
    "delayMessage": 1000,
    "unknownMessage": "",
    "listeningFromMe": false,
    "stopBotFromMe": true,
    "keepOpen": true,
    "debounceTime": 10,
    "triggerType": "all",
    "triggerOperator": "contains",
    "triggerValue": "",
    "splitMessages": false,
    "timePerChar": 0
  }'
```

**3. Confirmar containers Typebot estão up:**
```bash
docker ps --filter "name=typebot"
```

Se não estiverem, `docker compose up -d` no stack.

**4. Testar mandando mensagem pra Evolution** — Typebot deve responder.

**5. Investigar o que deu errado no sistema novo** com tempo, sem pressa.

**6. Quando resolver**, refazer cutover pro v3 (ver doc de arquitetura).

---

## Debug avançado — inspecionar execução específica

Se quiser entender exatamente o que aconteceu em uma mensagem:

1. Saber o horário aproximado em que o cliente mandou
2. n8n → `wpp-receiver-v3` → Executions → procurar execução próxima
3. Clicar na execução → canvas mostra caminho tomado
4. Clicar em cada node verde → painel lateral direito → abas:
   - **INPUT** — o que chegou nesse node
   - **OUTPUT** — o que saiu
   - **JSON** — ver estrutura completa
5. Se engine foi chamado, seguir o link da execução do `wpp-bot-engine`
6. Se sender foi chamado, seguir pro `wpp-sender`

Os 3 workflows mantêm histórico independente de execuções.
