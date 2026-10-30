-- REHEARSAL for Product Lifecycle Drop 2 (migrations 20261126100000-20261126100200), applied
-- on top of the already-live Drop 1 (+ security fix 20261125100800). Proves the new RLS/RPC
-- authorization logic against THROWAWAY __TEST_ data, inside ONE DO block that ends in an
-- unconditional RAISE EXCEPTION -- so the migrations' DDL and every row created below are rolled
-- back together as a single unit. A before/after fingerprint of the REAL org's own tables is
-- captured and compared BEFORE the final raise, proving nothing persisted from this run.
--
-- WRITTEN ONLY -- never executed by the agent that produced this file until explicitly asked.
-- Run by hand, after 11:00 IST, same gate as every other script in this feature.

do $rehearsal$
declare
  v_ist_hour int;
  v_expected_org_fingerprint text := '6f891cf85011f08c2f22fb4a208d21bd';
  v_org_fingerprint text;
  v_real_counts_before jsonb;
  v_real_counts_after jsonb;
  v_test_org uuid;
  v_product uuid;
  v_brand uuid;
  v_model uuid;
  v_cust uuid;
  v_sales_profile uuid;
  v_other_org uuid;
  v_other_master_profile uuid;
  v_schedule_id uuid;
  v_installed_id uuid;
  v_ticket_id uuid;
  v_results jsonb := '{}'::jsonb;
  v_mig0_text text := $mig0$-- Product Lifecycle & Automated Service Reminder System — Drop 2, migration 1/3.
-- Sales Daily Follow-ups must be actionable (owner amendment 2): Mark contacted (+note),
-- Snooze (pick a date), Create service request. Logged as an append-only action history,
-- NOT as lead_followups rows (that table's postpone/stuck/outcome invariants are lead-specific
-- and would be corrupted by a non-lead row type — see DECISIONS.md #13).

alter table public.customer_part_schedules
  add column snoozed_until date;
-- Snoozing is a SALES-SIDE deferral of being nagged about it, not a change to the real due
-- date: customer/technician alerts and status computation are completely unaffected by this
-- column — only the Sales Daily Follow-ups surfacing query reads it.

create table public.lifecycle_followup_actions (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  customer_part_schedule_id uuid not null references public.customer_part_schedules (id) on delete cascade,
  action_type text not null check (action_type in ('contacted', 'snoozed', 'service_request_created')),
  note text,
  snoozed_until date,
  service_ticket_id uuid references public.service_tickets (id),
  created_by uuid references public.profiles (id),
  created_at timestamptz not null default now()
);

create index lifecycle_followup_actions_schedule_idx
  on public.lifecycle_followup_actions (customer_part_schedule_id);
create index lifecycle_followup_actions_org_idx on public.lifecycle_followup_actions (org_id);

create trigger audit_lifecycle_followup_actions after insert or update or delete
  on public.lifecycle_followup_actions for each row execute function public.audit_master_change();

alter table public.lifecycle_followup_actions enable row level security;

create policy lifecycle_followup_actions_select_sales on public.lifecycle_followup_actions
  for select using (org_id = public.current_org_id() and public.is_sales_staff());

revoke all on public.lifecycle_followup_actions from public, anon;
grant select, insert on public.lifecycle_followup_actions to authenticated;
$mig0$;
  v_mig1_text text := $mig1$-- Product Lifecycle & Automated Service Reminder System — Drop 2, migration 2/3.
-- Every function below checks the caller's organisation AND specific authority itself (lesson
-- from the Drop 1 security review — SECURITY DEFINER bypasses RLS internally, so each function
-- must re-derive authorization, never rely on RLS alone), and every boolean built from an
-- equality against a possibly-null value is wrapped in coalesce(..., false) (the exact pitfall
-- that review caught in get_customer_due_parts).

create or replace function public.lifecycle_mark_followup_contacted(
  p_schedule_id uuid,
  p_note text default null
)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_org_id uuid;
begin
  select org_id into v_org_id from public.customer_part_schedules where id = p_schedule_id;
  if v_org_id is null then
    raise exception 'lifecycle_mark_followup_contacted: schedule % not found', p_schedule_id;
  end if;
  if not coalesce(v_org_id = public.current_org_id() and public.is_sales_staff(), false) then
    raise exception 'lifecycle_mark_followup_contacted: not authorized';
  end if;

  insert into public.lifecycle_followup_actions (org_id, customer_part_schedule_id, action_type, note, created_by)
  values (v_org_id, p_schedule_id, 'contacted', p_note, auth.uid());
