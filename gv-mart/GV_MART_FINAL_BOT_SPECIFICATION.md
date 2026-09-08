# GV Mart WhatsApp Bot — Final Build Specification
**Design philosophy:** This is a rule-based (decision-tree) chatbot, the same architecture used by production bots at scale across e-commerce, finance, and hospitality — predictable, secure, cheap to run, zero AI. Per industry-standard practice, every interaction follows one of three patterns: (1) a button/menu decision tree, (2) keyword-triggered lookup of real data, or (3) a structured multi-step flow that ends in a real CRM action (ticket, lead, enquiry). Nothing is generated — everything is either a live database fact or a pre-written, approved sentence.

**Client requirement (final, confirmed):** zero AI/LLM calls anywhere in the system. All replies come from real-time database lookups or fixed templates.

---

## 1. Core Design Principles (industry standard, applied throughout)
1. **Every conversation path is mapped in advance.** No open-ended free-form understanding — if it's not an explicit trigger, it's not answered directly.
2. **Every dead end offers an escape hatch.** No reply should leave the customer stuck — always offer "menu", "expert", or a next step.
3. **Fallback is consistent, not blank.** An unmatched message never gets silence — always the polite redirect + menu.
4. **Real data only, never invented.** If a database field is null/missing, say so honestly — never guess or leave a gap.
5. **Human handoff is always available.** "agent"/"expert" always escapes to a real person, at any point, any state.
6. **Data actions (tickets, leads, enquiries) only happen through structured flows**, never inferred from ambiguous free text.

---

## 2. Complete Intent/Keyword Library
*(Consolidates everything already built + confirmed additions — this is the authoritative reference; extend it here going forward.)*

| # | Intent | Trigger | Data source | Status |
|---|---|---|---|---|
| 1 | AMC/Warranty status | "amc", "warranty" | `wa_get_amc_status` → `enterAmcJourney` | ✅ Live |
| 2 | Service ticket status | phrase list (Cat. 2 of question bank) | `wa_get_service_ticket_status` | ✅ Live |
| 3 | Purchase history | phrase list (Cat. 3) | `wa_get_purchase_history` | ✅ Live |
| 4 | Business address | "address", "location", etc. | `wa_get_business_info` | ✅ Live |
| 5 | Business phone | "phone number", "contact number" | `wa_get_business_info` | ✅ Live |
| 6 | Business hours | "business hours", "when are you open" | `wa_get_business_info` | ✅ Live |
| 7 | Pricing | any price question, "buy" | Sales journey — no price disclosed | ✅ Live |
| 8 | New service booking | "service", complaint language | Service journey → real ticket | ✅ Live |
| 9 | Spare parts | "spares", "parts" | Spares journey → real enquiry | 🔲 add "parts" synonym |
| 10 | My account | "account" | Existing journey | ✅ Live |
| 11 | Human handoff | "agent", "human", "expert", "நிபுணர்" | Notification to staff | ✅ Live |
| 12 | Menu/navigation | "menu", "back", "cancel" | Mechanics | ✅ Live |
| 13 | Greeting | "hi", "hello", "vanakkam" | Returns menu | ✅ Live |
| 14 | Language switch | "tamil", "english" | Sets preference | ✅ Live |
| 15 | Off-topic chit-chat | anything unrelated | Polite redirect + menu | ✅ Live |
| 16 | Payment/security red flags | gpay, upi, bank details, long digit strings | Blocked, redirected, logged | ✅ Live |
| 17 | EMI info | "emi", "installment", "monthly payment" | `settings.emi_*` fields | 🔲 build now (approved) |
| 18 | Product availability/stock | "do you have X", "in stock" | `wa_get_product_price` (name/brand only, never price) | 🔲 build now (approved) |
| 19 | Installation time | — | No data source | ⏸️ deferred — monitor fallback logs |
| 20 | Payment methods accepted | — | No data source | ⏸️ deferred — monitor fallback logs |

---

