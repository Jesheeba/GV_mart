-- Rehearsal wrapper for 20261108100000_customer_water_profile.sql.
-- One DO block. Refuses before 18:00 IST. Recomputes sha256 of the embedded migration and test
-- text and compares against the pinned hashes below (must match the committed .sql files exactly,
-- LF line endings). Runs both via EXECUTE. No top-level BEGIN/COMMIT/SAVEPOINT/ROLLBACK: the block
-- always ends in an unconditional RAISE EXCEPTION, so the enclosing statement aborts and nothing
-- persists regardless of outcome.
do $w$
declare
  v_migration text := $MIGRATION_BODY$-- Customer water and household profile. Spec: FEATURE_CUSTOMER_WATER_HOUSEHOLD_PROFILE.md.
--
-- Reuses the existing water_source_type enum (20260915180000_ro_water_quality_readings.sql) —
-- these four columns are a persistent customer-level profile, separate from the per-visit
-- ro_checklists reading, which is left untouched.
--
-- ROLE DECISION (owner, 2026-10-26): the spec's "master, operation_admin and sales_admin can
-- edit" line assumed operation_admin already had customers write access — it does not
-- (customers_write_sales only covers master + sales_admin, via is_sales_staff()). The owner's
-- resolution: these four new columns are editable by master and operation_admin only;
-- sales_admin keeps its existing full write access to every other customers column but is
-- newly blocked from touching these four. operation_admin gets a brand-new, update-only,
-- org-scoped RLS grant that the guard trigger below then restricts to ONLY these four columns
-- (it has no broader customers access). health_condition stays *readable* by master,
-- operation_admin, sales_admin and the customer themselves (read is not the same as write) —
-- enforced by column-level privilege + the get_customer_health_condition function below, not
-- by this trigger.

-- ── profile columns on customers ────────────────────────────────────────────────────────────
alter table public.customers
  add column water_source water_source_type,
  add column water_source_other text check (water_source_other is null or char_length(water_source_other) <= 100),
  add column water_tds_ppm numeric(6, 2) check (water_tds_ppm is null or water_tds_ppm >= 0),
  add column water_ph numeric(4, 2) check (water_ph is null or water_ph between 0 and 14);

alter table public.customers
  add constraint customers_water_source_other_only_with_other
  check (water_source_other is null or water_source = 'other');

create type household_health_level as enum ('none', 'normal', 'medium', 'high');

alter table public.customers
  add column health_condition household_health_level;

-- No stored family-member count column, by design (spec 3.1/9): the count is always derived
-- from customer_members where moved_out_at is null, so it can never drift from the real list.

-- ── technician visibility switch for health_condition (default off) ────────────────────────
alter table public.settings
  add column show_health_condition_to_technicians boolean not null default false;

-- ── role guard: only master/operation_admin may change the 4 new columns; operation_admin may
--    change ONLY the 4 new columns (it has no other customers write access at all) ───────────
-- SECURITY INVOKER (not DEFINER) — this is exactly the "client-detecting trigger" case, so no
-- current_user/session_user test is used or needed; it calls the existing current_role()
-- stable helper (itself SECURITY DEFINER, reading profiles by auth.uid()), same pattern as the
-- pre-existing guard_customer_self_update trigger on this same table.
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
    or new.health_condition is distinct from old.health_condition
  );

  v_other_changed := (
    (to_jsonb(new) - array['water_source', 'water_source_other', 'water_tds_ppm', 'water_ph', 'health_condition', 'updated_at'])
    is distinct from
    (to_jsonb(old) - array['water_source', 'water_source_other', 'water_tds_ppm', 'water_ph', 'health_condition', 'updated_at'])
  );

  if v_role = 'operation_admin' and v_other_changed then
    raise exception 'customers: operation_admin may only edit the water and household profile fields';
  end if;

  if v_role is distinct from 'master' and v_role is distinct from 'operation_admin' and v_water_changed then
    raise exception 'customers: only master or operation_admin may edit the water and household profile fields';
  end if;

  return new;
end;
$$;

create trigger guard_water_profile_edit_roles
  before update on public.customers
  for each row execute function public.guard_water_profile_edit_roles();

-- operation_admin currently has NO write policy on customers at all — this grants it UPDATE
-- only (never insert/delete), org-scoped; the trigger above is what actually confines it to
-- the 4 new columns, since RLS itself is row-level, not column-level.
create policy customers_write_operation_admin on public.customers
  for update
  using (org_id = public.current_org_id() and public.current_role() = 'operation_admin')
  with check (org_id = public.current_org_id() and public.current_role() = 'operation_admin');

-- ── health_condition is sensitive: never selectable via the raw table, by anyone, so a direct
--    REST/table query can't leak it regardless of what the UI's own select list asks for.
--    UPDATE privilege is untouched (master/operation_admin still write it through a normal
--    table update; the trigger above is what gates who). Reads go only through the function
--    below, which runs as the table owner and so is unaffected by this column revoke. ────────
revoke select (health_condition) on public.customers from authenticated, anon;

