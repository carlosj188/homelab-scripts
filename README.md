# Homelab Scripts

Scripts de automação para gerenciamento de homelab e infraestrutura.

## Scripts

| Script | Descrição |
|--------|-----------|
| `ssh-manager.sh` | Gerenciamento de chaves SSH em múltiplos servidores |
| `wg-manager.sh` | Gerenciamento de peers WireGuard |
| `wg-status.sh` | Status e monitoramento de túneis WireGuard |
| `rclone-backup-immich.sh` | Backup incremental do Immich via rclone |

## Uso

1. Clone o repositório
2. Copie `.env.example` para `.env` e preencha com seus valores
3. Dê permissão de execução: `chmod +x *.sh`
4. Execute o script desejado

## Configuração

Copie o arquivo de exemplo e edite:
```bash
cp .env.example .env
nano .env
```

## Licença

MIT
