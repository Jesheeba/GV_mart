-- Rehearsal wrapper for 20261025200000_wa_initiated_allowlist_gate.sql. NOT RUN until the owner approves this text and names the run.
--
-- HOW IT IS USED: ONE request = the migration file, then this file, concatenated in that order, sent through the
-- Management API query endpoint (one transaction). Nothing in either file begins, commits, savepoints or rolls back by
-- itself, and this file ends in an UNCONDITIONAL RAISE EXCEPTION, so the request can never commit: the migration's column,
-- function and trigger all vanish with the rollback. The final RAISE prints every PASS/FAIL line.
-- It reads and creates nothing outside the migration's own objects: no row of any real table is written.
-- No exception handlers: a failing statement aborts the request with its own error (still rolled back).
--
-- 1. CLOCK GATE: the rehearsal may only run outside working hours (18:00-07:59 IST), the same window the AMC migration used.
--    Outside the window it raises before any check.
-- 2. PINNED HASHES: values read read-only on 2026-10-15 12:28 IST. If any differs, the live database is not the state this
--    migration was written against, and the rehearsal reports FAIL (it still raises at the end, nothing is kept).
--      public._trg_settings_wa_test_guard   md5(pg_get_functiondef)  a4280dd157e636140c4eab88e3408702
--      public.audit_master_change           md5(pg_get_functiondef)  030f4b88111c5e4d7722970754a5748d
--      public.settings: 79 columns before the migration, 3 non-internal triggers before, 310 public functions before
--      real organisation leads: count 64, identity 1649051d, updated_at a314b149 (baseline B formulas)

do $gate$
begin
  if extract(hour from (now() at time zone 'Asia/Kolkata')) between 8 and 17 then
    raise exception 'clock gate: % IST is inside working hours; run this rehearsal between 18:00 and 07:59 IST',
      to_char(now() at time zone 'Asia/Kolkata', 'YYYY-MM-DD HH24:MI');
  end if;
end $gate$;

create temp table res (n serial, line text);
create function pg_temp.chk(p_name text, p_ok boolean, p_info text default '') returns void language plpgsql as $f$
begin insert into pg_temp.res(line) values (case when coalesce(p_ok,false) then 'PASS  ' else 'FAIL  ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end); end $f$;

do $t$
declare
  v_def  text;
  v_org  uuid := 'b6822905-5557-4e43-a606-f26ecfd5a541';
  v_n    int;
  v_id   text;
  v_upd  text;
begin
  -- pinned hashes of objects the migration must NOT change
  perform pg_temp.chk('pin: _trg_settings_wa_test_guard unchanged',
    md5(pg_get_functiondef('public._trg_settings_wa_test_guard'::regproc)) = 'a4280dd157e636140c4eab88e3408702');
  perform pg_temp.chk('pin: audit_master_change unchanged',
    md5(pg_get_functiondef('public.audit_master_change'::regproc)) = '030f4b88111c5e4d7722970754a5748d');

  -- the migration's own objects
  perform pg_temp.chk('column added: 80 settings columns',
    (select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'settings') = 80);
  perform pg_temp.chk('column is boolean not null default true',
    exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'settings' and column_name = 'wa_initiated_allowlist_only'
               and data_type = 'boolean' and is_nullable = 'NO' and column_default = 'true'));
  perform pg_temp.chk('real organisation row reads true (gate closed by default)',
    (select wa_initiated_allowlist_only from public.settings where org_id = v_org) is true);
  perform pg_temp.chk('no settings row has the gate open or null',
    (select count(*) from public.settings where wa_initiated_allowlist_only is distinct from true) = 0);
  perform pg_temp.chk('exactly 4 triggers on settings (3 + the new guard)',
    (select count(*) from pg_trigger where tgrelid = 'public.settings'::regclass and not tgisinternal) = 4);
  perform pg_temp.chk('guard trigger is BEFORE UPDATE FOR EACH ROW and enabled',
    exists (select 1 from pg_trigger t
             where t.tgrelid = 'public.settings'::regclass and t.tgname = 'settings_wa_initiated_guard'
               and t.tgenabled = 'O' and (t.tgtype & 2) = 2 and (t.tgtype & 16) = 16 and (t.tgtype & 1) = 1));
  perform pg_temp.chk('311 public functions (310 + the guard)',
    (select count(*) from pg_proc where pronamespace = 'public'::regnamespace) = 311);

  -- ACL: the trigger function must not be executable by public, anon or authenticated
  perform pg_temp.chk('guard function: anon cannot execute',
    not has_function_privilege('anon', 'public._trg_settings_wa_initiated_guard()', 'execute'));
  perform pg_temp.chk('guard function: authenticated cannot execute',
    not has_function_privilege('authenticated', 'public._trg_settings_wa_initiated_guard()', 'execute'));
  perform pg_temp.chk('guard function: no PUBLIC execute in the ACL',
    not exists (select 1 from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                 where p.oid = 'public._trg_settings_wa_initiated_guard()'::regprocedure and a.grantee = 0 and a.privilege_type = 'EXECUTE'));

  -- the guard's own text: master-only, searches nothing implicitly
  v_def := pg_get_functiondef('public._trg_settings_wa_initiated_guard'::regproc);
  perform pg_temp.chk('guard body raises for non-master authenticated/anon',
    v_def like '%current_user in (''authenticated'', ''anon'')%' and v_def like '%is_master()%' and v_def like '%only a master can change the initiated-send gate%');
  perform pg_temp.chk('guard has an empty search_path', v_def like '%SET search_path TO ''''%');

  -- baseline B, unchanged by the migration
  select count(*), left(md5(string_agg(id::text, ',' order by id)), 8),
         left(md5(string_agg(id::text || ':' || updated_at::text, ',' order by id)), 8)
    into v_n, v_id, v_upd from public.leads where org_id = v_org;
  perform pg_temp.chk('baseline B: 64 leads', v_n = 64, v_n::text);
  perform pg_temp.chk('baseline B: identity hash 1649051d', v_id = '1649051d', v_id);
  perform pg_temp.chk('baseline B: updated_at hash a314b149', v_upd = 'a314b149', v_upd);
end $t$;

do $r$
declare v text;
begin
  select string_agg(line, E'\n' order by n) into v from pg_temp.res;
  raise exception E'RESULTS (always rolled back):\n%\n%', v,
    case when v like '%FAIL%' then 'AT LEAST ONE CHECK FAILED' else 'ALL CHECKS PASSED' end;
end $r$;