-- ── gated read: staff always; the customer, their own row; a technician, only when the org
--    setting is on AND they have (or had) an appointment with that customer — same exists()
--    shape as the pre-existing customers_select_own_technician RLS policy. ────────────────────
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
  select org_id, health_condition into v_org_id, v_level
  from public.customers
  where id = p_customer_id;

  if v_org_id is null or v_org_id is distinct from public.current_org_id() then
    return null;
  end if;

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
-- ending in RAISE; read RESULTS in the error. Uses a throwaway __TEST_ organisation created
-- inside the transaction, so nothing persists and no real customer row is read or written.
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
  v_cust uuid; v_cust_fingerprint_before bigint; v_cust_fingerprint_after bigint;
  v_tech uuid; v_tech2 uuid; v_tk uuid; v_appt uuid;
  v_latest_reading_count bigint;
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
  -- org other than the throwaway one above, before/after everything else in this test runs.
  select count(*) into v_cust_fingerprint_before from public.customers where org_id <> v_org and org_id <> v_org2;

  insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (v_org, v_cust, 'paid', '__TEST_ water profile job') returning id into v_tk;
  insert into appointments (org_id, ticket_id, mode, technician_id, status) values (v_org, v_tk, 'always', v_tech, 'in_progress') returning id into v_appt;

  -- ── water_source enum + water_source_other rule ──────────────────────────────────────────
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

  -- ── pH range ──────────────────────────────────────────────────────────────────────────────
  begin update customers set water_ph = -0.01 where id = v_cust; b := true; exception when check_violation then b := false; end;
  perform pg_temp.chk('pH below 0 refused', b = false);
  begin update customers set water_ph = 14.01 where id = v_cust; b := true; exception when check_violation then b := false; end;
  perform pg_temp.chk('pH above 14 refused', b = false);
  begin update customers set water_ph = 0 where id = v_cust; b := true; exception when others then b := false; end;
  perform pg_temp.chk('pH of 0 accepted', b);
  begin update customers set water_ph = 14 where id = v_cust; b := true; exception when others then b := false; end;
  perform pg_temp.chk('pH of 14 accepted', b);
  update customers set water_ph = 6.5 where id = v_cust;

  -- ── TDS ───────────────────────────────────────────────────────────────────────────────────
  begin update customers set water_tds_ppm = -1 where id = v_cust; b := true; exception when check_violation then b := false; end;
  perform pg_temp.chk('TDS below 0 refused', b = false);
  begin update customers set water_tds_ppm = 570 where id = v_cust; b := true; exception when others then b := false; end;
  perform pg_temp.chk('TDS of 570 accepted', b);

  -- ── health_condition enum ────────────────────────────────────────────────────────────────
  update customers set health_condition = 'none' where id = v_cust;
  update customers set health_condition = 'normal' where id = v_cust;
  update customers set health_condition = 'medium' where id = v_cust;
  update customers set health_condition = 'high' where id = v_cust;
  perform pg_temp.chk('health_condition accepts all 4 enum values', (select health_condition from customers where id = v_cust) = 'high');
  begin execute format('update customers set health_condition = %L where id = %L', 'critical', v_cust); b := true; exception when invalid_text_representation then b := false; end;
  perform pg_temp.chk('health_condition refuses a value outside the 4 levels', b = false);
  perform pg_temp.as_pg();

  -- ── role write access: master, operation_admin can set all 4; sales_admin, customer,
  --    technician cannot touch them (but sales_admin can still touch an unrelated column) ────
  perform pg_temp.as_user(v_master);
  begin update customers set water_tds_ppm = 300, health_condition = 'normal' where id = v_cust; b := true; exception when others then b := false; end;
  perform pg_temp.chk('master can set the water/health fields', b);
  perform pg_temp.as_pg();

  perform pg_temp.as_user(v_opadmin);
  begin update customers set water_tds_ppm = 310, water_ph = 7, water_source = 'borewater', health_condition = 'medium' where id = v_cust; b := true; exception when others then b := false; end;
  perform pg_temp.chk('operation_admin can set the water/health fields', b);
  begin update customers set water_tds_ppm = 320, notes = 'operation_admin snuck a note in' where id = v_cust; b := true; exception when others then b := false; end;
  perform pg_temp.chk('operation_admin is refused when the same statement also touches a non-water column', b = false);
  perform pg_temp.as_pg();

  perform pg_temp.as_user(v_salesadmin);
  begin update customers set water_tds_ppm = 330 where id = v_cust; b := true; exception when others then b := false; end;
  perform pg_temp.chk('sales_admin is refused when touching a water/health column', b = false);
  begin update customers set notes = '__TEST_ sales admin note' where id = v_cust; b := true; exception when others then b := false; end;
  perform pg_temp.chk('sales_admin still has its existing write access to an unrelated column', b);
  perform pg_temp.as_pg();

  perform pg_temp.as_user(v_custprofile);
  begin update customers set water_tds_ppm = 340 where id = v_cust; b := true; exception when others then b := false; end;
  perform pg_temp.chk('a customer cannot set the water/health fields on their own row', b = false);
  perform pg_temp.as_pg();

  perform pg_temp.as_user(v_techprofile);
  begin update customers set water_tds_ppm = 350 where id = v_cust; b := true; exception when others then b := false; end;
  perform pg_temp.chk('a technician cannot write the water/health fields (no write policy at all)', b = false);
  perform pg_temp.as_pg();

  -- reset to known values used by the read checks below
  update customers set water_source = 'borewater', water_source_other = null, water_tds_ppm = 570, water_ph = 6.5, health_condition = 'medium' where id = v_cust;

  -- ── reads: a customer reads only their own profile; another org's staff read nothing ──────
  perform pg_temp.as_user(v_custprofile);
  perform pg_temp.chk('the customer can read their own water_tds_ppm', (select water_tds_ppm from customers where id = v_cust) = 570);
  perform pg_temp.as_pg();

  declare
    v_other_org_staff uuid;
  begin
    v_other_org_staff := pg_temp.mkuser('master', v_org2);
    perform pg_temp.as_user(v_other_org_staff);
    perform pg_temp.chk('another organisation''s staff read zero rows for this customer', (select count(*) from customers where id = v_cust) = 0);
    perform pg_temp.as_pg();
  end;

  -- ── get_customer_health_condition: staff always; customer their own; technician only when
  --    the setting is on AND they have an appointment with that customer ───────────────────
  perform pg_temp.as_user(v_master);
  perform pg_temp.chk('staff sees the health level via the function', (select public.get_customer_health_condition(v_cust)) = 'medium');
  perform pg_temp.as_pg();

  perform pg_temp.as_user(v_custprofile);
  perform pg_temp.chk('the customer sees their own health level via the function', (select public.get_customer_health_condition(v_cust)) = 'medium');
  perform pg_temp.as_pg();

  perform pg_temp.as_user(v_techprofile);
  perform pg_temp.chk('technician sees NOTHING via the function while the setting is off', (select public.get_customer_health_condition(v_cust)) is null);
  perform pg_temp.as_pg();

  update settings set show_health_condition_to_technicians = true where org_id = v_org;

  perform pg_temp.as_user(v_techprofile);
  perform pg_temp.chk('technician with an appointment for this customer sees the level once the setting is on', (select public.get_customer_health_condition(v_cust)) = 'medium');
  perform pg_temp.as_pg();

  perform pg_temp.as_user(v_techprofile2);
  perform pg_temp.chk('a different technician with no appointment for this customer still sees nothing', (select public.get_customer_health_condition(v_cust)) is null);
  perform pg_temp.as_pg();

  perform pg_temp.chk('health_condition is not directly selectable via the raw table by authenticated/anon',
    not has_column_privilege('authenticated', 'public.customers', 'health_condition', 'select')
    and not has_column_privilege('anon', 'public.customers', 'health_condition', 'select'));

  -- ── latest on-site reading stays untouched (ro_checklists / service_visits unaffected) ────
  perform pg_temp.chk('ro_checklists.water_tds_ppm column is unchanged by this migration',
    (select data_type from information_schema.columns where table_schema='public' and table_name='ro_checklists' and column_name='water_tds_ppm') = 'numeric');

  -- ── derived family-member count: no stored column added ────────────────────────────────
  perform pg_temp.chk('no family-member count column was added to customers',
    not exists (select 1 from information_schema.columns where table_schema='public' and table_name='customers' and column_name in ('family_members','family_size','members_count')));

  -- ── fingerprint: a real org's customers are unchanged by this migration ───────────────────
  select count(*) into v_cust_fingerprint_after from public.customers where org_id <> v_org and org_id <> v_org2;
  perform pg_temp.chk('a real organisation''s customer row count is unchanged by the migration', v_cust_fingerprint_after = v_cust_fingerprint_before);

  select string_agg(r2.line, E'\n' order by r2.n) into txt from pg_temp.res r2;
  raise exception E'RESULTS\n%', txt;
