# MASTER PROMPT — CLAUDE / ML AUTOMAÇÕES

## 0. Papel que você assume

Você receberá um pacote real de software chamado **ML Automações**. Trate-o como um produto comercial de longo prazo, não como exercício, protótipo descartável, chatbot experimental ou coleção de workflows.

Sua missão é atuar como **principal arquiteto, engenheiro de software, engenheiro de IA, product architect e coordenador técnico**, usando subagentes/revisores especializados quando isso melhorar qualidade. A referência mental é uma equipe excepcional de engenharia, produto, segurança, dados, IA, UX, DevOps/SRE, pagamentos e especialistas verticais trabalhando com tempo suficiente para revisar cada decisão — sem transformar isso em complexidade gratuita.

O objetivo não é “escrever o maior código possível”. O objetivo é produzir a **melhor solução prática, robusta, simples de operar, observável, modular, segura e comercialmente valiosa**.

Quando houver solução melhor do que a visão inicial, proponha-a e justifique. Não preserve decisões ruins apenas porque já existem. Também não reescreva código funcional por preferência estética.

---

# 1. Objetivo de negócio e produto

A ML Automações pretende se tornar uma **plataforma modular de inteligência e automação empresarial**, capaz de conectar:

- clientes;
- funcionários;
- gestores;
- WhatsApp;
- Instagram;
- IA;
- atendimento;
- agenda;
- pedidos;
- catálogo;
- pagamentos;
- CRM;
- marketing;
- estoque;
- delivery;
- PDV;
- cozinha;
- analytics;
- automações;
- integrações externas.

A ambição é que cada módulo vertical seja suficientemente profundo para competir com bons SaaS especializados daquele setor e, ao mesmo tempo, obtenha uma vantagem adicional por estar integrado a uma camada de IA, comunicação e automação comum.

A ML **não deve ser “um SaaS tradicional com um bot grudado na frente”**.

Sempre que tecnicamente possível e adequado, **WhatsApp e Instagram devem ser a interface principal do cliente final**, e em operações simples também podem ser interfaces operacionais de funcionários e proprietários.

Os painéis externos existem para tarefas que realmente se beneficiam de tela dedicada: auditoria, configuração, controle, exceções, operação de cozinha, PDV, agenda visual, analytics, estoque, administração e suporte.

Princípio de UX:

> O cliente manda mensagem e resolve. A complexidade fica atrás da conversa.

---

# 2. Princípio arquitetural central: plataforma comum + domínios especializados

NÃO trate clínicas, restaurantes, barbearias, varejo e outros segmentos como se todos devessem usar o mesmo Core operacional.

A direção conceitual é:

```text
ML PLATFORM
├── Identity / Auth / Tenancy
├── Communication
├── AI Runtime
├── Knowledge
├── Customer / CRM Base
├── Events / Jobs / Outbox
├── Integrations
├── Security
├── Observability
├── Billing
└── Shared platform services

DOMAIN ENGINES
├── ML Appointments
├── ML Food
├── ML Commerce
├── ML Growth
├── ML Payments
├── ML Inventory
├── ML Reputation / CX
└── futuros módulos

APPLICATIONS
├── ML Manager
├── ML Employee
├── ML Admin
├── ML Kitchen / KDS
└── ML PDV
```

Essa taxonomia é hipótese, não dogma. Melhore-a se encontrar desenho superior.

Regra:

> O que é universal pertence à plataforma. O que é regra de negócio de um setor pertence ao respectivo domínio.

Não crie um “Core universal” com entidades artificiais tentando representar appointment, order, cart, kitchen ticket, SKU e payment como se fossem a mesma coisa.

---

# 3. Ordem de confiança das fontes deste pacote

Antes de alterar qualquer coisa, siga esta hierarquia:

1. **schema/introspecção real do banco de STAGING**, quando fornecidos;
2. **estado real do banco e contratos existentes**;
3. migrations canônicas realmente aplicadas;
4. workflow canônico V3 indicado no pacote;
5. código atual do pacote PROD FINAL LUNA;
6. snapshots de runtime;
7. documentação;
8. experimentos, versões modificadas e reconstruções históricas.

Se duas fontes divergem, não “escolha a que parece mais bonita”. Investigue a causa.

Não invente nomes de colunas, constraints, tabelas, endpoints, credentials ou contratos.

---

# 4. Estado atual e regra de segurança

Leia `02_CURRENT_STATE_AND_TRUST_ORDER.md` antes de qualquer modificação.

Regras obrigatórias:

- **não tocar PROD** sem autorização explícita;
- trabalhar primeiro em código local e STAGING;
- preservar o V3 funcional até o novo runtime passar E2E;
- migrations devem ser compatíveis com a base real;
- alterações destrutivas exigem plano de migração, rollback/compensação quando aplicável e validação;
- não confundir “validador estático passou” com “release operacional aprovada”.

---

# 5. Filosofia da IA: interpretar, não inventar fatos

Crie uma fronteira explícita de verdade (**Truth Boundary**).

O LLM pode:

- entender intenção;
- extrair entidades;
- resumir;
- redigir respostas;
- interpretar linguagem informal;
- sugerir opções com base nos dados recebidos;
- usar conhecimento geral quando apropriado;
- planejar uso de ferramentas;
- analisar mídia.

O LLM NÃO deve ser fonte de verdade para:

- preço;
- estoque;
- promoção;
- serviço cadastrado;
- profissional;
- agenda;
- disponibilidade;
- pedido;
- pagamento;
- política interna;
- delivery status;
- dados do cliente;
- permissões;
- status transacional.

Esses fatos precisam vir de APIs/funções/contratos estruturados do sistema.

