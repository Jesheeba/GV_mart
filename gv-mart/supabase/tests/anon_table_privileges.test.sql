-- Rolled-back DB test for 20261016500000_revoke_anon_table_privileges.sql.
-- Runner: this file with its single marker line (the one that says MIGRATION between two at-at signs) replaced by the
-- migration text; one transaction; ends in a RAISE.
-- Method: the same persona operation matrix runs BEFORE and AFTER the migration inside one transaction, against a
-- throwaway __TEST_ organisation, and the two outcome sets must be identical (no persona loses or gains anything).
-- Then: anon table access is refused; the 13 anon-callable helper functions still work for anon; a table, view and
-- sequence created in this transaction do NOT inherit anon privileges; authenticated keeps DML but not
-- TRUNCATE/REFERENCES/TRIGGER/MAINTAIN, on existing and new tables.
create temp table res (n serial, line text);
grant all on res to public;
grant usage on sequence res_n_seq to public;
create temp table ctx (k text primary key, v text);
grant all on ctx to public;
create temp table ops (id serial, persona text, label text, stmt text);
grant all on ops to public;
create temp table outcomes (phase text, persona text, label text, outcome text);
grant all on outcomes to public;

-- ── fixtures ───────────────────────────────────────────────────────────────────────────────────────────────────────
do $f$
declare
  v_org uuid; v_cust uuid; v_tk uuid; r record; v_u uuid;
begin
  insert into organizations(name) values ('__TEST_anon_table_privileges') returning id into v_org;
  insert into settings(org_id) values (v_org) on conflict (org_id) do nothing;
  insert into ctx values ('org', v_org::text);
  for r in select * from (values ('customer','customer',false),('technician','technician',true),('sales','sales_admin',false),
                                ('ops','operation_admin',false),('master','master',false)) t(n,ro,tech) loop
    v_u := gen_random_uuid();
    insert into auth.users(id, email) values (v_u, '__test_' || v_u || '@example.invalid');
    insert into profiles(id, org_id, full_name, role, is_active) values (v_u, v_org, '__TEST_' || r.n, r.ro::user_role, true);
    insert into ctx values ('u_' || r.n, v_u::text);
    if r.tech then
      insert into technicians(org_id, profile_id, is_active) values (v_org, v_u, true);
    end if;
    if r.n = 'customer' then
      insert into customers(org_id, name, mobile, primary_profile_id) values (v_org, '__TEST_c', '9000000001', v_u) returning id into v_cust;
      insert into ctx values ('cust', v_cust::text);
    end if;
  end loop;
  insert into service_tickets(org_id, customer_id, name_of_complaint, status) values (v_org, v_cust, '__TEST_ticket', 'open') returning id into v_tk;
  insert into ctx values ('tk', v_tk::text);
  insert into leads(org_id, name, mobile, source, status) values (v_org, '__TEST_lead', '9000000002', 'walk_in', 'new');

  insert into ops(persona, label, stmt) values
    ('customer', 'read own customer',      'select count(*) from public.customers'),
    ('customer', 'read own tickets',       'select count(*) from public.service_tickets'),
    ('customer', 'read catalogue',         'select count(*) from public.products'),
    ('customer', 'read notifications',     'select count(*) from public.notifications'),
    ('customer', 'update own profile row', 'update public.customers set name = name where id = (select v::uuid from pg_temp.ctx where k=''cust'')'),
    ('customer', 'helper current_customer_id', 'select public.current_customer_id()'),
    ('technician', 'read appointments',    'select count(*) from public.appointments'),
    ('technician', 'read tickets',         'select count(*) from public.service_tickets'),
    ('technician', 'read catalogue',       'select count(*) from public.products'),
    ('technician', 'read technicians',     'select count(*) from public.technicians'),
    ('technician', 'update own record',    'update public.technicians set zone = zone where org_id = (select v::uuid from pg_temp.ctx where k=''org'')'),
    ('technician', 'helper current_technician_id', 'select public.current_technician_id()'),
    ('sales', 'read leads',                'select count(*) from public.leads'),
    ('sales', 'insert lead',               'insert into public.leads(org_id,name,mobile,source,status) values ((select v::uuid from pg_temp.ctx where k=''org''),''__TEST_l2'',''9000000003'',''walk_in'',''new'')'),
    ('sales', 'update lead',               'update public.leads set name = name where org_id = (select v::uuid from pg_temp.ctx where k=''org'')'),
    ('sales', 'read customers',            'select count(*) from public.customers'),
    ('sales', 'read quotations',           'select count(*) from public.quotations'),
    ('ops', 'read tickets',                'select count(*) from public.service_tickets'),
    ('ops', 'update ticket',               'update public.service_tickets set priority = priority where org_id = (select v::uuid from pg_temp.ctx where k=''org'')'),
    ('ops', 'insert customer',             'insert into public.customers(org_id,name,mobile) values ((select v::uuid from pg_temp.ctx where k=''org''),''__TEST_c2'',''9000000004'')'),
    ('ops', 'read outbox',                 'select count(*) from public.whatsapp_outbox'),
    ('ops', 'read inventory',              'select count(*) from public.inventory'),
    ('master', 'read settings',            'select count(*) from public.settings'),
    ('master', 'update settings',          'update public.settings set po_approval_threshold = po_approval_threshold where org_id = (select v::uuid from pg_temp.ctx where k=''org'')'),
    ('master', 'read audit log',           'select count(*) from public.audit_log'),
    ('master', 'read profiles',            'select count(*) from public.profiles'),
    ('master', 'helper is_master',         'select public.is_master()');
