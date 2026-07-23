-- GV.md Section 3 ("Purchase Order — quotation-first, with safeguard").
--
-- ============================================================================
-- THIS IS A REVERSAL OF ALREADY-DEPLOYED, ALREADY-WORKING BEHAVIOR. Read
-- GV.md 3.1-3.2 and the whole of 20260722110000_reorder_formula_and_po_
-- approval_toggle.sql's `_auto_draft_purchase_order()` before touching this
-- file again. Summary of the change:
--
-- BEFORE (today, C1/C2): on the downward min_stock crossing, the trigger
-- picked ONE supplier (cheapest/preferred via supplier_products) and created
-- the PO immediately — either 'sent' (+ WhatsApp dispatch) if
-- settings.po_requires_approval is false, or 'draft' pending
-- approve_purchase_order if true.
--
-- AFTER (this migration, owner-approved GV.md 3.1): on the same crossing,
-- the trigger no longer picks a supplier or creates a PO. It instead opens a
-- `purchase_quote_requests` row and sends a quote-request WhatsApp stub to
-- EVERY known supplier of that item (all `supplier_products` rows, not just
-- the cheapest — GV.md doesn't specify a subset, so "all known suppliers" is
-- the simplest safe reading; documented here per this batch's own
-- instruction not to block on an unspecified UI/selection detail).
--
-- SAFEGUARD (GV.md 3.2, explicitly called out by the owner as required
-- BECAUSE this reverses a working stock-out protection): a
-- `settings.po_quote_timeout_hours` clock (default 24h, GV.md's own example
-- number) starts when the request opens. Once it elapses:
--   - if an admin has logged >=1 supplier reply (see `purchase_quote_replies`
--     / `log_purchase_quote_reply` below) by then, the LOWEST logged price
--     wins;
--   - if NOT ONE supplier has replied by timeout, it falls back to the exact
--     pre-existing behavior — last-known-cheapest/preferred
--     `supplier_products` row — so stock is never permanently stranded
--     waiting on a supplier who may never answer. This is GV.md's own words
--     ("so stock is never stranded"), not an interpretation.
-- Whichever supplier/price wins, PO creation from that point on is
-- byte-for-byte the same branch `_auto_draft_purchase_order` already had
-- (draft+approval-pending vs auto-send), now pulled out into
-- `_create_po_from_winning_quote()` so both the "resolved by reply" and
-- "resolved by fallback" paths share it verbatim. `approve_purchase_order`
-- itself is untouched — once a draft PO exists, its approval gate behaves
-- exactly as it does today.
--
-- ARCHITECTURE: no pg_cron (verified — grep the whole migrations/ tree,
-- only comments mentioning it as a hypothetical exist, e.g.
-- 20260702110100_service_amc_functions.sql:509 and
-- 20260715300000_operational_alerts.sql:9) and no scheduled Edge Function in
-- supabase/config.toml. So there is no infrastructure to fire a timer at
-- exactly `timeout_at`. This migration reuses the SAME "resolve-on-view"
-- pattern this codebase already established for exactly this gap
-- (refresh_amc_statuses / refresh_operational_alerts — "compute derived
-- state on page load, since nothing scans on a timer"): a new
-- `resolve_purchase_quote_requests(p_org_id)` RPC scans every OPEN request
-- whose `timeout_at` has passed and resolves it. It's called from the
-- Purchase page's new "Quotes" tab on mount (see PurchasePage.tsx /
-- PurchaseQuotesTab.tsx / useAutomation.ts), same shape as
-- useRefreshOperationalAlerts. Still-open (not yet timed out) requests are
-- listed on that tab too, with a "log a supplier's reply" action, so admins
-- are never blind to what's pending. A future pg_cron addition could call
-- the same RPC on a timer with zero further changes.
--
-- BOUNDARY: does not touch `_auto_assign_ticket_internal`, `create_sale`, or
-- `approve_purchase_order` (only calls the latter's already-existing draft
-- flow via the same insert shape it already used).
-- ============================================================================

