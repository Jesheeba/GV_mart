-- Supplier RFQ automation over WhatsApp — closes the two gaps identified
-- against the existing quote-first flow (20260725120000_po_quotation_
-- first_with_timeout_safeguard.sql / 20260729100000_reorder_max_stock_only.sql):
--
-- Gap A: the WhatsApp router had no concept of "the other party is a
-- supplier, not a customer" — wa_identify_supplier below is the check;
-- wiring it into handleMessage() happens in whatsapp-handle-message.ts, not
-- here (this migration is schema/RPC only).
-- Gap B: nothing turned a supplier's free-text reply into a
-- purchase_quote_replies row automatically — wa_log_quote_reply below is
-- the bot-facing write path the extraction module calls into.
--
-- Also fixes "Blocker 0": _auto_draft_purchase_order's fan-out to suppliers
-- inserted directly into whatsapp_outbox with status='sent' hardcoded and no
-- `body` in payload — it never went through sendMessage() (the real Wasi
-- transport) or wa-milestone-dispatch (the poller that pushes stub rows
-- through sendMessage()), so no supplier has ever actually received this
-- message. Fixed by giving the insert the same shape wa-milestone-dispatch
-- already knows how to pick up (a real payload.body, ref_type it will now
-- watch for) — see wa-milestone-dispatch/index.ts's MILESTONE_REF_TYPES
-- change in the same PR.
--
-- Explicitly does NOT touch: purchase_quote_requests, resolve_purchase_
-- quote_requests, log_purchase_quote_reply (the human-facing RPC — kept
-- is_ops_staff-gated exactly as-is), settings.po_requires_approval/
-- po_approval_threshold, _create_po_from_winning_quote, approve_purchase_
-- order. Everything downstream of a row landing in purchase_quote_replies
-- is unchanged, whether that row was written by an admin or by this
-- automation.

