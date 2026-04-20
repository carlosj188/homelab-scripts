# 01 — Arquitetura

## Visão geral

```
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│  Cliente WhatsApp                                               │
│       │                                                         │
│       ▼                                                         │
│  Evolution API ──────► webhook wpp-evolution-receive-v3         │
│                                       │                         │
│                                       ▼                         │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  wpp-receiver-v3                                         │   │
│  │  1. Está na ignore list? → aborta                        │   │
│  │  2. fromMe? TRUE  → pausa bot se for humano real         │   │
│  │              FALSE → se bot pausado, ignora              │   │
│  │                      senão → debounce 8s                 │   │
│  │                              → filtro dígito             │   │
│  │                              → chama engine              │   │
│  └──────────────────────────────────────────────────────────┘   │
│                                       │                         │
│                                       ▼                         │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  wpp-bot-engine (máquina de estados)                     │   │
│  │  → decide próxima mensagem baseada em step + input       │   │
│  │  → chama sender                                          │   │
│  │  → atualiza/limpa estado Redis                           │   │
│  │  → pausa bot ao fim do fluxo                             │   │
│  └──────────────────────────────────────────────────────────┘   │
│                                       │                         │
│                                       ▼                         │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  wpp-sender                                              │   │
│  │  → envia via Evolution API                               │   │
│  │  → marca anti-eco no Redis                               │   │
│  │  → loga Postgres                                         │   │
│  └──────────────────────────────────────────────────────────┘   │
│                                       │                         │
│                                       ▼                         │
│  Evolution API ──────► WhatsApp ──────► Cliente                 │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

## Componentes

### Infraestrutura (containers Docker)

Todos no stack `wpp-auto` em `/opt/wpp-auto/docker-compose.yml`:

| Container | Imagem | Função |
|---|---|---|
| `wpp-evolution` | `evoapicloud/evolution-api:latest` | Conexão WhatsApp (Baileys), expõe API REST em `:8080` |
| `wpp-n8n` | `docker.n8n.io/n8nio/n8n:latest` | Orquestração de workflows, exposto via `n8n.seudominio.com` |
| `wpp-postgres` | `postgres:16-alpine` | Banco compartilhado (n8n, evolution, wpp_bot) |
| `wpp-redis` | `redis:7-alpine` | Estado efêmero do bot |
| `wpp-typebot-builder` | `baptistearno/typebot-builder:latest` | **Desativado** (legacy, não deletado ainda) |
| `wpp-typebot-viewer` | `baptistearno/typebot-viewer:latest` | **Desativado** (legacy, não deletado ainda) |

Redes Docker: `wpp-auto_wpp-backend` (comunicação interna) e `wpp-auto_wpp-frontend` (apenas n8n).

### Workflows n8n

Acessível em https://n8n.seudominio.com

| Workflow | Trigger | Função |
|---|---|---|
| `wpp-receiver-v3` | Webhook `wpp-evolution-receive-v3` | Recebe eventos da Evolution, decide o fluxo |
| `wpp-bot-engine` | Execute Workflow | Motor conversacional (máquina de estados) |
| `wpp-sender` | Execute Workflow | Única saída pra Evolution API |

**Versões legacy** (manter desativadas por 2 semanas antes de deletar):
- `wpp-receiver` (v1 — sem debounce)
- `wpp-receiver-v2` (sem ignore list)
- `WhatsApp - Pausar bot quando eu responder` (experimento inicial)
- `My workflow` (teste inicial)

### Integração Typebot (desativada)

A Evolution API tem uma integração direta com Typebot (`/typebot/set`). Foi **desabilitada** em 19/04/2026 (`enabled: false`) mas não deletada. Pra reativar se precisar de rollback completo:

```bash
curl -X PUT \
  'http://localhost:8080/typebot/update/cmnwce6j800h7p54jk8hazju2/powerup-main' \
  -H 'apikey: SUA_EVOLUTION_API_KEY' \
  -H 'Content-Type: application/json' \
  -d '{"enabled": true, ...todos os campos originais...}'
```

## Configuração Evolution → webhook

Hoje aponta pra:
```
URL:    https://n8n.seudominio.com/webhook/wpp-evolution-receive-v3
Events: MESSAGES_UPSERT
```

Conferir:
```bash
curl -s -X GET 'http://localhost:8080/webhook/find/powerup-main' \
  -H 'apikey: SUA_EVOLUTION_API_KEY' | python3 -m json.tool