end;
$$;
revoke all on function public.lifecycle_mark_followup_contacted(uuid, text) from public, anon;
grant execute on function public.lifecycle_mark_followup_contacted(uuid, text) to authenticated;

create or replace function public.lifecycle_snooze_followup(
  p_schedule_id uuid,
  p_until date
)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_org_id uuid;
begin
  if p_until <= (now() at time zone 'Asia/Kolkata')::date then
    raise exception 'lifecycle_snooze_followup: snooze date must be in the future';
  end if;

  select org_id into v_org_id from public.customer_part_schedules where id = p_schedule_id;
  if v_org_id is null then
    raise exception 'lifecycle_snooze_followup: schedule % not found', p_schedule_id;
  end if;
  if not coalesce(v_org_id = public.current_org_id() and public.is_sales_staff(), false) then
    raise exception 'lifecycle_snooze_followup: not authorized';
  end if;

  update public.customer_part_schedules set snoozed_until = p_until where id = p_schedule_id;
  insert into public.lifecycle_followup_actions (org_id, customer_part_schedule_id, action_type, snoozed_until, created_by)
  values (v_org_id, p_schedule_id, 'snoozed', p_until, auth.uid());
end;
$$;
revoke all on function public.lifecycle_snooze_followup(uuid, date) from public, anon;
grant execute on function public.lifecycle_snooze_followup(uuid, date) to authenticated;

create or replace function public.lifecycle_create_service_request(p_schedule_id uuid)
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_org_id uuid;
  v_customer_id uuid;
  v_product_id uuid;
  v_label text;
  v_detected jsonb;
  v_ticket_id uuid;
  v_address_id uuid;
begin
  select cps.org_id, cip.customer_id, cip.product_id, cps.label
    into v_org_id, v_customer_id, v_product_id, v_label
  from public.customer_part_schedules cps
  join public.customer_installed_products cip on cip.id = cps.installed_product_id
  where cps.id = p_schedule_id;

  if v_org_id is null then
    raise exception 'lifecycle_create_service_request: schedule % not found', p_schedule_id;
  end if;
  if not coalesce(v_org_id = public.current_org_id() and public.is_sales_staff(), false) then
    raise exception 'lifecycle_create_service_request: not authorized';
  end if;

  select id into v_address_id from public.addresses where customer_id = v_customer_id order by created_at asc limit 1;

  v_detected := public._detect_ticket_type(v_org_id, v_customer_id, v_product_id);

  insert into public.service_tickets (
    org_id, customer_id, address_id, product_id, name_of_complaint, nature_of_complaint,
    type, priority, status, channel
  ) values (
    v_org_id, v_customer_id, v_address_id, v_product_id,
    'Spare part replacement due: ' || v_label,
    'Generated from a Product Lifecycle follow-up (' || v_label || ')',
    (v_detected->>'type')::ticket_type, 'normal', 'open', 'call'
  ) returning id into v_ticket_id;

  insert into public.lifecycle_followup_actions (org_id, customer_part_schedule_id, action_type, service_ticket_id, created_by)
  values (v_org_id, p_schedule_id, 'service_request_created', v_ticket_id, auth.uid());

  return v_ticket_id;
end;
$$;
revoke all on function public.lifecycle_create_service_request(uuid) from public, anon;
grant execute on function public.lifecycle_create_service_request(uuid) to authenticated;

-- ── customer-facing read RPCs (same authorization shape as get_customer_due_parts) ─────
create or replace function public.get_customer_installed_products(p_customer_id uuid)
returns setof public.customer_installed_products
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_customer_org uuid;
begin
  select org_id into v_customer_org from public.customers where id = p_customer_id;
  if v_customer_org is null then
    return;
  end if;
  if auth.uid() is not null then
    if not coalesce(
      (public.current_org_id() = v_customer_org and public.is_staff())
      or public.current_customer_id() = p_customer_id
      or public.is_technician_customer(p_customer_id),
      false
    ) then
      raise exception 'get_customer_installed_products: not authorized for this customer';
    end if;
  end if;
  return query
    select * from public.customer_installed_products
    where customer_id = p_customer_id and status = 'active'
    order by installation_date desc;
