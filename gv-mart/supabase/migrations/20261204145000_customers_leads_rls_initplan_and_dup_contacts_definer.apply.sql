-- APPLY script for 20261204145000_customers_leads_rls_initplan_and_dup_contacts_definer.sql
-- Guard 1: refuse if already registered. Guard 2: refuse on any drift from the live pins this
-- migration was reviewed against (the function body + all 12 policies' USING/WITH CHECK
-- expressions on public.customers and public.leads -- extended from the first round's 6 after
-- live EXPLAIN showed customers_write_sales, cmd ALL, still dominating the search query's cost).
-- Pins re-verified fresh against live catalog state immediately before this file was finalized --
-- no drift found.
-- Also captures a before/after row-count + md5 fingerprint of both tables' id lists and RAISES
-- (aborting the whole apply) if either changed -- this migration is index/policy/function-only and
-- must touch zero rows; this is the live, non-dry-run proof of that, not just the dryrun's.
-- Verification touches ONLY public.customers and public.leads -- audit_log is DELIBERATELY
-- EXCLUDED from every check in this file (live Disk IO incident this migration helps resolve).

do $guard$
declare
  v_fn_hash text;
  v_p1 text; v_p2 text; v_p3 text; v_p4 text; v_p5 text; v_p6 text;
  v_p7 text; v_p8 text; v_p9 text; v_p10 text; v_p11 text; v_p12 text;
begin
  if exists (select 1 from supabase_migrations.schema_migrations where version = '20261204145000') then
    raise exception 'already registered: migration 20261204145000 has already been applied -- refusing to re-apply';
  end if;

  select encode(sha256(replace(pg_get_functiondef('public.find_duplicate_contacts(text,text)'::regprocedure), E'\r', '')::bytea), 'hex') into v_fn_hash;
  if v_fn_hash is distinct from 'f7ba9d939faeb543fc92b63c550e7322bd37a5eb220913bb0e1b9f7bd148ba95' then
    raise exception 'DRIFT DETECTED: find_duplicate_contacts no longer matches the reviewed pin (live=%)', v_fn_hash;
  end if;

  select encode(sha256(replace(qual, E'\r', '')::bytea), 'hex') into v_p1
    from pg_policies where schemaname='public' and tablename='customers' and policyname='customers_select_own';
  if v_p1 is distinct from 'caadb5a05e0dc49b98c86171323eb9231942d52875c131d5a8040f58623e6402' then
    raise exception 'DRIFT DETECTED: customers_select_own no longer matches the reviewed pin (live=%)', v_p1;
  end if;

  select encode(sha256(replace(qual, E'\r', '')::bytea), 'hex') into v_p2
    from pg_policies where schemaname='public' and tablename='customers' and policyname='customers_select_own_technician';
  if v_p2 is distinct from '4baca8b4b2a098a3fc2ba962d2de4b003419e5dea1d14ff16cfa6e7657c4b4ab' then
    raise exception 'DRIFT DETECTED: customers_select_own_technician no longer matches the reviewed pin (live=%)', v_p2;
  end if;

  select encode(sha256(replace(qual, E'\r', '')::bytea), 'hex') into v_p3
    from pg_policies where schemaname='public' and tablename='customers' and policyname='customers_select_staff';
  if v_p3 is distinct from '81ddd9711dfa781c369d7a2a0a10b79657e76e584ad41bfd7da30e7a1441fb3a' then
    raise exception 'DRIFT DETECTED: customers_select_staff no longer matches the reviewed pin (live=%)', v_p3;
  end if;

  select encode(sha256(replace(qual, E'\r', '')::bytea), 'hex') into v_p4
    from pg_policies where schemaname='public' and tablename='leads' and policyname='leads_select_own_customer';
  if v_p4 is distinct from '1951840f1d6e529c8ed1dec31a73c66bc5350f903e8386c818c0ea3825334a56' then
    raise exception 'DRIFT DETECTED: leads_select_own_customer no longer matches the reviewed pin (live=%)', v_p4;
  end if;

  select encode(sha256(replace(qual, E'\r', '')::bytea), 'hex') into v_p5
    from pg_policies where schemaname='public' and tablename='leads' and policyname='leads_select_own_technician';
  if v_p5 is distinct from 'ff3d7f05a4ed0b1679e1b32d98e01c7e97334ba1b2b2e51517cb65f6ed528531' then
    raise exception 'DRIFT DETECTED: leads_select_own_technician no longer matches the reviewed pin (live=%)', v_p5;
  end if;

  select encode(sha256(replace(qual, E'\r', '')::bytea), 'hex') into v_p6
    from pg_policies where schemaname='public' and tablename='leads' and policyname='leads_select_staff';
  if v_p6 is distinct from '81ddd9711dfa781c369d7a2a0a10b79657e76e584ad41bfd7da30e7a1441fb3a' then
    raise exception 'DRIFT DETECTED: leads_select_staff no longer matches the reviewed pin (live=%)', v_p6;
  end if;

  select encode(sha256(replace(qual, E'\r', '')::bytea), 'hex') into v_p7
    from pg_policies where schemaname='public' and tablename='customers' and policyname='customers_update_own';
  if v_p7 is distinct from 'caadb5a05e0dc49b98c86171323eb9231942d52875c131d5a8040f58623e6402' then
    raise exception 'DRIFT DETECTED: customers_update_own no longer matches the reviewed pin (live=%)', v_p7;
  end if;

  select encode(sha256(replace(qual, E'\r', '')::bytea), 'hex') into v_p8
    from pg_policies where schemaname='public' and tablename='customers' and policyname='customers_write_operation_admin';
  if v_p8 is distinct from '36315289f3b98a92a51f069149e99db2954e72e251c580cd46e741014d937829' then
    raise exception 'DRIFT DETECTED: customers_write_operation_admin USING no longer matches the reviewed pin (live=%)', v_p8;
  end if;
  select encode(sha256(replace(with_check, E'\r', '')::bytea), 'hex') into v_p8
    from pg_policies where schemaname='public' and tablename='customers' and policyname='customers_write_operation_admin';
  if v_p8 is distinct from '36315289f3b98a92a51f069149e99db2954e72e251c580cd46e741014d937829' then
    raise exception 'DRIFT DETECTED: customers_write_operation_admin WITH CHECK no longer matches the reviewed pin (live=%)', v_p8;
  end if;

  select encode(sha256(replace(qual, E'\r', '')::bytea), 'hex') into v_p9
    from pg_policies where schemaname='public' and tablename='customers' and policyname='customers_write_sales';
  if v_p9 is distinct from '1fc127223756260e05a39d0a558f2262afe362d622829f12c75b36287960cc6a' then
    raise exception 'DRIFT DETECTED: customers_write_sales USING no longer matches the reviewed pin (live=%)', v_p9;
  end if;
  select encode(sha256(replace(with_check, E'\r', '')::bytea), 'hex') into v_p9
    from pg_policies where schemaname='public' and tablename='customers' and policyname='customers_write_sales';
  if v_p9 is distinct from '1fc127223756260e05a39d0a558f2262afe362d622829f12c75b36287960cc6a' then
    raise exception 'DRIFT DETECTED: customers_write_sales WITH CHECK no longer matches the reviewed pin (live=%)', v_p9;
  end if;

  select encode(sha256(replace(with_check, E'\r', '')::bytea), 'hex') into v_p10
    from pg_policies where schemaname='public' and tablename='leads' and policyname='leads_insert_own_technician';
  if v_p10 is distinct from 'c89b3ff5619dc0d245c867a5f760806ce25b96aea6d9486a34536736c8b1dbd6' then
    raise exception 'DRIFT DETECTED: leads_insert_own_technician no longer matches the reviewed pin (live=%)', v_p10;
  end if;

  select encode(sha256(replace(with_check, E'\r', '')::bytea), 'hex') into v_p11
    from pg_policies where schemaname='public' and tablename='leads' and policyname='leads_insert_sales';
  if v_p11 is distinct from '1fc127223756260e05a39d0a558f2262afe362d622829f12c75b36287960cc6a' then
    raise exception 'DRIFT DETECTED: leads_insert_sales no longer matches the reviewed pin (live=%)', v_p11;
  end if;

  select encode(sha256(replace(qual, E'\r', '')::bytea), 'hex') into v_p12
    from pg_policies where schemaname='public' and tablename='leads' and policyname='leads_update_sales';
  if v_p12 is distinct from '1fc127223756260e05a39d0a558f2262afe362d622829f12c75b36287960cc6a' then
    raise exception 'DRIFT DETECTED: leads_update_sales USING no longer matches the reviewed pin (live=%)', v_p12;
  end if;
  select encode(sha256(replace(with_check, E'\r', '')::bytea), 'hex') into v_p12
    from pg_policies where schemaname='public' and tablename='leads' and policyname='leads_update_sales';
  if v_p12 is distinct from '1fc127223756260e05a39d0a558f2262afe362d622829f12c75b36287960cc6a' then
    raise exception 'DRIFT DETECTED: leads_update_sales WITH CHECK no longer matches the reviewed pin (live=%)', v_p12;
  end if;
end $guard$;

do $anon_before$
begin
  create temp table if not exists zz_anon_before_145 (fn text) on commit drop;
  insert into zz_anon_before_145
  select p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')'
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'EXECUTE');
end $anon_before$;

