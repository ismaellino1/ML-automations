# ML Automações — Auditoria Fase A (somente leitura)

Data: 2026-09-19
Escopo: pacote `ML_CLAUDE_MASTER_HANDOFF` (ver `reference/handoff/`).
Status: entregue ao usuário em chat como resposta obrigatória pré-implementação (prompt mestre
§37/§28 Fase A). Nenhum código foi alterado durante esta fase; nenhuma migration foi executada;
PROD/STAGING não foram tocados.

> Este arquivo é a cópia de registro da auditoria completa. O conteúdo integral (seções A–J,
> achados D.1–D.21, matriz de classificação B, roadmap G, plano H, lacunas I, estratégia J) foi
> entregue ao usuário na conversa e é reproduzido aqui para referência permanente do repositório.
> Ver histórico da conversa da sessão para o texto completo original; este arquivo é atualizado
> conforme os achados são confirmados/refutados pela introspecção real de STAGING.
>
> **Atualização 2026-09-20**: a primeira rodada de introspecção real (AÇÃO-001, Seção 8) já
> voltou — 14 de 18 itens da Seção I confirmados existentes em STAGING, 3 confirmados genuinamente
> ausentes (nenhum falso positivo da auditoria original até agora). Ver
> `docs/AUDIT/PHASE_A_INTROSPECTION_UPDATE.md` para o detalhe completo e `RISK_REGISTER.md` para
> os status atualizados. Ainda faltam as Seções 0–7 (assinaturas/colunas exatas) para fechar P0.6
> por completo.

## Resumo executivo

O pacote contém 4 gerações sucessivas do produto (V3 canônica → RC1 → INTERMEDIATE → LUNA).
LUNA (baseline deste repositório) se autodeclara não aprovada para produção. O validador estático
do próprio pacote não verifica assinatura de chamada de função, existência de função referenciada,
nem contratos JSON entre funções — por isso vários defeitos CRITICAL passam despercebidos.

Achados CRITICAL confirmados por leitura direta de código (não apenas citados do handoff):

- D.1 — `ingest_whatsapp_webhook_final` perde o próprio audit trail em qualquer erro
  (rollback do savepoint de exceção desfaz o INSERT inicial de dedup).
- D.2 — Migration 051 colide com o contrato real de `core.message_delivery_events` (027);
  INSERT referencia colunas inexistentes, sem `event_key`; FK composta pode nem ser DDL válido.
- D.3 — `core.finalize_assistant_turn` (chamada por todo turno de conversa) não está definida
  em lugar nenhum deste pacote.
- D.4 — `execute_control_plane_action_final` (055, implementação completa) é código morto;
  todos os entry points reais chamam a versão `_v2` limitada (3 ações). Frontend `ml-console` é
  um esqueleto 0% funcional.
- D.5 — Pipeline de observabilidade global quebrado: `record_automation_incident_v1` espera 8
  argumentos posicionais, o Error Trigger global do n8n (workflow 99) chama com 1 JSONB.

Achados HIGH: D.6 (`run_housekeeping_v2` ausente), D.7 (`lease_owner` zerado antes de gravado),
D.8 (`businesses.code` vs `business_code` no arquivo do pacote, não só no snapshot de STAGING),
D.9 (`select_and_confirm_slot_offer_option_v3` ausente), D.10 (`appointment_calendar_syncs` +
funções de ciclo de vida ausentes), D.11 (ver reclassificação abaixo).

Achados MEDIUM/LOW: D.12–D.21 — frontend vazio, testes sem asserção real (0/15 cenários do
TEST_MATRIX automatizados), vídeo processado sem gate, padrão sistêmico de switches n8n com
ramos de erro não fiados, notificação de cancelamento órfã nos 3 workflows V3, ausência de
idempotência na nova forma de `message_delivery_events`, parâmetro `p_ignore_appointment_id`
nunca usado, nós órfãos no workflow canônico, mismatch de nome de arquivo/cabeçalho em 046,
tabela órfã `customer_marketing_preferences` após 052.

### Reclassificação de D.11 (correção solicitada pelo usuário)

**D.11 original estava mal enquadrado.** O nome do modelo (`gpt-5.6-luna`) não é, por si só, um
defeito — não tenho base para afirmar que um ID de modelo de um provider é inválido apenas por
desconhecê-lo. **O defeito real e comprovado é a divergência entre a existência de
`core.ai_runtime_policies`/`core.get_ai_runtime_policy_v1` (057) — que nunca são lidas por
nenhum consumidor — e o hardcode literal do modelo em dois nós n8n, reforçado pelo próprio
validador estático, contradizendo `docs/AI_MODEL_POLICY.md`.** Isso é reclassificado como:

- **D.11 (revisado) — HIGH, CONFIRMED**: divergência arquitetural doc/política/código sobre
  seleção de modelo de IA — não um defeito de nome de modelo. A validação de disponibilidade
  real do ID do modelo junto ao provider é um item separado, de verificação operacional
  (checklist de `MANUAL_ACTIONS_FOR_ISMAEL.md`), não uma afirmação de invalidade técnica feita
  por esta auditoria.

## Estrutura completa

Ver o restante das seções (B–J: mapa canônico/histórico, arquitetura reconstruída, roadmap
P0–P4, plano de execução, lacunas de informação, estratégia de validação) no histórico da
conversa desta sessão. Serão extraídas para arquivos dedicados (`ARCHITECTURE_CURRENT.md`,
`RISK_REGISTER.md`, `ROADMAP.md`) conforme a Fase B avança, para não duplicar manutenção entre
este arquivo e os documentos vivos.
