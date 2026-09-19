# ML Automações

Plataforma modular de automação empresarial WhatsApp/Instagram-first (agendamentos, pedidos,
CRM, IA de atendimento) sobre Postgres/Supabase + n8n.

Este repositório é o **workspace canônico** do produto. Ele foi inicializado em 2026-09-19 a
partir do pacote de handoff `ML_CLAUDE_MASTER_HANDOFF` (ver `reference/handoff/`), depois de uma
auditoria completa (Fase A) que identificou o estado real do código, contratos confirmados e
defeitos conhecidos. Detalhes em `docs/AUDIT/PHASE_A.md`.

## Estrutura

```
reference/
  handoff/      Cópia verbatim, IMUTÁVEL, do pacote de handoff original. Nunca editar.
                Fonte de evidência para qualquer disputa sobre "o que existia antes".
  historical/   Índice para as gerações históricas (V3 canônica/modificada/experimental,
                RC1, INTERMEDIATE) que vivem dentro de reference/handoff/. Não duplica bytes.

supabase/
  migrations/   Sequência canônica de migrations em evolução. Única fonte de verdade.
                NUNCA crie arquivos "_v2/_fixed/_final" concorrentes — corrija em uma
                migration nova numerada e documente a mudança no cabeçalho do arquivo.
  functions/    Edge Functions (Deno) — control-api, media-processor.
  preflight/    Scripts de verificação de contrato antes de aplicar migrations.
  scripts/      Validadores estáticos e scripts de introspecção read-only.
  tests/        Testes automatizados (pgTAP) — substituindo os não-testes herdados do LUNA.

n8n/            Workflows n8n canônicos, um arquivo por workflow, sem variantes paralelas.
apps/           Aplicações de frontend (ml-console).
domains/        Documentação e contratos por domínio de negócio (appointments, growth, food...).
platform/       Documentação da camada de plataforma compartilhada (identity, comms, AI runtime...).
prompts/        Prompts de sistema para os runtimes de IA.
schemas/        Contratos JSON Schema / OpenAPI usados por IA e APIs.
docs/           Documentação operacional, arquitetura, segurança, auditoria.
```

## Regras não-negociáveis

- **PROD nunca é alterado automaticamente.** Qualquer aplicação em PROD exige autorização
  explícita e fora deste fluxo.
- **Nenhuma migration histórica (001–042) é reescrita.** Correções viram migrations novas e
  numeradas sequencialmente.
- **Nenhum contrato é assumido.** Se uma função/tabela é referenciada mas não está neste
  repositório, ela é tratada como `UNVERIFIED` até confirmação real (introspecção de STAGING),
  nunca reconstruída por suposição.
- **Um único caminho canônico por responsabilidade.** Não deixe implementações concorrentes
  (`_v1`/`_v2`/`_final`) como candidatas ambíguas de produção — escolha uma, documente a decisão,
  e trate a(s) outra(s) como legado explicitamente aposentado.

## Estado atual

Ver `docs/AUDIT/PHASE_A.md` (diagnóstico completo) e `RISK_REGISTER.md`/`KNOWN_LIMITATIONS.md`
(mantidos continuamente). Este repositório está em correção ativa dos itens P0 identificados na
auditoria — ver `docs/P0_COMPLETION_REPORT.md` quando disponível para status.