Princípio:

```text
AI decides what the user probably means.
Core decides whether the action is valid and what is actually true.
```

---

# 6. Conversation Runtime e memória operacional

Não dependa apenas do histórico textual enviado ao modelo.

Projete estado conversacional estruturado, com conceitos equivalentes a:

- active domain;
- current intent;
- collected entities;
- pending action;
- pending offer/cart/order;
- expirations;
- customer-stated preferences;
- inferred preferences com origem/confiança;
- last execution;
- concise conversation summary;
- human handoff state;
- source channel.

A conversa precisa sobreviver a:

- mensagens curtas como “sim”, “a segunda”, “sábado”;
- horas ou dias de pausa;
- troca IA → humano → IA;
- canais diferentes quando houver identidade confiável;
- contexto longo sem reenviar centenas de mensagens ao modelo.

Diferencie memória operacional de memória narrativa.

---

# 7. Communication Layer — WhatsApp/Instagram-first

Crie uma camada de canais independente dos domínios de negócio.

Ela deve normalizar eventos e suportar, conforme APIs reais:

- texto;
- áudio;
- imagem;
- vídeo;
- documento;
- localização;
- replies;
- botões;
- listas;
- interações;
- catálogo/produto;
- templates;
- status de entrega;
- mídia;
- human handoff;
- webhooks duplicados e fora de ordem.

Projete também uma **Channel Experience Layer**: o domínio expressa a intenção de apresentação e a camada de canal escolhe a representação adequada.

Exemplo:

```text
Domain: SHOW_PRODUCT_OPTIONS(items)
WhatsApp -> lista/produtos/imagens conforme capacidade
Instagram -> experiência compatível com Direct
Web -> cards
```

Não acople regra de negócio à forma atual de renderização do WhatsApp.

Não use links externos como muleta. Use navegador somente quando necessário ou claramente superior.

---

# 8. Human Handoff

O handoff deve ser de primeira classe.

Quando um funcionário assume, entregue:

- resumo do problema;
- intenção atual;
- dados já coletados;
- ações já tentadas;
- objetos envolvidos;
- sugestões de próxima ação;
- motivo do handoff;
- risco/prioridade quando aplicável.

O cliente não deve precisar repetir tudo.

Handoff pode acontecer por:

- solicitação explícita;
- baixa confiança;
- reclamação;
- negociação especial;
- erro operacional;
- política da empresa;
- assunto sensível;
- aprovação humana necessária.

---

# 9. Knowledge

A base de conhecimento por empresa pode aceitar:

- PDF;
- DOCX;
- planilhas;
- sites;
- catálogos;
- cardápios;
- APIs;
- documentos internos;
- cadastro manual.

Projete:

- source provenance;
- versionamento;
- atualização;
- validade;
- desativação;
- segurança contra prompt injection;
- distinção entre fatos da empresa e conhecimento geral;
- retrieval observável;
- mecanismo para apontar de onde veio uma resposta interna.

---

# 10. Event-driven sem overengineering

Módulos devem publicar eventos de domínio quando isso reduzir acoplamento.

Exemplos:

- AppointmentConfirmed;
- AppointmentCancelled;
- OrderConfirmed;
- OrderPaid;
- ProductOutOfStock;
- CustomerOptedOut;
- ReviewReceived.

Um evento pode gerar jobs para Calendar, reminders, analytics, CRM, campanhas, impressão etc.

Não adicione Kafka/RabbitMQ apenas por sofisticação. Postgres + outbox + workers pode ser superior na escala atual.

---

# 11. Confiabilidade obrigatória

Para operações críticas, desenhe e teste:

- idempotency;
- transactions;
- row locks;
- concurrency;
- unique constraints adequadas;
- outbox;
- durable jobs;
- leases;
- retries;
- backoff;
- dead-letter;
- reconciliation;
- observability;
- duplicate webhook protection;
- out-of-order event handling;
- provider timeout ambiguity;
- compensação quando necessária;
- graceful degradation.

Se Meta, Calendar, payment provider ou print bridge cair, a ação não pode simplesmente desaparecer.

---

# 12. ML Appointments

Trate Appointments como produto vertical profundo, não como feature rasa.

Investigue e implemente quando apropriado:

- businesses/units;
- professionals;
- services;
- professional-service capabilities;
- prices/overrides;
- duration/overrides;
- buffers;
- business hours;
- professional hours;
- exceptions;
- holidays;
- blocks;
- rooms/resources/equipment quando o segmento exigir;
- availability engine;
- HOLD;
- slot offers;
- confirmation;
- cancellation;
- rebooking;
- active rescheduling;
- recurring appointments;
- packages/memberships quando justificável;
- deposits;
- reminders;
- no-show;
- check-in;
- completion;
- Calendar sync;
- waitlist;
- occupancy optimization.

Concorrência deve impedir dupla marcação mesmo com múltiplas requisições simultâneas.

### Waitlist inteligente

Não faça broadcast cego.

Considere:

- compatibilidade exata;
- tempo na fila;
- política FIFO/priority/VIP/membership/custom;
- oferta progressiva em lotes;
- expiração;
- reserva temporária se necessário;
- fairness configurável;
- auditoria da razão de prioridade.

### Occupancy Optimizer

Detecte buracos de agenda e identifique clientes compatíveis por serviço, profissional, preferência temporal, ciclo de retorno e consentimento. Prepare ações, não apenas gráficos.

---

# 13. ML Food — requisito de profundidade máxima

Leia também a especificação detalhada em `01_PRODUCT_VISION_AND_DOMAIN_REQUIREMENTS.md`.

O ML Food deve ser desenhado como um sistema operacional de restaurante integrado, não como um bot de pedidos.

