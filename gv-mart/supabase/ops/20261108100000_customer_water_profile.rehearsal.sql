-- Rehearsal wrapper for 20261108100000_customer_water_profile.sql.
-- One DO block. Refuses before 18:00 IST. Recomputes sha256 of the embedded migration and test
-- text (encode(sha256(convert_to(text,'UTF8')),'hex') — explicit UTF8 bytes, not a bytea cast)
-- and compares against the pinned hashes below (must match the committed .sql files exactly,
-- LF line endings). Takes a real-org customers row-count fingerprint before and after. Runs
-- both via EXECUTE. No top-level BEGIN/COMMIT/SAVEPOINT/ROLLBACK: the block always ends in an
-- unconditional RAISE EXCEPTION, so the enclosing statement aborts and nothing persists
-- regardless of outcome. No existing live function is redefined by this migration (confirmed:
-- guard_water_profile_edit_roles, stamp_customer_health_profile and get_customer_health_condition
-- are all brand new — nothing with these names exists today), so there is no md5-live-definition
-- pre-check section here; that mechanism only applies when redefining something already live.
do $w$
declare
  v_migration text := $MIGRATION_BODY$-- Customer water and household profile. Spec: FEATURE_CUSTOMER_WATER_HOUSEHOLD_PROFILE.md.
--
-- Revised per reviewer feedback (2026-10-26): health_condition lives in its own table,
-- customer_health_profile, not a customers column. customers' own grants and column
-- privileges are completely untouched by this migration — no revoke/regrant of any kind on
-- public.customers. Water fields (source/TDS/pH) stay on customers as before.

-- ── water profile columns on customers (unchanged shape; reuses the existing
--    water_source_type enum — 20260915180000_ro_water_quality_readings.sql) ───────────────
alter table public.customers
  add column water_source water_source_type,
  add column water_source_other text check (water_source_other is null or char_length(water_source_other) <= 100),
  add column water_tds_ppm numeric(6, 2) check (water_tds_ppm is null or water_tds_ppm >= 0),
  add column water_ph numeric(4, 2) check (water_ph is null or water_ph between 0 and 14);

alter table public.customers
  add constraint customers_water_source_other_only_with_other
  check (water_source_other is null or water_source = 'other');

-- ── role guard for the 4 water columns only: master/operation_admin may change them;
--    operation_admin may change ONLY them (it has no other customers write access at all).
--    This governs who may UPDATE these values — it does not touch customers' SELECT grants
--    or any other column's privileges. SECURITY INVOKER: a client-detecting trigger, so no
--    current_user/session_user test is used (that's only disallowed inside SECURITY DEFINER,
--    and isn't needed here either way — it calls the existing current_role() stable helper,
--    same pattern as the pre-existing guard_customer_self_update trigger on this table). ────
create or replace function public.guard_water_profile_edit_roles()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_role public.user_role;
  v_water_changed boolean;
  v_other_changed boolean;
begin
  v_role := public.current_role();

  v_water_changed := (
    new.water_source is distinct from old.water_source
    or new.water_source_other is distinct from old.water_source_other
    or new.water_tds_ppm is distinct from old.water_tds_ppm
    or new.water_ph is distinct from old.water_ph
  );

  v_other_changed := (
    (to_jsonb(new) - array['water_source', 'water_source_other', 'water_tds_ppm', 'water_ph', 'updated_at'])
    is distinct from
    (to_jsonb(old) - array['water_source', 'water_source_other', 'water_tds_ppm', 'water_ph', 'updated_at'])
  );

  if v_role = 'operation_admin' and v_other_changed then
    raise exception 'customers: operation_admin may only edit the water profile fields';
  end if;

  if v_role is distinct from 'master' and v_role is distinct from 'operation_admin' and v_water_changed then
    raise exception 'customers: only master or operation_admin may edit the water profile fields';
  end if;

  return new;
end;
$$;

create trigger guard_water_profile_edit_roles
  before update on public.customers
  for each row execute function public.guard_water_profile_edit_roles();

