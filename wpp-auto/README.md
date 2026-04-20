# wpp-auto — WhatsApp automation (n8n + Evolution API)

Automação de atendimento WhatsApp da PowerUP Informática usando n8n, Evolution API, Redis e PostgreSQL.

**Substitui** o stack anterior que usava Typebot. A migração foi feita em abril/2026 pra resolver limitações do Typebot (overrides de endpoints, debounce inflexível, dificuldade em controlar handoff bot/humano).

## Estrutura da documentação

- [`docs/01-arquitetura.md`](docs/01-arquitetura.md) — visão geral, diagrama, componentes
- [`docs/02-fluxo-do-bot.md`](docs/02-fluxo-do-bot.md) — máquina de estados, mensagens, customização
- [`docs/03-banco-de-dados.md`](docs/03-banco-de-dados.md) — schema Postgres + chaves Redis
- [`docs/04-operacao.md`](docs/04-operacao.md) — comandos do dia a dia (pausar bot, ignore list, etc.)
- [`docs/05-troubleshooting.md`](docs/05-troubleshooting.md) — bot não responde, debug, rollback
- [`docs/06-manutencao.md`](docs/06-manutencao.md) — backup, atualização, rotação de senhas

## TL;DR

Cliente manda mensagem → Evolution API → webhook n8n → workflow decide: ignora, pausa bot, ou responde via bot engine → envia pelo sender → volta pro cliente.

Stack rodando em `/opt/wpp-auto/docker-compose.yml` na VM `whats-auto` (Proxmox).

Componentes:
- **Evolution API** — conexão WhatsApp (Baileys)
- **n8n** — orquestração (3 workflows: receiver, bot-engine, sender)
- **PostgreSQL** — histórico de mensagens e handoffs
- **Redis** — estado efêmero (pausas, estados do bot, buffers de debounce)
