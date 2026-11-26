-- Referral sources everywhere + customer referral points (build-docs/features/referral-sources.md)
--
-- Owner decisions 2026-11-26: any screen can record Technician / Sales person-staff /
-- Existing customer / Someone else as the referrer; a customer referrer is linked by id;
-- a customer referrer earns points automatically, behind a master toggle (OFF by default),
-- credited once, when the referred customer's first invoice is paid.
--
-- Design: the billing RPCs (create_sale 18 KB, create_complaint_ticket, sell_amc_plan) are
-- NOT edited. New *_with_referrer wrappers record the referrer and then call the unchanged
-- originals in the same transaction, so a failed sale/ticket rolls the referrer back too.
-- Live md5 pins captured 2026-11-26 (_local_only/rehearsal-files/2026-11-26_referral_sources_live_pins.sql.out.txt):
--   _carry_over_lead_referral 9a4e65a10d7fe96340ae27f79465a166 (the only existing body replaced here)
--   create_sale 8cec65d6..., create_complaint_ticket 47cabf68..., sell_amc_plan c8ef1b8d...,
--   create_customer_with_details 08902395... (called, not changed)

-- ── 1. Columns + constraints ─────────────────────────────────────────────
alter table public.customers
  add column if not exists referred_by_customer_id uuid references public.customers(id) on delete set null;
alter table public.leads
  add column if not exists referred_by_customer_id uuid references public.customers(id) on delete set null;

create index if not exists customers_referred_by_customer_id_idx on public.customers (referred_by_customer_id) where referred_by_customer_id is not null;
create index if not exists leads_referred_by_customer_id_idx on public.leads (referred_by_customer_id) where referred_by_customer_id is not null;

alter table public.customers
  add constraint customers_referrer_one_kind check (referred_by_user_id is null or referred_by_customer_id is null),
  add constraint customers_referrer_not_self check (referred_by_customer_id is distinct from id);
alter table public.leads
  add constraint leads_referrer_customer_not_self check (referred_by_customer_id is null or customer_id is null or referred_by_customer_id <> customer_id);

comment on column public.customers.referred_by_customer_id is
  'Existing customer who referred this customer. Set once (at creation, lead-conversion carry-over, or the
   first referred transaction) -- never by a plain UPDATE, see aaa_guard_customers_referred_by_customer_id.
   Mutually exclusive with referred_by_user_id.';
comment on column public.leads.referred_by_customer_id is
  'Existing customer who referred this lead. Carried to customers.referred_by_customer_id on conversion.';

-- ── 2. Guards ────────────────────────────────────────────────────────────
-- Same set-once rule as _guard_customers_referred_by_user_id, plus a same-org check (the FK alone
-- does not check org). Clearing to null is allowed only when the referrer row is gone (ON DELETE SET NULL).
create or replace function public._guard_customers_referred_by_customer_id()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.referred_by_customer_id is not null
     and (tg_op = 'INSERT' or new.referred_by_customer_id is distinct from old.referred_by_customer_id)
     and not exists (select 1 from public.customers r where r.id = new.referred_by_customer_id and r.org_id = new.org_id) then
    raise exception '_guard_customers_referred_by_customer_id: referrer must be a customer in the same organisation';
  end if;

  if tg_op = 'INSERT' then
    if new.referred_by_customer_id is not null and new.referred_at is null then
      new.referred_at := now();
    end if;
    return new;
  end if;

  if new.referred_by_customer_id is distinct from old.referred_by_customer_id then
    if new.referred_by_customer_id is null
       and not exists (select 1 from public.customers r where r.id = old.referred_by_customer_id) then
      return new; -- referrer deleted, FK set null
    end if;
    if coalesce(current_setting('app.allow_referral_correction', true), '') <> 'on' then
      raise exception '_guard_customers_referred_by_customer_id: customers.referred_by_customer_id cannot be changed by a plain update';
    end if;
    if old.referred_by_customer_id is null and new.referred_by_customer_id is not null then
      new.referred_at := now();
    end if;
  end if;
  return new;
end;
$$;
revoke all on function public._guard_customers_referred_by_customer_id() from public, anon, authenticated;

drop trigger if exists aaa_guard_customers_referred_by_customer_id on public.customers;
create trigger aaa_guard_customers_referred_by_customer_id
  before insert or update of referred_by_customer_id on public.customers
  for each row execute function public._guard_customers_referred_by_customer_id();