-- operation_admin currently has NO write policy on customers at all — this grants it UPDATE
-- only (never insert/delete), org-scoped; the trigger above is what actually confines it to
-- the water columns, since RLS itself is row-level, not column-level.
create policy customers_write_operation_admin on public.customers
  for update
  using (org_id = public.current_org_id() and public.current_role() = 'operation_admin')
  with check (org_id = public.current_org_id() and public.current_role() = 'operation_admin');

-- ── technician visibility switch for health_condition (default off) ────────────────────────
alter table public.settings
  add column show_health_condition_to_technicians boolean not null default false;

-- ── health_condition: its own table. customers is not touched by any of this. ──────────────
create type household_health_level as enum ('none', 'normal', 'medium', 'high');

create table public.customer_health_profile (
  customer_id uuid primary key references public.customers (id) on delete cascade,
  org_id uuid not null references public.organizations (id) on delete cascade,
  health_condition household_health_level not null,
  updated_at timestamptz not null default now(),
  updated_by uuid references public.profiles (id)
);

create index customer_health_profile_org_id_idx on public.customer_health_profile (org_id);

-- Stamps updated_at/updated_by from the real caller — not an audit trigger (nothing is copied
-- to audit_log or anywhere else), just this row's own metadata. SECURITY INVOKER, no
-- current_user/session_user test.
create or replace function public.stamp_customer_health_profile()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  new.updated_at := now();
  new.updated_by := auth.uid();
  return new;
end;
$$;

create trigger stamp_customer_health_profile
  before insert or update on public.customer_health_profile
  for each row execute function public.stamp_customer_health_profile();

alter table public.customer_health_profile enable row level security;

-- master, operation_admin, sales_admin of the same org — reusing the existing is_staff()
-- helper (current_role() in ('master','operation_admin','sales_admin')), which is exactly
-- that role set. Read and write; no delete policy (not asked for).
create policy customer_health_profile_staff_select on public.customer_health_profile
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy customer_health_profile_staff_insert on public.customer_health_profile
  for insert with check (org_id = public.current_org_id() and public.is_staff());
create policy customer_health_profile_staff_update on public.customer_health_profile
  for update
  using (org_id = public.current_org_id() and public.is_staff())
  with check (org_id = public.current_org_id() and public.is_staff());

-- the customer — their own row, read-only (no insert/update policy for the customer role).
create policy customer_health_profile_select_own on public.customer_health_profile
  for select using (customer_id = public.current_customer_id());

-- Technicians get no policy at all here — zero table access, by omission. Ordinary table
-- grants (RLS still applies on top) so staff/the customer can reach the policies above.
grant select, insert, update on public.customer_health_profile to authenticated;

-- ── gated read, a technician's ONLY path to this value (SECURITY DEFINER, bypasses RLS/
--    grants entirely — not affected by anything above). Staff always; the customer, their
--    own row; a technician, only when the org setting is on AND they have (or had) an
--    appointment with that customer — same exists() shape as the pre-existing
--    customers_select_own_technician RLS policy. ───────────────────────────────────────────
create or replace function public.get_customer_health_condition(p_customer_id uuid)
returns household_health_level
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
  v_level household_health_level;
  v_technician_id uuid := public.current_technician_id();
begin
  select org_id into v_org_id from public.customers where id = p_customer_id;
  if v_org_id is null or v_org_id is distinct from public.current_org_id() then
    return null;
  end if;

  select health_condition into v_level from public.customer_health_profile where customer_id = p_customer_id;

  if public.is_staff() then
    return v_level;
  end if;

  if p_customer_id = public.current_customer_id() then
    return v_level;
  end if;

  if v_technician_id is not null
     and exists (select 1 from public.settings s where s.org_id = v_org_id and s.show_health_condition_to_technicians)
     and exists (
       select 1
       from public.service_tickets t
       join public.appointments a on a.ticket_id = t.id
       where t.customer_id = p_customer_id and a.technician_id = v_technician_id
     )
  then
    return v_level;
  end if;

  return null;
end;
$$;

revoke all on function public.get_customer_health_condition(uuid) from public, anon;
grant execute on function public.get_customer_health_condition(uuid) to authenticated;
$MIGRATION_BODY$;
  v_test text := $TEST_BODY$-- Rolled-back DB tests for migration 20261108100000_customer_water_profile. One transaction