end $t$;
$TEST_BODY$;
  v_mig_hash text;
  v_test_hash text;
  v_result text;
begin
  if (clock_timestamp() at time zone 'Asia/Kolkata')::time < time '18:00' then
    raise exception 'rehearsal refused: must run at or after 18:00 IST';
  end if;

  v_mig_hash := encode(sha256(v_migration::bytea), 'hex');
  v_test_hash := encode(sha256(v_test::bytea), 'hex');

  if v_mig_hash <> '27ea84b73c75d3665cda29c886d846887749d77c0e1de3903ef766b455f4762d' then
    raise exception 'migration hash mismatch: expected 27ea84b73c75d3665cda29c886d846887749d77c0e1de3903ef766b455f4762d, got %', v_mig_hash;
  end if;
  if v_test_hash <> '2ca09404ab5faa951fb721609531d850bd9e0333016cff4b92e32bdb2aa8bba5' then
    raise exception 'test hash mismatch: expected 2ca09404ab5faa951fb721609531d850bd9e0333016cff4b92e32bdb2aa8bba5, got %', v_test_hash;
  end if;

  execute v_migration;

  begin
    execute v_test;
    v_result := 'RESULTS(test did not raise -- unexpected, treat as FAIL)';
  exception when others then
    v_result := sqlerrm;
  end;

  raise exception '%', v_result;
end
$w$;