Jornada desejada:

```text
Discovery -> Menu -> Customization -> Cart -> Order -> Payment
-> Kitchen -> Production -> Pickup/Delivery -> CRM/Reorder
```

### 13.1 Cardápio visual dentro do WhatsApp/Instagram

Objetivo: experiência clara, progressiva e visual.

Não envie cardápio gigante em texto e não mande usuário para site por padrão.

Suporte conceitual a:

- categorias;
- imagens reais;
- descrições curtas;
- preço;
- disponibilidade;
- badges/destaques;
- combos;
- listas/produtos/botões onde APIs permitirem;
- busca conversacional;
- “repetir último pedido”.

O cliente deve poder dizer:

- “quero algo até R$ 30”;
- “tem sem lactose?”;
- “qual combo dá para duas pessoas?”;
- “quero o de ontem”;
- mandar foto e perguntar “tem esse?”.

### 13.2 Menu model realmente estruturado

Modele corretamente:

- product;
- category;
- size;
- flavor;
- modifier group;
- modifier;
- required/optional;
- min/max selections;
- price delta;
- substitutions;
- incompatibilities;
- availability;
- combo components;
- time-based availability.

Não transforme modificadores complexos apenas em observação textual.

### 13.3 Minimum necessary clarification

A IA deve perguntar apenas o que falta para construir um pedido válido.

### 13.4 Carrinho conversacional persistente

Suportar comandos naturais:

- “coloca coca”;
- “tira a batata”;
- “troca um dos dois para sem cebola”;
- “quanto deu?”;
- “manda no mesmo endereço”.

### 13.5 Upsell inteligente e não irritante

Upsell deve considerar contexto, margem, estoque, histórico e frequência. Respeitar recusa e saber não oferecer nada.

### 13.6 Pedido -> Kitchen Routing

Após confirmação, roteie itens para estações:

- chapa;
- fritadeira;
- bebidas;
- montagem;
- confeitaria;
- outras.

### 13.7 ML Kitchen / KDS

Tela operacional de baixa fricção:

- NEW;
- PREPARING;
- READY;
- delayed;
- timers;
- station filtering;
- bump/recall;
- priority;
- audit.

Suportar KDS-only, printer-only e híbrido.

### 13.8 Impressora térmica como infraestrutura de primeira classe

Projete ML Print / Local Agent ou alternativa melhor.

Cenário esperado:

```text
Cloud -> durable Print Job -> Local Bridge -> USB/LAN/Wi-Fi printer -> status/audit
```

Considere:

- ESC/POS;
- impressora de cozinha;
- balcão;
- recibo;
- etiqueta;
- múltiplas impressoras;
- roteamento por estação;
- retry;
- idempotência;
- reprint audit;
- failover configurável;
- offline/local resilience quando viável.

Nunca assuma que “HTTP request enviado” significa “papel impresso”. Modele os limites reais de confirmação de impressão.

### 13.9 Operação por WhatsApp do funcionário/dono

Permitir comandos autorizados como:

- “pausa X-Bacon”;
- “reativa em 30 min”;
- “como estão os pedidos?”;
- “fecha delivery hoje”;
- “reimprime pedido 182”.

Ações críticas exigem RBAC e confirmação.

### 13.10 Tempo de preparo dinâmico

Estimar por:

- fila;
- itens;
- estações;
- histórico;
- horário;
- capacidade;
- entregadores.

Atualizar promessa de prazo quando necessário.

### 13.11 Delivery

Considerar:

- endereço;
- geolocalização compartilhada;
- área de entrega;
- taxa;
- delivery zone;
- ETA;
- courier;
- pickup;
- status;
- integração com parceiros quando fizer sentido.

### 13.12 Omnichannel orders

WhatsApp, Instagram, PDV, mesa/QR e outros canais devem convergir para um Order Engine consistente, mantendo source attribution.

### 13.13 Mesas e comandas

Para operação presencial:

- tables;
- tabs;
- waiter;
- QR;
- add-to-tab;
- close bill;
- split payment quando pertinente.

### 13.14 Ficha técnica e custo

Separar SKU simples de ingrediente/recipe inventory.

Permitir cálculo de custo, margem, consumo e desperdício quando o nível de operação justificar.

### 13.15 Menu engineering

Transformar dados em ações, por exemplo:

- item popular com margem ruim;
- item muito visto e pouco comprado;
- combo com melhor attach rate;
- ingredientes que geram ruptura;
- sugestão de preço/teste, sempre como apoio ao gestor.

---

# 14. ML Commerce

Produto vertical para varejo.

Considere:

- catalog;
- categories;
- SKU;
- variants;
- attributes;
- inventory;
- prices;
- promotions;
- cart;
- checkout;
- payment;
- pickup;
- shipping/delivery;
- returns/refunds;
- suppliers quando necessário;
- customer history;
- recommendation;
- visual product matching;
- conversational selling.

A IA deve ser vendedor consultivo com verdade factual em tempo real.

---

# 15. ML Growth / CRM

Não reduza CRM a lista de contatos.

Diferencie:

- fatos declarados;
- fatos observados;
- inferências;
- scores/modelos;
- consentimentos.

Considere:

- campaigns;
- segmentation;
- opt-in/out;
- frequency caps;
- templates;
- reactivation;
- experimentation;
- attribution;
- revenue attribution;
- churn risk;
- recurrence patterns;
- next expected purchase/visit;
- journeys.

Marketing deve respeitar políticas do canal, consentimento e fadiga.

---

# 16. Opportunity Engine e Next Best Action

Explore como capacidade transversal futura.

Opportunity Engine detecta situações úteis:

- slot ocioso + clientes compatíveis;
- produto próximo de recompra;
- cliente com queda de frequência;
- campanha com leitura alta e conversão baixa;
- estoque em risco;
- pedido atrasado;
- capacidade ociosa.

Next Best Action recomenda a melhor reação:

- não agir;
- enviar mensagem;
- preparar campanha;
- oferecer horário;
- criar tarefa;
- acionar humano;
- esperar;
- ajustar operação.

Não permita ações invasivas sem consentimento ou política adequada.

---

# 17. Payments

Projete camada transversal com adapters quando isso realmente reduzir acoplamento.

Capacidades possíveis:

- PIX;
- payment links;
- cards;
- deposits;
- refunds;
- installments;
- subscriptions;
- receivables;
- collections;
- reconciliation;
- webhook idempotency.

Nunca trate timeout de pagamento como “falhou” sem reconciliar estado ambíguo.

---

# 18. Inventory

Evite um modelo único simplista.

Commerce: SKU/unit inventory.

Food: ingredientes, receitas, unidades de medida, yield, waste, substitutions.

Compartilhe infraestrutura apenas onde conceitos realmente coincidem.

---

# 19. ML Manager / Employee / Admin

## Manager

Não construir dashboard decorativo. Priorizar insights acionáveis e transição insight -> ação.

## Employee

Interface mínima por função. Mostrar apenas o necessário para executar trabalho.

## Admin

Operação interna da ML:

- tenants;
- modules;
- plans;
- billing;
- support;
- incidents;
- feature flags;
- integrations;
- health;
- usage;
- onboarding;
- audit.

---

# 20. Onboarding Agent

Onboarding deve reduzir drasticamente time-to-value.

Capacidades desejadas:

- identificar segmento;
- ativar módulos adequados;
- importar PDF/foto/planilha/cardápio/catálogo;
- cadastrar serviços/produtos/profissionais;
- importar horários;
- configurar personalidade;
- conectar WhatsApp/Instagram/Calendar/payment;
- validar dados;
- executar smoke tests;
- mostrar checklist de prontidão.

Sempre exigir revisão humana antes de publicar dados extraídos com incerteza material.

---

# 21. Automation Builder orientado ao domínio

Não crie clone do n8n para o cliente final sem necessidade.

Prefira regras de negócio de alto nível, inclusive via linguagem natural:

- “quando alguém cancelar com menos de 2h, tente preencher pela waitlist”;
- “se estoque < 10, avise gerente”;
- “se pedido > 20min, marque risco de atraso”.

IA pode transformar texto em regra estruturada, mas usuário deve revisar antes de ativar.

---

# 22. Security

Trate como produto multi-tenant sério.

Obrigatório avaliar:

- tenant isolation;
- RLS quando apropriado;
- RBAC;
- action-level permission;
- entity-level permission;
- least privilege;
- secret isolation;
- service-role exposure;
- audit;
- PII;
- LGPD;
- retention;
- encryption;
- rate limiting;
- abuse;
- prompt injection;
- untrusted document ingestion;
- SSRF/path traversal/file handling;
- webhook signature verification;
- payment verification;
- local agent security.

Conteúdo de usuário/documento nunca deve poder sobrescrever políticas de sistema ou executar ações privilegiadas por prompt injection.

---

# 23. Observability e explainability operacional

Precisamos responder:

- o que aconteceu?
- por que aconteceu?
- quem/qual worker executou?
- quais dados foram usados?
- qual tentativa falhou?
- qual retry ocorreu?
- por que cliente recebeu campanha?
- por que horário foi oferecido?
- por que pedido foi roteado à estação X?

Projete logs estruturados, correlation IDs, audit trail, metrics, incidents e health.

---

# 24. AI Evaluation

Não trocar prompt/modelo às cegas.

Avaliar:

- intent accuracy;
- entity extraction;
- action selection;
- hallucination rate;
- factual grounding;
- tool success;
- clarification rate;
- handoff rate;
- resolution rate;
- turns to resolution;
- latency;
- cost per resolved conversation;
- regression suites;
- adversarial cases.

Comparar baseline vs candidate antes de promover mudança importante.

---

# 25. Simulation / Dry Run

Antes de grandes ações, prever impacto.

Exemplo campanha:

- matched audience;
- consented;
- suppressed;
- frequency capped;
- estimated eligible;
- estimated provider cost quando possível;
- preview;
- schedule.

Aplicar princípio semelhante a importações, mudanças em massa e automações.

---

# 26. Benchmarking e inovação

Se houver acesso à internet, faça benchmarking atual e cite documentação oficial/concorrentes quando relevante.

Para cada vertical, classifique features em:

- **PARITY** — necessário para não ficar atrás;
- **SUPERIOR** — precisa fazer melhor;
- **DIFFERENTIATOR** — vantagem específica da ML;
- **MOAT** — valor que cresce com histórico, dados, integrações e aprendizado operacional.

Não copie features cegamente. Investigue reclamações, atritos e oportunidades criadas pela IA moderna.

---

# 27. Escopo de implementação e objetivo de 1 mês

O proprietário pretende trabalhar aproximadamente 6–7h/dia durante cerca de 1 mês e quer maximizar automação do desenvolvimento.

Seu papel é reduzir o trabalho manual dele ao mínimo justificável.

Entregue scripts, automações, documentação e arquivos prontos. Sempre que algo exigir ação humana, registre em `MANUAL_ACTIONS_FOR_ISMAEL.md` com:

- ação exata;
- por que é necessária;
- comando/UI;
- valor esperado;
- como validar;
- como reverter se aplicável.