-- ── row-data fingerprint, BEFORE -- proves this apply is index/policy/function-only, touches zero
-- rows in customers or leads. audit_log is DELIBERATELY excluded (see file header).
do $fp_before$
begin
  create temp table if not exists zz_fp_before_145 (tbl text, cnt bigint, fp text) on commit drop;
  insert into zz_fp_before_145
  select 'customers', count(*), md5(coalesce(string_agg(id::text, ',' order by id), '')) from public.customers
  union all
  select 'leads', count(*), md5(coalesce(string_agg(id::text, ',' order by id), '')) from public.leads;
end $fp_before$;

-- ── (a) ALTER POLICY -- ALL 12 customers + leads policies, InitPlan-wrapped ─────────────────────
alter policy customers_select_own on public.customers
  using (id = (select public.current_customer_id()));

alter policy customers_select_own_technician on public.customers
  using (
    exists (
      select 1
      from public.service_tickets t
      join public.appointments a on (a.ticket_id = t.id)
      where t.customer_id = customers.id
        and a.technician_id = (select public.current_technician_id())
    )
  );

alter policy customers_select_staff on public.customers
  using ((org_id = (select public.current_org_id())) and (select public.is_staff()));

alter policy customers_update_own on public.customers
  using (id = (select public.current_customer_id()));

