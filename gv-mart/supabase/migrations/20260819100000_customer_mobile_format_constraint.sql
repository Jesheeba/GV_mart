-- WhatsApp Integration, Phase 1 — phone-normalization gate.
--
-- Audit (2026-08-19) found customers.mobile 100% uniform bare 10-digit
-- (e.g. "9884012345") across all 31 rows — no +91, no spaces/dashes, no
-- leading 0. No data rewrite needed. This constraint only guards against
-- future drift: wa_identify_customer (next migration) is a plain equality
-- lookup against this column, and a value that silently stopped conforming
-- would make that lookup fail silently (customer treated as unrecognized)
-- rather than erroring loudly. Meta's inbound `from` field is normalized to
-- this same bare-10-digit shape at the WhatsApp boundary (see
-- _wa_normalize_phone in the next migration), not by changing this column.
alter table public.customers
  add constraint customers_mobile_format check (mobile ~ '^\d{10}$');
