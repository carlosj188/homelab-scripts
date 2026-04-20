# 06 — Manutenção

## Backup

### Estratégia em camadas

**1. Proxmox Backup Server (PBS)** — nível VM
- VM `whats-auto` tem backups diários via PBS (datastore `backups`)
- Cobre Docker volumes, configs, `.env`, tudo do sistema
- Primeira linha de defesa pra disaster recovery
- Restauração: PBS → Restore VM → pronta em minutos

**2. Backup do Postgres** — nível aplicação
- Histórico de mensagens preservado mesmo se VM inteira morrer
- Útil pra análises, auditoria

**3. Backup dos workflows n8n** — nível config
- JSON exportável de cada workflow
- Permite recriar a lógica em qualquer instância n8n

### Rotina sugerida

**Diário (PBS automatizado):**
Já configurado no Proxmox, não precisa fazer nada.

**Semanal (dump Postgres + export workflows):**

Cria script em `/opt/wpp-auto/scripts/backup-semanal.sh`:

```bash
#!/bin/bash
set -e

DATA=$(date +%Y-%m-%d)
BACKUP_DIR="/opt/wpp-auto/backups/$DATA"
mkdir -p "$BACKUP_DIR"

# Dump do database wpp_bot
docker exec -e PGPASSWORD='SENHA' wpp-postgres \
  pg_dump -U wpp_admin -d wpp_bot --clean --if-exists \
  > "$BACKUP_DIR/wpp_bot.sql"

# Compactar
gzip "$BACKUP_DIR/wpp_bot.sql"

# Manter só últimos 30 dias
find /opt/wpp-auto/backups -maxdepth 1 -type d -mtime +30 -exec rm -rf {} +

echo "Backup concluído: $BACKUP_DIR"
```

Agendar no crontab:
```bash
0 3 * * 0 /opt/wpp-auto/scripts/backup-semanal.sh >> /var/log/wpp-backup.log 2>&1
```

**Export de workflows (manual, quando fizer mudanças):**

No n8n, pra cada workflow:
1. Abre o workflow
2. Canto superior direito, 3 pontinhos (⋯) → **Download**
3. Salva em `~/homelab-scripts/wpp-migration/workflows/<nome>-YYYY-MM-DD.json`
4. Commit no git

### Restauração

**Postgres:**
```bash
# Dropar e recriar database (cuidado — perde dados atuais)
docker exec -it -e PGPASSWORD='SENHA' wpp-postgres psql -U wpp_admin -d postgres -c \
  "DROP DATABASE wpp_bot; CREATE DATABASE wpp_bot OWNER wpp_admin;"

# Restaurar dump
gunzip < backup/wpp_bot.sql.gz | \
  docker exec -i -e PGPASSWORD='SENHA' wpp-postgres psql -U wpp_admin -d wpp_bot
```

**n8n workflow:**
- Workflows → **Import from File** → seleciona JSON
- Reconfigurar credenciais (precisa clicar em cada node Redis/Postgres/Evolution e re-selecionar)
- Save + Publish

---

## Atualização de versões

### Evolution API
```bash
cd /opt/wpp-auto
docker compose pull wpp-evolution
docker compose up -d wpp-evolution
```

**⚠️ Cuidado:** Evolution tem breaking changes entre versões. Antes de atualizar:
1. Snapshot PBS da VM
2. Ler changelog em https://github.com/EvolutionAPI/evolution-api/releases
3. Testar em ambiente de staging se disponível

### n8n
```bash
cd /opt/wpp-auto
docker compose pull wpp-n8n
docker compose up -d wpp-n8n
```

Geralmente sem breaking changes. Workflows continuam funcionando.

### Postgres / Redis
Raramente precisa atualizar. Se for major version (ex: postgres 16→17), fazer:
1. Backup completo antes
2. Testar em staging
3. Upgrade pode requerer `pg_upgrade` ou dump/restore

---

## Rotação de senhas

Recomendado a cada 6 meses, ou imediatamente se vazou em algum lugar (ex: ficou em log, screenshot, etc.).

### Senhas no stack

Todas em `/opt/wpp-auto/.env`:

| Variável | Uso |
|---|---|
| `POSTGRES_PASSWORD` | Usada pelo n8n, Evolution, Typebot pra conectar no PG |
| `REDIS_PASSWORD` | Usada pelo n8n pra conectar no Redis |
| `EVOLUTION_API_KEY` | Header `apikey` em chamadas à Evolution |
| `SMTP_PASSWORD` | SMTP pro envio de emails (senha de app Gmail) |

