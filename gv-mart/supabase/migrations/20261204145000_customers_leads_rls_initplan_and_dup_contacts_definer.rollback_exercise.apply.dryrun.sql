-- ROLLBACK EXERCISE for 20261204145000_customers_leads_rls_initplan_and_dup_contacts_definer.sql
-- Runs, in ONE transaction that always rolls back (unconditional RAISE at the end, same pattern as
-- the main .apply.dryrun.sql): the real forward DDL (all 12 ALTER POLICY + the find_duplicate_contacts
-- CREATE OR REPLACE), immediately followed by the real rollback.sql DDL, then re-checks every one of
-- the same 12 policies' USING/WITH CHECK text plus the function body against the ORIGINAL
-- pre-migration sha256 pins -- proving rollback.sql genuinely restores the exact starting state,
-- not just "a" state. Nothing is left applied either way; this file is read-only in effect.

do $rollback_exercise$
declare
  v_fn_hash text;
  v_p1 text; v_p2 text; v_p3 text; v_p4 text; v_p5 text; v_p6 text;
  v_p7 text; v_p8 text; v_p9 text; v_p10 text; v_p11 text; v_p12 text;
  res text := '';
begin
  -- ── same starting-state guard as .apply.sql / .apply.dryrun.sql ───────────────────────────────
  if exists (select 1 from supabase_migrations.schema_migrations where version = '20261204145000') then
    raise exception 'already registered: migration 20261204145000 has already been applied -- refusing to exercise rollback against an already-applied migration';
  end if;

  select encode(sha256(replace(pg_get_functiondef('public.find_duplicate_contacts(text,text)'::regprocedure), E'\r', '')::bytea), 'hex') into v_fn_hash;
  if v_fn_hash is distinct from 'f7ba9d939faeb543fc92b63c550e7322bd37a5eb220913bb0e1b9f7bd148ba95' then
    raise exception 'DRIFT DETECTED: find_duplicate_contacts no longer matches the reviewed pin (live=%)', v_fn_hash;
  end if;
  select encode(sha256(replace(qual, E'\r', '')::bytea), 'hex') into v_p1 from pg_policies where schemaname='public' and tablename='customers' and policyname='customers_select_own';
  if v_p1 is distinct from 'caadb5a05e0dc49b98c86171323eb9231942d52875c131d5a8040f58623e6402' then raise exception 'DRIFT DETECTED: customers_select_own (live=%)', v_p1; end if;
  select encode(sha256(replace(qual, E'\r', '')::bytea), 'hex') into v_p2 from pg_policies where schemaname='public' and tablename='customers' and policyname='customers_select_own_technician';
  if v_p2 is distinct from '4baca8b4b2a098a3fc2ba962d2de4b003419e5dea1d14ff16cfa6e7657c4b4ab' then raise exception 'DRIFT DETECTED: customers_select_own_technician (live=%)', v_p2; end if;
  select encode(sha256(replace(qual, E'\r', '')::bytea), 'hex') into v_p3 from pg_policies where schemaname='public' and tablename='customers' and policyname='customers_select_staff';
  if v_p3 is distinct from '81ddd9711dfa781c369d7a2a0a10b79657e76e584ad41bfd7da30e7a1441fb3a' then raise exception 'DRIFT DETECTED: customers_select_staff (live=%)', v_p3; end if;
  select encode(sha256(replace(qual, E'\r', '')::bytea), 'hex') into v_p4 from pg_policies where schemaname='public' and tablename='leads' and policyname='leads_select_own_customer';
  if v_p4 is distinct from '1951840f1d6e529c8ed1dec31a73c66bc5350f903e8386c818c0ea3825334a56' then raise exception 'DRIFT DETECTED: leads_select_own_customer (live=%)', v_p4; end if;
  select encode(sha256(replace(qual, E'\r', '')::bytea), 'hex') into v_p5 from pg_policies where schemaname='public' and tablename='leads' and policyname='leads_select_own_technician';
  if v_p5 is distinct from 'ff3d7f05a4ed0b1679e1b32d98e01c7e97334ba1b2b2e51517cb65f6ed528531' then raise exception 'DRIFT DETECTED: leads_select_own_technician (live=%)', v_p5; end if;
  select encode(sha256(replace(qual, E'\r', '')::bytea), 'hex') into v_p6 from pg_policies where schemaname='public' and tablename='leads' and policyname='leads_select_staff';
  if v_p6 is distinct from '81ddd9711dfa781c369d7a2a0a10b79657e76e584ad41bfd7da30e7a1441fb3a' then raise exception 'DRIFT DETECTED: leads_select_staff (live=%)', v_p6; end if;
  select encode(sha256(replace(qual, E'\r', '')::bytea), 'hex') into v_p7 from pg_policies where schemaname='public' and tablename='customers' and policyname='customers_update_own';
  if v_p7 is distinct from 'caadb5a05e0dc49b98c86171323eb9231942d52875c131d5a8040f58623e6402' then raise exception 'DRIFT DETECTED: customers_update_own (live=%)', v_p7; end if;
  select encode(sha256(replace(qual, E'\r', '')::bytea), 'hex') into v_p8 from pg_policies where schemaname='public' and tablename='customers' and policyname='customers_write_operation_admin';
  if v_p8 is distinct from '36315289f3b98a92a51f069149e99db2954e72e251c580cd46e741014d937829' then raise exception 'DRIFT DETECTED: customers_write_operation_admin USING (live=%)', v_p8; end if;
  select encode(sha256(replace(with_check, E'\r', '')::bytea), 'hex') into v_p8 from pg_policies where schemaname='public' and tablename='customers' and policyname='customers_write_operation_admin';
  if v_p8 is distinct from '36315289f3b98a92a51f069149e99db2954e72e251c580cd46e741014d937829' then raise exception 'DRIFT DETECTED: customers_write_operation_admin WITH CHECK (live=%)', v_p8; end if;
  select encode(sha256(replace(qual, E'\r', '')::bytea), 'hex') into v_p9 from pg_policies where schemaname='public' and tablename='customers' and policyname='customers_write_sales';
  if v_p9 is distinct from '1fc127223756260e05a39d0a558f2262afe362d622829f12c75b36287960cc6a' then raise exception 'DRIFT DETECTED: customers_write_sales USING (live=%)', v_p9; end if;
  select encode(sha256(replace(with_check, E'\r', '')::bytea), 'hex') into v_p9 from pg_policies where schemaname='public' and tablename='customers' and policyname='customers_write_sales';
  if v_p9 is distinct from '1fc127223756260e05a39d0a558f2262afe362d622829f12c75b36287960cc6a' then raise exception 'DRIFT DETECTED: customers_write_sales WITH CHECK (live=%)', v_p9; end if;
  select encode(sha256(replace(with_check, E'\r', '')::bytea), 'hex') into v_p10 from pg_policies where schemaname='public' and tablename='leads' and policyname='leads_insert_own_technician';
  if v_p10 is distinct from 'c89b3ff5619dc0d245c867a5f760806ce25b96aea6d9486a34536736c8b1dbd6' then raise exception 'DRIFT DETECTED: leads_insert_own_technician (live=%)', v_p10; end if;
  select encode(sha256(replace(with_check, E'\r', '')::bytea), 'hex') into v_p11 from pg_policies where schemaname='public' and tablename='leads' and policyname='leads_insert_sales';
  if v_p11 is distinct from '1fc127223756260e05a39d0a558f2262afe362d622829f12c75b36287960cc6a' then raise exception 'DRIFT DETECTED: leads_insert_sales (live=%)', v_p11; end if;
  select encode(sha256(replace(qual, E'\r', '')::bytea), 'hex') into v_p12 from pg_policies where schemaname='public' and tablename='leads' and policyname='leads_update_sales';
  if v_p12 is distinct from '1fc127223756260e05a39d0a558f2262afe362d622829f12c75b36287960cc6a' then raise exception 'DRIFT DETECTED: leads_update_sales USING (live=%)', v_p12; end if;
  select encode(sha256(replace(with_check, E'\r', '')::bytea), 'hex') into v_p12 from pg_policies where schemaname='public' and tablename='leads' and policyname='leads_update_sales';
  if v_p12 is distinct from '1fc127223756260e05a39d0a558f2262afe362d622829f12c75b36287960cc6a' then raise exception 'DRIFT DETECTED: leads_update_sales WITH CHECK (live=%)', v_p12; end if;

  res := res || E'\nok   starting-state pins all matched -- proceeding to apply forward, then rollback';

  -- ── APPLY forward (identical DDL to .apply.sql, minus the schema_migrations registration --
  -- not needed to exercise the policy/function round-trip, and this whole thing rolls back anyway) ─
  alter policy customers_select_own on public.customers
    using (id = (select public.current_customer_id()));
  alter policy customers_select_own_technician on public.customers
    using (
      exists (
        select 1 from public.service_tickets t join public.appointments a on (a.ticket_id = t.id)
        where t.customer_id = customers.id and a.technician_id = (select public.current_technician_id())
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
      select 'customer'::text as source, c.id, c.name, c.mobile, c.email, c.created_at,
        (select count(*) from public.service_tickets t where t.customer_id = c.id)::bigint as ticket_count,
        (select count(*) from public.invoices i where i.customer_id = c.id)::bigint as invoice_count
      from public.customers c
      where c.org_id = v_org_id and not c.is_test
        and ((v_mobile_key is not null and public._mobile_key(c.mobile) = v_mobile_key) or (v_email <> '' and lower(c.email) = v_email))
      union all
      select 'lead'::text, l.id, l.name, l.mobile, null::text, l.created_at, 0::bigint, 0::bigint
      from public.leads l
      where l.org_id = v_org_id and not l.is_test and v_mobile_key is not null and public._mobile_key(l.mobile) = v_mobile_key
    ) matches
    order by created_at desc
    limit 10;
  end;
  $function$;
  revoke all on function public.find_duplicate_contacts(text, text) from public, anon;
  grant execute on function public.find_duplicate_contacts(text, text) to authenticated;

  res := res || E'\nok   forward DDL applied (12 policies + function) inside this transaction';

  -- ── ROLLBACK (identical DDL to .rollback.sql) ───────────────────────────────────────────────
  alter policy customers_select_own on public.customers
    using (id = current_customer_id());
  alter policy customers_select_own_technician on public.customers
    using (
      exists (
        select 1 from public.service_tickets t join public.appointments a on (a.ticket_id = t.id)
        where t.customer_id = customers.id and a.technician_id = current_technician_id()
      )
    );
  alter policy customers_select_staff on public.customers
    using ((org_id = current_org_id()) and is_staff());
  alter policy customers_update_own on public.customers
    using (id = current_customer_id());
  alter policy customers_write_operation_admin on public.customers
    using ((org_id = current_org_id()) and ("current_role"() = 'operation_admin'::user_role))
    with check ((org_id = current_org_id()) and ("current_role"() = 'operation_admin'::user_role));
  alter policy customers_write_sales on public.customers
    using ((org_id = current_org_id()) and is_sales_staff())
    with check ((org_id = current_org_id()) and is_sales_staff());
  alter policy leads_insert_own_technician on public.leads
    with check ((owner_id = current_technician_id()) and (status = 'new'::lead_status));
  alter policy leads_insert_sales on public.leads
    with check ((org_id = current_org_id()) and is_sales_staff());
  alter policy leads_select_own_customer on public.leads
    using (customer_id = current_customer_id());
  alter policy leads_select_own_technician on public.leads
    using (owner_id = current_technician_id());
  alter policy leads_select_staff on public.leads
    using ((org_id = current_org_id()) and is_staff());
  alter policy leads_update_sales on public.leads
    using ((org_id = current_org_id()) and is_sales_staff())
    with check ((org_id = current_org_id()) and is_sales_staff());

  create or replace function public.find_duplicate_contacts(p_mobile text default null::text, p_email text default null::text)
  returns table(source text, id uuid, name text, mobile text, email text, created_at timestamp with time zone, ticket_count bigint, invoice_count bigint)
  language plpgsql
  stable
  set search_path to 'public'
  as $function$
declare
  v_org_id uuid := public.current_org_id();
  -- _mobile_key (20261016110000_test_customer_flag.sql, already live) -- last
  -- 10 digits only. Deliberately NOT the unapplied 2A migration's
  -- normalize_mobile (country-code/trunk-prefix aware): that function does not
  -- exist live yet, and this RPC must work independently of whether/when that
  -- other migration is ever approved.
  v_mobile_key text := public._mobile_key(p_mobile);
  v_email text := lower(btrim(coalesce(p_email, '')));
begin
  if not public.is_staff() then
    raise exception 'find_duplicate_contacts: caller is not staff';
  end if;

  if v_org_id is null then
    raise exception 'find_duplicate_contacts: no organisation for the current session';
  end if;

  -- Nothing to match on -- return no rows rather than scanning the org.
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
    -- Leads have no email column -- mobile-only match. Always zero
    -- ticket/invoice counts (a lead isn't a customer yet).
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
  grant execute on function public.find_duplicate_contacts(text, text) to authenticated, service_role;

  res := res || E'\nok   rollback DDL applied (12 policies + function) inside the same transaction';

  -- ── re-check: does every pin match the ORIGINAL values again, after the round-trip? ───────────
  select encode(sha256(replace(pg_get_functiondef('public.find_duplicate_contacts(text,text)'::regprocedure), E'\r', '')::bytea), 'hex') into v_fn_hash;
  res := res || E'\n' || case when v_fn_hash = 'f7ba9d939faeb543fc92b63c550e7322bd37a5eb220913bb0e1b9f7bd148ba95' then 'ok   find_duplicate_contacts restored exactly' else 'FAIL find_duplicate_contacts NOT restored exactly (live=' || v_fn_hash || ')' end;

  select encode(sha256(replace(qual, E'\r', '')::bytea), 'hex') into v_p1 from pg_policies where schemaname='public' and tablename='customers' and policyname='customers_select_own';
  res := res || E'\n' || case when v_p1 = 'caadb5a05e0dc49b98c86171323eb9231942d52875c131d5a8040f58623e6402' then 'ok   customers_select_own restored exactly' else 'FAIL customers_select_own NOT restored (live=' || v_p1 || ')' end;
  select encode(sha256(replace(qual, E'\r', '')::bytea), 'hex') into v_p2 from pg_policies where schemaname='public' and tablename='customers' and policyname='customers_select_own_technician';
  res := res || E'\n' || case when v_p2 = '4baca8b4b2a098a3fc2ba962d2de4b003419e5dea1d14ff16cfa6e7657c4b4ab' then 'ok   customers_select_own_technician restored exactly' else 'FAIL customers_select_own_technician NOT restored (live=' || v_p2 || ')' end;
  select encode(sha256(replace(qual, E'\r', '')::bytea), 'hex') into v_p3 from pg_policies where schemaname='public' and tablename='customers' and policyname='customers_select_staff';
  res := res || E'\n' || case when v_p3 = '81ddd9711dfa781c369d7a2a0a10b79657e76e584ad41bfd7da30e7a1441fb3a' then 'ok   customers_select_staff restored exactly' else 'FAIL customers_select_staff NOT restored (live=' || v_p3 || ')' end;
  select encode(sha256(replace(qual, E'\r', '')::bytea), 'hex') into v_p4 from pg_policies where schemaname='public' and tablename='leads' and policyname='leads_select_own_customer';
  res := res || E'\n' || case when v_p4 = '1951840f1d6e529c8ed1dec31a73c66bc5350f903e8386c818c0ea3825334a56' then 'ok   leads_select_own_customer restored exactly' else 'FAIL leads_select_own_customer NOT restored (live=' || v_p4 || ')' end;
  select encode(sha256(replace(qual, E'\r', '')::bytea), 'hex') into v_p5 from pg_policies where schemaname='public' and tablename='leads' and policyname='leads_select_own_technician';
  res := res || E'\n' || case when v_p5 = 'ff3d7f05a4ed0b1679e1b32d98e01c7e97334ba1b2b2e51517cb65f6ed528531' then 'ok   leads_select_own_technician restored exactly' else 'FAIL leads_select_own_technician NOT restored (live=' || v_p5 || ')' end;
  select encode(sha256(replace(qual, E'\r', '')::bytea), 'hex') into v_p6 from pg_policies where schemaname='public' and tablename='leads' and policyname='leads_select_staff';
  res := res || E'\n' || case when v_p6 = '81ddd9711dfa781c369d7a2a0a10b79657e76e584ad41bfd7da30e7a1441fb3a' then 'ok   leads_select_staff restored exactly' else 'FAIL leads_select_staff NOT restored (live=' || v_p6 || ')' end;
  select encode(sha256(replace(qual, E'\r', '')::bytea), 'hex') into v_p7 from pg_policies where schemaname='public' and tablename='customers' and policyname='customers_update_own';
  res := res || E'\n' || case when v_p7 = 'caadb5a05e0dc49b98c86171323eb9231942d52875c131d5a8040f58623e6402' then 'ok   customers_update_own restored exactly' else 'FAIL customers_update_own NOT restored (live=' || v_p7 || ')' end;
  select encode(sha256(replace(qual, E'\r', '')::bytea), 'hex') into v_p8 from pg_policies where schemaname='public' and tablename='customers' and policyname='customers_write_operation_admin';
  res := res || E'\n' || case when v_p8 = '36315289f3b98a92a51f069149e99db2954e72e251c580cd46e741014d937829' then 'ok   customers_write_operation_admin USING restored exactly' else 'FAIL customers_write_operation_admin USING NOT restored (live=' || v_p8 || ')' end;
  select encode(sha256(replace(with_check, E'\r', '')::bytea), 'hex') into v_p8 from pg_policies where schemaname='public' and tablename='customers' and policyname='customers_write_operation_admin';
  res := res || E'\n' || case when v_p8 = '36315289f3b98a92a51f069149e99db2954e72e251c580cd46e741014d937829' then 'ok   customers_write_operation_admin WITH CHECK restored exactly' else 'FAIL customers_write_operation_admin WITH CHECK NOT restored (live=' || v_p8 || ')' end;
  select encode(sha256(replace(qual, E'\r', '')::bytea), 'hex') into v_p9 from pg_policies where schemaname='public' and tablename='customers' and policyname='customers_write_sales';
  res := res || E'\n' || case when v_p9 = '1fc127223756260e05a39d0a558f2262afe362d622829f12c75b36287960cc6a' then 'ok   customers_write_sales USING restored exactly' else 'FAIL customers_write_sales USING NOT restored (live=' || v_p9 || ')' end;
  select encode(sha256(replace(with_check, E'\r', '')::bytea), 'hex') into v_p9 from pg_policies where schemaname='public' and tablename='customers' and policyname='customers_write_sales';
  res := res || E'\n' || case when v_p9 = '1fc127223756260e05a39d0a558f2262afe362d622829f12c75b36287960cc6a' then 'ok   customers_write_sales WITH CHECK restored exactly' else 'FAIL customers_write_sales WITH CHECK NOT restored (live=' || v_p9 || ')' end;
  select encode(sha256(replace(with_check, E'\r', '')::bytea), 'hex') into v_p10 from pg_policies where schemaname='public' and tablename='leads' and policyname='leads_insert_own_technician';
  res := res || E'\n' || case when v_p10 = 'c89b3ff5619dc0d245c867a5f760806ce25b96aea6d9486a34536736c8b1dbd6' then 'ok   leads_insert_own_technician restored exactly' else 'FAIL leads_insert_own_technician NOT restored (live=' || v_p10 || ')' end;
  select encode(sha256(replace(with_check, E'\r', '')::bytea), 'hex') into v_p11 from pg_policies where schemaname='public' and tablename='leads' and policyname='leads_insert_sales';
  res := res || E'\n' || case when v_p11 = '1fc127223756260e05a39d0a558f2262afe362d622829f12c75b36287960cc6a' then 'ok   leads_insert_sales restored exactly' else 'FAIL leads_insert_sales NOT restored (live=' || v_p11 || ')' end;
  select encode(sha256(replace(qual, E'\r', '')::bytea), 'hex') into v_p12 from pg_policies where schemaname='public' and tablename='leads' and policyname='leads_update_sales';
  res := res || E'\n' || case when v_p12 = '1fc127223756260e05a39d0a558f2262afe362d622829f12c75b36287960cc6a' then 'ok   leads_update_sales USING restored exactly' else 'FAIL leads_update_sales USING NOT restored (live=' || v_p12 || ')' end;
  select encode(sha256(replace(with_check, E'\r', '')::bytea), 'hex') into v_p12 from pg_policies where schemaname='public' and tablename='leads' and policyname='leads_update_sales';
  res := res || E'\n' || case when v_p12 = '1fc127223756260e05a39d0a558f2262afe362d622829f12c75b36287960cc6a' then 'ok   leads_update_sales WITH CHECK restored exactly' else 'FAIL leads_update_sales WITH CHECK NOT restored (live=' || v_p12 || ')' end;

  -- also confirm the grant state is restored (authenticated, service_role -- the TRUE original,
  -- not the forward migration's narrowed authenticated-only)
  res := res || E'\nINFO grants after rollback: ' || (
    select string_agg(grantee, ',' order by grantee)
    from information_schema.routine_privileges
    where routine_schema='public' and routine_name='find_duplicate_contacts' and privilege_type='EXECUTE'
  );

  raise exception E'ROLLBACK-EXERCISE-OK:%', res;
end
$rollback_exercise$;
