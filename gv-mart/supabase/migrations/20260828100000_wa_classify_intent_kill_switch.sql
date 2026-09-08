-- 2026-08-28: owner decision — turn off ALL AI in the customer WhatsApp
-- bot pipeline, not just the Answer Layer (settings.wa_answer_layer_enabled,
-- already off since 11:56:42 UTC today). Phase 5b's classifyWithClaude
-- (routing free text to a menu journey) and the new free-text-relevance
-- guard (checkFreeTextRelevance, whatsapp-classify-intent.ts) are both
-- Anthropic calls too — "just for routing", per the owner's own framing,
-- but still AI, still in scope. Same on/off pattern as
-- wa_answer_layer_enabled (checked in the impure shell, no redeploy needed
-- to flip it back on later) — not a blunt "remove the API key" approach,
-- which would also silently disable extractQuote's supplier-reply price
-- extraction (whatsapp-handle-message.ts's handleSupplierReply), a
-- separate, always-on operational path unrelated to this decision.
alter table public.settings
  add column wa_classify_intent_enabled boolean not null default true;

-- Set OFF immediately for this org, per the explicit "effective immediately"
-- instruction — not left defaulting true pending a future manual toggle.
update public.settings set wa_classify_intent_enabled = false;
