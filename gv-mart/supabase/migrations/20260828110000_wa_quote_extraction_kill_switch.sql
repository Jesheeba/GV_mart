-- 2026-08-28: last remaining live Anthropic call in the system —
-- extractQuote (whatsapp-extract-quote.ts), called from handleSupplierReply
-- for a supplier's WhatsApp price-quote reply. Deliberately a SEPARATE,
-- independent flag from wa_answer_layer_enabled and wa_classify_intent_
-- enabled: this is a genuinely different feature (supplier RFQ price
-- logging, not customer conversation), always checked before the
-- customer-bot kill switch even runs, by original design. Bundling it
-- under either existing flag would make one toggle silently affect two
-- unrelated things.
--
-- Default false, matching "off by default" per the owner's zero-AI
-- decision — not left defaulting true pending a future manual toggle.
alter table public.settings
  add column wa_quote_extraction_enabled boolean not null default false;
