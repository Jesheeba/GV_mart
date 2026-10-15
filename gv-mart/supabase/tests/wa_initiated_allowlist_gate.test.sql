-- Rolled-back DB tests for 20261025200000_wa_initiated_allowlist_gate.
-- NOT RUN (written for review). Run only through the rehearsal wrapper the owner approves
-- (supabase/rehearsals/rehearsal_20261025200000_wa_initiated_allowlist_gate.sql): the wrapper applies the migration and then
-- this file in ONE request; this file ends in an unconditional RAISE, so nothing is committed. A throwaway __TEST_ organisation
-- only; nothing is sent; no real row is written. The real organisation's leads are read (baseline B) and never written.
--
-- The wrapper stores the object counts it measured BEFORE the migration in transaction-local settings:
--   rehearsal.cols_before  rehearsal.funcs_before  rehearsal.trigs_before
-- so the structural checks are relative (+1 column, +1 function, +1 trigger) and keep working after other migrations land.
--
-- PINNED (read-only values; the owner's run order says to re-read the two md5 values just before the run and refuse on a diff):
--   _trg_settings_wa_test_guard  a4280dd157e636140c4eab88e3408702
--   audit_master_change          030f4b88111c5e4d7722970754a5748d
--   baseline B, real organisation: 64 leads, identity 1649051d, updated_at a314b149
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
create function pg_temp.as_service() returns void language plpgsql as $f$
begin perform set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true); execute 'set local role service_role'; end $f$;
create function pg_temp.as_pg() returns void language plpgsql as $f$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $f$;
-- one UPDATE of the gate column as whoever is current; returns 'rows=N' or 'ERR:<message>'
create function pg_temp.upd_gate(p_org uuid, p_val boolean) returns text language plpgsql as $f$
declare n int;
begin
  update public.settings set wa_initiated_allowlist_only = p_val where org_id = p_org;
  get diagnostics n = row_count;
  return 'rows=' || n;
exception when others then return 'ERR:' || sqlerrm; end $f$;
create function pg_temp.upd_other(p_org uuid) returns text language plpgsql as $f$
declare n int;
begin
  update public.settings set gst_rate = gst_rate where org_id = p_org;
  get diagnostics n = row_count;
  return 'rows=' || n;
exception when others then return 'ERR:' || sqlerrm; end $f$;

do $t$
declare
  v_org     uuid;
  v_master  uuid;
  v_sales   uuid;
  v_ops     uuid;
  v_cust    uuid;
  v_real    uuid := 'b6822905-5557-4e43-a606-f26ecfd5a541';
  v_def     text;
  s         text;
  v         boolean;
  n         int;
  v_id      text;
  v_upd     text;
  v_cols0   int := current_setting('rehearsal.cols_before')::int;
  v_funcs0  int := current_setting('rehearsal.funcs_before')::int;
  v_trigs0  int := current_setting('rehearsal.trigs_before')::int;