Não esconda complexidade real dizendo que algo está pronto quando ainda exige configuração/validação externa.

### Estratégia sugerida

Produzir visão completa de longo prazo, mas priorizar uma release comercial forte.

P0/P1 devem consolidar:

- plataforma comum;
- WhatsApp;
- AI runtime;
- knowledge;
- appointments;
- growth essencial;
- manager/employee/admin mínimos úteis;
- observability/security;
- Food como segundo vertical âncora com implementação funcional robusta, se viável dentro do ciclo.

Commerce/Payments/Inventory podem evoluir conforme dependências e capacidade, mas a arquitetura deve deixar caminho limpo.

Você pode propor outra prioridade se justificar por dependências/ROI.

---

# 28. Processo obrigatório de trabalho

## Fase A — AUDIT ONLY

Primeiro, não modifique arquivos.

1. Leia `00_START_HERE/*`.
2. Inventarie o repositório.
3. Reconstrua arquitetura real.
4. Mapeie schema/contratos/dependências.
5. Diferencie canônico, experimental, histórico e reconstruído.
6. Compare visão desejada com implementação atual.
7. Produza diagnóstico.

Classifique componentes:

- PRESERVAR;
- MELHORAR;
- REFATORAR;
- SUBSTITUIR;
- REMOVER;
- ADIAR.

## Fase B — TARGET DESIGN

Produza:

- arquitetura-alvo;
- domain boundaries;
- event model;
- data contracts;
- permission model;
- integration model;
- AI/tool contracts;
- migration strategy;
- rollout strategy;
- P0–P4 roadmap.

## Fase C — IMPLEMENTATION

Somente depois do plano:

- faça alterações incrementais;
- use Git commits pequenos e descritivos;
- prefira branches/worktrees por área;
- execute testes após cada bloco;
- mantenha changelog.

## Fase D — ADVERSARIAL REVIEW

Um agente/revisor separado deve tentar quebrar:

- migrations;
- tenant isolation;
- permissions;
- concurrency;
- idempotency;
- payments;
- webhooks;
- retries;
- printing;
- AI actions;
- Food order parsing;
- Calendar;
- imports.

## Fase E — STAGING

Somente após validação local/estática:

- preflight;
- migrations em STAGING;
- SQL tests;
- workflow imports inativos;
- provider credentials;
- E2E;
- failure/recovery scenarios.

PROD somente depois.

---

# 29. Regra para migrations

Nunca assuma que uma migration “vai funcionar” porque compila.

Antes de cada migration significativa:

1. consultar contrato real;
2. checar colunas/constraints/functions dependentes;
3. detectar objetos preexistentes;
4. testar em transação com fail-fast;
5. validar objetos resultantes;
6. executar testes de runtime;
7. registrar compatibilidade.

Quando uma migration antiga já está aplicada, não reescreva história de forma perigosa. Crie migration corretiva ou estratégia explícita.

---

# 30. Regra para código “pronto”

Não use TODO/placeholders/mocks permanentes em funcionalidade marcada como concluída.

Se algo não puder ser finalizado por falta de credencial/API/decisão, marque explicitamente:

- BLOCKED_EXTERNAL;
- REQUIRES_CONFIGURATION;
- DEFERRED;
- NOT_IMPLEMENTED.

Nunca simule conclusão.

---

# 31. Testes mínimos por feature crítica

Considere pelo menos:

- happy path;
- invalid input;
- duplicate request;
- concurrency;
- race condition;
- stale state;
- provider timeout;
- provider 4xx/5xx;
- ambiguous external outcome;
- retry;
- dead-letter;
- worker crash;
- expired lease;
- out-of-order webhook;
- duplicate webhook;
- unauthorized actor;
- cross-tenant attack;
- malformed media;
- prompt injection;
- rollback/partial failure.

---

# 32. Performance e custos

Para IA, sempre avaliar:

- modelo necessário;
- tokens;
- cache;
- summarization;
- deterministic alternative;
- batching;
- latency;
- quality tradeoff;
- cost per operation.

Não usar LLM para operação que constraint SQL ou regra simples resolve melhor.

---

# 33. Equipe de agentes sugerida

Se a ferramenta suportar subagentes, considere:

- Principal Architect;
- Database/Postgres Engineer;
- AI/LLM Engineer;
- Meta/Channels Engineer;
- Appointments Domain Engineer;
- Food Domain Engineer;
- Commerce Domain Engineer;
- CRM/Growth Engineer;
- Payments Engineer;
- Frontend/UX Engineer;
- Security Engineer;
- SRE/DevOps;
- QA/Adversarial Reviewer.

Não precisa criar todos se não agregar. A função é separar responsabilidades e promover revisão cruzada.

---

# 34. Entregáveis obrigatórios

Leia `03_EXPECTED_DELIVERABLES_AND_DEFINITION_OF_DONE.md`.

No mínimo, ao fim do ciclo, quero:

1. diagnóstico do estado atual;
2. arquitetura-alvo;
3. mapa de módulos e contratos;
4. roadmap P0–P4;
5. repositório reorganizado ou plano de reorganização;
6. migrations compatíveis;
7. workflows/serviços necessários;
8. testes;
9. scripts de instalação/validação;
10. documentação;
11. `MANUAL_ACTIONS_FOR_ISMAEL.md`;
12. `KNOWN_LIMITATIONS.md`;
13. `RELEASE_READINESS.md`;
14. matriz E2E;
15. plano de rollback/cutover.

---

# 35. O que NÃO fazer

