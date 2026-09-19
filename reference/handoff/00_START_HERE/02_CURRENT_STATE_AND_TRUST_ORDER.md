# CURRENT STATE & SOURCE TRUST ORDER — 2026-09-19

## Estado resumido

A base histórica 001–042 já existia antes do pacote atual. Um overlay 043–057 foi gerado no pacote `ML_AUTOMACOES_PROD_FINAL_LUNA`.

### STAGING conhecido

- base 001–042 restaurada e preflight aprovado;
- 043 aplicada e verificada;
- 044 aplicada e verificada;
- 045 aplicada e verificada;
- 046 aplicada e verificada;
- 047 aplicada e verificada;
- 048 aplicada em cópia corrigida por incompatibilidade `businesses.code` vs `businesses.business_code`;
- 049 aplicada e verificada;
- 050 aplicada e verificada;
- 051 NÃO deve ser presumida como aplicada;
- 052–057 ainda não devem ser presumidas como aplicadas.

PROD não deve ser alterado durante a auditoria.

## Canonicidade dos workflows V3

`01_CURRENT_IMPLEMENTATION/v3_reference/01_CORE_UNIVERSAL_V3_CANONICAL.json`
= referência V3 canônica.

`01_CORE_UNIVERSAL_V3_NONCANONICAL_MODIFIED.json`
= versão modificada/problemática; usar apenas para comparação.

`01_CORE_UNIVERSAL_V3_1_CALENDAR_ROUTING_EXPERIMENTAL.json`
= experimental/não canônica.

## Pacote 043–057

`ML_AUTOMACOES_PROD_FINAL_LUNA` é uma **candidata de implementação**, não prova de produção pronta.

O relatório estático ter PASS significa apenas integridade estática das verificações implementadas.

## Ordem de confiança

1. schema/introspecção real de STAGING;
2. objetos/funções realmente existentes no banco;
3. migrations canônicas exatas;
4. V3 canônica;
5. pacote LUNA atual;
6. runtime snapshots;
7. docs;
8. arquivos reconstruídos/experimentais.

## Lacuna importante do pacote de handoff

Este handoff não contém necessariamente os arquivos individuais exatos de TODAS as migrations 001–042. Ele inclui as migrations históricas que estavam disponíveis no contexto e um local para adicionar as demais.

Antes da auditoria definitiva, adicione:

- `schema.sql` atual de STAGING ou do backup lógico equivalente;
- migrations 001–042 exatas, se estiverem disponíveis localmente.

O schema real é mais importante do que reconstruir arquivos ausentes.

## Não incluir

Não enviar ao Claude:

- `.env` real;
- access tokens;
- service role key;
- Meta token;
- OpenAI/Anthropic key;
- Google client secret;
- dump de dados de clientes sem necessidade;
- `data.sql` de produção por padrão.

Use `.env.example` e placeholders.
