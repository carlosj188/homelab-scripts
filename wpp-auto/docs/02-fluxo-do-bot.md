# 02 — Fluxo do bot

## Mensagens atuais

### Menu inicial
Enviado quando cliente novo manda qualquer mensagem, ou quando estado expira.

```
👋 Olá! Você entrou em contato com a *PowerUP Informática*.

Estamos prontos para te atender. Escolha uma das opções:

*1* - Suporte Técnico
*2* - Financeiro
*3* - Vendas
*0* - Atendimento humano

Digite o número correspondente para continuar.
```

### Opção 1 — Suporte Técnico
**Prompt (após escolher 1):**
```
🔧 Conectando ao suporte técnico.

Descreva o problema que um técnico vai te atender em instantes.
```

**Fechamento (após descrever):**
```
✅ Passando para o Técnico, aguarde.
```

### Opção 2 — Financeiro
**Prompt:**
```
💰 Para questões financeiras, envie seu *CPF ou CNPJ*.
```

**Fechamento:**
```
✅ Aguarde o setor financeiro.
```

### Opção 3 — Vendas
**Prompt:**
```
🛒 Nossa equipe comercial já está te atendendo.

Qual produto te interessa?
```

**Fechamento:**
```
✅ Passando para o setor de vendas, aguarde.
```

### Opção 0 — Atendimento humano
**Prompt:**
```
👤 Descreva o problema pra adiantar o chamado.
```

**Fechamento:**
```
✅ Passando para um atendente humano. Aguarde!!
```

### Mensagem de erro (menu inválido)
Quando cliente manda algo que não tem dígito 0-3:
```
Hmm, recebi sua mensagem 👍
Pra te direcionar melhor, digite só o número da opção:

*1* - Suporte Técnico
*2* - Financeiro
*3* - Vendas
*0* - Falar com atendente
```

## Como editar o fluxo

**Toda a lógica está em um único node JavaScript** do workflow `wpp-bot-engine`, chamado **"Decidir resposta"**.

### Mudar texto de uma mensagem

1. Abrir `wpp-bot-engine` no n8n
2. Clicar no node **"Decidir resposta"**
3. Editar as constantes no topo do código:

```javascript
const MSG_MENU = `👋 Olá! Você entrou em contato com a *PowerUP Informática*.
...`;

const MSG_TECNICO_PEDIR = `🔧 Conectando ao suporte técnico.
...`;
```

4. Save + Publish

### Adicionar uma opção nova no menu

Exemplo: adicionar opção **4 - Agendamento**.

1. Editar `MSG_MENU` adicionando a linha `*4* - Agendamento`
2. Editar o regex que detecta dígito (no filtro do receiver, em `wpp-receiver-v3` node "Filtrar input inteligente"):

Mudar:
```javascript
const match = msgStr.match(/(?:^|\s|[^\w])([0-3])(?:\s|$|[^\w])/);
```

Para:
```javascript
const match = msgStr.match(/(?:^|\s|[^\w])([0-4])(?:\s|$|[^\w])/);
```

3. Editar o regex do trimmed na mesma função:
```javascript
if (/^[0-3]$/.test(trimmed)) {  // mudar pra [0-4]
```

4. No node "Decidir resposta" do engine, adicionar as constantes novas:
```javascript
const MSG_AGENDAMENTO_PEDIR = `📅 Vamos agendar! Qual data você prefere?`;
const MSG_AGENDAMENTO_FINAL = `✅ Agendamento anotado, em breve confirmamos.`;
```

5. Adicionar a branch no switch `currentStep === 'menu'`:
```javascript
} else if (digit === '4') {
  response = {
    mensagem: MSG_AGENDAMENTO_PEDIR,
    novo_estado: { step: 'aguardando_agendamento', set_at: new Date().toISOString() },
    pausar_bot: false,
    ttl_estado: 3600
  };
}
```

6. Adicionar branch pra `aguardando_agendamento`:
```javascript
} else if (currentStep === 'aguardando_agendamento') {
  response = {
    mensagem: MSG_AGENDAMENTO_FINAL,
    novo_estado: null,
    pausar_bot: true,
    ttl_estado: 0
  };
}
```

7. Save + Publish ambos os workflows.

### Mudar debounce de 8s pra outro valor

1. Abrir `wpp-receiver-v3`
2. Clicar no node **"Wait 8s (debounce)"**
3. Mudar campo `amount` (em segundos)
4. Save + Publish

Cuidado: se aumentar muito, cliente percebe demora. Se diminuir muito, rajadas fragmentam. 5-10s é sweet spot.

### Mudar TTL da pausa (24h pra outro valor)

Tem **2 lugares** onde pausa é criada:

**1. Receiver** (quando atendente escreve manual) — node "Redis: pausar bot 24h", campo `ttl` (segundos).

**2. Engine** (quando fluxo termina) — node "Redis: pausar bot 24h", campo `ttl` (segundos).

86400 = 24h. Alterar os dois pra consistência.

## Dicas de design do fluxo

**Regra de ouro:** o bot deve **sempre** terminar em um estado que pause ou espere input. Nunca deixar o cliente sem saber o que fazer.

**Validação de input:** atualmente aceita qualquer coisa em estados `aguardando_*`. Se quiser validar CPF antes de finalizar o fluxo financeiro, adicionar lógica no handler de `aguardando_doc`:

```javascript
} else if (currentStep === 'aguardando_doc') {
  // Valida CPF (11 dígitos) ou CNPJ (14 dígitos)
  const onlyDigits = contentRaw.replace(/\D/g, '');
  if (onlyDigits.length !== 11 && onlyDigits.length !== 14) {
    response = {
      mensagem: 'Formato inválido. Envie apenas os números do CPF ou CNPJ.',
      novo_estado: { step: 'aguardando_doc', set_at: new Date().toISOString() },
      pausar_bot: false,
      ttl_estado: 3600
    };
  } else {
    response = {
      mensagem: MSG_FINANCEIRO_FINAL,
      novo_estado: null,
      pausar_bot: true,
      ttl_estado: 0
    };
  }
}
```

**Horário comercial:** pra bot responder diferente fora do expediente, adicionar no início do script:

```javascript
const now = new Date();
const hour = now.getUTCHours() - 3; // UTC-3 para horário de Brasília
const day = now.getUTCDay(); // 0=domingo, 6=sábado
const foraDoExpediente = day === 0 || day === 6 || hour < 8 || hour >= 18;

if (foraDoExpediente && currentStep === null) {
  return [{
    json: {
      contact_number: contactNumber,
      instance: instance,
      mensagem: '⏰ Estamos fora do horário comercial (8h-18h, seg-sex). Responderemos assim que possível.',
      novo_estado: null,
      pausar_bot: true,
      ttl_estado: 0
    }
  }];
}
```