alter policy customers_write_operation_admin on public.customers
  using ((org_id = (select public.current_org_id())) and ((select public."current_role"()) = 'operation_admin'::user_role))
  with check ((org_id = (select public.current_org_id())) and ((select public."current_role"()) = 'operation_admin'::user_role));

alter policy customers_write_sales on public.customers
  using ((org_id = (select public.current_org_id())) and (select public.is_sales_staff()))
  with check ((org_id = (select public.current_org_id())) and (select public.is_sales_staff()));

alter policy leads_insert_own_technician on public.leads
  with check ((owner_id = (select public.current_technician_id())) and (status = 'new'::lead_status));

alter policy leads_insert_sales on public.leads
  with check ((org_id = (select public.current_org_id())) and (select public.is_sales_staff()));

alter policy leads_select_own_customer on public.leads
  using (customer_id = (select public.current_customer_id()));

alter policy leads_select_own_technician on public.leads
  using (owner_id = (select public.current_technician_id()));

alter policy leads_select_staff on public.leads
  using ((org_id = (select public.current_org_id())) and (select public.is_staff()));

alter policy leads_update_sales on public.leads
  using ((org_id = (select public.current_org_id())) and (select public.is_sales_staff()))
  with check ((org_id = (select public.current_org_id())) and (select public.is_sales_staff()));

-- ── (c) find_duplicate_contacts -- SECURITY DEFINER, search_path='', return shape UNCHANGED ─────
create or replace function public.find_duplicate_contacts(p_mobile text default null::text, p_email text default null::text)
returns table(source text, id uuid, name text, mobile text, email text, created_at timestamp with time zone, ticket_count bigint, invoice_count bigint)
language plpgsql
security definer
stable
set search_path to ''
as $function$
declare
  v_org_id uuid := public.current_org_id();
  v_mobile_key text := public._mobile_key(p_mobile);
  v_email text := lower(btrim(coalesce(p_email, '')));
begin
  if not public.is_staff() then
    raise exception 'find_duplicate_contacts: caller is not staff';
  end if;

  if v_org_id is null then
    raise exception 'find_duplicate_contacts: no organisation for the current session';
  end if;

  if v_mobile_key is null and v_email = '' then
    return;
  end if;

  return query
  select * from (
    select
      'customer'::text as source,
      c.id,
      c.name,
      c.mobile,
      c.email,
      c.created_at,
      (select count(*) from public.service_tickets t where t.customer_id = c.id)::bigint as ticket_count,
      (select count(*) from public.invoices i where i.customer_id = c.id)::bigint as invoice_count
    from public.customers c
    where c.org_id = v_org_id
      and not c.is_test
      and (
        (v_mobile_key is not null and public._mobile_key(c.mobile) = v_mobile_key)
        or (v_email <> '' and lower(c.email) = v_email)
      )
    union all
    select
      'lead'::text,
      l.id,
      l.name,
      l.mobile,
      null::text,
      l.created_at,
      0::bigint,
      0::bigint
    from public.leads l
    where l.org_id = v_org_id
      and not l.is_test
      and v_mobile_key is not null
      and public._mobile_key(l.mobile) = v_mobile_key
  ) matches
  order by created_at desc
  limit 10;
end;
$function$;