end
$f$;

-- ── the persona matrix, run once before and once after ─────────────────────────────────────────────────────────────
create function pg_temp.run_matrix(p_phase text) returns void language plpgsql as $m$
declare r record; v_uid text; v_err text;
begin
  for r in select * from ops order by id loop
    select v into v_uid from ctx where k = 'u_' || r.persona;
    perform set_config('request.jwt.claims', json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
    begin
      execute 'set local role authenticated';
      execute r.stmt;
      execute 'reset role';
      insert into outcomes values (p_phase, r.persona, r.label, 'ok');
    exception when others then
      execute 'reset role';
      get stacked diagnostics v_err = returned_sqlstate;
      insert into outcomes values (p_phase, r.persona, r.label, 'ERR ' || v_err);
    end;
  end loop;
end
$m$;

select pg_temp.run_matrix('before');

-- @@MIGRATION@@

select pg_temp.run_matrix('after');

-- ── assertions ─────────────────────────────────────────────────────────────────────────────────────────────────────
do $t$
declare
  n int; r record; v_err text; v_ok boolean;
  fn text;
begin
  -- 1. persona parity
  select count(*) into n from (
    (select persona, label, outcome from outcomes where phase = 'before' except select persona, label, outcome from outcomes where phase = 'after')
    union all
    (select persona, label, outcome from outcomes where phase = 'after' except select persona, label, outcome from outcomes where phase = 'before')) d;
  insert into res(line) values (case when n = 0 then 'PASS  every persona operation has the same outcome before and after (' || (select count(*) from outcomes where phase='after') || ' operations)'
                                else 'FAIL  persona outcomes differ in ' || n || ' operation(s)' end);
  for r in select b.persona, b.label, b.outcome bo, a.outcome ao from outcomes b join outcomes a using (persona, label)
           where b.phase = 'before' and a.phase = 'after' and b.outcome <> a.outcome loop
    insert into res(line) values ('FAIL  ' || r.persona || ' / ' || r.label || ': before ' || r.bo || ', after ' || r.ao);
  end loop;
  select count(*) into n from outcomes where phase = 'after' and outcome = 'ok';
  insert into res(line) values (case when n >= 20 then 'PASS  ' || n || ' persona operations succeed after the migration (the matrix is not vacuous)' else 'FAIL  only ' || n || ' persona operations succeed' end);
  for r in select persona, label, outcome from outcomes where phase = 'after' and outcome <> 'ok' order by 1,2 loop
    insert into res(line) values ('INFO  after: ' || r.persona || ' / ' || r.label || ' => ' || r.outcome || ' (same as before)');
  end loop;

  -- 2. anon holds nothing on existing relations
  select count(*) into n from pg_class c
   where c.relnamespace = 'public'::regnamespace and c.relkind in ('r','p','v','m','S','f')
     and (has_table_privilege('anon', c.oid, 'SELECT') or has_table_privilege('anon', c.oid, 'INSERT') or has_table_privilege('anon', c.oid, 'UPDATE')
          or has_table_privilege('anon', c.oid, 'DELETE') or has_table_privilege('anon', c.oid, 'TRUNCATE') or has_table_privilege('anon', c.oid, 'REFERENCES')
          or has_table_privilege('anon', c.oid, 'TRIGGER') or has_table_privilege('anon', c.oid, 'MAINTAIN'))
     and c.relname not like '\_\_%';
  insert into res(line) values (case when n = 0 then 'PASS  anon holds no privilege on any public table/view' else 'FAIL  anon still holds a privilege on ' || n || ' public relation(s)' end);

  -- 3. anon table access is refused (not an empty result)
  for r in select unnest(array['customers','service_tickets','leads','settings','whatsapp_outbox','profiles']) t loop
    begin
      execute 'set local role anon';
      execute format('select count(*) from public.%I', r.t);
      execute 'reset role';
      insert into res(line) values ('FAIL  anon could select from ' || r.t);
    exception when insufficient_privilege then
      execute 'reset role';
      insert into res(line) values ('PASS  anon select from ' || r.t || ' is refused (42501)');
    when others then
      execute 'reset role';
      insert into res(line) values ('FAIL  anon select from ' || r.t || ': ' || sqlerrm);
    end;
  end loop;
  begin
    execute 'set local role anon';
    insert into public.leads(org_id, name, mobile, source, status) values ((select v::uuid from ctx where k = 'org'), '__TEST_anon', '9000000009', 'walk_in', 'new');
    execute 'reset role';
    insert into res(line) values ('FAIL  anon could insert a lead');
  exception when insufficient_privilege then
    execute 'reset role';
    insert into res(line) values ('PASS  anon insert is refused (42501)');
  end;

  -- 4. the 13 functions that must stay anon-callable still work for anon
  foreach fn in array array['"current_role"()','current_org_id()','current_customer_id()','current_technician_id()','current_technician_is_active()',
                            'is_master()','is_ops_staff()','is_staff()','is_sales_staff()',
                            'customer_owns_appointment(gen_random_uuid())','customer_sees_technician(gen_random_uuid())',
                            'customer_sees_technician_profile(gen_random_uuid())','is_technician_customer(gen_random_uuid())'] loop
    begin
      execute 'set local role anon';
      execute 'select public.' || fn;
      execute 'reset role';
      insert into res(line) values ('PASS  anon can still call ' || fn);
    exception when others then
      execute 'reset role';
      insert into res(line) values ('FAIL  anon cannot call ' || fn || ': ' || sqlerrm);
    end;
  end loop;
  begin
    execute 'set local role anon';
    perform 1 from pg_namespace where nspname = 'public';
    execute 'reset role';
    insert into res(line) values ('PASS  anon keeps USAGE on schema public');
  exception when others then
    execute 'reset role';
    insert into res(line) values ('FAIL  anon lost schema usage: ' || sqlerrm);
  end;

  -- 5. authenticated keeps DML but not the four removed privileges, on existing tables
  select count(*) into n from pg_class c
   where c.relnamespace = 'public'::regnamespace and c.relkind in ('r','p')
     and (has_table_privilege('authenticated', c.oid, 'TRUNCATE') or has_table_privilege('authenticated', c.oid, 'REFERENCES')
          or has_table_privilege('authenticated', c.oid, 'TRIGGER') or has_table_privilege('authenticated', c.oid, 'MAINTAIN'));
  insert into res(line) values (case when n = 0 then 'PASS  authenticated has no TRUNCATE/REFERENCES/TRIGGER/MAINTAIN on any public table' else 'FAIL  authenticated still has one of them on ' || n || ' table(s)' end);
  select count(*) into n from pg_class c
   where c.relnamespace = 'public'::regnamespace and c.relkind = 'r' and c.relrowsecurity
     -- a table with no policy at all (lead_rotation) is deliberately closed to clients and is not part of this check
     and exists (select 1 from pg_policies p where p.schemaname = 'public' and p.tablename = c.relname)
     and not has_table_privilege('authenticated', c.oid, 'SELECT');
  insert into res(line) values (case when n = 0 then 'PASS  authenticated still has SELECT on every RLS table that has a policy' else 'FAIL  authenticated lost SELECT on ' || n || ' table(s)' end);

  -- 6. new objects created in this transaction do NOT inherit anon privileges
  create table public.__tmp_acl_probe (id int primary key, v text);
  create view public.__tmp_acl_probe_v as select id from public.__tmp_acl_probe;
  create sequence public.__tmp_acl_probe_seq;
  v_ok := not (has_table_privilege('anon', 'public.__tmp_acl_probe', 'SELECT') or has_table_privilege('anon', 'public.__tmp_acl_probe', 'INSERT')
               or has_table_privilege('anon', 'public.__tmp_acl_probe', 'UPDATE') or has_table_privilege('anon', 'public.__tmp_acl_probe', 'DELETE')
               or has_table_privilege('anon', 'public.__tmp_acl_probe', 'TRUNCATE'));
  insert into res(line) values (case when v_ok then 'PASS  a new table does NOT get anon privileges' else 'FAIL  a new table inherited anon privileges' end);
  insert into res(line) values (case when not has_table_privilege('anon', 'public.__tmp_acl_probe_v', 'SELECT') then 'PASS  a new view does NOT get anon privileges' else 'FAIL  a new view inherited anon privileges' end);
  insert into res(line) values (case when not has_sequence_privilege('anon', 'public.__tmp_acl_probe_seq', 'USAGE') and not has_sequence_privilege('anon', 'public.__tmp_acl_probe_seq', 'SELECT')
                                     then 'PASS  a new sequence does NOT get anon privileges' else 'FAIL  a new sequence inherited anon privileges' end);
  insert into res(line) values (case when has_table_privilege('authenticated', 'public.__tmp_acl_probe', 'SELECT') and has_table_privilege('authenticated', 'public.__tmp_acl_probe', 'INSERT')
                                          and has_table_privilege('authenticated', 'public.__tmp_acl_probe', 'UPDATE') and has_table_privilege('authenticated', 'public.__tmp_acl_probe', 'DELETE')
                                     then 'PASS  a new table still gets authenticated DML (RLS then governs it)' else 'FAIL  a new table lost authenticated DML' end);
  insert into res(line) values (case when not (has_table_privilege('authenticated', 'public.__tmp_acl_probe', 'TRUNCATE') or has_table_privilege('authenticated', 'public.__tmp_acl_probe', 'REFERENCES')
                                               or has_table_privilege('authenticated', 'public.__tmp_acl_probe', 'TRIGGER') or has_table_privilege('authenticated', 'public.__tmp_acl_probe', 'MAINTAIN'))
                                     then 'PASS  a new table does not get authenticated TRUNCATE/REFERENCES/TRIGGER/MAINTAIN' else 'FAIL  a new table inherited the removed authenticated privileges' end);
  insert into res(line) values (case when has_table_privilege('service_role', 'public.__tmp_acl_probe', 'SELECT') and has_table_privilege('service_role', 'public.__tmp_acl_probe', 'INSERT')
                                     then 'PASS  service_role keeps full access to new tables' else 'FAIL  service_role lost access to new tables' end);

  -- 7. report any other default-ACL rows that would still hand anon privileges to future objects
  for r in select pg_get_userbyid(d.defaclrole) creator, d.defaclobjtype::text typ
             from pg_default_acl d join pg_namespace s on s.oid = d.defaclnamespace
            where s.nspname = 'public' and d.defaclacl::text like '%anon=%' loop
    insert into res(line) values ('WARN  default ACL still grants anon for objects created by ' || r.creator || ' (type ' || r.typ || '): run as that role');
  end loop;

  raise exception E'RESULTS:\n%', (select string_agg(res.line, E'\n' order by res.n) from res);
end
$t$;