```

## Credenciais n8n

No n8n tem 3 credenciais configuradas (Personal project):

| Nome | Tipo | Uso |
|---|---|---|
| `Redis account` | Redis | Host `wpp-redis:6379` |
| `Postgres account` | Postgres | Host `wpp-postgres:5432`, DB `wpp_bot`, user `wpp_admin` |
| `Evolution account` | Evolution API (community node) | Server URL `http://evolution-api:8080`, API key |

IDs das credenciais (usados nos JSONs dos workflows):
- Redis: `YEun9v2RmIsI97HG`
- Postgres: `ED6cdHtL5HTFU4o8`
- Evolution: `2VodQgJvFM7OlLpa`

## Por que três camadas?

**Receiver** separado do **engine**:
- Receiver lida com protocolo (webhook, eventos, pausas, anti-eco)
- Engine lida com lógica conversacional (menu, estados, roteamento)
- Se algum dia você trocar Evolution por outro (WAHA, API oficial), só reescreve o receiver — engine permanece igual

**Sender** isolado:
- Única parte do sistema que conhece a Evolution API pra envio
- Centraliza retry, anti-eco e logging
- Adicionar delays, filas ou rate limiting no futuro mexe em 1 lugar só

**Comparação com arquitetura anterior (Typebot):**

| Aspecto | Typebot (antes) | n8n (agora) |
|---|---|---|
| Lógica conversacional | GUI visual (Typebot builder) | JavaScript em 1 node Code |
| Debounce | Fixo 10s, sem filtro inteligente | 8s + filtro de dígitos |
| Handoff bot→humano | Conflito com overrides de endpoint | Flag Redis com TTL 24h |
| Ignore list | `ignoreJids` mas brigava com debounce | Chave Redis simples |
| Histórico | Apenas no Typebot, difícil query | Postgres com SQL livre |
| Controle | Split: Typebot + n8n competindo | Unified: tudo em n8n |

## Fluxo de decisões do receiver

```
Webhook recebe evento
  │
  ├─ event != "messages.upsert"? → ABORTA
  │
  ├─ contact na ignore list? (bot:ignore:<num>) → ABORTA (silencioso)
  │
  ├─ fromMe = true?
  │    │
  │    ├─ É eco do próprio bot? (bot:sent_msg:<id> existe?) → ABORTA
  │    │
  │    └─ Atendente escrevendo manualmente → PAUSA BOT 24h
  │       + loga handoff + loga msg out_human
  │
  └─ fromMe = false (cliente)
       │
       ├─ Bot pausado? (bot:paused:<num> existe?) → ABORTA
       │
       └─ Processar:
            1. Loga msg in no Postgres
            2. Append no buffer debounce (buffer:msgs:<num>)
            3. Marca message_id como "último" (buffer:last:<num>)
            4. Wait 8s
            5. Ainda sou o último? Não → ABORTA (outra instância processa)
            6. Lê buffer
            7. Limpa buffer
            8. Filtro inteligente (procura dígito 0-3 ou concatena)
            9. Chama bot engine
```

## Fluxo de decisões do bot engine

Máquina de estados gerenciada via Redis (`bot:state:<numero>`):

```
Estados:
  (vazio)                       — cliente novo/expirado
  menu                          — mostrou menu, aguardando opção
  aguardando_problema_tecnico   — opção 1, aguardando problema
  aguardando_doc                — opção 2, aguardando CPF/CNPJ
  aguardando_produto            — opção 3, aguardando produto
  aguardando_problema_humano    — opção 0, aguardando problema

Transições:
  (vazio)      → menu                        (envia menu)
  menu + "1"   → aguardando_problema_tecnico (envia "descreva problema")
  menu + "2"   → aguardando_doc              (envia "envie CPF/CNPJ")
  menu + "3"   → aguardando_produto          (envia "qual produto")
  menu + "0"   → aguardando_problema_humano  (envia "descreva problema")
  menu + outro → menu                        (envia "msg inválida")
  aguardando_* + qualquer → (vazio) + PAUSA BOT 24h
                                             (envia "passando para setor")
```

TTL do estado: 1 hora. Se cliente ficar 1h sem responder, volta ao menu.