-- ending in RAISE; read RESULTS in the error. Uses throwaway __TEST_ organisations created
-- inside the transaction only, so nothing persists and no real customer row is read or written.
create temp table res (n serial, line text);
grant all on res to public;
grant usage on sequence res_n_seq to public;
create function pg_temp.chk(p_name text, p_ok boolean, p_info text default '') returns void language plpgsql as $f$
begin insert into pg_temp.res(line) values (case when coalesce(p_ok,false) then 'PASS  ' else 'FAIL  ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end); end $f$;
create function pg_temp.mkuser(p_role text, p_org uuid) returns uuid language plpgsql as $f$
declare v uuid := gen_random_uuid();
begin
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
  values (v, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '__t_' || p_role || '_' || v || '@test.invalid', 'x', now(), now(), now(), '{}', '{}');
  insert into public.profiles (id, org_id, full_name, role, is_active) values (v, p_org, '__TEST_ ' || p_role, p_role::public.user_role, true)
    on conflict (id) do update set role = excluded.role, is_active = true, org_id = excluded.org_id;
  return v;
end $f$;
create function pg_temp.as_user(p_uid uuid) returns void language plpgsql as $f$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true); execute 'set local role authenticated'; end $f$;
create function pg_temp.as_pg() returns void language plpgsql as $f$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $f$;

do $t$
declare
  v_org uuid; v_org2 uuid;
  v_master uuid; v_opadmin uuid; v_salesadmin uuid; v_custprofile uuid; v_techprofile uuid; v_techprofile2 uuid;
  v_cust uuid; v_fp_before bigint; v_fp_after bigint;
  v_tech uuid; v_tech2 uuid; v_tk uuid; v_appt uuid; v_other_org_staff uuid;
  b boolean; txt text;