-- ── 3.2: admin-settable quotation timeout (settings) ─────────────────────
-- Default 24 — GV.md's own example number ("e.g. 24 hrs"), used verbatim per
-- this batch's instruction not to block on confirming it with the owner.
alter table public.settings
  add column if not exists po_quote_timeout_hours numeric(6, 2) not null default 24 check (po_quote_timeout_hours > 0);

-- ── New schema: open quote requests + admin-logged supplier replies ──────
-- One row per reorder event that went to quote-first (the "already open"
-- guard in _auto_draft_purchase_order below prevents more than one open
-- request per org+item at a time, same as the pre-existing open-PO guard).
-- `order_qty` is locked in at request-open time (computed the same way the
-- old trigger computed it immediately) rather than recomputed at
-- resolution — the quantity the low-stock crossing actually called for
-- shouldn't silently drift just because resolution happens hours later.
create table public.purchase_quote_requests (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  inventory_id uuid references public.inventory (id) on delete set null,
  item_type public.item_type not null,
  item_id uuid not null,
  order_qty integer not null check (order_qty > 0),
  status text not null default 'open' check (status in ('open', 'resolved')),
  requested_at timestamptz not null default now(),
  timeout_at timestamptz not null,
  resolved_at timestamptz,
  resolved_po_id uuid references public.purchase_orders (id) on delete set null,
  -- 'reply': a logged supplier reply won. 'fallback': timeout passed with
  -- zero replies, last-known-cheapest was used (the GV.md 3.2 safeguard
  -- path). 'no_supplier': timeout passed, zero replies, AND every
  -- supplier_products link for the item was removed in the meantime — there
  -- is truly nothing left to order against; closed out with a notification
  -- instead of looping forever.
  resolution text check (resolution in ('reply', 'fallback', 'no_supplier')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index purchase_quote_requests_org_status_idx on public.purchase_quote_requests (org_id, status);
create index purchase_quote_requests_item_idx on public.purchase_quote_requests (org_id, item_type, item_id);
create index purchase_quote_requests_timeout_idx on public.purchase_quote_requests (status, timeout_at);

alter table public.purchase_quote_requests enable row level security;

create policy purchase_quote_requests_select_staff on public.purchase_quote_requests
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy purchase_quote_requests_write_ops on public.purchase_quote_requests for all
  using (org_id = public.current_org_id() and public.is_ops_staff())
  with check (org_id = public.current_org_id() and public.is_ops_staff());

-- Suppliers are external (contacted over WhatsApp, not app users) — a reply
-- has to be recorded BY AN ADMIN on the supplier's behalf, per GV.md 3.2's
-- own framing ("based on replies"). One logged reply per (request,
-- supplier); re-logging the same supplier on the same request corrects the
-- price rather than creating a duplicate (see log_purchase_quote_reply's
-- upsert below) — an admin fixing a mis-typed price shouldn't create two
-- competing rows for one supplier.
create table public.purchase_quote_replies (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  request_id uuid not null references public.purchase_quote_requests (id) on delete cascade,
  supplier_id uuid not null references public.suppliers (id) on delete cascade,
  price numeric(12, 2) not null check (price >= 0),
  note text,
  logged_by uuid references public.profiles (id) on delete set null,
  logged_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

create unique index purchase_quote_replies_request_supplier_uq on public.purchase_quote_replies (request_id, supplier_id);
create index purchase_quote_replies_request_idx on public.purchase_quote_replies (request_id);

alter table public.purchase_quote_replies enable row level security;

create policy purchase_quote_replies_select_staff on public.purchase_quote_replies
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy purchase_quote_replies_write_ops on public.purchase_quote_replies for all
  using (org_id = public.current_org_id() and public.is_ops_staff())
  with check (org_id = public.current_org_id() and public.is_ops_staff());

-- ── Shared PO-creation step (moved verbatim from the old trigger body) ───
-- Exactly the old _auto_draft_purchase_order's two branches (draft+approval
-- vs auto-send+dispatch), now parameterized on "whoever won the quote step"
-- instead of inlined after an immediate cheapest-supplier pick. Both the
-- "resolved by reply" and "resolved by fallback" paths in
-- resolve_purchase_quote_requests below call this, so
-- settings.po_requires_approval is honored identically no matter which path
-- produced the winning supplier/price — this migration inserts a step
-- BEFORE PO creation, it does not touch the approval gate itself.
create or replace function public._create_po_from_winning_quote(
  p_org_id uuid,
  p_item_type public.item_type,
  p_item_id uuid,
  p_order_qty integer,
  p_supplier_id uuid,
  p_price numeric,
  p_inventory_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_po_id uuid;
  v_total numeric(12, 2);
  v_threshold numeric(12, 2);
  v_requires_approval boolean;
begin
  select po_approval_threshold, po_requires_approval into v_threshold, v_requires_approval
  from public.settings where org_id = p_org_id;
  v_total := coalesce(p_price, 0) * p_order_qty;

  if v_requires_approval then
    -- Same as the old trigger's ON branch: draft, no dispatch, mandatory
    -- pending approval regardless of amount.
    insert into public.purchase_orders (org_id, supplier_id, status, total)
    values (p_org_id, p_supplier_id, 'draft', v_total)
    returning id into v_po_id;

    insert into public.po_items (org_id, po_id, item_type, item_id, qty, price)
    values (p_org_id, v_po_id, p_item_type, p_item_id, p_order_qty, coalesce(p_price, 0));

    insert into public.approvals (org_id, type, ref_id, requested_by, status)
    select p_org_id, 'po', v_po_id, id, 'pending' from public.profiles where org_id = p_org_id and role = 'master' limit 1;

    insert into public.notifications (org_id, role, type, title, body, ref_id)
    values (
      p_org_id, 'operation_admin', 'low_stock', 'Quote resolved — PO awaiting approval',
      format('A supplier quote was resolved and a draft purchase order for %s units needs approval before it sends.', p_order_qty),
      p_inventory_id
    );

    return v_po_id;
  end if;

  -- Same as the old trigger's OFF branch: send immediately, only the
  -- amount threshold (independent of the toggle) flags it for review.
  insert into public.purchase_orders (org_id, supplier_id, status, total, sent_channel)
  values (p_org_id, p_supplier_id, 'sent', v_total, 'whatsapp')
  returning id into v_po_id;

  insert into public.po_items (org_id, po_id, item_type, item_id, qty, price)
  values (p_org_id, v_po_id, p_item_type, p_item_id, p_order_qty, coalesce(p_price, 0));

  insert into public.whatsapp_outbox (org_id, direction, to_mobile, milestone, template, payload, ref_type, ref_id, status)
  values (p_org_id, 'outbound', (select whatsapp from public.suppliers where id = p_supplier_id), 'po_sent', 'po.auto_sent',
          jsonb_build_object('po_id', v_po_id, 'total', v_total, 'item_type', p_item_type, 'item_id', p_item_id),
          'purchase_order', v_po_id, 'sent');

  insert into public.notifications (org_id, role, type, title, body, ref_id)
  values (
    p_org_id, 'operation_admin', 'low_stock', 'Quote resolved — PO auto-drafted',
    format('A supplier quote was resolved and a purchase order for %s units was auto-drafted and sent.', p_order_qty),
    p_inventory_id
  );

  if v_threshold is not null and v_total > v_threshold then
    insert into public.approvals (org_id, type, ref_id, requested_by, status)
    select p_org_id, 'po', v_po_id, id, 'pending' from public.profiles where org_id = p_org_id and role = 'master' limit 1;
  end if;

  return v_po_id;
end;
$$;

-- ── Reorder trigger: request quotes instead of ordering immediately ──────
-- Based on the truly-latest _auto_draft_purchase_order
-- (20260722110000_reorder_formula_and_po_approval_toggle.sql). C1's
-- max_stock-based order-qty formula is UNCHANGED — only what happens after
-- computing v_order_qty changes (used to create a PO immediately; now opens
-- a quote request). The "already open" guard is widened to also cover an
-- already-open quote request, so a still-below-min-stock item that keeps
-- getting inventory writes doesn't spawn a second concurrent quote request
-- before the first one resolves.
create or replace function public._auto_draft_purchase_order()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order_qty integer;
  v_already_open boolean;
  v_has_supplier boolean;
  v_timeout_hours numeric(6, 2);
  v_request_id uuid;
begin
  if new.stock_qty > new.min_stock or (old.stock_qty is not null and old.stock_qty <= old.min_stock) then
    return new;
  end if;

  select exists (
    select 1
    from public.po_items poi
    join public.purchase_orders po on po.id = poi.po_id
    where po.org_id = new.org_id and po.status in ('draft', 'sent')
      and poi.item_type = new.item_type and poi.item_id = new.item_id
  ) or exists (
    select 1 from public.purchase_quote_requests qr
    where qr.org_id = new.org_id and qr.status = 'open'
      and qr.item_type = new.item_type and qr.item_id = new.item_id
  ) into v_already_open;
  if v_already_open then
    insert into public.notifications (org_id, role, type, title, body, ref_id)
    values (
      new.org_id, 'operation_admin', 'low_stock', 'Stock critical (reorder already in progress)',
      format('Stock for this %s is at %s (min %s). A purchase order or open supplier quote request already covers it.', new.item_type, new.stock_qty, new.min_stock),
      new.id
    );
    return new;
  end if;

  select exists (
    select 1 from public.supplier_products
    where org_id = new.org_id and item_type = new.item_type and item_id = new.item_id
  ) into v_has_supplier;
  if not v_has_supplier then
    -- Same early-return as before: no known supplier means no PO and now
    -- also no quote request is possible.
    return new;
  end if;

  -- C1 formula, unchanged.
  v_order_qty := greatest(1, coalesce(new.max_stock, new.min_stock + new.reorder_qty) - new.stock_qty);

  select po_quote_timeout_hours into v_timeout_hours from public.settings where org_id = new.org_id;
  v_timeout_hours := coalesce(v_timeout_hours, 24);

  insert into public.purchase_quote_requests (org_id, inventory_id, item_type, item_id, order_qty, status, requested_at, timeout_at)
  values (new.org_id, new.id, new.item_type, new.item_id, v_order_qty, 'open', now(), now() + (v_timeout_hours * interval '1 hour'))
  returning id into v_request_id;

  -- GV.md 3.1: quote-request WhatsApp stub to EVERY known supplier of the
  -- item (not just the cheapest) — same insert shape as every other
  -- whatsapp_outbox call site (e.g. the po.auto_sent dispatch below).
  insert into public.whatsapp_outbox (org_id, direction, to_mobile, milestone, template, payload, ref_type, ref_id, status)
  select new.org_id, 'outbound', s.whatsapp, 'po_quote_request', 'po.quote_request',
         jsonb_build_object('request_id', v_request_id, 'item_type', new.item_type, 'item_id', new.item_id, 'order_qty', v_order_qty),
         'purchase_quote_request', v_request_id, 'sent'
  from public.supplier_products sp
  join public.suppliers s on s.id = sp.supplier_id
  where sp.org_id = new.org_id and sp.item_type = new.item_type and sp.item_id = new.item_id;

  insert into public.notifications (org_id, role, type, title, body, ref_id)
  values (
    new.org_id, 'operation_admin', 'low_stock', 'Stock critical — quote requests sent',
    format('Stock for this %s is at %s (min %s). Quote requests were sent to all known suppliers for %s units; the lowest logged reply (or last-known-cheapest if nobody replies) will be ordered automatically after %s hours.', new.item_type, new.stock_qty, new.min_stock, v_order_qty, v_timeout_hours),
    new.id
  );

  return new;
end;
$$;

-- ── Resolve-on-view: close out timed-out quote requests ───────────────────
-- No pg_cron / scheduled function exists in this stack (verified — see the
-- header comment). Called from the Purchase page's Quotes tab on mount,
-- same "compute on page load" shape as refresh_operational_alerts /
-- refresh_amc_statuses. Gated to is_ops_staff (matches the write_ops policy
-- level on purchase_orders/po_items/supplier_products, since this creates
-- real POs) — a plain staff viewer (sales_admin) can still SELECT the
-- resulting rows via the select_staff policies above, they just don't
-- trigger resolution themselves.
create or replace function public.resolve_purchase_quote_requests(p_org_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_req record;
  v_best_supplier uuid;
  v_best_price numeric(12, 2);
  v_po_id uuid;
  v_resolution text;
  v_resolved_count integer := 0;
begin
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'resolve_purchase_quote_requests: org mismatch';
  end if;
  if not public.is_ops_staff() then
    raise exception 'resolve_purchase_quote_requests: caller is not ops staff';
  end if;

  -- FOR UPDATE SKIP LOCKED: two admins opening the Quotes tab at the same
  -- moment must not both resolve (and double-PO) the same request — the
  -- same double-dispatch race approve_purchase_order already guards against
  -- via its UPDATE...WHERE-status pattern, applied here via row locking
  -- instead since this loops over a set rather than updating one row.
  for v_req in
    select *
    from public.purchase_quote_requests
    where org_id = p_org_id and status = 'open' and timeout_at <= now()
    order by requested_at
    for update skip locked
  loop
    v_best_supplier := null;
    v_best_price := null;

    select r.supplier_id, r.price into v_best_supplier, v_best_price
    from public.purchase_quote_replies r
    where r.request_id = v_req.id
    order by r.price asc, r.logged_at asc
    limit 1;

    if v_best_supplier is not null then
      v_resolution := 'reply';
    else
      -- GV.md 3.2 SAFEGUARD: nobody replied by timeout — fall back to the
      -- exact pre-quote-first behavior (last-known-cheapest/preferred
      -- supplier_products row), so the reorder is never stranded waiting on
      -- a supplier who may never answer.
      select supplier_id, price into v_best_supplier, v_best_price
      from public.supplier_products
      where org_id = v_req.org_id and item_type = v_req.item_type and item_id = v_req.item_id
      order by is_preferred desc, price asc
      limit 1;
      v_resolution := 'fallback';
    end if;

    if v_best_supplier is null then
      -- Every supplier_products link for the item was removed after the
      -- request was opened — nothing left to fall back to. Close the
      -- request out (don't leave it perpetually "open past timeout",
      -- re-scanned forever) and flag for manual purchasing.
      update public.purchase_quote_requests
      set status = 'resolved', resolved_at = now(), resolution = 'no_supplier', updated_at = now()
      where id = v_req.id;

      insert into public.notifications (org_id, role, type, title, body, ref_id)
      values (
        v_req.org_id, 'operation_admin', 'low_stock', 'Quote request expired — no supplier available',
        format('Quote requests for this %s timed out with no replies, and no supplier is linked to it anymore. Order manually.', v_req.item_type),
        v_req.inventory_id
      );
    else
      v_po_id := public._create_po_from_winning_quote(
        v_req.org_id, v_req.item_type, v_req.item_id, v_req.order_qty, v_best_supplier, v_best_price, v_req.inventory_id
      );

      update public.purchase_quote_requests
      set status = 'resolved', resolved_at = now(), resolved_po_id = v_po_id, resolution = v_resolution, updated_at = now()
      where id = v_req.id;
    end if;

    v_resolved_count := v_resolved_count + 1;
  end loop;

  return v_resolved_count;
end;
$$;

grant execute on function public.resolve_purchase_quote_requests(uuid) to authenticated;

-- ── Admin logs a supplier's phoned/WhatsApped-back price ──────────────────
-- Suppliers aren't app users, so their reply can only ever be recorded by an
-- admin on their behalf (GV.md 3.1/3.2). Upsert on (request_id, supplier_id)
-- so correcting a mis-typed price re-logs rather than duplicates. Only
-- valid against a still-open request and a supplier that was actually sent
-- a quote request for this item (i.e. has a supplier_products link for it)
-- — guards against logging a reply from an uninvited supplier.
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

  return v_reply_id;
end;
$$;

grant execute on function public.log_purchase_quote_reply(uuid, uuid, numeric, text) to authenticated;