-- ── Shared item-name resolution ───────────────────────────────────────────
-- item_type/item_id is polymorphic across products/spares/gifts (same shape
-- services/suppliers.ts's listSupplierProducts already resolves client-side
-- for the admin UI) — needed here for a readable quote-request message body
-- and for describing an unparsed reply to the admin.
create or replace function public._wa_item_display_name(p_org_id uuid, p_item_type public.item_type, p_item_id uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select case p_item_type
    when 'product' then (select name from public.products where id = p_item_id and org_id = p_org_id)
    when 'spare' then (select name from public.spares where id = p_item_id and org_id = p_org_id)
    when 'gift' then (select name from public.gifts where id = p_item_id and org_id = p_org_id)
  end;
$$;

-- ── Blocker 0 fix: real, readable, actually-dispatched quote requests ────
-- Same guard/quote-request-open logic as 20260729100000's version, verbatim
-- — only the whatsapp_outbox fan-out changes (a loop instead of a set-based
-- insert, so each supplier gets a name-personalized rendered body).
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
  v_item_name text;
  v_supplier record;
  v_rendered jsonb;
  v_body text;
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
    return new;
  end if;

  v_order_qty := greatest(1, new.max_stock - new.stock_qty);
  v_item_name := coalesce(public._wa_item_display_name(new.org_id, new.item_type, new.item_id), 'an item');

  select po_quote_timeout_hours into v_timeout_hours from public.settings where org_id = new.org_id;
  v_timeout_hours := coalesce(v_timeout_hours, 24);

  insert into public.purchase_quote_requests (org_id, inventory_id, item_type, item_id, order_qty, status, requested_at, timeout_at)
  values (new.org_id, new.id, new.item_type, new.item_id, v_order_qty, 'open', now(), now() + (v_timeout_hours * interval '1 hour'))
  returning id into v_request_id;

  -- One row per invited supplier, each with its own rendered/fallback body
  -- — this is what wa-milestone-dispatch now finds and pushes through
  -- sendMessage() (Blocker 0 fix; see that function's MILESTONE_REF_TYPES).
  for v_supplier in
    select s.id, s.whatsapp, s.name
    from public.supplier_products sp
    join public.suppliers s on s.id = sp.supplier_id
    where sp.org_id = new.org_id and sp.item_type = new.item_type and sp.item_id = new.item_id
  loop
    if v_supplier.whatsapp is null then
      -- Nothing to dispatch to. The purchase_quote_requests row and the
      -- admin notification below still cover this item; skip creating a
      -- phantom outbox row with a null destination.
      continue;
    end if;

    v_rendered := public._wa_render_template(
      new.org_id, 'po.quote_request',
      jsonb_build_object('supplier_name', v_supplier.name, 'item_name', v_item_name, 'order_qty', v_order_qty::text)
    );
    -- Deliberately deviates from the customer milestone triggers (which
    -- leave payload.body empty when no whatsapp_templates row exists): no
    -- migration has ever seeded ANY milestone template (checked
    -- supabase/seed/seed.ts), so relying solely on _wa_render_template
    -- would leave this path silently non-functional the same way Blocker 0
    -- was. An admin can still override the wording later via Automation >
    -- Templates (row name "po.quote_request") with no code change.
    v_body := case when (v_rendered ->> 'found')::boolean then v_rendered ->> 'body'
      else format('Hi %s, we need a quote for %s (qty: %s). Please reply with your price per unit (and delivery time if possible). - GV Mart', v_supplier.name, v_item_name, v_order_qty)
    end;

    insert into public.whatsapp_outbox (org_id, direction, to_mobile, milestone, template, type, payload, ref_type, ref_id, status)
    values (
      new.org_id, 'outbound', v_supplier.whatsapp, 'po_quote_request', 'po.quote_request',
      case when (v_rendered ->> 'found')::boolean then 'template' else 'text' end,
      jsonb_build_object('request_id', v_request_id, 'item_type', new.item_type, 'item_id', new.item_id, 'order_qty', v_order_qty, 'supplier_id', v_supplier.id, 'body', v_body),
      'purchase_quote_request', v_request_id, 'sent'
    );
  end loop;

  insert into public.notifications (org_id, role, type, title, body, ref_id)
  values (
    new.org_id, 'operation_admin', 'low_stock', 'Stock critical — quote requests sent',
    format('Stock for this %s is at %s (min %s). Quote requests were sent to all known suppliers for %s units; the lowest logged reply (or last-known-cheapest if nobody replies) will be ordered automatically after %s hours.', new.item_type, new.stock_qty, new.min_stock, v_order_qty, v_timeout_hours),
    new.id
  );

  return new;
end;
$$;

-- ── Gap A: recognize an inbound WhatsApp number as a supplier ────────────
-- Same shape as wa_identify_customer (20260819120000_whatsapp_bot_rpcs.sql):
-- normalize, look up, return a plain found:false rather than throwing when
-- nothing matches (throwing is reserved for a genuinely malformed phone
-- number, matching wa_identify_customer's own contract — this runs BEFORE
-- wa_identify_customer in handleMessage, so it inherits first refusal on a
-- bad number either way). suppliers.whatsapp has no format constraint (free
-- text, entered via the admin Suppliers UI), so it's normalized at compare
-- time rather than assumed already-bare-10-digit like customers.mobile.
create or replace function public.wa_identify_supplier(p_org_id uuid, p_phone text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_phone text;
  v_supplier public.suppliers;
begin
  v_phone := public._wa_normalize_phone(p_phone);
  if v_phone is null then
    raise exception 'wa_identify_supplier: % is not a resolvable phone number', p_phone;
  end if;

  select * into v_supplier from public.suppliers
  where org_id = p_org_id and public._wa_normalize_phone(whatsapp) = v_phone
  limit 1;

  if v_supplier.id is null then
    return jsonb_build_object('found', false, 'phone', v_phone);
  end if;

  return jsonb_build_object('found', true, 'supplier_id', v_supplier.id, 'name', v_supplier.name, 'phone', v_phone);
end;
$$;

-- Intentionally NOT granted to authenticated — service_role only (decision #3, whatsapp_bot_rpcs.sql), same as wa_identify_customer.

-- ── Gap A2: open quote requests this supplier was actually invited to ────
-- Scoped through supplier_products (not just "any open request in the org")
-- so a reply can only ever attribute to a request this supplier was
-- genuinely sent — same invitation check log_purchase_quote_reply already
-- enforces. Used by handleSupplierReply for count-based disambiguation:
-- 0 -> not a quote reply, 1 -> unambiguous, >1 -> flag for manual review.
create or replace function public.wa_supplier_open_quote_requests(p_org_id uuid, p_supplier_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'request_id', qr.id,
    'item_type', qr.item_type,
    'item_id', qr.item_id,
    'item_name', public._wa_item_display_name(qr.org_id, qr.item_type, qr.item_id),
    'order_qty', qr.order_qty,
    'requested_at', qr.requested_at
  ) order by qr.requested_at), '[]'::jsonb)
  from public.purchase_quote_requests qr
  where qr.org_id = p_org_id and qr.status = 'open'
    and exists (
      select 1 from public.supplier_products sp
      where sp.org_id = qr.org_id and sp.supplier_id = p_supplier_id
        and sp.item_type = qr.item_type and sp.item_id = qr.item_id
    );
$$;

-- Intentionally NOT granted to authenticated — service_role only (decision #3).

-- ── Gap B3: bot-facing analog of log_purchase_quote_reply ────────────────
-- Byte-for-byte the same validation/upsert as log_purchase_quote_reply
-- (20260725120000), MINUS the is_ops_staff() gate: the webhook calls
-- Postgres with the service_role key, so there is no auth.uid() and that
-- check would always fail (see decision #3's own reasoning for why every
-- bot RPC is its own ungated, explicitly-org-scoped function rather than
-- reusing a staff-gated one). log_purchase_quote_reply itself is untouched
-- — the admin-facing manual-logging path keeps its existing auth contract
-- exactly as-is; this is a separate entry point into the same table.
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

  return v_reply_id;
end;
$$;

-- Intentionally NOT granted to authenticated — service_role only (decision #3).