begin
  insert into organizations (name) values ('__TEST_water_profile_org') returning id into v_org;
  insert into organizations (name) values ('__TEST_water_profile_org2') returning id into v_org2;

  v_master := pg_temp.mkuser('master', v_org);
  v_opadmin := pg_temp.mkuser('operation_admin', v_org);
  v_salesadmin := pg_temp.mkuser('sales_admin', v_org);
  v_custprofile := pg_temp.mkuser('customer', v_org);
  v_techprofile := pg_temp.mkuser('technician', v_org);
  v_techprofile2 := pg_temp.mkuser('technician', v_org);
  insert into technicians (org_id, profile_id, is_active) values (v_org, v_techprofile, true) returning id into v_tech;
  insert into technicians (org_id, profile_id, is_active) values (v_org, v_techprofile2, true) returning id into v_tech2;

  insert into customers (org_id, name, mobile, primary_profile_id)
    values (v_org, '__TEST_ water profile customer', '9000000301', v_custprofile) returning id into v_cust;

  -- "a real organisation's customers are unchanged by the migration" fingerprint: taken on an
  -- org other than the throwaway ones above, before/after everything else in this test runs.
  select count(*) into v_fp_before from public.customers where org_id <> v_org and org_id <> v_org2;

  insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (v_org, v_cust, 'paid', '__TEST_ water profile job') returning id into v_tk;
  insert into appointments (org_id, ticket_id, mode, technician_id, status) values (v_org, v_tk, 'always', v_tech, 'in_progress') returning id into v_appt;

  -- ══ WATER FIELDS ON customers ══════════════════════════════════════════════════════════

  -- water_source enum + water_source_other rule
  perform pg_temp.as_user(v_master);
  update customers set water_source = 'corporation' where id = v_cust;
  update customers set water_source = 'borewater' where id = v_cust;
  update customers set water_source = 'other' where id = v_cust;
  perform pg_temp.chk('water_source accepts all 3 enum values', (select water_source from customers where id = v_cust) = 'other');

  begin update customers set water_source = 'corporation', water_source_other = 'well' where id = v_cust; b := true; exception when check_violation then b := false; end;
  perform pg_temp.chk('water_source_other is refused unless water_source = other', b = false);
  begin update customers set water_source = 'other', water_source_other = 'well water' where id = v_cust; b := true; exception when others then b := false; end;
  perform pg_temp.chk('water_source_other accepted with water_source = other', b);
  update customers set water_source_other = null where id = v_cust;

  -- pH: 0 and 14 accepted; -0.1 and 14.1 refused
  begin update customers set water_ph = -0.1 where id = v_cust; b := true; exception when check_violation then b := false; end;
  perform pg_temp.chk('pH of -0.1 refused', b = false);
  begin update customers set water_ph = 14.1 where id = v_cust; b := true; exception when check_violation then b := false; end;
  perform pg_temp.chk('pH of 14.1 refused', b = false);
  begin update customers set water_ph = 0 where id = v_cust; b := true; exception when others then b := false; end;
  perform pg_temp.chk('pH of 0 accepted', b);
  begin update customers set water_ph = 14 where id = v_cust; b := true; exception when others then b := false; end;
  perform pg_temp.chk('pH of 14 accepted', b);
  update customers set water_ph = 6.5 where id = v_cust;

  -- TDS
  begin update customers set water_tds_ppm = -1 where id = v_cust; b := true; exception when check_violation then b := false; end;
  perform pg_temp.chk('TDS below 0 refused', b = false);
  begin update customers set water_tds_ppm = 570 where id = v_cust; b := true; exception when others then b := false; end;
  perform pg_temp.chk('TDS of 570 accepted', b);
  perform pg_temp.as_pg();

  -- role write access: master, operation_admin can set the water columns; sales_admin,
  -- customer, technician cannot (sales_admin keeps its existing write access elsewhere)
  perform pg_temp.as_user(v_master);
  begin update customers set water_tds_ppm = 300 where id = v_cust; b := true; exception when others then b := false; end;
  perform pg_temp.chk('master can set the water fields', b);
  perform pg_temp.as_pg();

  perform pg_temp.as_user(v_opadmin);
  begin update customers set water_tds_ppm = 310, water_ph = 7, water_source = 'borewater' where id = v_cust; b := true; exception when others then b := false; end;
  perform pg_temp.chk('operation_admin can set the water fields', b);
  begin update customers set water_tds_ppm = 320, notes = 'operation_admin snuck a note in' where id = v_cust; b := true; exception when others then b := false; end;
  perform pg_temp.chk('operation_admin is refused when the same statement also touches a non-water column', b = false);
  perform pg_temp.as_pg();

  perform pg_temp.as_user(v_salesadmin);
  begin update customers set water_tds_ppm = 330 where id = v_cust; b := true; exception when others then b := false; end;
  perform pg_temp.chk('sales_admin is refused when touching a water column', b = false);
  begin update customers set notes = '__TEST_ sales admin note' where id = v_cust; b := true; exception when others then b := false; end;
  perform pg_temp.chk('sales_admin still has its existing write access to an unrelated column', b);
  perform pg_temp.as_pg();

  perform pg_temp.as_user(v_custprofile);
  begin update customers set water_tds_ppm = 340 where id = v_cust; b := true; exception when others then b := false; end;
  perform pg_temp.chk('a customer cannot set the water fields on their own row', b = false);
  perform pg_temp.as_pg();

  perform pg_temp.as_user(v_techprofile);
  begin update customers set water_tds_ppm = 350 where id = v_cust; b := true; exception when others then b := false; end;
  perform pg_temp.chk('a technician cannot write the water fields (no write policy at all)', b = false);
  perform pg_temp.as_pg();

  update customers set water_source = 'borewater', water_source_other = null, water_tds_ppm = 570, water_ph = 6.5 where id = v_cust;

  -- customers reads: a customer reads only their own profile; another org's staff read nothing
  perform pg_temp.as_user(v_custprofile);
  perform pg_temp.chk('the customer can read their own water_tds_ppm', (select water_tds_ppm from customers where id = v_cust) = 570);
  perform pg_temp.as_pg();

  v_other_org_staff := pg_temp.mkuser('master', v_org2);
  perform pg_temp.as_user(v_other_org_staff);
  perform pg_temp.chk('another organisation''s staff read zero customers rows for this customer', (select count(*) from customers where id = v_cust) = 0);
  perform pg_temp.as_pg();

  -- no family-member count column was added, and ro_checklists is untouched
  perform pg_temp.chk('no family-member count column was added to customers',
    not exists (select 1 from information_schema.columns where table_schema='public' and table_name='customers' and column_name in ('family_members','family_size','members_count')));
  perform pg_temp.chk('ro_checklists.water_tds_ppm column is unchanged by this migration',
    (select data_type from information_schema.columns where table_schema='public' and table_name='ro_checklists' and column_name='water_tds_ppm') = 'numeric');
  perform pg_temp.chk('health_condition is NOT a column on customers (lives in its own table)',
    not exists (select 1 from information_schema.columns where table_schema='public' and table_name='customers' and column_name='health_condition'));

  -- ══ customer_health_profile (its own table) ═══════════════════════════════════════════

  -- write access: master, operation_admin, sales_admin (is_staff()) can insert/update;
  -- customer and technician cannot
  perform pg_temp.as_user(v_master);
  begin
    insert into customer_health_profile (customer_id, org_id, health_condition) values (v_cust, v_org, 'high');
    b := true;
  exception when others then b := false; end;
  perform pg_temp.chk('master can insert a health_condition row', b);
  perform pg_temp.chk('updated_by is stamped from auth.uid(), not client-supplied', (select updated_by from customer_health_profile where customer_id = v_cust) = v_master);
  perform pg_temp.as_pg();

  perform pg_temp.as_user(v_opadmin);
  begin update customer_health_profile set health_condition = 'medium' where customer_id = v_cust; b := true; exception when others then b := false; end;
  perform pg_temp.chk('operation_admin can update health_condition', b and (select updated_by from customer_health_profile where customer_id = v_cust) = v_opadmin);
  perform pg_temp.as_pg();

  perform pg_temp.as_user(v_salesadmin);
  begin update customer_health_profile set health_condition = 'medium' where customer_id = v_cust; b := true; exception when others then b := false; end;
  perform pg_temp.chk('sales_admin can update health_condition (is_staff())', b);
  perform pg_temp.as_pg();

  perform pg_temp.as_user(v_custprofile);
  begin update customer_health_profile set health_condition = 'none' where customer_id = v_cust; b := true; exception when others then b := false; end;
  perform pg_temp.chk('a customer cannot write their own health_condition row', b = false);
  perform pg_temp.as_pg();

  perform pg_temp.as_user(v_techprofile);
  begin update customer_health_profile set health_condition = 'none' where customer_id = v_cust; b := true; exception when others then b := false; end;
  perform pg_temp.chk('a technician cannot write customer_health_profile at all', b = false);
  perform pg_temp.as_pg();

  -- health_condition enum itself refuses an out-of-range value
  begin execute format('insert into customer_health_profile (customer_id, org_id, health_condition) values (%L, %L, %L)', gen_random_uuid(), v_org, 'critical'); b := true; exception when invalid_text_representation then b := false; end;
  perform pg_temp.chk('health_condition enum refuses a value outside the 4 levels', b = false);

  -- reset to a known value for the read checks below
  update customer_health_profile set health_condition = 'medium' where customer_id = v_cust;

  -- direct-table reads: staff yes; the customer their own row; a technician NEVER (no policy
  -- at all, regardless of the show_health_condition_to_technicians setting); another org's
  -- staff read nothing
  perform pg_temp.as_user(v_master);
  perform pg_temp.chk('staff reads the row directly from customer_health_profile', (select health_condition from customer_health_profile where customer_id = v_cust) = 'medium');
  perform pg_temp.as_pg();

  perform pg_temp.as_user(v_custprofile);
  perform pg_temp.chk('the customer reads their own customer_health_profile row directly', (select health_condition from customer_health_profile where customer_id = v_cust) = 'medium');
  perform pg_temp.chk('the customer reads NO ONE ELSE''S customer_health_profile row', (select count(*) from customer_health_profile where customer_id <> v_cust) = 0);
  perform pg_temp.as_pg();

  perform pg_temp.as_user(v_other_org_staff);
  perform pg_temp.chk('another organisation''s staff read zero customer_health_profile rows for this customer', (select count(*) from customer_health_profile where customer_id = v_cust) = 0);
  perform pg_temp.as_pg();

  perform pg_temp.as_user(v_techprofile);
  perform pg_temp.chk('a technician reads ZERO rows directly from customer_health_profile (setting off)', (select count(*) from customer_health_profile where customer_id = v_cust) = 0);
  perform pg_temp.as_pg();

  -- get_customer_health_condition: the function path
  perform pg_temp.as_user(v_techprofile);
  perform pg_temp.chk('technician cannot read health via the function either while the setting is off', (select public.get_customer_health_condition(v_cust)) is null);
  perform pg_temp.as_pg();

  update settings set show_health_condition_to_technicians = true where org_id = v_org;

  perform pg_temp.as_user(v_techprofile);
  perform pg_temp.chk('technician reads ZERO rows directly even with the setting ON (no table policy exists for them)', (select count(*) from customer_health_profile where customer_id = v_cust) = 0);
  perform pg_temp.chk('technician reads the level via the function ONLY, once the setting is on and they have an appointment', (select public.get_customer_health_condition(v_cust)) = 'medium');
  perform pg_temp.as_pg();

  perform pg_temp.as_user(v_techprofile2);
  perform pg_temp.chk('a different technician with no appointment for this customer still gets nothing from the function', (select public.get_customer_health_condition(v_cust)) is null);
  perform pg_temp.as_pg();

  perform pg_temp.as_user(v_master);
  perform pg_temp.chk('staff gets the level from the function too', (select public.get_customer_health_condition(v_cust)) = 'medium');
  perform pg_temp.as_pg();

  perform pg_temp.as_user(v_custprofile);
  perform pg_temp.chk('the customer gets their own level from the function too', (select public.get_customer_health_condition(v_cust)) = 'medium');
  perform pg_temp.as_pg();

  -- fingerprint: a real org's customers are unchanged by this migration
  select count(*) into v_fp_after from public.customers where org_id <> v_org and org_id <> v_org2;
  perform pg_temp.chk('a real organisation''s customer row count is unchanged by the migration', v_fp_after = v_fp_before);

  select string_agg(r2.line, E'\n' order by r2.n) into txt from pg_temp.res r2;
  raise exception E'RESULTS\n%', txt;
