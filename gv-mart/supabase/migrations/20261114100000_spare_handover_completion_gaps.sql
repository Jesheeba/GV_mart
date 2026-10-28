-- Spare hand-over completion: closes the 4 PARTIAL gaps found by the 2026-10-27 audit
-- (SPARE_HANDOVER_AUDIT_2026_10_27.md) against requirements 2, 3, 6, 7 of the spare
-- hand-over / technician-stock / return feature. Requirements 1 ("master/operation_admin,
-- not sales_admin, hand to one technician"), 4 ("job use deducts the technician's own
-- stock, never double-deducts central") and 5 ("return moves tech -> central, confirmed by
-- master/operation_admin") were already MET on main and are UNTOUCHED here.
--
-- NOT APPLIED to any database. Nothing in this file has been run against a live project.
--
-- Backward compatibility: every new column is nullable with no default that changes
-- existing semantics, and no existing row needs a backfill:
--   - spare_handovers.given_by: NULL for every row created before this column existed --
--     there is no source of truth for who actually gave a past hand-over beyond the
--     (unrelated) admin_sign_url image, so NULL correctly means "not recorded."
--   - spare_handover_items.received_qty / dispute_note: NULL means "no dispute raised,"
--     which is the true state of every existing row (nobody could raise a dispute before
--     this migration -- the feature didn't exist).
-- Both redefined functions (create_spare_handover, create_service_invoice) keep their exact
-- existing signatures, so every existing caller (admin web, technician app) keeps working
-- unchanged; the only behavior delta is the one new column write / one new notification.
--
-- Requirement 2 ("who gave it" + "a disputed quantity is flagged to staff"):
--   - spare_handovers.given_by, set by create_spare_handover from auth.uid() (the calling
--     ops-staff member) on both the normal-path and conflict-retry INSERT.
--   - spare_handover_items.received_qty / dispute_note, written only by the new
--     report_spare_handover_discrepancy() RPC below.
--   - report_spare_handover_discrepancy(): technician-only. Verifies the item belongs to a
--     hand-over addressed to the calling technician, records the disputed quantity, and
--     inserts a notifications row targeted at role='operation_admin' -- which
--     notifications_select_own_role (20260715100000_service_visits_customer_rls_and_
--     notification_role_fix.sql) already widens to master too via public.is_master(), the
--     same pattern submit_rating uses for its low_rating notification
--     (20260702120000_technician_phase7_functions.sql) -- so both master and operation_admin
--     see it, sales_admin does not (matches requirement 1's role boundary).
--
-- Requirement 6 ("a shortfall must be flagged for staff, not lost silently"):
--   create_service_invoice's existing 'service_use_shortfall' branch (first introduced
--   20260921140000_service_use_van_stock_and_shortfall_tagging.sql, unchanged verbatim
--   through the live 20261016160000_rental_generator_scheduling.sql body) already tags the
--   inventory_movements row correctly -- it was never silently lost from the books -- but
--   nothing ever surfaced that tag to staff. This redefinition adds exactly one notification
--   insert, gated on `v_movement_reason = 'service_use_shortfall'`, right after the existing
--   movement insert. Every other line is byte-for-byte the live body; see the rehearsal
--   wrapper (20261114100000_spare_handover_completion_gaps.rehearsal.sql) for the embedded
--   original used to verify that claim against whatever is actually live before this is ever
--   applied.
--
-- Requirement 3 ("a technician sees only his own stock") / 7 ("staff see a ledger: handed
-- over, used, returned, balance"): technician_spare_ledger is a brand-new VIEW, not a change
-- to any existing table -- zero migration risk to existing rows. It is `security_invoker`
-- (Postgres defaults a view to running with the view OWNER's privileges on the underlying
-- tables unless this is set explicitly -- pinned here on purpose, same pattern as the live
-- v_referral_events view, 20261016140000_referral_overview_read_model.sql), so visibility is
-- governed entirely by the RLS already on inventory_movements (staff-only:
-- inventory_movements_select_staff, 20260701091300_rls.sql) and technician_stock_levels
-- (staff-all / own-technician: 20260921110000_technician_van_stock_schema.sql) -- no new RLS
-- policy is needed or added, and no caller gets access to anything they couldn't already
-- query directly. The technician's own "My spares" screen (Step C) reads
-- technician_stock_levels directly instead (its existing technician_stock_levels_select_own
-- policy already scopes a technician to their own balance; the ledger view itself resolves
-- to zero rows for a technician today because inventory_movements has no technician-visible
-- policy, so it's a staff-only view as the requirement asks for).

-- ── requirement 2: given_by + dispute columns ──────────────────────────────────────────────
alter table public.spare_handovers
  add column given_by uuid references public.profiles (id) on delete set null;

alter table public.spare_handover_items
  add column received_qty integer,
  add column dispute_note text;

alter table public.spare_handover_items
  add constraint spare_handover_items_received_qty_check check (received_qty is null or received_qty >= 0);

comment on column public.spare_handovers.given_by is
  'Profile id of the master/operation_admin who created this hand-over via create_spare_handover(). NULL for rows created before 2026-11-14 -- no source of truth to backfill from.';
comment on column public.spare_handover_items.received_qty is
  'Set by report_spare_handover_discrepancy() when the technician says the physical quantity received differs from qty_given. NULL = no dispute raised.';
comment on column public.spare_handover_items.dispute_note is
  'Optional free-text note accompanying a disputed received_qty.';

-- ── requirement 2: create_spare_handover now records given_by ─────────────────────────────
-- Original live body (20260921120000_spare_handover_per_technician_stock.sql) reproduced
-- verbatim except: (a) `given_by` added to both header INSERTs' column/value lists, bound to
-- auth.uid(); (b) `set search_path = public` added -- the live function has none, which is
-- safe to tighten since every reference inside is already schema-qualified with `public.`.
create or replace function public.create_spare_handover(
  p_org_id uuid,
  p_technician_id uuid,
  p_date date,
  p_items jsonb -- [{spare_id, qty_given}, ...]
)
returns uuid
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_handover_id uuid;
  v_item record;
  v_new_stock integer;
  v_have integer;
begin
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'create_spare_handover: org mismatch';
  end if;
  if not public.is_ops_staff() then
    raise exception 'create_spare_handover: caller is not ops staff';
  end if;

  insert into public.spare_handovers (org_id, technician_id, date, status, given_by)
  values (p_org_id, p_technician_id, p_date, 'pending', auth.uid())
  on conflict do nothing
  returning id into v_handover_id;

  -- date has no unique constraint (a technician can have more than one handover per day in
  -- principle), so on_conflict above never actually fires today -- kept defensive, unchanged
  -- from the live body.
  if v_handover_id is null then
    insert into public.spare_handovers (org_id, technician_id, date, status, given_by)
    values (p_org_id, p_technician_id, p_date, 'pending', auth.uid())
    returning id into v_handover_id;
  end if;

  if p_items is not null and jsonb_array_length(p_items) > 0 then
    for v_item in select * from jsonb_to_recordset(p_items) as x(spare_id uuid, qty_given integer)
    loop
      if v_item.qty_given is null or v_item.qty_given <= 0 then
        continue;
      end if;
      insert into public.spare_handover_items (org_id, handover_id, spare_id, qty_given)
      values (p_org_id, v_handover_id, v_item.spare_id, v_item.qty_given);

      -- Warehouse-side decrement, unchanged conditional UPDATE.
      update public.inventory
        set stock_qty = stock_qty - v_item.qty_given
        where org_id = p_org_id and item_type = 'spare' and item_id = v_item.spare_id
          and location = 'warehouse' and stock_qty >= v_item.qty_given
        returning stock_qty into v_new_stock;

      if v_new_stock is null then
        select stock_qty into v_have
          from public.inventory
          where org_id = p_org_id and item_type = 'spare' and item_id = v_item.spare_id
            and location = 'warehouse';
        raise exception 'create_spare_handover: insufficient warehouse stock for spare % (need %, have %)',
          v_item.spare_id, v_item.qty_given, coalesce(v_have, 0);
      end if;

      -- Per-technician van-side increment, unchanged.
      insert into public.technician_stock_levels (org_id, technician_id, item_type, item_id, stock_qty)
      values (p_org_id, p_technician_id, 'spare', v_item.spare_id, v_item.qty_given)
      on conflict (org_id, technician_id, item_type, item_id)
      do update set stock_qty = technician_stock_levels.stock_qty + excluded.stock_qty, updated_at = now();

      insert into public.inventory_movements (org_id, item_type, item_id, change_qty, reason, ref_id, technician_id)
      values (p_org_id, 'spare', v_item.spare_id, -v_item.qty_given, 'spare_handover', v_handover_id, p_technician_id);
    end loop;
  end if;

  return v_handover_id;
end;
$$;

revoke all on function public.create_spare_handover(uuid, uuid, date, jsonb) from public, anon, authenticated;
grant execute on function public.create_spare_handover(uuid, uuid, date, jsonb) to authenticated;

-- ── requirement 2: technician-side dispute RPC (new) ───────────────────────────────────────
-- SECURITY DEFINER is required here (not a stylistic choice): the technician must be able to
-- raise a staff notification, and notifications_insert_ops (20260701091300_rls.sql) only
-- allows is_ops_staff() to INSERT into public.notifications directly -- same justification
-- submit_rating already uses for its own low_rating notification
-- (20260702120000_technician_phase7_functions.sql). No current_user/session_user check is
-- used inside -- caller identity comes from public.current_technician_id() (auth.uid()-based)
-- exactly like every other technician-only RPC in this codebase.
create or replace function public.report_spare_handover_discrepancy(
  p_org_id uuid,
  p_item_id uuid,
  p_received_qty integer,
  p_note text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tech_id uuid;
  v_item public.spare_handover_items;
  v_handover public.spare_handovers;
  v_tech_name text;
  v_spare_name text;
begin
  v_tech_id := public.current_technician_id();
  if v_tech_id is null then
    raise exception 'report_spare_handover_discrepancy: caller is not a technician';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'report_spare_handover_discrepancy: org mismatch';
  end if;
  if p_received_qty is null or p_received_qty < 0 then
    raise exception 'report_spare_handover_discrepancy: received quantity must be zero or more';
  end if;

  select * into v_item from public.spare_handover_items where id = p_item_id and org_id = p_org_id;
  if v_item is null then
    raise exception 'report_spare_handover_discrepancy: item % not found', p_item_id;
  end if;

  select * into v_handover from public.spare_handovers where id = v_item.handover_id and org_id = p_org_id;
  if v_handover is null or v_handover.technician_id is distinct from v_tech_id then
    raise exception 'report_spare_handover_discrepancy: item % does not belong to the calling technician', p_item_id;
  end if;
  if p_received_qty = v_item.qty_given then
    raise exception 'report_spare_handover_discrepancy: received quantity matches the handed-over quantity, nothing to flag';
  end if;

  update public.spare_handover_items
    set received_qty = p_received_qty, dispute_note = nullif(btrim(coalesce(p_note, '')), '')
    where id = p_item_id;

  select p.full_name into v_tech_name
    from public.technicians t join public.profiles p on p.id = t.profile_id
    where t.id = v_tech_id;
  select name into v_spare_name from public.spares where id = v_item.spare_id;

  insert into public.notifications (org_id, role, type, title, body, ref_id)
  values (
    p_org_id, 'operation_admin', 'spare_handover_disputed', 'Spare hand-over quantity disputed',
    format('%s reports receiving %s of %s on the %s hand-over (handed over: %s).',
      coalesce(v_tech_name, 'A technician'), p_received_qty, coalesce(v_spare_name, 'a spare'),
      to_char(v_handover.date, 'DD Mon YYYY'), v_item.qty_given),
    v_handover.id
  );
end;
$$;

revoke all on function public.report_spare_handover_discrepancy(uuid, uuid, integer, text) from public, anon, authenticated;
grant execute on function public.report_spare_handover_discrepancy(uuid, uuid, integer, text) to authenticated;

-- ── requirement 6: create_service_invoice now flags a shortfall to staff ──────────────────
-- Original live body: 20261016160000_rental_generator_scheduling.sql lines 147-450 (same
-- signature, SECURITY DEFINER, SET search_path TO 'public'). Reproduced verbatim below except
-- for the single new `if v_movement_reason = 'service_use_shortfall' then insert into
-- notifications ... end if;` block added right after the existing inventory_movements insert
-- inside the spares loop. See this migration's own header and the rehearsal wrapper for the
-- exact-match proof against the live function before this is ever applied.
create or replace function public.create_service_invoice(p_org_id uuid, p_visit_id uuid, p_service_charge numeric, p_discount_percent numeric, p_spares jsonb, p_payment_method payment_method, p_txn_id text, p_payment_description text, p_is_chargeable boolean, p_amount_paid numeric default null::numeric, p_installations jsonb default '[]'::jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_tech_id uuid;
  v_visit service_visits;
  v_ticket service_tickets;
  v_settings settings;
  v_subtotal numeric(12, 2) := 0;
  v_discount numeric(12, 2);
  v_gst numeric(12, 2);
  v_total numeric(12, 2);
  v_amount_paid numeric(12, 2);
  v_invoice invoices;
  v_item record;
  v_price numeric(12, 2);
  v_cost numeric(12, 2);
  v_line_discount numeric(12, 2);
  v_new_stock integer;
  v_movement_reason text;
  v_approval_id uuid;
  v_effective_charge numeric(12, 2);
  v_amc_plan_id uuid;
  v_is_spare_covered boolean;
  v_rental_contract rental_contracts;
  v_rental_plan rental_plans;
  v_rental_interval_months integer;
  v_rental_visit_date date;
  v_rental_ticket_id uuid;
  v_rental_address_id uuid;
  v_install record; -- INSTALLATION TRACKING
  v_credit_qty integer;
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

  -- A completed ticket is never invoiced (or credited) twice. The same technician repeating the call (offline-queue replay)
  -- gets the existing invoice back and nothing else is written; anyone else gets an error.
  if v_ticket.status = 'completed' then
    if v_ticket.invoice_id is not null and v_visit.technician_id = v_tech_id then
      return jsonb_build_object('invoice_id', v_ticket.invoice_id,
        'total', (select i.total from public.invoices i where i.id = v_ticket.invoice_id),
        'approval_id', null, 'already_completed', true);
    end if;
    raise exception 'create_service_invoice: ticket % is already completed', v_ticket.id;
  end if;

  if p_discount_percent < 0 then
    raise exception 'create_service_invoice: discount cannot be negative';
  end if;
  if p_discount_percent > v_settings.discount_admin_max then
    raise exception 'create_service_invoice: discount % exceeds the admin limit of %', p_discount_percent, v_settings.discount_admin_max;
  end if;

  if p_payment_method = 'transfer'
     and (nullif(p_txn_id, '') is null or nullif(p_payment_description, '') is null) then
    raise exception 'create_service_invoice: bank transfer requires a transaction ID and description';
  end if;

  if v_ticket.type = 'amc' and v_ticket.contract_id is not null then
    select plan_id into v_amc_plan_id from public.amc_contracts where id = v_ticket.contract_id;
  end if;

  v_effective_charge := case when p_is_chargeable then coalesce(p_service_charge, 0) else 0 end;
  v_subtotal := v_effective_charge;

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
      v_is_spare_covered := v_amc_plan_id is null or exists (
        select 1 from public.amc_plan_covered_spares cs
        where cs.plan_id = v_amc_plan_id and cs.spare_id = v_item.spare_id
      );
      if p_is_chargeable or not v_is_spare_covered then
        v_subtotal := v_subtotal + (v_price * v_item.qty);
      end if;
    end loop;
  end if;

  v_discount := round(v_subtotal * p_discount_percent / 100, 2);
  v_gst := round((v_subtotal - v_discount) * v_settings.gst_rate / 100, 2);
  v_total := v_subtotal - v_discount + v_gst;

  v_amount_paid := coalesce(p_amount_paid, v_total);
  if v_amount_paid < 0 then
    raise exception 'create_service_invoice: amount_paid cannot be negative';
  end if;
  if v_amount_paid > v_total then
    raise exception 'create_service_invoice: amount_paid (%) cannot exceed the invoice total (%)', v_amount_paid, v_total;
  end if;

  insert into public.invoices (
    org_id, customer_id, type, subtotal, discount, gst, total,
    payment_method, txn_id, payment_description, payment_status, amount_paid
  ) values (
    p_org_id, v_ticket.customer_id, 'spare', v_subtotal, v_discount, v_gst, v_total,
    p_payment_method, nullif(p_txn_id, ''), nullif(p_payment_description, ''),
    public._derive_payment_status(v_amount_paid, v_total), v_amount_paid
  ) returning * into v_invoice;

  if p_spares is not null and jsonb_array_length(p_spares) > 0 then
    for v_item in select * from jsonb_to_recordset(p_spares) as x(spare_id uuid, qty integer)
    loop
      select price, cost_price into v_price, v_cost from public.spares where id = v_item.spare_id and org_id = p_org_id;
      v_is_spare_covered := v_amc_plan_id is null or exists (
        select 1 from public.amc_plan_covered_spares cs
        where cs.plan_id = v_amc_plan_id and cs.spare_id = v_item.spare_id
      );
      v_price := case when p_is_chargeable or not v_is_spare_covered then v_price else 0 end;
      v_line_discount := round(v_price * v_item.qty * p_discount_percent / 100, 2);

      insert into public.invoice_items (org_id, invoice_id, item_type, item_id, qty, price, discount, cost)
      values (p_org_id, v_invoice.id, 'spare', v_item.spare_id, v_item.qty, v_price, v_line_discount, v_cost);

      insert into public.service_spares_used (org_id, visit_id, spare_id, qty, cost)
      values (p_org_id, p_visit_id, v_item.spare_id, v_item.qty, v_price * v_item.qty);

      -- This technician's own van balance first (was the pooled, org-wide
      -- `inventory` location='van' row - see this migration's header).
      update public.technician_stock_levels
        set stock_qty = stock_qty - v_item.qty, updated_at = now()
        where org_id = p_org_id and technician_id = v_tech_id
          and item_type = 'spare' and item_id = v_item.spare_id and stock_qty >= v_item.qty
        returning stock_qty into v_new_stock;

      if v_new_stock is not null then
        v_movement_reason := 'service_use_van';
      else
        -- Van didn't cover it (never handed over, or not enough) - fall
        -- back to warehouse, same conditional UPDATE as before, but now
        -- tagged so Group 5 reporting can flag the shortfall distinctly
        -- from a normal van deduction.
        update public.inventory
          set stock_qty = stock_qty - v_item.qty
          where org_id = p_org_id and item_type = 'spare' and item_id = v_item.spare_id
            and location = 'warehouse' and stock_qty >= v_item.qty
          returning stock_qty into v_new_stock;
        v_movement_reason := 'service_use_shortfall';
      end if;
      if v_new_stock is null then
        raise exception 'create_service_invoice: insufficient stock for spare % (need %)', v_item.spare_id, v_item.qty;
      end if;

      insert into public.inventory_movements (org_id, item_type, item_id, change_qty, reason, ref_id, technician_id)
      values (p_org_id, 'spare', v_item.spare_id, -v_item.qty, v_movement_reason, p_visit_id, v_tech_id);

      -- NEW (requirement 6): a shortfall must be flagged for staff, not just tagged in the
      -- ledger. role='operation_admin' reaches master too via notifications_select_own_role's
      -- is_master() widening -- sales_admin, correctly, does not see it.
      if v_movement_reason = 'service_use_shortfall' then
        insert into public.notifications (org_id, role, type, title, body, ref_id)
        select p_org_id, 'operation_admin', 'spare_use_shortfall', 'Spare used with no recorded van stock',
          format('%s used %s x %s on a job without enough recorded van stock; drawn from the warehouse instead. Consider a hand-over.',
            coalesce(p.full_name, 'A technician'), v_item.qty, coalesce(s.name, 'a spare')),
          p_visit_id
        from public.technicians t
        join public.profiles p on p.id = t.profile_id
        left join public.spares s on s.id = v_item.spare_id
        where t.id = v_tech_id;
      end if;
    end loop;
  end if;

  -- INSTALLATION TRACKING: distinct from spares - logs which products were
  -- newly installed on this visit, purely for incentive counting (no
  -- invoice line, no stock movement - the product itself was already sold/
  -- stocked through its own path; this just credits the technician).
  if p_installations is not null and jsonb_array_length(p_installations) > 0 then
    for v_install in select * from jsonb_to_recordset(p_installations) as x(product_id uuid, qty integer)
    loop
      if v_install.qty is null or v_install.qty <= 0 then
        raise exception 'create_service_invoice: qty must be positive for installed product %', v_install.product_id;
      end if;
      if not exists (select 1 from public.products where id = v_install.product_id and org_id = p_org_id) then
        raise exception 'create_service_invoice: product % not found in org %', v_install.product_id, p_org_id;
      end if;

      insert into public.installations_logged (org_id, visit_id, technician_id, product_id, qty)
      values (p_org_id, p_visit_id, v_tech_id, v_install.product_id, v_install.qty);
    end loop;
  end if;

  -- Installation incentive: the ticket's per-unit charge (a master-editable snapshot) x units logged for the ticket's
  -- product, minimum 1. Created PENDING; the master approves it before Compute counts it. One credit per ticket+technician.
  if v_ticket.type = 'installation' and v_ticket.product_id is not null and coalesce(v_ticket.installation_charge_snapshot, 0) > 0 then
    select greatest(1, coalesce(sum(il.qty), 0))::integer into v_credit_qty
    from public.installations_logged il
    where il.visit_id = p_visit_id and il.product_id = v_ticket.product_id;
    insert into public.installation_incentive_credits (org_id, ticket_id, visit_id, technician_id, product_id, qty, unit_amount, amount, status)
    values (p_org_id, v_ticket.id, p_visit_id, v_tech_id, v_ticket.product_id, v_credit_qty,
            v_ticket.installation_charge_snapshot, v_ticket.installation_charge_snapshot * v_credit_qty, 'pending')
    on conflict (ticket_id, technician_id) do nothing;
    if found then
      insert into public.notifications (org_id, role, type, title, body, ref_id)
      values (p_org_id, 'master', 'installation_credit_pending', 'Installation incentive to approve',
              format('Installation completed: incentive of %s (%s unit(s)) is waiting for your approval.',
                     v_ticket.installation_charge_snapshot * v_credit_qty, v_credit_qty), v_ticket.id);
    end if;
  end if;

  update public.service_visits
    set service_charge = v_effective_charge, discount = p_discount_percent
    where id = p_visit_id;

  update public.service_tickets set status = 'completed', invoice_id = v_invoice.id where id = v_ticket.id;
  update public.appointments set status = 'completed'
    where ticket_id = v_ticket.id and technician_id = v_tech_id and status in ('scheduled', 'in_progress');

  if v_ticket.type = 'amc' and v_ticket.contract_id is not null then
    update public.amc_contracts
      set next_service_date = (
        select min((a.scheduled_at at time zone 'Asia/Kolkata')::date)
        from public.service_tickets st
        join public.appointments a on a.ticket_id = st.id
        where st.contract_id = v_ticket.contract_id
          and st.type = 'amc'
          and a.status in ('scheduled', 'in_progress')
      )
      where id = v_ticket.contract_id;
  end if;

  if v_ticket.type = 'warranty' and v_ticket.warranty_id is not null then
    update public.warranties
      set next_service_date = (
        select min((a.scheduled_at at time zone 'Asia/Kolkata')::date)
        from public.service_tickets st
        join public.appointments a on a.ticket_id = st.id
        where st.warranty_id = v_ticket.warranty_id
          and st.type = 'warranty'
          and a.status in ('scheduled', 'in_progress')
      )
      where id = v_ticket.warranty_id;
  end if;

  if v_ticket.type = 'rental' and v_ticket.rental_contract_id is not null then
    select * into v_rental_contract from public.rental_contracts where id = v_ticket.rental_contract_id;
    if v_rental_contract.status = 'active' then
      select * into v_rental_plan from public.rental_plans where id = v_rental_contract.plan_id;
      -- next visit: round(12 / visits_per_year) months from today (was integer division), rolled to a working day
      v_rental_interval_months := greatest(1, public._visit_month_offset(v_rental_plan.visits_per_year, 1));
      v_rental_visit_date := public._visit_working_day(p_org_id, ((now() at time zone 'Asia/Kolkata')::date + make_interval(months => v_rental_interval_months))::date);
      v_rental_address_id := coalesce(v_rental_contract.address_id, v_ticket.address_id);

      insert into public.service_tickets (
        org_id, customer_id, address_id, product_id, name_of_complaint, nature_of_complaint,
        type, priority, status, channel, rental_contract_id
      ) values (
        p_org_id, v_rental_contract.customer_id, v_rental_address_id, v_rental_contract.product_id,
        'Rental scheduled service', v_rental_plan.name, 'rental', 'normal', 'open', 'walk_in', v_rental_contract.id
      )
      returning id into v_rental_ticket_id;

      insert into public.appointments (org_id, ticket_id, mode, scheduled_at, available_from, available_to, status)
      values (p_org_id, v_rental_ticket_id, 'datetime', public._visit_start_ts(p_org_id, v_rental_visit_date),
              public._visit_window_from(p_org_id), public._visit_window_to(p_org_id), 'scheduled');

      perform public._auto_assign_ticket_internal(v_rental_ticket_id, p_org_id, p_skip_rating_logic => true);

      update public.rental_contracts set next_service_date = v_rental_visit_date where id = v_rental_contract.id;
    end if;
  end if;

  if p_discount_percent > v_settings.discount_tech_max then
    insert into public.approvals (org_id, type, ref_id, requested_by, status)
    values (p_org_id, 'discount', v_invoice.id, auth.uid(), 'pending')
    returning id into v_approval_id;
  end if;

  if (now() at time zone 'Asia/Kolkata')::time >= v_settings.work_end then
    update public.attendance
    set shift_end_prompt_pending = true
    where technician_id = v_tech_id and org_id = p_org_id
      and date = (now() at time zone 'Asia/Kolkata')::date;

    insert into public.notifications (org_id, user_id, type, title, body, ref_id)
    select p_org_id, p.id, 'shift_end_prompt', 'Shift end reached',
      format('Your shift ended at %s. Reply to continue or check out.', to_char(v_settings.work_end, 'HH12:MI AM')), v_invoice.id
    from public.technicians t join public.profiles p on p.id = t.profile_id
    where t.id = v_tech_id;
  else
    perform public._auto_assign_next_ticket_to_technician(p_org_id, v_tech_id);
  end if;

  return jsonb_build_object('invoice_id', v_invoice.id, 'total', v_total, 'approval_id', v_approval_id);
end;
$function$;

revoke all on function public.create_service_invoice(uuid, uuid, numeric, numeric, jsonb, payment_method, text, text, boolean, numeric, jsonb) from public, anon, authenticated;
grant execute on function public.create_service_invoice(uuid, uuid, numeric, numeric, jsonb, payment_method, text, text, boolean, numeric, jsonb) to authenticated;

-- ── requirement 3 + 7: per-technician/per-spare staff ledger (new view) ───────────────────
-- security_invoker = on, same pattern as the live v_referral_events
-- (20261016140000_referral_overview_read_model.sql): visibility is entirely delegated to the
-- RLS already on inventory_movements (staff-only) and technician_stock_levels
-- (staff-all / own-technician). A technician querying this view sees zero rows today (their
-- RLS grants no access to inventory_movements at all) -- which is correct, since this is the
-- STAFF ledger; the technician's own balance comes from technician_stock_levels directly
-- (Step C's "My spares" screen), already covered by technician_stock_levels_select_own.
create view public.technician_spare_ledger
with (security_invoker = on) as
select
  m.org_id,
  m.technician_id,
  t.profile_id,
  p.full_name as technician_name,
  m.item_id as spare_id,
  s.name as spare_name,
  s.sku as spare_sku,
  coalesce(sum(case when m.reason = 'spare_handover' then -m.change_qty else 0 end), 0)::integer as qty_handed_over,
  coalesce(sum(case when m.reason in ('service_use_van', 'service_use_shortfall') then -m.change_qty else 0 end), 0)::integer as qty_used,
  coalesce(sum(case when m.reason = 'return' then m.change_qty else 0 end), 0)::integer as qty_returned,
  coalesce(tsl.stock_qty, 0) as balance
from public.inventory_movements m
join public.technicians t on t.id = m.technician_id
join public.profiles p on p.id = t.profile_id
join public.spares s on s.id = m.item_id
left join public.technician_stock_levels tsl
  on tsl.org_id = m.org_id and tsl.technician_id = m.technician_id
 and tsl.item_type = 'spare' and tsl.item_id = m.item_id
where m.item_type = 'spare' and m.technician_id is not null
group by m.org_id, m.technician_id, t.profile_id, p.full_name, m.item_id, s.name, s.sku, tsl.stock_qty;

revoke all on public.technician_spare_ledger from public, anon;
grant select on public.technician_spare_ledger to authenticated, service_role;

comment on view public.technician_spare_ledger is
  'Staff-facing ledger: per technician/spare, handed-over/used/returned totals plus current balance. Visibility is entirely driven by invoker RLS on inventory_movements (staff-only) and technician_stock_levels (staff-all/own) -- no RLS on the view itself.';

notify pgrst, 'reload schema';