## 3. Conversation Flow Map (how a message resolves, in order)

```
Inbound message
  │
  ├─► Payment/security red flag? ──► Block, redirect, log (never captured as data)
  │
  ├─► Mechanic keyword (menu/back/cancel/agent/language)? ──► Handle directly
  │
  ├─► Bare greeting only? ──► Return to menu
  │
  ├─► Status/info detector match (Categories 1–6, 17, 18)? ──► Real DB lookup → template reply
  │
  ├─► Menu-item keyword (buy/service/spares/account) or menu tap? ──► Enter that journey
  │
  ├─► Inside an active structured flow (booking steps, capture steps)? ──► Continue flow,
  │      with red-flag/off-topic guard still active on free-text capture steps
  │
  └─► Nothing matched ──► Polite fallback + menu (never silence)
```

---

## 4. Template Tone Standard (apply to every reply, existing and new)
Every template — existing or newly built — should read like a helpful, professional staff member, not a database dump:
- Short (WhatsApp-appropriate, 1-3 sentences)
- Warm but efficient — no excessive apology, no robotic phrasing
- Always end with a clear next step (a keyword to reply, or "menu")
- EN + TA pair for every template (Tanglish phrases route to whichever template matches the trigger — English or Tamil pair, per existing pattern), not a third dynamically-generated variant

**Audit pass requested:** review every existing template reply against this standard and flag any that read too clinical/robotic — propose warmer alternatives, show before/after, get approval before changing live copy.

---

