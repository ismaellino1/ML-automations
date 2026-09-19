# SECURITY & SECRETS RULES FOR HANDOFF

## Pode enviar

- `.env.example`;
- nomes de variáveis;
- URLs públicas/documentação;
- schemas;
- migrations;
- código;
- dados sintéticos;
- IDs técnicos não secretos quando necessários para reproduzir estrutura.

## Não enviar por padrão

- `.env` real;
- database password;
- service_role key;
- JWT secret;
- Meta access token;
- Google client secret;
- OpenAI/Anthropic API key;
- payment provider secret;
- private keys;
- production customer data;
- production `data.sql`.

## Se Claude precisar validar provider real

Configure secrets diretamente no ambiente seguro da ferramenta/CI, nunca no prompt ou em arquivo versionado.
