# GV Mart — WhatsApp Integration Build Plan

**Scope:** Add WhatsApp as a second interface to the existing GV Mart application.
**Not in scope:** Journey builder, ERP integration, Customer 360, omnichannel, predictive service.

---

## Core principle

> WhatsApp is a **client** of GV Mart's existing business logic — not a second implementation of it.

The bot calls the same Postgres RPCs the web app calls. It never inserts directly into business tables. If this rule breaks, you own two divergent implementations of your business rules and will reconcile them forever.

**No architectural change is required.** Business logic already lives centrally in Postgres RPCs; this adds a caller. Everything below is additive.

---

## Four decisions to make before writing code

| # | Decision | Take this | Why |
|---|---|---|---|
| 1 | Conversation state location | Postgres, not n8n | Survives restarts, debuggable from the app, transport-swappable |
| 2 | Transport coupling | One adapter interface | Wasi ↔ Evolution/AiSensy becomes config, not rework |
| 3 | Bot authorisation | Per-RPC phone ownership check | Bot runs as service role — **RLS does not protect it** |
| 4 | Business rules | Bot calls existing RPCs only | Prevents logic drift |

### The transport question — decide before quoting

Wasi is the natural home for this, but Phase 3 (RLS) is in progress and Phases 5–6 are outstanding. GV Mart's delivery date would be coupled to Wasi's completion.

- **Wait for Wasi** — cleanest, date depends on unfinished product
- **Ship on Evolution/AiSensy, migrate later** ← recommended; migration is cheap if decision 2 holds
- **Rush Wasi for GV Mart** — how multi-tenant platforms get shaped around one tenant and become unsellable to the second

---

## Phase 0 — Prerequisites (start week 1, runs in parallel)

These are the long poles. They are mostly waiting, not working, which is why they go first.

- [ ] **Phone data audit.** Are `customers.phone` values normalised (+91, no spaces, consistent)? Everything in this project rests on that lookup succeeding. If dirty, clean it now — unglamorous and easily skipped.
- [ ] Meta business verification, WABA, phone number
- [ ] **Submit templates for approval** (see Phase 3) — approval cycles are slow and rejections common
- [ ] Confirm transport decision
- [ ] Confirm the app has a usable customer↔product↔AMC relationship to read from

---

## Phase 1 — Foundation

**Database (additive only, no changes to existing tables' semantics):**

```
whatsapp_conversations   phone, customer_id, journey, step, collected jsonb,
                         status, expires_at, last_message_at
whatsapp_messages        direction, wa_message_id (unique), type, payload, status, error
whatsapp_templates       name, category, approval_status, variable_map
whatsapp_media           storage_path, linked_ticket_id, linked_customer_id
```

Columns added to existing tables:
- `source` enum (`app` | `whatsapp`) on tickets and leads
- `whatsapp_number` normalised + indexed on customers
- `phone_verified` flag

**RPCs:**

- `wa_identify_customer(phone)` → customer + products + AMC status + open tickets + last service, in one call. This single function powers most of the customer-recognition value.
- `wa_get_conversation(phone)` / `wa_save_step(...)`

**Webhook receiver** — Edge Function, signature verification, **idempotency on `wa_message_id`**. Meta retries; without this you create duplicate tickets. This is the single most commonly missed item.

**Transport adapter** — one `sendMessage()` entry point. Nothing else touches the transport.

**Exit criteria:** inbound message logged, customer resolved, conversation row created, outbound reply delivered.

---

## Phase 2 — Journeys

Each journey: collect only what's missing → write via **existing** RPC → confirm.

**Menu** (renamed per client document — free changes, just do them):
Buy/Upgrade · Book Service · Parts & Accessories · AMC & Maintenance · My GV Mart Account · Talk to an Expert

> **Format constraint:** WhatsApp list messages cap at 10 rows, reply buttons at 3. Six menu items fit a list. "My GV Mart Account" with ten sub-items sits exactly at the ceiling — use a list, and don't let it grow.

**Service** — problem type → urgency → slot → address confirm → ticket
Do **not** ask capacity or model. Look it up. This is the highest-value, lowest-cost idea in the client's document.

**Sales** — three paths (know what I want / help me choose / explore) → segment → qualifying questions → lead

**Spares** — resolve product from CRM → category → quantity → enquiry

**AMC** — status lookup, renew, benefits

**My Account** — read-only: products, service history, ticket status, AMC, warranty

**Bot-facing write RPCs** — thin wrappers that validate phone ownership, then call existing RPCs:
`wa_create_service_ticket()`, `wa_create_lead()`, `wa_create_spare_enquiry()`

**Conversation mechanics:** back · main menu · cancel/start over · talk to team on every step; resume prompt on return; step timeout; Tamil/English (reuse existing i18n strings, don't duplicate).

**Security gate — review by hand, do not trust generated code.**
Every `wa_*` function independently verifies the calling phone owns the record it touches. RLS will not do this for you. A missing check leaks one customer's service history to another.

**Exit criteria:** all five journeys create correct records; tickets appear in the technician app automatically (same tables, Realtime already subscribed — this is a strong demo for the client and costs nothing).

---

## Phase 3 — Templates & notifications

Anything sent outside the 24-hour service window needs an approved template.

| Template | Category |
|---|---|
| Ticket created / technician assigned / en route / completed | Utility |
| AMC expiry 30 / 15 / 7 day | Utility |
| Feedback request | Utility |
| Promotional follow-up | Marketing (throttled by quality rating) |

Marketing volume is capped by messaging tier, which starts low. Plus: outbound send queue with retry, scheduled jobs for AMC reminders.

---

## Phase 4 — Ops surface (in the React app)

**New screens:** conversation list + transcript · human handover inbox · template manager · failed-send log · **bot kill switch, prominently placed**

**Modified screens:** WhatsApp source badge on tickets/leads · WhatsApp photos in ticket detail · conversation history on customer profile · photo attachments in technician app

> **Hard rule:** the bot never answers pricing or payment questions from anything but database values. Route to human handover otherwise. A bot fabricating prices into conversation history is a real, previously-encountered failure mode.

The kill switch matters more than it sounds — when the bot misbehaves with a live customer you want one click, not a redeploy.

---

## Phase 5 — Intent layer

Free-text and Tanglish classification → `{sales, service, spare, amc, support}` + segment + product hint.

**LLM classifies. Deterministic code routes.** The AI never manages state or invents business rules. Below a confidence threshold, fall back to the menu rather than guessing.

**Media:** photos (fault/water report → Storage → attached to ticket) and native location share are cheap and useful. **Voice notes are a research spike, not a feature** — Tanglish code-mixed speech-to-text is unreliable. Prototype before promising.

---

## Effort weighting

| Area | Share |
|---|---|
| Bot logic | 35% |
| Database + RPCs | 25% |
| Frontend / ops surface | 25% |
| Meta setup + templates | 15% (mostly waiting — start first) |

---

## Explicitly deferred

Journey builder · question library abstraction · product-master-driven journeys · ERP integration · Customer 360 · predictive service · omnichannel · automated AMC renewal

These are the client document's Year 3–6 items. Quote separately if pursued. The journey builder in particular is a product in its own right — n8n already is one, and a config file solves the stated problem in an afternoon.

---

## The two failures most likely to actually happen

1. **Missing webhook idempotency** → duplicate tickets in production
2. **Missing per-RPC phone ownership check** → cross-customer data leak

Neither is difficult. Both are easy to skip.
