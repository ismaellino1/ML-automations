# Segurança
- service_role somente em Edge Functions/server.
- segredos nunca em tabelas, prompts ou frontend.
- RLS em superfícies públicas.
- core não deve ser exposto anonimamente.
- Security Definer sempre com search_path vazio e nomes qualificados.
- webhooks internos protegidos por Header Auth.
- mídia é tratada como conteúdo não confiável; prompt injection em mídia é ignorada.
- outbox/campaigns respeitam consentimento e frequência.
- executar `n8n audit` antes de produção.