- Não tocar PROD automaticamente.
- Não apagar V3 antes do cutover.
- Não unificar domínios diferentes por “elegância”.
- Não criar microserviços porque “parece enterprise”.
- Não criar Kafka/Kubernetes/event sourcing sem necessidade demonstrável.
- Não usar LLM como banco de dados.
- Não colocar segredo em frontend.
- Não criar interface enorme para o cliente final quando WhatsApp/Instagram resolvem melhor.
- Não esconder falhas com try/catch que engole erro.
- Não afirmar produção-ready sem E2E real.
- Não reescrever partes estáveis sem benefício mensurável.
- Não priorizar quantidade de features acima de coerência e confiabilidade.

---

# 36. Pergunta permanente de qualidade

Para cada decisão importante, pergunte:

- Esta é a melhor solução prática?
- O domínio está correto?
- O dado tem fonte de verdade clara?
- A ação é idempotente?
- A falha é recuperável?
- A operação é auditável?
- O tenant está isolado?
- O funcionário entende o estado?
- O cliente tem atrito desnecessário?
- Existe alternativa mais simples?
- Isso gera valor comercial mensurável?
- Como vamos testar?

---

# 37. Primeira resposta esperada de você

NÃO comece alterando código.

Depois de ler o pacote inteiro, responda primeiro com:

## A. Diagnóstico do estado atual

## B. Mapa do que é canônico, histórico, experimental e incompleto

## C. Arquitetura atual reconstruída

## D. Principais riscos e incompatibilidades

## E. Arquitetura-alvo recomendada

## F. Módulos e responsabilidades

## G. Roadmap P0–P4

## H. Plano de execução para maximizar conclusão em ~1 mês

## I. Lista de informações/arquivos realmente ausentes

## J. Estratégia de implementação incremental e validação

Somente após essa resposta e aprovação, iniciar alterações.

---

# 38. Mandato competitivo por produto: cada “ML” deve ser um produto vertical sério

Não trate os módulos da ML como features auxiliares de um chatbot.

Para cada domínio, a meta é combinar:

```text
profundidade operacional de um excelente SaaS vertical
+
experiência conversacional nativa
+
integração entre módulos
+
IA realmente útil
+
automação confiável
+
controle/auditoria para empresa
+
simplicidade extrema para cliente e funcionário
```

Faça benchmarking real e atualizado dos melhores produtos relevantes quando pesquisa externa estiver disponível.

Para cada domínio, produza uma matriz:

- **PARITY** — capacidades que precisamos para não ficar abaixo do mercado;
- **SUPERIOR** — pontos em que devemos deliberadamente fazer melhor;
- **DIFFERENTIATOR** — capacidades raras que a ML pode criar pela combinação IA + dados + ações;
- **MOAT** — valor que aumenta com histórico, integrações, configuração, automação e aprendizado operacional;
- **DO NOT BUILD** — funcionalidades populares que não justificam custo/complexidade para nossa estratégia.

A meta não é copiar concorrentes, mas compreender o benchmark mínimo e procurar saltos de UX e operação possíveis na era de IA.

---

# 39. WhatsApp/Instagram são superfícies principais, não simples gateways

A ML deve inverter o padrão de muitos SaaS.

Não queremos:

```text
mensagem -> bot -> link -> site -> login -> formulário -> operação
```

Queremos, quando as APIs reais permitirem:

```text
mensagem -> entendimento -> dados reais -> ação -> confirmação
```

O cliente final deve conseguir resolver dentro de WhatsApp/Instagram o máximo sensato de:

- descoberta;
- consulta;
- comparação;
- navegação de catálogo/cardápio;
- personalização;
- agendamento;
- remarcação;
- cancelamento;
- pedido;
- carrinho;
- checkout;
- pagamento quando o canal/provider permitir a experiência adequada;
- acompanhamento;
- suporte;
- recompra;
- avaliação.

Quando uma etapa externa for tecnicamente necessária, use o menor desvio possível e preserve o estado da conversa para retorno imediato.

Os sistemas dedicados da ML existem principalmente para:

- operação interna;
- configuração;
- auditoria;
- exceções;
- tarefas que exigem visão espacial/densa;
- cozinha;
- PDV;
- estoque;
- analytics;
- suporte;
- administração.

Não force funcionário/dono a abrir dashboard para uma ação simples que pode ser feita de modo seguro pelo próprio WhatsApp.

Exemplos autorizados e permissionados:

- “pausa o X-Bacon”;
- “libera calabresa às 20h”;
- “bloqueia minha agenda amanhã de 14h às 15h”;
- “quantos pedidos estão atrasados?”;
- “reimprime o pedido 181”;
- “fecha delivery por hoje”.

Ações críticas exigem autorização, confirmação e auditoria conforme risco.

---

# 40. ML Food — padrão de excelência esperado

O ML Food deve ser tratado como produto vertical completo, e não como chatbot de pedidos.

## 40.1 Jornada integrada

Projete a cadeia completa:

```text
Descoberta
-> cardápio visual
-> busca/recomendação
-> personalização
-> carrinho
-> checkout
-> pagamento
-> confirmação
-> roteamento para produção
-> KDS/impressão
-> preparo
-> expedição
-> retirada/entrega
-> acompanhamento
-> fechamento
-> CRM/recompra
-> analytics/menu engineering
```

## 40.2 Cardápio visual dentro do canal

Evite cardápios gigantes em texto e evite link externo por padrão.

Use progressão visual e contexto:

```text
Categorias
-> produtos
-> imagens reais
-> nome
-> descrição curta
-> preço
-> disponibilidade
-> opções/modificadores
-> adicionar/personalizar
```

Explorar capacidades reais de catálogo/produto/lista/botões/mídia do WhatsApp e experiências compatíveis no Instagram.

A apresentação deve se adaptar a:

- tamanho do menu;
- hora do dia;
- disponibilidade;
- histórico do cliente;
- origem da campanha/post;
- capacidade real do canal;
- objetivo atual da conversa.

Exemplos naturais:

- “quero algo até 35 reais”;
- “me mostra os combos”;
- “tem pizza de frango sem catupiry?”;
- “quero repetir meu último pedido”;
- “algo pra quatro pessoas”;
- “qual desses tem menos adicionais obrigatórios?”

A resposta deve ser grounded no menu real.

## 40.3 Menu model robusto

Considere, conforme negócio:

- menus por horário/canal/unidade;
- categorias;
- products;
- variants;
- size;
- flavor;
- half-and-half;
- modifier groups;
- modifiers;
- required/optional choices;
- min/max selections;
- quantity limits;
- extra price;
- substitutions;
- incompatibilities;
- combos;
- promotional bundles;
- availability windows;
- channel availability;
- images/media;
- allergens/dietary flags quando confiavelmente cadastrados;
- recipe/ingredient relation quando Inventory estiver ativo.

Não transforme modificadores estruturáveis em texto livre por conveniência.

## 40.4 Parsing de pedidos complexos

Exemplo:

> “dois X-Bacon: um sem cebola e com bacon extra; no outro troca cheddar por mussarela. Uma coca 2L sem gelo.”

O resultado deve virar Order/OrderItems/Modifiers estruturados e validados.

A IA interpreta; o Food Engine valida se combinações e preços são permitidos.

Se houver ambiguidade, aplique **minimum necessary clarification**: pergunte somente o que impede a execução segura.

## 40.5 Carrinho conversacional persistente

Entender mensagens incrementais:

- “coloca uma coca”;
- “tira a batata”;
- “troca a segunda pizza para grande”;
- “quanto deu?”;
- “manda no endereço de sempre”.

Carrinho deve ter versionamento/concorrência e não depender do texto acumulado do LLM.

## 40.6 Upsell inteligente e não irritante

Sugestões devem considerar:

- contexto;
- item atual;
- margem;
- estoque;
- oferta real;
- histórico;
- frequência de rejeição;
- limites de contato;
- probabilidade de benefício.

O sistema deve saber **não oferecer nada**.

## 40.7 Kitchen Routing Engine

Após confirmação, os itens devem ser roteáveis por estação:

```text
CHAPA
FRITADEIRA
PIZZA
BAR
BALCÃO
EXPEDIÇÃO
```

Um pedido pode gerar tickets para múltiplas estações e uma visão de expo/agregação.

Projete dependências entre itens e conclusão do pedido total.

## 40.8 ML Kitchen / KDS

Considere:

- novos / preparando / prontos;
- timer/idade do ticket;
- station view;
- expo view;
- bump;
- recall;
- prioridade;
- modifiers legíveis;
- notas importantes;
- atraso/SLA;
- reabertura controlada;
- cancelamento/alteração depois do envio;
- auditoria de quem alterou estado;
- reconexão/offline;
- sincronização em tempo real;
- display simplificado para toque;
- som/alerta configurável;
- acessibilidade e legibilidade a distância.

## 40.9 Impressão térmica como subsistema sério

Projete uma infraestrutura de impressão, não `HTTP -> print()` improvisado.

Possível fluxo:

```text
OrderConfirmed
-> PrintJob durável
-> cloud queue
-> ML Local Agent / Print Bridge
-> USB/LAN/Wi-Fi/ESC-POS
-> printer
```

Avalie alternativas melhores quando existirem.

Suportar conforme necessidade:

- múltiplas impressoras;
- roteamento por estação;
- cozinha;
- balcão;
- recibo;
- comanda;
- etiquetas;
- templates;
- encoding/accent handling;
- largura 58/80mm;
- corte/gaveta quando aplicável;
- health status;
- retry;
- reprint;
- failover configurável;
- idempotência;
- auditoria.

Não afirme certeza física de impressão se o protocolo não fornecer ACK real. Diferencie estados como:

- QUEUED;
- DELIVERED_TO_AGENT;
- WRITTEN_TO_DEVICE/SOCKET;
- ACKNOWLEDGED (quando suportado);
- ASSUMED_PRINTED;
- FAILED;
- REPRINT_REQUESTED.

Se impressora cair, job não desaparece.

Evite duplicar ticket silenciosamente após outcome ambíguo.

## 40.10 Cozinha híbrida

Suportar evolutivamente:

- printer only;
- KDS only;
- KDS + printer;
- múltiplas stations;
- múltiplas unidades.

Restaurante pequeno não deve precisar de infraestrutura enterprise para operar.

## 40.11 Dynamic ETA e capacidade

Não use ETA fixo quando puder modelar melhor.

Considere:

- fila atual;
- quantidade/tipo de itens;
- station load;
- tempos históricos;
- dia/horário;
- capacidade;
- courier availability;
- pedidos prioritários;
- backlog.

O sistema deve atualizar promessas para novos pedidos quando cozinha congestiona.

## 40.12 Operational Intelligence

Exemplo de insight útil:

> “O tempo médio subiu de 18 para 31 min nos últimos 40 min; 71% do backlog depende da chapa.”

Ações possíveis:

- atualizar ETA;
- pausar item/canal;
- reduzir raio de delivery;
- chamar reforço;
- visualizar estação gargalo.

Não apenas mostrar gráfico.

## 40.13 Delivery

Projetar:

- endereços;
- geolocation;
- address normalization;
- delivery zones;
- taxa;
- mínimo;
- ETA;
- courier assignment;
- status;
- tracking quando disponível;
- integrações externas;
- retirada;
- delivery próprio;
- proof/status de entrega conforme operação.

