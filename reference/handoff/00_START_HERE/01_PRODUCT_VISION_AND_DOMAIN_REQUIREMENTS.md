# ML AUTOMAÇÕES — PRODUCT VISION & DOMAIN REQUIREMENTS

Este documento complementa o prompt mestre. Ele descreve a ambição de produto, não obriga uma implementação específica.

## 1. Tese de produto

A ML deve reduzir a distância entre **“o cliente pediu alguma coisa”** e **“a operação empresarial realmente aconteceu”**.

Em vez de um chatbot que responde e manda links, a plataforma deve converter conversas em ações estruturadas, seguras, auditáveis e integradas.

### Cliente

- usa WhatsApp/Instagram sempre que possível;
- navega por opções visualmente;
- não precisa aprender comandos;
- não repete dados já fornecidos;
- consegue comprar, pedir, agendar, acompanhar, remarcar e pedir suporte.

### Funcionário

- recebe tarefas já estruturadas;
- não copia pedido do WhatsApp para outro sistema;
- consegue operar por painel especializado ou, quando simples, por mensagens administrativas;
- vê contexto completo quando assume conversa.

### Gestor

- audita tudo;
- controla exceções;
- vê insights acionáveis;
- configura políticas;
- mede resultado;
- transforma insight em ação.

---

## 2. Fundamentos compartilhados

### Identity / Tenancy

Suportar empresa, organização, unidade, usuários, membros e papéis. Preparar multi-unit com herança + override.

### CRM base

Customer 360 deve distinguir:

- explicit fact;
- observed fact;
- inferred preference;
- score;
- consent.

### Communication

Canal é interface, não Core de negócio.

### AI Runtime

Separar interpretação, planejamento, tool calling, response generation, media understanding e business intelligence conforme necessidade.

### Knowledge

Knowledge empresarial precisa de provenance, versionamento e segurança.

### Jobs / Outbox

Side effects externos são duráveis.

### Audit / Observability

Toda ação importante precisa ser explicável.

---

# 3. ML Appointments

## Público

- barbearias;
- salões;
- estética;
- clínicas;
- consultórios;
- fisioterapia;
- oficinas com hora marcada;
- prestadores;
- outros serviços.

## Experiência do cliente

Exemplos:

- “tem horário com Pedro amanhã depois das 15?”
- “quero o mesmo de sempre”
- “passa meu horário para sábado de manhã”
- “se aparecer vaga hoje me avisa”

## Motor operacional

Considerar:

- serviço;
- profissional;
- compatibilidade;
- duração;
- preços/overrides;
- buffers;
- recursos/salas/equipamentos quando aplicável;
- business hours;
- professional schedules;
- exceptions;
- notice;
- horizon;
- concurrency;
- multiple services;
- recurring appointments;
- packages/memberships quando relevante.

## Waitlist

Progressive offers, expiration, configurable priority, fairness, audit.

## Growth integration

No-show prevention, smart reactivation, occupancy filling.

## Payments integration

Deposits, prepayment, refund policy, reconciliation.

---

# 4. ML Food — visão aprofundada

## 4.1 Meta

Construir um sistema que una benefícios de:

- cardápio digital;
- atendimento;
- ordering;
- POS;
- KDS;
- impressoras;
- delivery;
- payments;
- CRM;
- inventory;
- analytics;
- automation.

Mas manter a experiência do cliente predominantemente dentro do WhatsApp/Instagram.

## 4.2 Cardápio visual progressivo

Nunca despejar cardápio inteiro em texto por padrão.

Experiência ideal:

```text
Escolha uma categoria
-> veja produtos com imagem/preço/descrição
-> personalize
-> adicione
-> veja carrinho
-> pague
-> acompanhe
```

Usar componentes reais do canal onde disponíveis.

### Exemplos de entrada natural

- “quero jantar até 40 reais”
- “quero um combo para 3”
- “tem pizza meio a meio?”
- “manda o último pedido”
- “tem algo sem lactose?”

## 4.3 Modelo de menu

Entidades conceituais:

- Menu;
- Category;
- Product;
- Product Variant;
- Size;
- Flavor;
- ModifierGroup;
- Modifier;
- Combo;
- AvailabilityWindow;
- ChannelAvailability;
- Price;
- Image/Media.

Constraints:

- min/max choices;
- required/optional;
- incompatibility;
- substitution;
- additional price;
- stock availability.

## 4.4 Pedido complexo estruturado

“2 X-Bacon: um sem cebola e bacon extra; outro troca cheddar por mussarela.”

Deve virar linhas/modificadores estruturados, não nota livre apenas.

## 4.5 Cart state

Carrinho precisa sobreviver entre mensagens e compreender alterações incrementais.

## 4.6 Checkout

- delivery/pickup/dine-in;
- address;
- zone fee;
- ETA;
- payment option;
- customer confirmation;
- order lock/version.

## 4.7 Kitchen routing

Itens vão para estações apropriadas.

Exemplo:

```text
Order 182
X-Bacon -> CHAPA
Batata -> FRITADEIRA
Coca -> BALCÃO
```

## 4.8 KDS

Features a avaliar:

- ticket cards;
- station view;
- age/timer;
- new/preparing/ready;
- bump;
- recall;
- priority;
- notes/modifiers legíveis;
- allergen warning quando aplicável;
- expo view;
- audit;
- offline/reconnect behavior.