end;
$$;
revoke all on function public.get_customer_installed_products(uuid) from public, anon;
grant execute on function public.get_customer_installed_products(uuid) to authenticated;

create or replace function public.get_customer_replacement_history(p_customer_id uuid)
returns table (
  id uuid,
  label text,
  replaced_date date,
  previous_due_date date,
  next_due_date date,
  product_id uuid,
  installed_product_id uuid
)
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_customer_org uuid;
begin
  select org_id into v_customer_org from public.customers where id = p_customer_id;
  if v_customer_org is null then
    return;
  end if;
  if auth.uid() is not null then
    if not coalesce(
      (public.current_org_id() = v_customer_org and public.is_staff())
      or public.current_customer_id() = p_customer_id
      or public.is_technician_customer(p_customer_id),
      false
    ) then
      raise exception 'get_customer_replacement_history: not authorized for this customer';
    end if;
  end if;
  return query
    select prh.id, cps.label, prh.replaced_date, prh.previous_due_date, prh.next_due_date,
           cip.product_id, cip.id as installed_product_id
    from public.part_replacement_history prh
    join public.customer_part_schedules cps on cps.id = prh.customer_part_schedule_id
    join public.customer_installed_products cip on cip.id = cps.installed_product_id
    where cip.customer_id = p_customer_id
    order by prh.replaced_date desc;
end;
$$;
revoke all on function public.get_customer_replacement_history(uuid) from public, anon;
grant execute on function public.get_customer_replacement_history(uuid) to authenticated;

-- ── Sales Daily Follow-ups surfacing (read helper the merge-bucket calls) ──────────────
-- Excludes anything snoozed into the future; test customers excluded same as everywhere else.
create or replace function public.get_lifecycle_followups_for_sales(p_org_id uuid)
returns table (
  schedule_id uuid,
  customer_id uuid,
  customer_name text,
  product_name text,
  label text,
  next_due_date date,
  status text
)
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if not coalesce(p_org_id = public.current_org_id() and public.is_sales_staff(), false) then
    raise exception 'get_lifecycle_followups_for_sales: not authorized';
  end if;
  return query
    select cps.id, cip.customer_id, c.name, p.name, cps.label, cps.next_due_date, cps.status
    from public.customer_part_schedules cps
    join public.customer_installed_products cip on cip.id = cps.installed_product_id
    join public.customers c on c.id = cip.customer_id
    join public.products p on p.id = cip.product_id
    where cps.org_id = p_org_id
      and cps.status in ('due_soon', 'due', 'overdue')
      and (cps.snoozed_until is null or cps.snoozed_until <= (now() at time zone 'Asia/Kolkata')::date)
      and not public.is_test_customer(cip.customer_id)
    order by cps.next_due_date;
end;
$$;
revoke all on function public.get_lifecycle_followups_for_sales(uuid) from public, anon;
grant execute on function public.get_lifecycle_followups_for_sales(uuid) to authenticated;
$mig1$;
  v_mig2_text text := $mig2$-- Product Lifecycle & Automated Service Reminder System — Drop 2, migration 3/3.
-- Standard release-wide anon-exposure sweep (hard rule), same pattern as Drop 1's.

revoke all on function
  public.lifecycle_mark_followup_contacted(uuid, text),
  public.lifecycle_snooze_followup(uuid, date),
  public.lifecycle_create_service_request(uuid),
  public.get_customer_installed_products(uuid),
  public.get_customer_replacement_history(uuid),
  public.get_lifecycle_followups_for_sales(uuid)
from public, anon;

revoke all on public.lifecycle_followup_actions from public, anon;

select
  n.nspname, p.proname, pg_catalog.pg_get_userbyid(p.proowner) as owner,
  has_function_privilege('anon', p.oid, 'EXECUTE') as anon_can_execute
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'lifecycle_mark_followup_contacted', 'lifecycle_snooze_followup',
    'lifecycle_create_service_request', 'get_customer_installed_products',
    'get_customer_replacement_history', 'get_lifecycle_followups_for_sales'
  )
  and has_function_privilege('anon', p.oid, 'EXECUTE');