end $t$;
$TEST_BODY$;
  v_mig_hash text;
  v_test_hash text;
  v_result text;
  v_wrapper_fp_before bigint;
  v_wrapper_fp_after bigint;
begin
  if (clock_timestamp() at time zone 'Asia/Kolkata')::time < time '18:00' then
    raise exception 'rehearsal refused: must run at or after 18:00 IST';
  end if;

  -- real-org fingerprint, outside the __TEST_ organisations the embedded test creates for
  -- itself — taken at the wrapper level too, before the migration runs at all.
  select count(*) into v_wrapper_fp_before
  from public.customers
  where org_id not in (select id from public.organizations where name like '\_\_TEST\_%' escape '\');

  v_mig_hash := encode(sha256(convert_to(v_migration, 'UTF8')), 'hex');
  v_test_hash := encode(sha256(convert_to(v_test, 'UTF8')), 'hex');

  if v_mig_hash <> '0f5d96fc5ffdfb1364649e285d704ec9f68cb2219f24a60608e3285ac47d7c6e' then
    raise exception 'migration hash mismatch: expected 0f5d96fc5ffdfb1364649e285d704ec9f68cb2219f24a60608e3285ac47d7c6e, got %', v_mig_hash;
  end if;
  if v_test_hash <> 'aff0557ef28430200a003f0cfc05bc95eee5c03408d5bd1cb1e16695bae0c096' then
    raise exception 'test hash mismatch: expected aff0557ef28430200a003f0cfc05bc95eee5c03408d5bd1cb1e16695bae0c096, got %', v_test_hash;
  end if;

  execute v_migration;

  begin
    execute v_test;
    v_result := 'RESULTS(test did not raise -- unexpected, treat as FAIL)';
  exception when others then
    v_result := sqlerrm;
  end;

  select count(*) into v_wrapper_fp_after
  from public.customers
  where org_id not in (select id from public.organizations where name like '\_\_TEST\_%' escape '\');

  raise exception E'wrapper-level real-org customers fingerprint: before=% after=% (match=%)\n%',
    v_wrapper_fp_before, v_wrapper_fp_after, (v_wrapper_fp_before = v_wrapper_fp_after), v_result;
end
$w$;