-- Leads stay freely editable by sales staff; only the org must match.
create or replace function public._guard_leads_referred_by_customer_id()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.referred_by_customer_id is not null
     and (tg_op = 'INSERT' or new.referred_by_customer_id is distinct from old.referred_by_customer_id)
     and not exists (select 1 from public.customers r where r.id = new.referred_by_customer_id and r.org_id = new.org_id) then
    raise exception '_guard_leads_referred_by_customer_id: referrer must be a customer in the same organisation';
  end if;
  return new;
end;
$$;
revoke all on function public._guard_leads_referred_by_customer_id() from public, anon, authenticated;

drop trigger if exists aaa_guard_leads_referred_by_customer_id on public.leads;
create trigger aaa_guard_leads_referred_by_customer_id
  before insert or update of referred_by_customer_id on public.leads
  for each row execute function public._guard_leads_referred_by_customer_id();

-- ── 3. Customer referral points (master toggle, OFF by default) ──────────
alter table public.settings
  add column if not exists customer_referral_points_enabled boolean not null default false,
  add column if not exists customer_referral_points integer not null default 0;
alter table public.settings
  add constraint settings_customer_referral_points_range check (customer_referral_points between 0 and 100000);

alter table public.referral_points add column if not exists source text;
-- At most one automatic award per referred customer, safe under concurrent invoices.
create unique index if not exists referral_points_customer_referral_once_idx
  on public.referral_points (ref_id) where source = 'customer_referral';