## 4.9 Printing

### Objetivo

Restaurantes pequenos devem poder operar apenas com impressora térmica; maiores podem usar KDS + printers.

### Print infrastructure

- durable print queue;
- local bridge/agent quando necessário;
- printer registry;
- station mapping;
- ESC/POS;
- USB/LAN/Wi-Fi;
- retry;
- reprint;
- audit;
- health;
- failover;
- duplicate protection.

### Estados

Não inventar certeza física impossível. Dependendo da impressora/protocolo, diferenciar:

- queued;
- delivered_to_agent;
- written_to_printer/socket;
- acknowledged quando hardware suportar;
- assumed_printed;
- failed;
- manually_confirmed/reprinted.

## 4.10 Funcionário/dono pelo WhatsApp

Exemplos autorizados:

- “pausa calabresa”;
- “reativa às 20h”;
- “quantos pedidos?”;
- “pedido 181 está pronto”;
- “reimprime 181”;
- “fecha delivery”.

## 4.11 Dynamic ETA

Estimativa por fila, station load, historical prep, item mix, courier availability.

## 4.12 Delivery

- geolocation/address normalization;
- delivery zones;
- fees;
- courier assignment;
- tracking/status;
- partner integrations;
- delivery SLA.

## 4.13 Tables / tabs

- QR/table association;
- waiter/user;
- open tab;
- add items;
- split/close;
- audit.

## 4.14 Recipe inventory

- ingredient;
- unit;
- conversion;
- recipe;
- yield;
- waste;
- availability propagation.

Se bacon zerar, o sistema deve entender quais itens/modificadores ficam indisponíveis.

## 4.15 Menu engineering

- contribution margin;
- popularity;
- attach rate;
- abandon rate;
- item view -> add conversion;
- out-of-stock loss;
- recommended experiments.

---

# 5. ML Commerce

## Objetivo

Fazer WhatsApp/Instagram funcionar como vendedor consultivo e interface de compra, com um commerce engine sério atrás.

## Funções

- catalog;
- visual browsing;
- search;
- SKU/variant;
- stock;
- price;
- promo;
- cart;
- payment;
- delivery/pickup;
- order status;
- returns;
- repeat purchase;
- recommendations grounded in real inventory.

## Visual matching

Foto enviada -> candidate products -> confidence -> real catalog lookup.

## Automotive/other vertical extensions

Não force tudo ao Commerce base. Ex.: autopeças pode precisar vehicle fitment como subdomain.

---

# 6. Clínicas e serviços regulados

Não trate clínica como “barbearia com nomes diferentes”.

Investigar:

- rooms/resources;
- return appointments;
- intake;
- documents;
- preparation instructions;
- consent;
- waiting queue;
- payments;
- insurance/convênios quando aplicável;
- privacy;
- clinical boundaries.

IA comercial/administrativa não deve assumir papel de diagnóstico ou prescrição sem produto e safeguards específicos.

---

# 7. ML Growth

## Reativação individual

Não apenas “60 dias sem vir”. Detectar ciclo esperado por cliente/serviço/produto.

## Campaign engine

- audience rules;
- consent;
- templates;
- frequency cap;
- send windows;
- A/B tests;
- attribution;
- conversion;
- revenue.

## Abandon recovery

Detectar processos inacabados com contexto, sem spam.

---

# 8. Opportunity + Next Best Action

A ML deve identificar oportunidades e riscos, mas não bombardear gestor.

Priorizar poucas recomendações de alto impacto.

Exemplos:

- slot gap;
- churn risk;
- low-stock risk;
- kitchen bottleneck;
- campaign anomaly;
- high-interest/low-conversion product;
- payment collection opportunity.

---

# 9. ML Payments

- PIX;
- card/payment links;
- deposits;
- refunds;
- subscriptions;
- collections;
- reconciliation;
- idempotent webhooks;
- ambiguous outcome recovery.

---

# 10. ML Reputation / CX

- internal satisfaction;
- public review invitation sem manipulative review gating;
- complaint detection;
- service recovery;
- escalation;
- root-cause tagging;
- retention follow-up.

---

# 11. Multi-unit

Modelar organization/business/location com configuração herdável e overrides.

Considerar profissional em múltiplas unidades, estoque por local, campanhas multi-location e analytics consolidado.

---

# 12. Manager intelligence

Manager deve responder “o que devo fazer?” e não apenas “o que aconteceu?”.

Cada insight importante deve poder levar a ação relevante.

---

# 13. Onboarding

Meta: reduzir configuração manual e erro.

Ingestão de documentos/imagens deve gerar draft revisável, nunca publicação cega.

---

# 14. Moat legítimo

Retenção deve vir de valor acumulado:

- histórico;
- integrações;
- automações;
- conhecimento;
- preferências;
- benchmarks próprios;
- operational learning;
- process fit;
- analytics.

Sempre permitir exportação adequada.

---

# 15. Métrica de excelência por módulo

Para cada ML, avaliar simultaneamente:

1. Cliente: ficou mais fácil?
2. Funcionário: reduziu trabalho manual?
3. Gestor: aumentou controle/inteligência?
4. Empresa: gerou receita/reduziu custo/risco?
5. Plataforma: ficou confiável e escalável?
6. Operação: falhas são recuperáveis?
7. Concorrência: existe vantagem real além de “tem IA”? 
