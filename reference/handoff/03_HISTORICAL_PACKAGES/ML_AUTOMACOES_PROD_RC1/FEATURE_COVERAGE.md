# Feature coverage — PROD RC1

| Capability | Workflow/Core contract |
|---|---|
| Multi-tenant | business_id obrigatório no Core |
| Inbound idempotente | prepare_assistant_turn |
| Texto natural | IA Orquestradora |
| Botões/listas | structured command |
| Availability | execute_assistant_action_v4 |
| Booking/confirm | Core V4 sobre lógica consolidada |
| GET appointment | Core V4 |
| Customer cancellation | Core V4 |
| Professional/business cancellation | Control Plane + outbox |
| Rebooking CANCELLED | Core V4 |
| Rescheduling CONFIRMED | Core V4 + Calendar jobs |
| Waitlist | Core V4 + scheduler |
| Human handoff | request_human_handoff_v1 |
| Interactive WhatsApp | outbox payload canônico |
| Session/template outbound | WhatsApp worker |
| Calendar create/delete | Calendar worker |
| Calendar reconciliation | search by appointment marker before CREATE |
| Calendar retry | job retry/backoff |
| Reminders | scheduler |
| Reactivation/recurrence | scheduler |
| Housekeeping | scheduler |
| Error capture | Error workflow |
| RBAC Admin/Manager/Employee | Control Plane + Core |
| Tenant onboarding | Control Plane/Core contract |
| Audit | DB contract |
| Dead-letter | DB contract |