revoke all on function public.find_duplicate_contacts(text, text) from public, anon;
grant execute on function public.find_duplicate_contacts(text, text) to authenticated;

-- ── register + anon-exposure diff + before/after counts (customers/leads only) ─────────────────
insert into supabase_migrations.schema_migrations (version, name, statements)
values ('20261204145000', 'customers_leads_rls_initplan_and_dup_contacts_definer', array[]::text[]);

do $anon_after$
declare
  v_new_grants text[];
begin
  create temp table if not exists zz_anon_after_145 (fn text) on commit drop;
  insert into zz_anon_after_145
  select p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')'
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'EXECUTE');

  select array_agg(fn) into v_new_grants
  from zz_anon_after_145
  where fn not in (select fn from zz_anon_before_145);

  if v_new_grants is not null then
    raise exception 'ANON EXPOSURE REGRESSION: new anon-executable functions after this migration: %', v_new_grants;
  end if;
end $anon_after$;

do $fp_after$
declare
  v_fp_mismatch boolean := false;
  v_rec record;
begin
  create temp table zz_fp_after_145 (tbl text, cnt bigint, fp text) on commit drop;
  insert into zz_fp_after_145
  select 'customers', count(*), md5(coalesce(string_agg(id::text, ',' order by id), '')) from public.customers
  union all
  select 'leads', count(*), md5(coalesce(string_agg(id::text, ',' order by id), '')) from public.leads;

  for v_rec in
    select b.tbl, b.cnt as cnt_before, b.fp as fp_before, a.cnt as cnt_after, a.fp as fp_after
    from zz_fp_before_145 b join zz_fp_after_145 a on a.tbl = b.tbl
  loop
    if v_rec.cnt_before is distinct from v_rec.cnt_after or v_rec.fp_before is distinct from v_rec.fp_after then
      v_fp_mismatch := true;
    end if;
  end loop;

  if v_fp_mismatch then
    raise exception 'FINGERPRINT MISMATCH: this apply is supposed to be index/policy/function-only -- a row in customers or leads changed. Refusing to leave this applied -- investigate before retrying.';
  end if;
end $fp_after$;

select
  'applied' as status,
  now() as applied_at,
  (select count(*) from zz_anon_before_145) as anon_before_count,
  (select count(*) from zz_anon_after_145) as anon_after_count,
  (select count(*) from public.customers) as customers_count_after,
  (select count(*) from public.leads) as leads_count_after,
  (select cnt from zz_fp_before_145 where tbl = 'customers') as customers_fp_before_cnt,
  (select fp from zz_fp_before_145 where tbl = 'customers') as customers_fp_before,
  (select cnt from zz_fp_after_145 where tbl = 'customers') as customers_fp_after_cnt,
  (select fp from zz_fp_after_145 where tbl = 'customers') as customers_fp_after,
  (select cnt from zz_fp_before_145 where tbl = 'leads') as leads_fp_before_cnt,
  (select fp from zz_fp_before_145 where tbl = 'leads') as leads_fp_before,
  (select cnt from zz_fp_after_145 where tbl = 'leads') as leads_fp_after_cnt,
  (select fp from zz_fp_after_145 where tbl = 'leads') as leads_fp_after,
  (select count(*) from pg_proc where proname = 'find_duplicate_contacts' and pronamespace = 'public'::regnamespace) as overload_count,
  (select pg_get_function_identity_arguments(oid) from pg_proc where proname = 'find_duplicate_contacts' and pronamespace = 'public'::regnamespace) as signature,
  (select pg_get_function_result(oid) from pg_proc where proname = 'find_duplicate_contacts' and pronamespace = 'public'::regnamespace) as return_columns,
  (select prosecdef from pg_proc where proname = 'find_duplicate_contacts' and pronamespace = 'public'::regnamespace) as is_security_definer,
  (select proconfig from pg_proc where proname = 'find_duplicate_contacts' and pronamespace = 'public'::regnamespace) as proconfig,
  (select bool_or(grantee = 'anon') from information_schema.routine_privileges where routine_schema='public' and routine_name='find_duplicate_contacts') as anon_has_execute,
  (select bool_or(grantee = 'public') from information_schema.routine_privileges where routine_schema='public' and routine_name='find_duplicate_contacts') as public_has_execute,
  (select bool_or(grantee = 'authenticated') from information_schema.routine_privileges where routine_schema='public' and routine_name='find_duplicate_contacts') as authenticated_has_execute;
  -- Expected: overload_count=1, signature/return_columns unchanged from the live pin,
  -- is_security_definer=true, proconfig contains 'search_path=', anon_has_execute=false,
  -- public_has_execute=false, authenticated_has_execute=true.
