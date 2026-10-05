-- Drop superseded overloads that were left behind when these RPCs gained parameters.
-- Each older signature is a strict subset of the current one (the extra parameters all
-- have defaults), so a call that supplies only the old arguments is ambiguous between
-- the two and, if it resolved to the old one, silently skipped the newer behaviour
-- (e.g. create_sale without p_amount_paid, sell_amc_plan without the referral credit).
--
-- Verified no callers before dropping: the app's only call sites (services/sales.ts,
-- services/amc.ts, services/customerApp.ts) send the newest parameter sets; no edge
-- function, SQL function, view, policy or cron job references the old versions
-- (create_rental mentions create_sale only in comments); nothing depends on them.
-- Plain DROP (no CASCADE): fails loudly if anything unexpected does.
--
-- Current signatures kept:
--   create_sale(uuid, uuid, jsonb, uuid, integer, uuid, numeric)
--   sell_amc_plan(uuid, uuid, uuid, uuid, date, integer, uuid)
--   renew_amc_plan(uuid, uuid, uuid, text, integer, text, uuid)

drop function if exists public.create_sale(uuid, uuid, jsonb, uuid, integer);
drop function if exists public.sell_amc_plan(uuid, uuid, uuid, uuid, date, integer);
drop function if exists public.renew_amc_plan(uuid, uuid, uuid, text, integer);
drop function if exists public.renew_amc_plan(uuid, uuid, uuid, text, integer, text);
