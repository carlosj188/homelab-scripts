#!/bin/bash
# Backup semanal do wpp_bot
# Agendar: 0 3 * * 0 /opt/wpp-auto/scripts/backup-semanal.sh >> /var/log/wpp-backup.log 2>&1

set -e

# CONFIGURAR antes de usar:
POSTGRES_PASSWORD=""  # copiar do .env
BACKUP_BASE="/opt/wpp-auto/backups"

# Validação
if [ -z "$POSTGRES_PASSWORD" ]; then
  echo "[ERRO] POSTGRES_PASSWORD não configurada no script"
  exit 1
fi

DATA=$(date +%Y-%m-%d)
BACKUP_DIR="$BACKUP_BASE/$DATA"
mkdir -p "$BACKUP_DIR"

echo "[$(date)] Iniciando backup em $BACKUP_DIR"

# Dump do database wpp_bot
docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" wpp-postgres \
  pg_dump -U wpp_admin -d wpp_bot --clean --if-exists \
  > "$BACKUP_DIR/wpp_bot.sql"

gzip "$BACKUP_DIR/wpp_bot.sql"
echo "[$(date)] Dump wpp_bot concluído"

# Manter só últimos 30 dias
find "$BACKUP_BASE" -maxdepth 1 -type d -mtime +30 -exec rm -rf {} +
echo "[$(date)] Limpeza de backups > 30 dias concluída"

echo "[$(date)] Backup finalizado: $BACKUP_DIR"