### Como rotacionar (exemplo Postgres)

**1. Gerar nova senha aleatória:**
```bash
NEW_PASS=$(openssl rand -hex 24)
echo "$NEW_PASS"
```

**2. Alterar dentro do Postgres:**
```bash
docker exec -it -e PGPASSWORD='SENHA_ATUAL' wpp-postgres psql -U wpp_admin -d postgres -c \
  "ALTER USER wpp_admin WITH PASSWORD 'NOVA_SENHA';"
```

**3. Atualizar `.env`:**
```bash
sed -i "s/POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=NOVA_SENHA/" /opt/wpp-auto/.env
```

**4. Atualizar credencial no n8n:**
- https://n8n.seudominio.com → Credentials → `Postgres account`
- Campo Password → atualizar → Save

**5. Reiniciar containers que usam a senha:**
```bash
cd /opt/wpp-auto
docker compose up -d --force-recreate wpp-evolution
# n8n pega do credential store, não precisa reiniciar
```

**6. Validar:**
```bash
# Tentar conectar
docker exec -it -e PGPASSWORD='NOVA_SENHA' wpp-postgres psql -U wpp_admin -l
```

**7. Testar bot end-to-end** mandando mensagem real.

### API Key da Evolution

Troca pelo próprio painel da Evolution ou regenera via variável de ambiente + restart. Depois **atualizar credencial `Evolution account` no n8n**.

---

## Limpeza do legacy Typebot

**Condição:** sistema novo rodando estável por 2 semanas sem rollback.

### Remover containers Typebot

**1. Editar `/opt/wpp-auto/docker-compose.yml`** removendo os serviços:
```yaml
# DELETAR ESSAS SEÇÕES:
  wpp-typebot-builder:
    ...
  wpp-typebot-viewer:
    ...
```

**2. Remover da Evolution:**
```bash
curl -X DELETE 'http://localhost:8080/typebot/delete/<TYPEBOT_BINDING_ID>/powerup-main' \
  -H 'apikey: EVOLUTION_API_KEY'
```

**3. Aplicar compose:**
```bash
cd /opt/wpp-auto
docker compose up -d --remove-orphans
```

Containers Typebot desaparecem.

**4. Remover database Typebot** (só depois de confirmar que não precisa dos dados):
```sql
DROP DATABASE typebot;
```

### Remover workflows legacy do n8n

Só depois de 2+ semanas com v3 estável:

1. n8n → workflows
2. `wpp-receiver` (v1) → 3 pontinhos (⋯) → Delete
3. `wpp-receiver-v2` → Delete
4. `WhatsApp - Pausar bot quando eu responder` → Delete (experimento)
5. `My workflow` → Delete (teste)

Manter apenas: `wpp-receiver-v3`, `wpp-bot-engine`, `wpp-sender`.

---

## Monitoramento (sugestões futuras)

Atualmente o sistema não tem monitoramento ativo além dos logs do Graylog (que recebe de vários containers). Ideias pra adicionar:

**1. Alerta via Telegram/Discord quando Evolution desconecta:**
Cron que roda a cada 5 min:
```bash
STATUS=$(curl -s -X GET 'http://localhost:8080/instance/fetchInstances' \
  -H 'apikey: KEY' | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['connectionStatus'])")

if [ "$STATUS" != "open" ]; then
  curl -X POST "https://api.telegram.org/botTOKEN/sendMessage" \
    -d "chat_id=SEU_ID&text=⚠️ Evolution desconectou: $STATUS"
fi
```

**2. Grafana + Postgres:**
- Connect Grafana ao `wpp_bot`
- Dashboard com:
  - Mensagens/dia (linha temporal)
  - Taxa de handoff (bot→humano)
  - Tempo médio de atendimento por cliente
  - Top clientes por volume

**3. Métricas de saúde exportadas:**
- Workflow n8n "health check" que roda a cada minuto
- Testa: Redis responde, Postgres responde, Evolution responde, bot-engine executa
- Se falhar, manda alerta

---

## Contato de suporte (referências)

- Evolution API: https://doc.evolution-api.com
- n8n docs: https://docs.n8n.io
- Baileys (biblioteca WhatsApp por baixo): https://github.com/WhiskeySockets/Baileys