begin
  -- ---------- pinned objects the migration must not change ----------
  perform pg_temp.chk('pin: _trg_settings_wa_test_guard unchanged',
    md5(pg_get_functiondef('public._trg_settings_wa_test_guard'::regproc)) = 'a4280dd157e636140c4eab88e3408702');
  perform pg_temp.chk('pin: audit_master_change unchanged',
    md5(pg_get_functiondef('public.audit_master_change'::regproc)) = '030f4b88111c5e4d7722970754a5748d');

  -- ---------- structure, relative to the counts taken before the migration ----------
  perform pg_temp.chk('exactly one new settings column',
    (select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'settings') = v_cols0 + 1);
  perform pg_temp.chk('exactly one new public function',
    (select count(*) from pg_proc where pronamespace = 'public'::regnamespace) = v_funcs0 + 1);
  perform pg_temp.chk('exactly one new trigger on settings',
    (select count(*) from pg_trigger where tgrelid = 'public.settings'::regclass and not tgisinternal) = v_trigs0 + 1);
  perform pg_temp.chk('column is boolean not null default true',
    exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'settings' and column_name = 'wa_initiated_allowlist_only'
               and data_type = 'boolean' and is_nullable = 'NO' and column_default = 'true'));
  perform pg_temp.chk('every existing settings row reads true (gate closed by default)',
    (select count(*) from public.settings where wa_initiated_allowlist_only is distinct from true) = 0);
  perform pg_temp.chk('guard trigger is BEFORE UPDATE FOR EACH ROW and enabled',
    exists (select 1 from pg_trigger t
             where t.tgrelid = 'public.settings'::regclass and t.tgname = 'settings_wa_initiated_guard'
               and t.tgenabled = 'O' and (t.tgtype & 2) = 2 and (t.tgtype & 16) = 16 and (t.tgtype & 1) = 1));

  -- ---------- ACL ----------
  perform pg_temp.chk('guard function: anon and authenticated cannot execute',
    not has_function_privilege('anon', 'public._trg_settings_wa_initiated_guard()', 'execute')
    and not has_function_privilege('authenticated', 'public._trg_settings_wa_initiated_guard()', 'execute'));
  perform pg_temp.chk('guard function: no PUBLIC execute in the ACL',
    not exists (select 1 from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                 where p.oid = 'public._trg_settings_wa_initiated_guard()'::regprocedure and a.grantee = 0 and a.privilege_type = 'EXECUTE'));
  v_def := pg_get_functiondef('public._trg_settings_wa_initiated_guard'::regproc);
  perform pg_temp.chk('guard function has an empty search_path', v_def like '%SET search_path TO ''''%');

  -- ---------- behaviour ----------
  insert into organizations (name) values ('__TEST_initiated_gate') returning id into v_org;
  insert into settings (org_id) values (v_org) on conflict (org_id) do nothing;
  v_master := pg_temp.mkuser('master', v_org);
  v_sales  := pg_temp.mkuser('sales_admin', v_org);
  v_ops    := pg_temp.mkuser('operation_admin', v_org);
  v_cust   := pg_temp.mkuser('customer', v_org);
  perform pg_temp.chk('throwaway organisation starts with the gate closed',
    (select wa_initiated_allowlist_only from settings where org_id = v_org) is true);

  -- 1. as shipped, row security already stops a non-master before the trigger is reached: 0 rows, value unchanged
  perform pg_temp.as_user(v_sales);
  s := pg_temp.upd_gate(v_org, false);
  perform pg_temp.as_pg();
  perform pg_temp.chk('sales_admin: row security refuses the update (0 rows, no error), gate still true',
    s = 'rows=0' and (select wa_initiated_allowlist_only from settings where org_id = v_org) is true, s);

  -- 2. the trigger is the second line of defence. To exercise it itself, open an UPDATE policy for this rolled-back
  --    transaction only, so a non-master row passes row security and reaches the trigger.
  create policy rehearsal_open_update on public.settings for update to authenticated using (true) with check (true);

  perform pg_temp.as_user(v_sales);
  s := pg_temp.upd_gate(v_org, false);
  perform pg_temp.as_pg();
  perform pg_temp.chk('authenticated NON-master (sales_admin): refused by the trigger with its own message',
    s like 'ERR:%only a master can change the initiated-send gate%'
    and (select wa_initiated_allowlist_only from settings where org_id = v_org) is true, s);

  perform pg_temp.as_user(v_ops);
  s := pg_temp.upd_gate(v_org, false);
  perform pg_temp.as_pg();
  perform pg_temp.chk('authenticated NON-master (operation_admin): refused by the trigger',
    s like 'ERR:%only a master can change the initiated-send gate%', s);

  perform pg_temp.as_user(v_cust);
  s := pg_temp.upd_gate(v_org, false);
  perform pg_temp.as_pg();
  perform pg_temp.chk('authenticated customer-role user: refused by the trigger',
    s like 'ERR:%only a master can change the initiated-send gate%', s);

  perform pg_temp.as_user(v_sales);
  s := pg_temp.upd_other(v_org);
  perform pg_temp.as_pg();
  perform pg_temp.chk('the same non-master can still update another settings column (the guard is only about this column)',
    s = 'rows=1', s);

  perform pg_temp.as_user(v_master);
  s := pg_temp.upd_gate(v_org, false);
  v := (select wa_initiated_allowlist_only from settings where org_id = v_org);
  perform pg_temp.as_pg();
  perform pg_temp.chk('authenticated MASTER: the update succeeds and the gate reads false', s = 'rows=1' and v is false, s);

  perform pg_temp.as_user(v_master);
  s := pg_temp.upd_gate(v_org, true);
  perform pg_temp.as_pg();
  perform pg_temp.chk('authenticated MASTER can close the gate again', s = 'rows=1', s);

  perform pg_temp.as_pg();
  s := pg_temp.upd_gate(v_org, false);
  perform pg_temp.chk('owner role (postgres): the update succeeds', s = 'rows=1', s);
  s := pg_temp.upd_gate(v_org, true);

  perform pg_temp.as_service();
  s := pg_temp.upd_gate(v_org, false);
  perform pg_temp.as_pg();
  perform pg_temp.chk('service_role: the update succeeds',
    s = 'rows=1' and (select wa_initiated_allowlist_only from settings where org_id = v_org) is false, s);

  -- 3. null is refused by the column itself
  s := null;
  begin
    update public.settings set wa_initiated_allowlist_only = null where org_id = v_org;
  exception when others then s := sqlerrm; end;
  perform pg_temp.chk('the column refuses null', s is not null, coalesce(s, 'accepted'));

  -- ---------- baseline B ----------
  select count(*), left(md5(string_agg(id::text, ',' order by id)), 8),
         left(md5(string_agg(id::text || ':' || updated_at::text, ',' order by id)), 8)
    into n, v_id, v_upd from public.leads where org_id = v_real;
  perform pg_temp.chk('baseline B: 64 leads', n = 64, n::text);
  perform pg_temp.chk('baseline B: identity hash 1649051d', v_id = '1649051d', v_id);
  perform pg_temp.chk('baseline B: updated_at hash a314b149', v_upd = 'a314b149', v_upd);

  raise exception 'RESULTS%', E'\n' || (select string_agg(r2.line, E'\n' order by r2.n) from pg_temp.res r2);
end $t$;