## 5. Scalability & Extensibility (addressing "will this keep up as the business grows")
1. **Data always live** — already true for every DB-backed category; nothing further needed here.
2. **New phrasings need explicit addition** — this is the one manual dependency of a zero-AI design. Recommended mitigation, build now: a simple admin UI screen (Settings or Automation page) where staff can add new trigger phrases mapped to an existing category, without a code deploy. This is the single highest-leverage investment for long-term scalability without AI.
3. **Fallback visibility** — build a simple report/query (even just a documented SQL query, doesn't need a UI) showing the most common unmatched messages from the last N days, so new phrases/categories get prioritized by real evidence, not guesswork.
4. **Fuzzy/typo tolerance** — deterministic (non-AI) matching that tolerates small misspellings, to reduce false "no match" cases without any ML/embedding model involved.

---

## 6. Testing Checklist (before considering any new category "done")
For every new or modified trigger:
- [ ] Real match test — the intended phrase triggers the correct reply with real data
- [ ] Non-collision test — an unrelated message containing a similar word does NOT falsely trigger it
- [ ] Null-data test — if the underlying data is missing, the honest "not on file" reply fires, never a guess
- [ ] Tanglish/Tamil variant test, where applicable
- [ ] Fallback test — confirm messages that should NOT match still correctly fall through to the generic decline

---

## 7. Execution Instructions for Claude Code
Work through this specification top to bottom, autonomously, reporting progress at each numbered section rather than waiting for approval on every micro-decision — EXCEPT:
- Any new customer-facing template wording — show before implementing (per section 4's audit and any new templates in section 2)
- Any schema/migration change — show diff before applying
- Any deploy — show diff, run esbuild check, confirm before pushing live

**Immediate action items (already approved, proceed directly):**
1. Add "parts" synonym, all pending phrase additions from the question bank review
2. Build EMI info (item 17)
3. Build product availability/stock (item 18)
4. Build the fallback-visibility query/report (section 5.3)

**Propose-then-build (needs a design review before implementation, same as everything else this session):**
5. Admin UI phrase manager (section 5.2) — propose the design/scope first
6. Template tone audit (section 4) — show before/after examples first

**Explicitly deferred, do not build without new instruction:**
- Installation time / payment methods (items 19–20) — revisit only if fallback data shows real demand
- Anything resembling vector search, embeddings, or any ML-based matching — conflicts with the zero-AI requirement

Once all "immediate" and "propose-then-build" items are complete and tested per section 6, report a final summary: what's live, what's covered, what's still deferred and why — so this can be handed off as a complete, documented system.

---

## 8. Operations & Handoff (as of 2026-08-28)

**Status:** all Section 7 items complete, tested per Section 6, and live. Zero AI calls anywhere in the system — confirmed via full-repo grep; every Anthropic call site is either behind an independently-off settings flag (`wa_answer_layer_enabled`, `wa_classify_intent_enabled`, `wa_quote_extraction_enabled` — all off, all independent of each other) or undeployed entirely.

### Extending phrase coverage — two ways
1. **Admin UI, no deploy needed:** Automation page → **Bot Phrases** tab. Add a phrase, pick one of the 13 safe categories (the 7 status-answer categories + 6 menu-item synonyms). Additive only — never replaces the code-reviewed baseline, just adds more ways to trigger it. Mechanics (menu/cancel/back/expert-keyword/language switch), bare greetings, and payment red-flag phrases are deliberately **not** editable here — those stay code-review-only.
2. **Code, review + deploy:** `TRIGGER_PHRASES` / `AVAILABILITY_PHRASES` in `supabase/functions/_shared/whatsapp-status-answers.ts`, and `MENU_ITEM_SYNONYMS` in `supabase/functions/_shared/whatsapp-journeys.ts`.

### Fuzzy/typo tolerance
Small misspellings of an existing phrase still match (Levenshtein edit distance, length-gated — short words stay exact-match-only, since a 1-edit typo on a 2-3 letter word is too likely to just be a different real word). Scoped to the same 13 safe categories as the phrase manager — mechanics/greetings/red-flags stay exact-match, deliberately untouched. Every fuzzy (non-exact) match is logged to the Edge Function console with the tag `"resolved via FUZZY match"` — check Function Logs in the Supabase dashboard periodically to spot-check real hits. Two known word collisions were found and hard-excluded during build/test (`expert`↔`expect`, `parts`↔`pants`); other, less common collisions may exist and aren't excluded — the log is the ongoing safety net for those.

### Fallback-visibility query — what customers are asking that nothing answers
Run periodically in the Supabase SQL editor (Dashboard → SQL Editor):

```sql
select
  f.created_at as declined_at,
  f.to_mobile as phone,
  q.body as customer_question
from whatsapp_outbox f
left join lateral (
  select payload->>'body' as body
  from whatsapp_outbox i
  where i.direction = 'inbound'
    and i.payload->>'from' = '91' || f.to_mobile
    and i.created_at < f.created_at
  order by i.created_at desc
  limit 1
) q on true
where f.direction = 'outbound'
  and (
    f.payload->>'body' ilike 'I''m not able to help with that specific question%'
    or f.payload->>'body' ilike 'அந்தக் கேள்விக்கு%'
  )
order by f.created_at desc
limit 100;
```

Use this to decide what genuinely needs a new phrase/category next — including whether to revisit the deferred items below.

### Deferred — revisit only with real evidence from the query above
- Installation time, payment methods accepted (intent library items 19-20) — no data source exists yet; build only if the fallback query shows real recurring demand, not speculatively.
- Anything vector/embedding/ML-based — explicitly out of scope, conflicts with the zero-AI requirement.

### Key files
| File | Owns |
|---|---|
| `supabase/functions/_shared/whatsapp-status-answers.ts` | Status-answer categories (service ticket, purchase history, business info, EMI, availability) and their trigger phrases |
| `supabase/functions/_shared/whatsapp-journeys.ts` | Mechanics, menu-item synonyms, greeting/red-flag detection, fuzzy-matching primitives (`containsWholePhraseFuzzy`, `levenshteinDistance`) |
| `supabase/functions/_shared/whatsapp-handle-message.ts` | Overall dispatch order (mirrors Section 3's flow map), phrase-manager DB read |
| `src/app/admin/automation/PhraseManagerTab.tsx` | The Bot Phrases admin screen |
| `wa_custom_trigger_phrases` (table) | Staff-added phrases — additive only |