create or replace function public._maybe_award_customer_referral(p_customer_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid;
  v_referrer uuid;
  v_name text;
  v_enabled boolean;
  v_points integer;
begin
  select c.org_id, c.referred_by_customer_id, c.name into v_org, v_referrer, v_name
  from public.customers c where c.id = p_customer_id;
  if v_referrer is null then
    return;
  end if;

  select s.customer_referral_points_enabled, s.customer_referral_points into v_enabled, v_points
  from public.settings s where s.org_id = v_org;
  if not coalesce(v_enabled, false) or coalesce(v_points, 0) <= 0 then
    return;
  end if;

  if not exists (select 1 from public.invoices i where i.customer_id = p_customer_id and i.payment_status = 'paid') then
    return;
  end if;

  insert into public.referral_points (org_id, customer_id, points, reason, ref_id, source)
  values (v_org, v_referrer, v_points, format('Referral: %s', v_name), p_customer_id, 'customer_referral')
  on conflict (ref_id) where source = 'customer_referral' do nothing;
end;
$$;
revoke all on function public._maybe_award_customer_referral(uuid) from public, anon, authenticated;

-- A points failure must never block an invoice; it is logged instead of swallowed silently.
create or replace function public._trg_invoice_customer_referral_points()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  begin
    perform public._maybe_award_customer_referral(new.customer_id);
  exception when others then
    insert into public.audit_log (org_id, actor_id, action, table_name, row_id, before, after)
    values (new.org_id, auth.uid(), 'customer_referral_points_failed', 'invoices', new.id, null,
            jsonb_build_object('error', sqlerrm, 'customer_id', new.customer_id));
  end;
  return null;
end;
$$;
revoke all on function public._trg_invoice_customer_referral_points() from public, anon, authenticated;

drop trigger if exists invoices_customer_referral_points on public.invoices;
create trigger invoices_customer_referral_points
  after insert or update of payment_status on public.invoices
  for each row when (new.payment_status = 'paid')
  execute function public._trg_invoice_customer_referral_points();

-- ── 4. Shared referrer helpers ───────────────────────────────────────────
-- Sets the customer-level referrer once: only when none is set and the customer has no qualifying
-- purchase history yet (same anti-abuse rule as the lead-conversion carry-over).
create or replace function public._apply_customer_referrer(p_customer_id uuid, p_referred_by_user_id uuid, p_referred_by_customer_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid;
  v_cust uuid;
begin
  if p_referred_by_user_id is null and p_referred_by_customer_id is null then
    return false;
  end if;
  select referred_by_user_id, referred_by_customer_id into v_user, v_cust
  from public.customers where id = p_customer_id for update;
  if not found or v_user is not null or v_cust is not null
     or public.customer_has_qualifying_history(p_customer_id) then
    return false;
  end if;

  perform set_config('app.allow_referral_correction', 'on', true);
  update public.customers
    set referred_by_user_id = p_referred_by_user_id,
        referred_by_customer_id = case when p_referred_by_user_id is null then p_referred_by_customer_id end
    where id = p_customer_id;
  perform set_config('app.allow_referral_correction', 'off', true);

  perform public._maybe_award_customer_referral(p_customer_id);
  return true;
end;
$$;
revoke all on function public._apply_customer_referrer(uuid, uuid, uuid) from public, anon, authenticated;

-- Validates a non-technician referrer; returns the trimmed referrer name/phone for "someone else".
create or replace function public._validate_referrer(p_org_id uuid, p_customer_id uuid, p_referred_by_user_id uuid, p_referred_by_customer_id uuid, p_referred_by_name text)
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if num_nonnulls(p_referred_by_user_id, p_referred_by_customer_id, nullif(btrim(coalesce(p_referred_by_name, '')), '')) > 1 then
    raise exception 'referrer: pick only one referrer';
  end if;
  if p_referred_by_user_id is not null then
    if p_referred_by_user_id = auth.uid() then
      raise exception 'referrer: you cannot refer yourself';
    end if;
    if not exists (
      select 1 from public.profiles pr
      where pr.id = p_referred_by_user_id and pr.org_id = p_org_id and pr.is_active
        and (pr.role in ('master', 'operation_admin', 'sales_admin')
             or (pr.role = 'technician' and exists (select 1 from public.technicians t where t.profile_id = pr.id and t.is_active)))
    ) then
      raise exception 'referrer: % is not an active technician or staff member in this organisation', p_referred_by_user_id;
    end if;
  end if;
  if p_referred_by_customer_id is not null then
    if p_referred_by_customer_id = p_customer_id then
      raise exception 'referrer: a customer cannot refer themselves';
    end if;
    if not exists (select 1 from public.customers c where c.id = p_referred_by_customer_id and c.org_id = p_org_id) then
      raise exception 'referrer: customer % not found in this organisation', p_referred_by_customer_id;
    end if;
  end if;
end;
$$;
revoke all on function public._validate_referrer(uuid, uuid, uuid, uuid, text) from public, anon, authenticated;

-- Records a non-technician referrer for a sale / complaint / AMC: one referral lead (no owner_id, so
-- no finder credit -- that stays technician-only) + the customer-level referrer if still unset.
create or replace function public._record_transaction_referrer(
  p_org_id uuid, p_customer_id uuid, p_referred_by_user_id uuid, p_referred_by_customer_id uuid,
  p_referred_by_name text, p_referred_by_phone text, p_context text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_name text := nullif(btrim(coalesce(p_referred_by_name, '')), '');
  v_phone text := nullif(btrim(coalesce(p_referred_by_phone, '')), '');
  v_customer record;
  v_lead_id uuid;
begin
  if p_referred_by_user_id is null and p_referred_by_customer_id is null and v_name is null then
    return null;
  end if;
  if p_org_id is distinct from public.current_org_id() or not public.is_staff() then
    raise exception 'referrer: not allowed';
  end if;
  perform public._validate_referrer(p_org_id, p_customer_id, p_referred_by_user_id, p_referred_by_customer_id, v_name);

  select id, name, mobile into v_customer from public.customers where id = p_customer_id and org_id = p_org_id;
  if not found then
    raise exception 'referrer: customer % not found in this organisation', p_customer_id;
  end if;

  if p_referred_by_customer_id is not null then
    select name, mobile into v_name, v_phone from public.customers where id = p_referred_by_customer_id;
  end if;

  insert into public.leads (org_id, customer_id, name, mobile, source, status, referred_by_user_id, referred_by_customer_id, referred_by_name, referred_by_phone)
  values (p_org_id, p_customer_id, v_customer.name, v_customer.mobile, 'referral', 'won',
          p_referred_by_user_id, p_referred_by_customer_id, left(v_name, 120), left(v_phone, 20))
  returning id into v_lead_id;

  insert into public.lead_activities (org_id, lead_id, type, note)
  values (p_org_id, v_lead_id, 'converted', format('%s, referred by %s', p_context,
          coalesce(v_name, (select full_name from public.profiles where id = p_referred_by_user_id), 'staff')));

  perform public._apply_customer_referrer(p_customer_id, p_referred_by_user_id, p_referred_by_customer_id);
  return v_lead_id;
end;
$$;
revoke all on function public._record_transaction_referrer(uuid, uuid, uuid, uuid, text, text, text) from public, anon, authenticated;

-- ── 5. Lead conversion carry-over: also carries a customer referrer ─────
-- Body = live 9a4e65a1... with: early return only when BOTH referrers are null; a customer referrer
-- read from the lead; each UPDATE keeps the one-kind rule; the bypass flag is reset after use.
create or replace function public._carry_over_lead_referral(p_org_id uuid, p_lead_id uuid, p_customer_id uuid, p_mobile text, p_referred_by_user_id uuid)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_unambiguous_id uuid;
  v_has_history boolean;
  v_ref_customer uuid;
begin
  if p_customer_id is null then
    return;
  end if;
  select l.referred_by_customer_id into v_ref_customer from public.leads l where l.id = p_lead_id;
  if v_ref_customer = p_customer_id then
    v_ref_customer := null;
  end if;
  if p_referred_by_user_id is null and v_ref_customer is null then
    return;
  end if;

  v_unambiguous_id := public.customer_mobile_match_is_unambiguous(p_org_id, p_mobile);
  v_has_history := public.customer_has_qualifying_history(p_customer_id);

  if v_unambiguous_id is distinct from p_customer_id then
    insert into public.audit_log (org_id, actor_id, action, table_name, row_id, before, after)
    values (p_org_id, auth.uid(), 'referral_carryover_skipped_ambiguous_mobile', 'leads', p_lead_id,
            jsonb_build_object('mobile', p_mobile, 'resolved_customer_id', p_customer_id),
            jsonb_build_object('reason', 'mobile match is ambiguous, placeholder, or does not resolve to the same customer the lead was attached to -- referral NOT carried over, lead conversion proceeds normally'));
    return;
  end if;

  if v_has_history then
    insert into public.audit_log (org_id, actor_id, action, table_name, row_id, before, after)
    values (p_org_id, auth.uid(), 'referral_carryover_skipped_existing_history', 'leads', p_lead_id,
            jsonb_build_object('customer_id', p_customer_id),
            jsonb_build_object('reason', 'customer already has qualifying purchase history before this conversion -- referral NOT carried over'));
    return;
  end if;

  perform set_config('app.allow_referral_correction', 'on', true);
  if p_referred_by_user_id is not null then
    update public.customers
      set referred_by_user_id = p_referred_by_user_id
      where id = p_customer_id and referred_by_user_id is null and referred_by_customer_id is null;
  else
    update public.customers
      set referred_by_customer_id = v_ref_customer
      where id = p_customer_id and referred_by_user_id is null and referred_by_customer_id is null;
  end if;
  perform set_config('app.allow_referral_correction', 'off', true);
end;
$function$;
revoke all on function public._carry_over_lead_referral(uuid, uuid, uuid, text, uuid) from public, anon, authenticated;

-- ── 6. Public wrappers (callers: New Customer, New Sale, New Complaint, Sell AMC) ──
create or replace function public.create_customer_with_referrer(
  p_org_id uuid, p_profession text, p_source text, p_members jsonb, p_address jsonb,
  p_referred_by_user_id uuid default null, p_referred_by_customer_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  -- Same predicate as the customers_write_sales RLS policy create_customer_with_details runs under.
  if p_org_id is distinct from public.current_org_id() or not public.is_sales_staff() then
    raise exception 'create_customer_with_referrer: only master or sales staff may create customers';
  end if;
  if p_referred_by_user_id is not null and p_referred_by_customer_id is not null then
    raise exception 'referrer: pick only one referrer';
  end if;
  v_id := public.create_customer_with_details(p_org_id, p_profession, p_source, p_members, p_address, p_referred_by_user_id);
  if p_referred_by_customer_id is not null then
    perform public._validate_referrer(p_org_id, v_id, null, p_referred_by_customer_id, null);
    perform public._apply_customer_referrer(v_id, null, p_referred_by_customer_id);
  end if;
  return v_id;
end;
$$;

create or replace function public.create_sale_with_referrer(
  p_org_id uuid, p_customer_id uuid, p_cart jsonb, p_quotation_id uuid default null, p_redeem_points integer default 0,
  p_referred_by_technician_id uuid default null, p_amount_paid numeric default null,
  p_referred_by_user_id uuid default null, p_referred_by_customer_id uuid default null,
  p_referred_by_name text default null, p_referred_by_phone text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_referred_by_technician_id is not null
     and num_nonnulls(p_referred_by_user_id, p_referred_by_customer_id, nullif(btrim(coalesce(p_referred_by_name, '')), '')) > 0 then
    raise exception 'referrer: pick only one referrer';
  end if;
  perform public._record_transaction_referrer(p_org_id, p_customer_id, p_referred_by_user_id, p_referred_by_customer_id, p_referred_by_name, p_referred_by_phone, 'Sale');
  return public.create_sale(p_org_id, p_customer_id, p_cart, p_quotation_id, p_redeem_points, p_referred_by_technician_id, p_amount_paid);
end;
$$;

create or replace function public.create_complaint_ticket_with_referrer(
  p_org_id uuid, p_customer_id uuid, p_address_id uuid, p_product_id uuid, p_brand_id uuid, p_model_id uuid,
  p_name_of_complaint text, p_nature_of_complaint text, p_priority priority_level, p_channel ticket_channel,
  p_appointment_mode appointment_mode, p_auto_assign boolean, p_scheduled_date date default null, p_slot_id uuid default null,
  p_referred_by_technician_id uuid default null, p_unlisted_product_name text default null, p_complaint_type_id uuid default null,
  p_unavailable_windows jsonb default null, p_technician_id uuid default null,
  p_referred_by_user_id uuid default null, p_referred_by_customer_id uuid default null,
  p_referred_by_name text default null, p_referred_by_phone text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_referred_by_technician_id is not null
     and num_nonnulls(p_referred_by_user_id, p_referred_by_customer_id, nullif(btrim(coalesce(p_referred_by_name, '')), '')) > 0 then
    raise exception 'referrer: pick only one referrer';
  end if;
  perform public._record_transaction_referrer(p_org_id, p_customer_id, p_referred_by_user_id, p_referred_by_customer_id, p_referred_by_name, p_referred_by_phone, 'Service complaint');
  return public.create_complaint_ticket(p_org_id, p_customer_id, p_address_id, p_product_id, p_brand_id, p_model_id,
    p_name_of_complaint, p_nature_of_complaint, p_priority, p_channel, p_appointment_mode, p_auto_assign, p_scheduled_date,
    p_slot_id, p_referred_by_technician_id, p_unlisted_product_name, p_complaint_type_id, p_unavailable_windows, p_technician_id);
end;
$$;

create or replace function public.sell_amc_plan_with_referrer(
  p_org_id uuid, p_customer_id uuid, p_product_id uuid, p_plan_id uuid,
  p_start_date date default ((now() at time zone 'Asia/Kolkata'))::date, p_years integer default null,
  p_referred_by_technician_id uuid default null, p_confirm_backdated boolean default false,
  p_referred_by_user_id uuid default null, p_referred_by_customer_id uuid default null,
  p_referred_by_name text default null, p_referred_by_phone text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_referred_by_technician_id is not null
     and num_nonnulls(p_referred_by_user_id, p_referred_by_customer_id, nullif(btrim(coalesce(p_referred_by_name, '')), '')) > 0 then
    raise exception 'referrer: pick only one referrer';
  end if;
  perform public._record_transaction_referrer(p_org_id, p_customer_id, p_referred_by_user_id, p_referred_by_customer_id, p_referred_by_name, p_referred_by_phone, 'AMC sale');
  return public.sell_amc_plan(p_org_id, p_customer_id, p_product_id, p_plan_id, p_start_date, p_years, p_referred_by_technician_id, p_confirm_backdated);
end;
$$;

-- This project auto-grants EXECUTE to anon on new functions (2026-08-27 leak) -- revoke explicitly.
revoke all on function public.create_customer_with_referrer(uuid, text, text, jsonb, jsonb, uuid, uuid) from public, anon;
revoke all on function public.create_sale_with_referrer(uuid, uuid, jsonb, uuid, integer, uuid, numeric, uuid, uuid, text, text) from public, anon;
revoke all on function public.create_complaint_ticket_with_referrer(uuid, uuid, uuid, uuid, uuid, uuid, text, text, priority_level, ticket_channel, appointment_mode, boolean, date, uuid, uuid, text, uuid, jsonb, uuid, uuid, uuid, text, text) from public, anon;
revoke all on function public.sell_amc_plan_with_referrer(uuid, uuid, uuid, uuid, date, integer, uuid, boolean, uuid, uuid, text, text) from public, anon;
grant execute on function public.create_customer_with_referrer(uuid, text, text, jsonb, jsonb, uuid, uuid) to authenticated;
grant execute on function public.create_sale_with_referrer(uuid, uuid, jsonb, uuid, integer, uuid, numeric, uuid, uuid, text, text) to authenticated;
grant execute on function public.create_complaint_ticket_with_referrer(uuid, uuid, uuid, uuid, uuid, uuid, text, text, priority_level, ticket_channel, appointment_mode, boolean, date, uuid, uuid, text, uuid, jsonb, uuid, uuid, uuid, text, text) to authenticated;
grant execute on function public.sell_amc_plan_with_referrer(uuid, uuid, uuid, uuid, date, integer, uuid, boolean, uuid, uuid, text, text) to authenticated;
