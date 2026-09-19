# Escopo implementado

## Atendimento
- WhatsApp inbound normalizado e idempotente.
- Delivery callbacks.
- texto, botão, lista e mídia.
- áudio, imagem, documento e sticker; vídeo é tratado como mídia e só deve ser habilitado após E2E do processador.
- IA consultiva para assuntos relacionados ao negócio.
- catálogo, FAQ/knowledge e promoções como fatos do Core.
- structured interactions bypassam IA quando determinísticas.
- fallback seguro quando IA falha.

## Agenda
- disponibilidade, slot offers, confirmação.
- consulta, cancelamento, rebooking e active rescheduling.
- waitlist V2.
- Calendar assíncrono com retry/dead-letter.
- remarcação desacoplada em DELETE da origem + CREATE do replacement.

## Growth
- lembretes em múltiplos estágios.
- reativação baseada em engagement profile.
- campanhas com consentimento, supressão, frequency cap e atribuição.
- marketing opt-out conversacional.

## Plataforma
- ML Admin / Manager / Employee sobre o mesmo Core.
- RBAC, memberships, auditoria, incidentes e observabilidade.
- catálogo de produtos e knowledge base.
- jobs com lease, backoff, retry e dead-letter.
- tenant-safe contracts.

## IA
- GPT-5.6 Luna como padrão de produção.
- Transcrição especializada para áudio.
- prompts separados: Orchestrator, Response Engine, Media Analyst e Campaign Copy.