$mig2$;

begin
  select md5(o.id::text || '|' || o.name) into v_org_fingerprint
  from public.organizations o where o.name not like '%__TEST_%' order by o.created_at asc limit 1;
  if v_org_fingerprint is null then
    raise exception 'ORG CHECK: no non-test organisation found -- refusing';
  end if;
  if v_org_fingerprint <> v_expected_org_fingerprint then
    raise exception 'ORG CHECK: fingerprint mismatch (expected %, got %) -- refusing', v_expected_org_fingerprint, v_org_fingerprint;
  end if;

  set lock_timeout = '5s';

  v_ist_hour := extract(hour from (now() at time zone 'Asia/Kolkata'));
  if v_ist_hour < 11 then
    raise exception 'GATE: refusing before 11:00 IST (current IST hour %)', v_ist_hour;
  end if;

  -- RUN the 3 migrations first (creates lifecycle_followup_actions etc. for this rehearsal
  -- transaction only) -- the BEFORE snapshot below reads this new table too, so it must exist
  -- first; what matters is this snapshot is taken before any throwaway test fixture is inserted.
  execute v_mig0_text;
  execute v_mig1_text;
  execute v_mig2_text;


  -- BEFORE snapshot of every real table this drop's migrations touch/create rows in
  select jsonb_build_object(
    'organizations', (select count(*) from public.organizations where name not like '%__TEST_%'),
    'customer_part_schedules', (select count(*) from public.customer_part_schedules cps
      join public.customer_installed_products cip on cip.id = cps.installed_product_id
      where not public.is_test_customer(cip.customer_id)),
    'lifecycle_followup_actions', (select count(*) from public.lifecycle_followup_actions a
      join public.customer_part_schedules cps on cps.id = a.customer_part_schedule_id
      join public.customer_installed_products cip on cip.id = cps.installed_product_id
      where not public.is_test_customer(cip.customer_id)),
    'service_tickets', (select count(*) from public.service_tickets st where not public.is_test_customer(st.customer_id))
  ) into v_real_counts_before;

  -- ---- throwaway test fixtures (helpers copied from the proven pg_temp.mkuser/as_user/as_pg
  -- mechanism already used successfully in the Drop 1 rehearsal) ----
  execute 'create temp table __lifecycle_drop2_rehearsal_marker (x int)';
  do $g$ begin execute format('alter default privileges in schema %s grant execute on functions to public', pg_my_temp_schema()::regnamespace); end $g$;
  create function pg_temp.mkuser(p_role text, p_org uuid) returns uuid language plpgsql as $f$
  declare v uuid := gen_random_uuid();
  begin
    insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
    values (v, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '__t_' || p_role || '_' || v || '@test.invalid', 'x', now(), now(), now(), '{}', '{}');
    insert into public.profiles (id, org_id, full_name, role, is_active) values (v, p_org, '__TEST_ ' || p_role, p_role::public.user_role, true);
    return v;
  end $f$;
  create function pg_temp.as_user(p_uid uuid) returns void language plpgsql as $f$
  begin perform set_config('request.jwt.claims', jsonb_build_object('sub', p_uid, 'role', 'authenticated')::text, true); execute 'set local role authenticated'; end $f$;
  create function pg_temp.as_pg() returns void language plpgsql as $f$
  begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $f$;

  insert into public.organizations (name) values ('__TEST_lifecycle_drop2_rehearsal_' || gen_random_uuid()) returning id into v_test_org;
  insert into public.organizations (name) values ('__TEST_lifecycle_drop2_other_org_' || gen_random_uuid()) returning id into v_other_org;
  insert into public.brands (org_id, name, category) values (v_test_org, '__TEST_ Brand', 'ro') returning id into v_brand;
  insert into public.models (org_id, brand_id, name) values (v_test_org, v_brand, '__TEST_ Model') returning id into v_model;
  insert into public.products (org_id, brand_id, model_id, name, category, price) values (v_test_org, v_brand, v_model, '__TEST_ Product', 'ro', 100) returning id into v_product;
  insert into public.customers (org_id, name, mobile, is_test) values (v_test_org, '__TEST_ Customer', '9000000001', true) returning id into v_cust;
  v_sales_profile := pg_temp.mkuser('sales_admin', v_test_org);
  v_other_master_profile := pg_temp.mkuser('master', v_other_org);

  insert into public.product_lifecycle_configs (org_id, product_id, lifetime_value, lifetime_unit) values (v_test_org, v_product, 5, 'years');
  insert into public.product_spare_schedules (org_id, product_id, label, interval_value, interval_unit) values (v_test_org, v_product, '__TEST_ Filter', 3, 'months');
  v_installed_id := public.create_installed_product(v_cust, v_product, current_date, null, false);
  select id into v_schedule_id from public.customer_part_schedules where installed_product_id = v_installed_id limit 1;
  update public.customer_part_schedules set status = 'due', next_due_date = current_date where id = v_schedule_id;

  -- sales of the test org can mark contacted / snooze / create a service request
  perform pg_temp.as_user(v_sales_profile);
  perform public.lifecycle_mark_followup_contacted(v_schedule_id, 'rehearsal note');
  perform public.lifecycle_snooze_followup(v_schedule_id, current_date + 10);
  select public.lifecycle_create_service_request(v_schedule_id) into v_ticket_id;
  v_results := v_results || jsonb_build_object('sales_actions_succeeded', v_ticket_id is not null);

  -- snooze excludes it from the sales list immediately (snoozed 10 days out)
  perform pg_temp.as_pg();
  perform pg_temp.as_user(v_sales_profile);
  v_results := v_results || jsonb_build_object('snoozed_excluded_from_sales_list', not exists (
    select 1 from public.get_lifecycle_followups_for_sales(v_test_org) f where f.schedule_id = v_schedule_id
  ));
  perform pg_temp.as_pg();

  -- a master of a DIFFERENT org is blocked from every one of the new RPCs
  perform pg_temp.as_user(v_other_master_profile);
  begin
    perform public.lifecycle_mark_followup_contacted(v_schedule_id, 'x');
    v_results := v_results || jsonb_build_object('cross_org_mark_contacted_blocked', false);
  exception when others then
    v_results := v_results || jsonb_build_object('cross_org_mark_contacted_blocked', sqlerrm like '%not authorized%');
  end;
  begin
    perform public.get_lifecycle_followups_for_sales(v_test_org);
    v_results := v_results || jsonb_build_object('cross_org_followups_list_blocked', false);
  exception when others then
    v_results := v_results || jsonb_build_object('cross_org_followups_list_blocked', sqlerrm like '%not authorized%');
  end;
  perform pg_temp.as_pg();

  -- AFTER snapshot -- must be byte-for-byte identical to BEFORE (everything above touched only
  -- __TEST_ rows; is_test_customer()/name-based filters exclude them from these counts anyway,
  -- and this whole transaction will be rolled back besides)
  select jsonb_build_object(
    'organizations', (select count(*) from public.organizations where name not like '%__TEST_%'),
    'customer_part_schedules', (select count(*) from public.customer_part_schedules cps
      join public.customer_installed_products cip on cip.id = cps.installed_product_id
      where not public.is_test_customer(cip.customer_id)),
    'lifecycle_followup_actions', (select count(*) from public.lifecycle_followup_actions a
      join public.customer_part_schedules cps on cps.id = a.customer_part_schedule_id
      join public.customer_installed_products cip on cip.id = cps.installed_product_id
      where not public.is_test_customer(cip.customer_id)),
    'service_tickets', (select count(*) from public.service_tickets st where not public.is_test_customer(st.customer_id))
  ) into v_real_counts_after;

  if v_real_counts_before is distinct from v_real_counts_after then
    raise exception 'FINGERPRINT MISMATCH: real-table counts changed during rehearsal (before=% after=%) -- this must never happen', v_real_counts_before, v_real_counts_after;
  end if;

  v_results := v_results || jsonb_build_object(
    'real_table_counts_before', v_real_counts_before,
    'real_table_counts_after', v_real_counts_after,
    'real_table_counts_unchanged', true,
    'org_fingerprint', v_org_fingerprint
  );

  raise exception 'RESULTS: %', v_results;
end;
$rehearsal$;
