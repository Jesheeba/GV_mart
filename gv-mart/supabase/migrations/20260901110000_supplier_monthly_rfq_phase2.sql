-- Supplier Monthly RFQ pipeline — Phase 2: the calendar trigger itself,
-- reliable auto-resolve (not just resolve-on-view), "mark as no response",
-- and the low-stock gate on PO creation. Builds on Phase 1
-- (20260901100000_supplier_monthly_rfq_phase1.sql).
--
-- Every new/changed function below applies the same correctness rules used
-- throughout this feature (per the approved plan's cross-cutting section):
--   - date/time comparisons use IST explicitly, never bare now()/current_date
--   - concurrency guards are a single atomic UPDATE...WHERE (state-flip-as-
--     lock), matching approve_purchase_order's existing idiom — never a
--     separate read-then-write
--   - a pending-state RPC re-verifies that state itself rather than trusting
--     the caller's view of it

-- ── "Mark as no response" — admin can settle a supplier that isn't going to
-- reply, so the Quotes tab stops showing them as awaiting forever. This has
-- ZERO effect on how resolve_purchase_quote_requests picks a winner — a
-- supplier with no purchase_quote_replies row was never a resolution
-- candidate whether dismissed or not. It's purely bookkeeping for the admin
-- UI's comparison table (see PurchaseQuotesTab.tsx).
create table public.purchase_quote_dismissals (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  request_id uuid not null references public.purchase_quote_requests (id) on delete cascade,
  supplier_id uuid not null references public.suppliers (id) on delete cascade,
  dismissed_by uuid references public.profiles (id) on delete set null,
  dismissed_at timestamptz not null default now()
);

create unique index purchase_quote_dismissals_request_supplier_uq on public.purchase_quote_dismissals (request_id, supplier_id);
create index purchase_quote_dismissals_request_idx on public.purchase_quote_dismissals (request_id);

alter table public.purchase_quote_dismissals enable row level security;

create policy purchase_quote_dismissals_select_staff on public.purchase_quote_dismissals
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy purchase_quote_dismissals_write_ops on public.purchase_quote_dismissals for all
  using (org_id = public.current_org_id() and public.is_ops_staff())
  with check (org_id = public.current_org_id() and public.is_ops_staff());

create or replace function public.mark_quote_supplier_no_response(p_request_id uuid, p_supplier_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_req public.purchase_quote_requests;
  v_id uuid;
begin
  if not public.is_ops_staff() then
    raise exception 'mark_quote_supplier_no_response: caller is not ops staff';
  end if;

  -- Re-verified here, not trusted from the caller's (possibly stale) view of
  -- the request — same discipline as log_purchase_quote_reply's own guard.
  select * into v_req from public.purchase_quote_requests
  where id = p_request_id and org_id = public.current_org_id();
  if v_req.id is null then
    raise exception 'mark_quote_supplier_no_response: quote request % not found', p_request_id;
  end if;
  if v_req.status is distinct from 'open' then
    raise exception 'mark_quote_supplier_no_response: quote request % is already resolved', p_request_id;
  end if;

  if not exists (
    select 1 from public.supplier_products
    where org_id = v_req.org_id and supplier_id = p_supplier_id
      and item_type = v_req.item_type and item_id = v_req.item_id
  ) then
    raise exception 'mark_quote_supplier_no_response: supplier % was not invited to this request', p_supplier_id;
  end if;

  if exists (select 1 from public.purchase_quote_replies where request_id = p_request_id and supplier_id = p_supplier_id) then
    raise exception 'mark_quote_supplier_no_response: supplier % already logged a reply for this request', p_supplier_id;
  end if;

  insert into public.purchase_quote_dismissals (org_id, request_id, supplier_id, dismissed_by)
  values (v_req.org_id, p_request_id, p_supplier_id, auth.uid())
  on conflict (request_id, supplier_id) do nothing
  returning id into v_id;

  return v_id;
end;
$$;

grant execute on function public.mark_quote_supplier_no_response(uuid, uuid) to authenticated;

-- ── Low-stock gate + service-role auto-resolve twin ───────────────────────
-- resolve_purchase_quote_requests's loop body is extracted into a private
-- core so it can be called both from the existing staff-gated wrapper
-- (unchanged signature/grant — PurchaseQuotesTab.tsx keeps working exactly
-- as before) and from a new service-role wrapper the cron job calls, same
-- split already used for wa_log_quote_reply vs log_purchase_quote_reply.
alter table public.purchase_quote_requests drop constraint if exists purchase_quote_requests_resolution_check;
alter table public.purchase_quote_requests add constraint purchase_quote_requests_resolution_check
  check (resolution in ('reply', 'fallback', 'no_supplier', 'no_po_not_low_stock'));

create or replace function public._resolve_purchase_quote_requests_core(p_org_id uuid)
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
  v_stock_qty integer;
  v_min_stock integer;
begin
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
      select supplier_id, price into v_best_supplier, v_best_price
      from public.supplier_products
      where org_id = v_req.org_id and item_type = v_req.item_type and item_id = v_req.item_id
      order by is_preferred desc, price asc
      limit 1;
      v_resolution := 'fallback';
    end if;

    if v_best_supplier is null then
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
      -- NEW: only actually place an order if the item is still at/below its
      -- minimum stock right now — a monthly price-refresh request (opened
      -- for every supplier-linked item, not just low-stock ones) should
      -- record the winning price for comparison without auto-ordering
      -- something that was never actually short. Scoped to the warehouse
      -- location, matching where supplier reordering happens (vans are
      -- restocked from the warehouse, not ordered from suppliers directly).
      select stock_qty, min_stock into v_stock_qty, v_min_stock
      from public.inventory
      where org_id = v_req.org_id and item_type = v_req.item_type and item_id = v_req.item_id and location = 'warehouse';

      if v_stock_qty is not null and v_stock_qty > v_min_stock then
        update public.purchase_quote_requests
        set status = 'resolved', resolved_at = now(), resolution = 'no_po_not_low_stock', updated_at = now()
        where id = v_req.id;
        -- Deliberately no notification here — this is the expected, routine
        -- outcome for most items on a monthly batch, not an alert-worthy
        -- event. The winning price is still visible in the Quotes tab's
        -- resolved list and already landed in supplier_products via
        -- wa_log_quote_reply/log_purchase_quote_reply's price write-back.
      else
        v_po_id := public._create_po_from_winning_quote(
          v_req.org_id, v_req.item_type, v_req.item_id, v_req.order_qty, v_best_supplier, v_best_price, v_req.inventory_id
        );

        update public.purchase_quote_requests
        set status = 'resolved', resolved_at = now(), resolved_po_id = v_po_id, resolution = v_resolution, updated_at = now()
        where id = v_req.id;
      end if;
    end if;

    v_resolved_count := v_resolved_count + 1;
  end loop;

  return v_resolved_count;
end;
$$;

-- Public, staff-gated wrapper — unchanged contract from the original
-- resolve_purchase_quote_requests (same signature, same grant), just now
-- delegating its loop body to the shared core above.
create or replace function public.resolve_purchase_quote_requests(p_org_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'resolve_purchase_quote_requests: org mismatch';
  end if;
  if not public.is_ops_staff() then
    raise exception 'resolve_purchase_quote_requests: caller is not ops staff';
  end if;

  return public._resolve_purchase_quote_requests_core(p_org_id);
end;
$$;

grant execute on function public.resolve_purchase_quote_requests(uuid) to authenticated;

-- Service-role twin — no auth.uid()/current_org_id() available when called
-- from wa-scheduled-tasks with the service_role key, same reasoning as
-- every other wa_*/service-only RPC in this feature (decision #3).
create or replace function public.wa_resolve_purchase_quote_requests(p_org_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
begin
  return public._resolve_purchase_quote_requests_core(p_org_id);
end;
$$;

-- Intentionally NOT granted to authenticated — service_role only.

-- ── Monthly calendar RFQ trigger ──────────────────────────────────────────
-- Called from wa-scheduled-tasks on its existing (GH-Actions-fixed, 5-min)
-- schedule — see that function for why there's no pg_cron here. Every
-- distinct item with at least one supplier_products link gets a fresh
-- quote request this month (keeps pricing current org-wide); which of
-- those actually turn into a PO is decided later, per-item, by the
-- low-stock gate just added to _resolve_purchase_quote_requests_core.
create or replace function public.open_monthly_quote_requests(p_org_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_today_ist date := (now() at time zone 'Asia/Kolkata')::date;
  v_this_month text := to_char(v_today_ist, 'YYYY-MM');
  v_timeout_hours numeric(6, 2);
  v_item record;
  v_supplier record;
  v_order_qty integer;
  v_already_open boolean;
  v_request_id uuid;
  v_item_name text;
  v_rendered jsonb;
  v_body text;
  v_count integer := 0;
  v_inv_id uuid;
  v_inv_stock integer;
  v_inv_max integer;
begin
  -- Atomic claim: the WHERE clause is the entire concurrency guard (same
  -- state-flip-as-lock idiom as approve_purchase_order) — if today isn't
  -- the configured day, or this month already ran, the UPDATE matches zero
  -- rows and we return immediately. Two overlapping invocations for the
  -- same org can't both pass this and open two batches for the month.
  update public.settings
  set po_quote_last_run_month = v_this_month
  where org_id = p_org_id
    and po_quote_day_of_month is not null
    and po_quote_day_of_month = extract(day from v_today_ist)::int
    and po_quote_last_run_month is distinct from v_this_month
  returning po_quote_timeout_hours into v_timeout_hours;

  if not found then
    return 0;
  end if;
  v_timeout_hours := coalesce(v_timeout_hours, 24);

  for v_item in
    select distinct sp.item_type, sp.item_id
    from public.supplier_products sp
    where sp.org_id = p_org_id
  loop
    -- Same "already covered" guard as the reactive trigger — don't
    -- duplicate a reorder that's already in flight for this item.
    select exists (
      select 1 from public.po_items poi join public.purchase_orders po on po.id = poi.po_id
      where po.org_id = p_org_id and po.status in ('draft', 'sent')
        and poi.item_type = v_item.item_type and poi.item_id = v_item.item_id
    ) or exists (
      select 1 from public.purchase_quote_requests qr
      where qr.org_id = p_org_id and qr.status = 'open'
        and qr.item_type = v_item.item_type and qr.item_id = v_item.item_id
    ) into v_already_open;
    if v_already_open then
      continue;
    end if;

    -- Only an item actually tracked in the warehouse can be quoted for —
    -- same basis _auto_draft_purchase_order uses for order_qty.
    select id, stock_qty, max_stock into v_inv_id, v_inv_stock, v_inv_max
    from public.inventory
    where org_id = p_org_id and item_type = v_item.item_type and item_id = v_item.item_id and location = 'warehouse';
    if v_inv_id is null then
      continue;
    end if;
    v_order_qty := greatest(1, v_inv_max - v_inv_stock);

    v_item_name := coalesce(public._wa_item_display_name(p_org_id, v_item.item_type, v_item.item_id), 'an item');

    insert into public.purchase_quote_requests (org_id, inventory_id, item_type, item_id, order_qty, status, requested_at, timeout_at)
    values (p_org_id, v_inv_id, v_item.item_type, v_item.item_id, v_order_qty, 'open', now(), now() + (v_timeout_hours * interval '1 hour'))
    returning id into v_request_id;

    for v_supplier in
      select s.id, s.whatsapp, s.name
      from public.supplier_products sp
      join public.suppliers s on s.id = sp.supplier_id
      where sp.org_id = p_org_id and sp.item_type = v_item.item_type and sp.item_id = v_item.item_id
    loop
      if v_supplier.whatsapp is null then
        continue;
      end if;

      v_rendered := public._wa_render_template(
        p_org_id, 'po.quote_request',
        jsonb_build_object('supplier_name', v_supplier.name, 'item_name', v_item_name, 'order_qty', v_order_qty::text)
      );
      v_body := case when (v_rendered ->> 'found')::boolean then v_rendered ->> 'body'
        else format('Hi %s, monthly price check - please reply with your current price for %s (qty: %s) and delivery time if possible. - GV Mart', v_supplier.name, v_item_name, v_order_qty)
      end;

      insert into public.whatsapp_outbox (org_id, direction, to_mobile, milestone, template, type, payload, ref_type, ref_id, status)
      values (
        p_org_id, 'outbound', v_supplier.whatsapp, 'po_quote_request', 'po.quote_request',
        case when (v_rendered ->> 'found')::boolean then 'template' else 'text' end,
        jsonb_build_object('request_id', v_request_id, 'item_type', v_item.item_type, 'item_id', v_item.item_id, 'order_qty', v_order_qty, 'supplier_id', v_supplier.id, 'body', v_body),
        'purchase_quote_request', v_request_id, 'sent'
      );
    end loop;

    v_count := v_count + 1;
  end loop;

  if v_count > 0 then
    insert into public.notifications (org_id, role, type, title, body, ref_id)
    values (
      p_org_id, 'operation_admin', 'monthly_rfq_sent', 'Monthly supplier price check sent',
      format('Quote requests were sent to every known supplier for %s item(s) as this month''s scheduled price check. Only items still at or below their minimum stock when replies resolve will actually be ordered — see Purchase > Quotes.', v_count),
      null
    );
  end if;

  return v_count;
end;
$$;

-- Intentionally NOT granted to authenticated — service_role only, called from wa-scheduled-tasks.
