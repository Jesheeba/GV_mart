-- Supplier Monthly RFQ pipeline — Phase 1 (settings + deterministic price
-- write-back). See gv-mart's plan doc for the full pipeline; this migration
-- only adds what Phase 1 needs:
--   1. settings.po_quote_day_of_month / po_quote_last_run_month — the
--      admin-configurable "send RFQs on this day every month" trigger read
--      by a new branch in wa-scheduled-tasks (Phase 2, not this migration).
--   2. supplier_products.price_updated_at — so a supplier's pricing table
--      can show "last updated", and both quote-reply-logging RPCs now write
--      the newly-logged price straight back into supplier_products, keeping
--      it current without any separate admin step.
--
-- Deliberately does NOT touch resolve_purchase_quote_requests, PO creation,
-- or approval — those are later phases.

alter table public.settings
  add column if not exists po_quote_day_of_month integer check (po_quote_day_of_month between 1 and 31),
  add column if not exists po_quote_last_run_month text;

comment on column public.settings.po_quote_day_of_month is
  'Day of month (1-31) the automatic monthly supplier RFQ fires on. Null = feature off.';
comment on column public.settings.po_quote_last_run_month is
  'YYYY-MM (IST) of the last month the monthly RFQ actually ran — guards against firing twice in one month across repeated cron ticks.';

alter table public.supplier_products
  add column if not exists price_updated_at timestamptz;

-- Backfill: treat existing rows' price as "current as of when the link/price
-- was last touched" rather than leaving it null (which would read as "never
-- priced" in the UI for links that predate this column).
update public.supplier_products set price_updated_at = updated_at where price_updated_at is null;

-- ── wa_log_quote_reply: bot-facing reply logging, now also refreshes
-- supplier_products.price ────────────────────────────────────────────────
-- No unique constraint exists on (supplier_id, item_type, item_id) in
-- supplier_products (verified against 20260701090400_suppliers_purchase.sql
-- — the UI only ever creates one link per pair by convention, not a DB
-- guarantee), so this is a plain UPDATE over the matching row(s), not an
-- upsert. The supplier_products link is already known to exist at this
-- point — wa_log_quote_reply's own guard above raises if it doesn't — so
-- this only ever touches a link that was already there.
create or replace function public.wa_log_quote_reply(
  p_org_id uuid,
  p_request_id uuid,
  p_supplier_id uuid,
  p_price numeric,
  p_note text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_req public.purchase_quote_requests;
  v_reply_id uuid;
begin
  if p_price is null or p_price < 0 then
    raise exception 'wa_log_quote_reply: price must be a non-negative amount';
  end if;

  select * into v_req from public.purchase_quote_requests
  where id = p_request_id and org_id = p_org_id;
  if v_req.id is null then
    raise exception 'wa_log_quote_reply: quote request % not found', p_request_id;
  end if;
  if v_req.status is distinct from 'open' then
    raise exception 'wa_log_quote_reply: quote request % is already resolved', p_request_id;
  end if;

  if not exists (
    select 1 from public.supplier_products
    where org_id = v_req.org_id and supplier_id = p_supplier_id
      and item_type = v_req.item_type and item_id = v_req.item_id
  ) then
    raise exception 'wa_log_quote_reply: supplier % was not sent a quote request for this item', p_supplier_id;
  end if;

  insert into public.purchase_quote_replies (org_id, request_id, supplier_id, price, note, logged_by, logged_at)
  values (v_req.org_id, p_request_id, p_supplier_id, p_price, p_note, null, now())
  on conflict (request_id, supplier_id) do update
    set price = excluded.price, note = excluded.note, logged_by = excluded.logged_by, logged_at = excluded.logged_at
  returning id into v_reply_id;

  update public.supplier_products
  set price = p_price, price_updated_at = now()
  where org_id = v_req.org_id and supplier_id = p_supplier_id
    and item_type = v_req.item_type and item_id = v_req.item_id;

  return v_reply_id;
end;
$$;

-- Intentionally NOT granted to authenticated — service_role only (unchanged from 20260825150000).

-- ── log_purchase_quote_reply: the human-facing twin, same price write-back ─
create or replace function public.log_purchase_quote_reply(
  p_request_id uuid,
  p_supplier_id uuid,
  p_price numeric,
  p_note text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_req public.purchase_quote_requests;
  v_reply_id uuid;
begin
  if not public.is_ops_staff() then
    raise exception 'log_purchase_quote_reply: caller is not ops staff';
  end if;
  if p_price is null or p_price < 0 then
    raise exception 'log_purchase_quote_reply: price must be a non-negative amount';
  end if;

  select * into v_req from public.purchase_quote_requests
  where id = p_request_id and org_id = public.current_org_id();
  if v_req.id is null then
    raise exception 'log_purchase_quote_reply: quote request % not found', p_request_id;
  end if;
  if v_req.status is distinct from 'open' then
    raise exception 'log_purchase_quote_reply: quote request % is already resolved', p_request_id;
  end if;

  if not exists (
    select 1 from public.supplier_products
    where org_id = v_req.org_id and supplier_id = p_supplier_id
      and item_type = v_req.item_type and item_id = v_req.item_id
  ) then
    raise exception 'log_purchase_quote_reply: supplier % was not sent a quote request for this item', p_supplier_id;
  end if;

  insert into public.purchase_quote_replies (org_id, request_id, supplier_id, price, note, logged_by, logged_at)
  values (v_req.org_id, p_request_id, p_supplier_id, p_price, p_note, auth.uid(), now())
  on conflict (request_id, supplier_id) do update
    set price = excluded.price, note = excluded.note, logged_by = excluded.logged_by, logged_at = excluded.logged_at
  returning id into v_reply_id;

  update public.supplier_products
  set price = p_price, price_updated_at = now()
  where org_id = v_req.org_id and supplier_id = p_supplier_id
    and item_type = v_req.item_type and item_id = v_req.item_id;

  return v_reply_id;
end;
$$;

-- Grant unchanged from 20260725120000 (authenticated, gated by is_ops_staff() inside the function body).
grant execute on function public.log_purchase_quote_reply(uuid, uuid, numeric, text) to authenticated;