Cliente pode enviar localização pelo WhatsApp quando suportado.

## 40.14 Mesas, comandas e atendimento presencial

Quando aplicável:

- table;
- tab/comanda;
- waiter;
- QR association;
- add items;
- transfer table;
- split bill;
- close;
- audit.

Pedido presencial, WhatsApp, Instagram, QR e PDV devem convergir para um Order Engine consistente, preservando `source`.

## 40.15 Inventory/recipe integration

Food inventory pode ser ingrediente/ficha técnica, diferente de SKU de varejo.

Exemplo:

```text
1 X-Bacon
-> 1 pão
-> 1 carne
-> 2 queijo
-> 30 g bacon
-> 20 g molho
```

Considere unidades, conversões, rendimento, perdas, substituição e propagation de disponibilidade.

Se bacon acabar, o sistema deve descobrir quais itens/modificadores são afetados.

## 40.16 Menu engineering

Gerar inteligência sobre:

- contribution margin;
- popularity;
- attach rate;
- views -> cart;
- cart -> order;
- abandonment;
- out-of-stock loss;
- modifier performance;
- horário/dia;
- campanha/origem;
- preço/testes.

Transformar análise em ação simulável.

---

# 41. O mesmo rigor deve ser aplicado a TODOS os domínios

Para cada domínio, responda simultaneamente a quatro perspectivas:

## Cliente
Como resolver com menos passos, menos tela, menos dúvida e mais confiança?

## Funcionário
Que digitação, cópia, conferência e tarefa repetitiva pode desaparecer?

## Gestor
Que controle, inteligência, auditoria e ação faltam hoje?

## Plataforma
Como fazer isso de modo estruturado, seguro, recuperável e escalável?

Não aceite que:

- ML Appointments seja apenas “agenda pelo WhatsApp”;
- ML Commerce seja apenas “catálogo pelo WhatsApp”;
- ML Food seja apenas “pedido pelo WhatsApp”;
- ML Growth seja apenas “disparo de mensagem”;
- ML Manager seja apenas dashboard;
- ML AI seja apenas chat.

Cada um deve possuir profundidade operacional própria.

---

# 42. Modo de execução: maximizar entrega e minimizar trabalho manual do usuário

O objetivo operacional deste handoff é concluir o máximo possível em aproximadamente **1 mês de trabalho intensivo do usuário (~6–7h/dia)**.

Portanto:

- automatize boilerplate;
- gere scripts reproduzíveis;
- gere migrations completas;
- gere testes;
- gere imports/workflows;
- gere configurações exemplo;
- gere documentação;
- gere verificadores;
- faça validações locais sempre que possível;
- use subagentes paralelos quando seguro;
- não interrompa o usuário para decisões triviais que podem ser tomadas por engenharia razoável e documentadas.

Pergunte somente quando uma decisão for realmente bloqueante, irreversível ou de produto substancial.

Para decisões não bloqueantes:

1. escolha a opção tecnicamente melhor;
2. documente a decisão;
3. deixe configuração quando houver tradeoff legítimo.

A meta é que o usuário passe a maior parte do tempo em:

- fornecer credentials localmente;
- conectar serviços externos;
- executar comandos;
- validar UX;
- testar cenários reais;
- tomar decisões de negócio;
- aprovar mudanças importantes.

E NÃO em copiar SQL manualmente ou escrever boilerplate repetitivo.

---

# 43. Contrato de ações manuais

Mantenha continuamente um arquivo `MANUAL_ACTIONS_FOR_ISMAEL.md`.

Cada ação deve conter:

```text
ID
Objetivo
Ambiente (LOCAL/STAGING/PROD)
Pré-requisitos
Comando ou caminho exato
O que o usuário precisa preencher
Resultado esperado
Como validar
Como desfazer/recuperar se falhar
Risco
Status
```

Nunca peça ao usuário para enviar secret/token/senha no chat.

Marque claramente tarefas que apenas ele pode fazer por dependerem de painel/conta/consentimento externo.

---

# 44. Entrega concentrada, execução incremental

O usuário quer receber o máximo do projeto pronto de uma vez.

Interprete isso como:

> produzir uma entrega ampla e integrada de código, scripts, testes e documentação.

NÃO interprete como:

> aplicar uma mudança monolítica e cega em produção.

Pode haver uma grande entrega de artefatos, porém a instalação deve possuir gates:

```text
static validation
-> local tests
-> database preflight
-> STAGING migration
-> contract verification
-> integration tests
-> E2E providers
-> failure/recovery tests
-> release readiness
-> PROD cutover
```

---

# 45. Formato final de entrega esperado

Ao final da implementação principal, entregue um repositório/pacote que um operador consiga seguir, contendo no mínimo:

- código-fonte final;
- migrations versionadas;
- schema/contracts;
- n8n/workers/serviços;
- apps necessárias;
- `.env.example` sem secrets;
- scripts de bootstrap;
- scripts de preflight;
- scripts de migrations;
- scripts de smoke/E2E quando tecnicamente possível;
- seeds de STAGING seguros;
- health checks;
- observability setup;
- dashboards/alerts definidos;
- docs de arquitetura;
- docs por domínio;
- docs de integrações;
- threat model;
- test matrix;
- `MANUAL_ACTIONS_FOR_ISMAEL.md`;
- `KNOWN_LIMITATIONS.md`;
- `RELEASE_READINESS.md`;
- `CHANGELOG.md`;
- `DECISIONS.md`/ADRs para escolhas relevantes;
- rollout/cutover/rollback plan.

O resultado deve ser operacionalmente navegável por outra pessoa sem depender de memória de chat.
