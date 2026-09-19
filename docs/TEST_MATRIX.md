# Matriz de testes obrigatória
1. Texto normal, erro ortográfico, gíria, idioma misto.
2. Slot offer, clique válido, clique antigo, clique duplicado.
3. Cancelamento pelo cliente, profissional e empresa.
4. Reschedule ativo: antigo RESCHEDULED, novo CONFIRMED, Calendar DELETE+CREATE.
5. Rebook cancelado.
6. Áudio, imagem, documento, vídeo e mídia corrompida.
7. Promoção vigente, expirada, opt-out e frequência.
8. Lembrete antes do horário; nunca após cancelamento.
9. Falha Meta, Calendar, OpenAI e Media Processor com retry.
10. Duplo webhook idêntico não duplica appointment, mensagem ou campanha.
11. Dois workers concorrentes não claimam o mesmo job.
12. RBAC: Employee não executa ações de Manager/Admin.
13. Tenant isolation.
14. Dead-letter e replay controlado.
15. Recovery após reinício do n8n.
