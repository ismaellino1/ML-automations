# Política de IA — PROD FINAL

Modelo padrão de atendimento: `gpt-5.6-luna`.

Uso:
- Orquestrador: Luna, raciocínio médio.
- Response Engine: Luna, raciocínio baixo.
- Análise de imagem/documento: Luna.
- Áudio: `gpt-4o-mini-transcribe` para transcrição e Luna para interpretação do conteúdo.
- Interações estruturadas do WhatsApp não gastam IA quando o comando é determinístico.

A escolha de Luna reduz custo no caminho de alto volume. A política também está persistida em
`core.ai_runtime_policies`, para permitir evolução sem redesenhar o Core.

Não troque o modelo diretamente em vários workflows. A alteração deve partir da política de runtime
e ser aplicada de forma versionada.
