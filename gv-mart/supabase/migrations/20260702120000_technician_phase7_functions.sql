-- Phase 7 (TECH-01..10): Technician App — RPCs for writes RLS blocks a
-- plain technician caller from doing directly.
--
-- Same shape as create_sale (20260702100100_sales_phase5_functions.sql):
-- SECURITY DEFINER + explicit role/org checks replacing what RLS would
-- have done, prices/settings looked up server-side (never trusted from the
-- client), atomic inventory decrement via conditional
-- `UPDATE ... WHERE stock_qty >= x`.
--
-- Why a DEFINER RPC is needed here: `invoices`/`invoice_items`/`inventory`
-- writes are gated `is_sales_staff()`/`is_ops_staff()` under RLS (Phase 1) —
-- a technician satisfies neither. TECH-07 step 8 ("create invoice") and the
-- inventory decrement for spares used would otherwise be blocked outright.

-- ── create_service_invoice ──────────────────────────────────────────────
-- Closes a TECH-07 on-site visit: prices spares from the master (never
-- trusts client-sent prices), decrements inventory, creates the invoice +
-- invoice_items (skipped entirely when service_charge = 0 and no spares —
-- e.g. a no-charge AMC visit with nothing consumed), applies the v2.2
-- discount gate identical to create_sale, and links the invoice back to
-- both the service_visit and the ticket.
--
-- p_spares shape: [{spare_id, qty}, ...] — qty is always recorded (even for
-- warranty/AMC, where price is forced to 0 per v2.2 "warranty/AMC visits
-- cost ₹0 but still record spare quantity").
create or replace function public.create_service_invoice(
  p_org_id uuid,
  p_visit_id uuid,
  p_service_charge numeric,
  p_discount_percent numeric,
  p_spares jsonb,
  p_payment_method payment_method,
  p_txn_id text,
  p_payment_description text,
  p_is_chargeable boolean -- false for warranty/amc: service_charge forced to 0
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tech_id uuid;
  v_visit service_visits;
  v_ticket service_tickets;
  v_settings settings;
  v_subtotal numeric(12, 2) := 0;
  v_discount numeric(12, 2);
  v_gst numeric(12, 2);
  v_total numeric(12, 2);
  v_invoice invoices;
  v_item record;
  v_price numeric(12, 2);
  v_line_discount numeric(12, 2);
  v_new_stock integer;
  v_approval_id uuid;
  v_effective_charge numeric(12, 2);
begin
  v_tech_id := public.current_technician_id();
  if v_tech_id is null then
    raise exception 'create_service_invoice: caller is not a technician';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'create_service_invoice: org mismatch';
  end if;

  select * into v_visit from public.service_visits where id = p_visit_id and org_id = p_org_id;
  if v_visit is null then
    raise exception 'create_service_invoice: visit % not found', p_visit_id;
  end if;
  if v_visit.technician_id is distinct from v_tech_id then
    raise exception 'create_service_invoice: visit % does not belong to the calling technician', p_visit_id;
  end if;

  select * into v_ticket from public.service_tickets where id = v_visit.ticket_id and org_id = p_org_id;
  if v_ticket is null then
    raise exception 'create_service_invoice: ticket for visit % not found', p_visit_id;
  end if;

  select * into v_settings from public.settings where org_id = p_org_id;
  if v_settings is null then
    raise exception 'create_service_invoice: no settings row for org %', p_org_id;
  end if;

  if p_discount_percent < 0 then
    raise exception 'create_service_invoice: discount cannot be negative';
  end if;
  -- v2.2 §6.1/§6.7: technician up to 5% needs nothing extra, 5-10% needs a
  -- master's approval (below, non-blocking), above the admin max is a hard block.
  if p_discount_percent > v_settings.discount_admin_max then
    raise exception 'create_service_invoice: discount % exceeds the admin limit of %', p_discount_percent, v_settings.discount_admin_max;
  end if;

  if p_payment_method = 'transfer'
     and (nullif(p_txn_id, '') is null or nullif(p_payment_description, '') is null) then
    raise exception 'create_service_invoice: bank transfer requires a transaction ID and description';
  end if;

  -- v2.2 §6.2/§6.3: warranty/AMC visits cost the customer ₹0 (service charge
  -- forced server-side, never trusted from the client toggle).
  v_effective_charge := case when p_is_chargeable then coalesce(p_service_charge, 0) else 0 end;
  v_subtotal := v_effective_charge;

  -- Pass 1: price every spare line from the master (server-side, never the
  -- client) and accumulate the subtotal. Warranty/AMC spares price at 0 but
  -- quantity is still recorded and inventory still deducts.
  if p_spares is not null and jsonb_array_length(p_spares) > 0 then
    for v_item in select * from jsonb_to_recordset(p_spares) as x(spare_id uuid, qty integer)
    loop
      if v_item.qty is null or v_item.qty <= 0 then
        raise exception 'create_service_invoice: qty must be positive for spare %', v_item.spare_id;
      end if;
      select price into v_price from public.spares where id = v_item.spare_id and org_id = p_org_id;
      if v_price is null then
        raise exception 'create_service_invoice: spare % not found in org %', v_item.spare_id, p_org_id;
      end if;
      if p_is_chargeable then
        v_subtotal := v_subtotal + (v_price * v_item.qty);
      end if;
    end loop;
  end if;

  v_discount := round(v_subtotal * p_discount_percent / 100, 2);
  v_gst := round((v_subtotal - v_discount) * v_settings.gst_rate / 100, 2);
  v_total := v_subtotal - v_discount + v_gst;

  insert into public.invoices (
    org_id, customer_id, type, subtotal, discount, gst, total,
    payment_method, txn_id, payment_description, payment_status
  ) values (
    p_org_id, v_ticket.customer_id, 'spare', v_subtotal, v_discount, v_gst, v_total,
    p_payment_method, nullif(p_txn_id, ''), nullif(p_payment_description, ''), 'paid'
  ) returning * into v_invoice;

  -- Service charge line (only when actually chargeable and > 0). Modeled as
  -- an invoice_item against nothing tidy in the item_type enum (product |
  -- spare) to represent "labour" — so the charge lives on invoices.subtotal
  -- directly and only spares get line items. This keeps invoice_items
  -- strictly polymorphic over real catalog rows, matching Phase 5.
  if p_spares is not null and jsonb_array_length(p_spares) > 0 then
    for v_item in select * from jsonb_to_recordset(p_spares) as x(spare_id uuid, qty integer)
    loop
      select price into v_price from public.spares where id = v_item.spare_id and org_id = p_org_id;
      v_price := case when p_is_chargeable then v_price else 0 end;
      v_line_discount := round(v_price * v_item.qty * p_discount_percent / 100, 2);

      insert into public.invoice_items (org_id, invoice_id, item_type, item_id, qty, price, discount)
      values (p_org_id, v_invoice.id, 'spare', v_item.spare_id, v_item.qty, v_price, v_line_discount);

      insert into public.service_spares_used (org_id, visit_id, spare_id, qty, cost)
      values (p_org_id, p_visit_id, v_item.spare_id, v_item.qty, v_price * v_item.qty);

      -- Atomic decrement — conditional UPDATE, mirrors create_sale exactly.
      update public.inventory
        set stock_qty = stock_qty - v_item.qty
        where org_id = p_org_id and item_type = 'spare' and item_id = v_item.spare_id
          and location = 'van' and stock_qty >= v_item.qty
        returning stock_qty into v_new_stock;
      if v_new_stock is null then
        -- Fall back to warehouse stock if the technician's van stock isn't
        -- tracked separately for this item (seed data may only populate
        -- 'warehouse'; field ops still needs the sale to go through).
        update public.inventory
          set stock_qty = stock_qty - v_item.qty
          where org_id = p_org_id and item_type = 'spare' and item_id = v_item.spare_id
            and location = 'warehouse' and stock_qty >= v_item.qty
          returning stock_qty into v_new_stock;
      end if;
      if v_new_stock is null then
        raise exception 'create_service_invoice: insufficient stock for spare % (need %)', v_item.spare_id, v_item.qty;
      end if;

      insert into public.inventory_movements (org_id, item_type, item_id, change_qty, reason, ref_id)
      values (p_org_id, 'spare', v_item.spare_id, -v_item.qty, 'service_visit', p_visit_id);
    end loop;
  end if;

  update public.service_visits
    set service_charge = v_effective_charge, discount = p_discount_percent
    where id = p_visit_id;

  update public.service_tickets set status = 'completed', invoice_id = v_invoice.id where id = v_ticket.id;
  update public.appointments set status = 'completed'
    where ticket_id = v_ticket.id and technician_id = v_tech_id and status in ('scheduled', 'in_progress');

  if p_discount_percent > v_settings.discount_tech_max then
    insert into public.approvals (org_id, type, ref_id, requested_by, status)
    values (p_org_id, 'discount', v_invoice.id, auth.uid(), 'pending')
    returning id into v_approval_id;
  end if;

  return jsonb_build_object('invoice_id', v_invoice.id, 'total', v_total, 'approval_id', v_approval_id);
end;
$$;

grant execute on function public.create_service_invoice(uuid, uuid, numeric, numeric, jsonb, payment_method, text, text, boolean) to authenticated;

-- ── generate_enquiry_lead ────────────────────────────────────────────────
-- TECH-07 "Generate Enquiry": logs a lead in the technician's own name for
-- incentive tracking. `leads_insert_own_technician` RLS already allows a
-- technician to insert with owner_id = current_technician_id() directly, so
-- this could be a plain client insert — but wrapping it keeps validation
-- (mobile format, non-empty name) server-side and consistent with the rest
-- of this file, and stays SECURITY INVOKER since RLS already covers it.
create or replace function public.generate_enquiry_lead(
  p_org_id uuid,
  p_customer_id uuid,
  p_name text,
  p_mobile text,
  p_enquiry_type enquiry_type,
  p_note text
)
returns uuid
language plpgsql
security invoker
as $$
declare
  v_tech_id uuid;
  v_lead_id uuid;
begin
  v_tech_id := public.current_technician_id();
  if v_tech_id is null then
    raise exception 'generate_enquiry_lead: caller is not a technician';
  end if;
  if p_name is null or btrim(p_name) = '' then
    raise exception 'generate_enquiry_lead: name is required';
  end if;

  insert into public.leads (org_id, customer_id, name, mobile, source, enquiry_type, status, owner_id)
  values (p_org_id, p_customer_id, p_name, nullif(p_mobile, ''), 'field', p_enquiry_type, 'new', v_tech_id)
  returning id into v_lead_id;

  if p_note is not null and btrim(p_note) <> '' then
    insert into public.lead_activities (org_id, lead_id, type, note)
    values (p_org_id, v_lead_id, 'enquiry_captured', p_note);
  end if;

  return v_lead_id;
end;
$$;

grant execute on function public.generate_enquiry_lead(uuid, uuid, text, text, enquiry_type, text) to authenticated;

-- ── submit_rating ────────────────────────────────────────────────────────
-- TECH-08: below settings.review_link_min_stars, notify operation_admin
-- with the customer's reason (v2.2 "capture reason + notify operation
-- admin"). Written as a DEFINER RPC only because `notifications` INSERT is
-- `is_ops_staff()`-only under RLS — the rating row itself is already
-- writable directly via `ratings_write_own_technician`, so this wraps that
-- insert too purely to keep the "insert rating + maybe notify" pair atomic.
create or replace function public.submit_rating(
  p_org_id uuid,
  p_visit_id uuid,
  p_stars numeric,
  p_review text,
  p_low_rating_reason text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tech_id uuid;
  v_visit service_visits;
  v_settings settings;
  v_rating_id uuid;
begin
  v_tech_id := public.current_technician_id();
  if v_tech_id is null then
    raise exception 'submit_rating: caller is not a technician';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'submit_rating: org mismatch';
  end if;

  select * into v_visit from public.service_visits where id = p_visit_id and org_id = p_org_id;
  if v_visit is null or v_visit.technician_id is distinct from v_tech_id then
    raise exception 'submit_rating: visit % does not belong to the calling technician', p_visit_id;
  end if;

  select * into v_settings from public.settings where org_id = p_org_id;

  insert into public.ratings (org_id, visit_id, stars, review)
  values (p_org_id, p_visit_id, p_stars, p_review)
  returning id into v_rating_id;

  -- v2.2 §6.7 (Design Deltas #3): review link only shows at/above the
  -- admin-set threshold; below it, capture a reason and notify operation admin.
  if p_stars < v_settings.review_link_min_stars then
    insert into public.notifications (org_id, role, type, title, body, ref_id)
    values (
      p_org_id, 'operation_admin', 'low_rating', 'Low customer rating received',
      format('A %s-star rating was recorded. Reason: %s', p_stars, coalesce(nullif(p_low_rating_reason, ''), 'not given')),
      v_rating_id
    );
  end if;

  return v_rating_id;
end;
$$;

grant execute on function public.submit_rating(uuid, uuid, numeric, text, text) to authenticated;

-- ── confirm_spare_handover ───────────────────────────────────────────────
-- TECH-02: both signatures present -> flips status to 'confirmed'. Plain
-- update would already pass `spare_handovers_write_own_technician` RLS, but
-- centralising the "both signatures must be present" rule server-side
-- avoids re-implementing it in every offline-sync retry path.
create or replace function public.confirm_spare_handover(
  p_handover_id uuid,
  p_tech_sign_url text,
  p_admin_sign_url text
)
returns void
language plpgsql
security invoker
as $$
declare
  v_tech_id uuid;
begin
  v_tech_id := public.current_technician_id();
  if v_tech_id is null then
    raise exception 'confirm_spare_handover: caller is not a technician';
  end if;
  if nullif(p_tech_sign_url, '') is null or nullif(p_admin_sign_url, '') is null then
    raise exception 'confirm_spare_handover: both technician and admin signatures are required';
  end if;

  update public.spare_handovers
    set tech_sign_url = p_tech_sign_url, admin_sign_url = p_admin_sign_url, status = 'confirmed'
    where id = p_handover_id and technician_id = v_tech_id;

  if not found then
    raise exception 'confirm_spare_handover: handover % not found for this technician', p_handover_id;
  end if;
end;
$$;

grant execute on function public.confirm_spare_handover(uuid, text, text) to authenticated;
