# ONE-MONTH EXECUTION TARGET

Objetivo: maximizar a quantidade de trabalho concluído em aproximadamente 1 mês, com o proprietário dedicando ~6–7h/dia.

## Princípio

Automatizar ao máximo trabalho de engenharia; reservar tempo humano para:

- decisões de produto;
- credenciais;
- configuração de providers;
- testes de UX;
- validação de negócio;
- E2E;
- aprovação de mudanças perigosas.

## Estratégia sugerida

### Semana 1 — Audit + target architecture + repo hygiene

- ler tudo;
- consolidar schema/contracts;
- resolver 043–057 corretamente;
- montar testes;
- decidir estrutura alvo;
- produzir manual de instalação.

### Semana 2 — Platform + Appointments hardening

- estabilizar runtime;
- WhatsApp;
- AI/tool contracts;
- Appointments;
- Calendar;
- retry/dead-letter;
- Manager/Employee essenciais;
- security/observability.

### Semana 3 — Food vertical anchor

- menu engine;
- cart/order;
- kitchen routing;
- KDS MVP forte;
- print bridge/queue;
- payment hooks;
- delivery basics;
- WhatsApp ordering UX.

### Semana 4 — Integration/E2E/hardening

- full E2E;
- failure injection;
- pilot data;
- UX correction;
- deployment scripts;
- release readiness;
- staged cutover.

Claude pode propor ordem melhor, mas deve justificar.

## Regra de priorização

Não sacrificar integridade transacional para “ter mais features”.

Preferir um vertical realmente bom a cinco verticais superficiais, mantendo arquitetura preparada para expansão.
