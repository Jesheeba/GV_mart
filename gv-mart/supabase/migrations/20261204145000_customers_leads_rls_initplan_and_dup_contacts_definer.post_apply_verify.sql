-- POST-APPLY VERIFICATION for 20261204145000_customers_leads_rls_initplan_and_dup_contacts_definer.sql
-- NOT part of the apply -- read-only, run by the owner right after the real apply, against the
-- real post-apply state. No role impersonation writes anything; no churn (no index creation, no
-- ANALYZE, no INSERT/UPDATE/DELETE of any kind) -- a plain, minimal snapshot, plus three read-only
-- SELECT-only calls through the real find_duplicate_contacts function (staff/non-staff/anon),
-- each reported as a PASS/FAIL line. audit_log is not touched.

do $verify$
declare
  v_org uuid;
  v_master uuid; v_ops uuid; v_sales uuid; v_tech uuid; v_cust uuid;
  v_search_plan jsonb;
  v_dup_plan jsonb;
  v_rec record;
  v_staff_ok boolean := false;
  v_nonstaff_refused boolean := false;
  v_anon_refused boolean := false;
  res text := '';
begin
  select o.id into v_org from public.organizations o where o.name not like '\_\_TEST%' escape '\' order by o.created_at asc limit 1;
  select p.id into v_master from public.profiles p join auth.users u on u.id = p.id where u.email = 'master@gvmart.test';
  select p.id into v_ops from public.profiles p join auth.users u on u.id = p.id where u.email = 'operation_admin@gvmart.test';
  select p.id into v_sales from public.profiles p join auth.users u on u.id = p.id where u.email = 'sales_admin@gvmart.test';
  select p.id into v_tech from public.profiles p join auth.users u on u.id = p.id where u.email = 'technician@gvmart.test';
  select p.id into v_cust from public.profiles p join auth.users u on u.id = p.id where u.email = 'customer@gvmart.test';

  -- ── plain EXPLAIN, no ANALYZE, as real staff (master) -- the actual post-apply plan, no churn ──
  perform set_config('request.jwt.claims', json_build_object('sub', v_master, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  execute $q$
    explain (format json)
    select id, name, mobile from public.customers
    where org_id = $1 and archived_at is null and (name ilike '%test%' or mobile ilike '%test%' or email ilike '%test%')
    limit 6
  $q$ into v_search_plan using v_org;
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);

  -- find_duplicate_contacts's own inner query, as it runs under SECURITY DEFINER -- not
  -- impersonating 'authenticated' for this one, same reasoning as the dryrun (see that file).
  execute $q$
    explain (format json)
    select c.id, c.name, c.mobile, c.created_at
    from public.customers c
    where c.org_id = $1 and not c.is_test
      and (public._mobile_key(c.mobile) = public._mobile_key('9092766740') or lower(c.email) = 'test@example.com')
  $q$ into v_dup_plan using v_org;

  res := res || E'\nINFO search_plan (real role, no ANALYZE, no indexes applied yet unless the companion index migration has also shipped)=' || v_search_plan::text;
  res := res || E'\nINFO search_plan total cost=' || (v_search_plan->0->'Plan'->>'Total Cost');
  res := res || E'\nINFO dup_plan (owner-role context, SECURITY DEFINER)=' || v_dup_plan::text;
  res := res || E'\nINFO dup_plan total cost=' || (v_dup_plan->0->'Plan'->>'Total Cost');

  -- ── visibility counts, 6 roles x 2 tables -- read-only, no comparison needed (nothing to
  -- compare against in this file; this is a one-shot snapshot of the real post-apply state) ──────
  for v_rec in
    select * from (values
      ('master', v_master), ('operation_admin', v_ops), ('sales_admin', v_sales),
      ('technician', v_tech), ('customer', v_cust), ('anon', null::uuid)
    ) as t(role_label, uid)
  loop
    if v_rec.uid is not null then
      perform set_config('request.jwt.claims', json_build_object('sub', v_rec.uid, 'role', 'authenticated')::text, true);
      execute 'set local role authenticated';
    else
      perform set_config('request.jwt.claims', '', true);
      execute 'set local role anon';
    end if;

    begin
      res := res || E'\nINFO visibility role=' || v_rec.role_label || ' customers=' || (select count(*) from public.customers)::text;
    exception when others then
      res := res || E'\nINFO visibility role=' || v_rec.role_label || ' customers=DENIED (' || sqlstate || ': ' || left(sqlerrm, 80) || ')';
    end;

    begin
      res := res || E'  leads=' || (select count(*) from public.leads)::text;
    exception when others then
      res := res || E'  leads=DENIED (' || sqlstate || ': ' || left(sqlerrm, 80) || ')';
    end;

    execute 'reset role';
    perform set_config('request.jwt.claims', '', true);
  end loop;

  -- ── find_duplicate_contacts real behavior, against the real post-apply function -- read-only:
  -- the function itself is STABLE and performs no writes; these calls only SELECT through it.
  -- Same three-case shape as the dryrun's own rehearsal of this (staff/non-staff/anon), now run
  -- for real, as the real roles, after the real apply.
  begin
    perform set_config('request.jwt.claims', json_build_object('sub', v_master, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    perform count(*) from public.find_duplicate_contacts('9092766740', null);
    v_staff_ok := true;
    execute 'reset role';
    perform set_config('request.jwt.claims', '', true);
  exception when others then
    execute 'reset role';
    perform set_config('request.jwt.claims', '', true);
    res := res || E'\nFAIL staff (master) call raised unexpectedly: ' || sqlerrm;
  end;
  res := res || E'\n' || case when v_staff_ok then 'PASS staff (master) call to find_duplicate_contacts succeeded' else 'FAIL staff call did not succeed' end;

  begin
    perform set_config('request.jwt.claims', json_build_object('sub', v_tech, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    perform count(*) from public.find_duplicate_contacts('9092766740', null);
    execute 'reset role';
    perform set_config('request.jwt.claims', '', true);
    res := res || E'\nFAIL non-staff (technician) call was NOT refused -- security regression';
  exception when others then
    execute 'reset role';
    perform set_config('request.jwt.claims', '', true);
    if sqlerrm ilike '%not staff%' then
      v_nonstaff_refused := true;
    else
      res := res || E'\nFAIL non-staff call refused for the WRONG reason: ' || sqlerrm;
    end if;
  end;
  res := res || E'\n' || case when v_nonstaff_refused then 'PASS non-staff (technician) call correctly refused with the "not staff" message' else 'FAIL non-staff refusal check did not pass as expected' end;

  begin
    perform set_config('request.jwt.claims', '', true);
    execute 'set local role anon';
    perform count(*) from public.find_duplicate_contacts('9092766740', null);
    execute 'reset role';
    res := res || E'\nFAIL anon call was NOT refused -- security regression';
  exception when others then
    execute 'reset role';
    perform set_config('request.jwt.claims', '', true);
    v_anon_refused := true;
    res := res || E'\nINFO anon refusal error text: ' || sqlerrm;
  end;
  res := res || E'\n' || case when v_anon_refused then 'PASS anon call correctly refused (no EXECUTE grant)' else 'FAIL anon refusal check did not pass as expected' end;

  -- This file makes no real writes anywhere (every `perform` above is set_config, a session
  -- variable, not a table write) -- ending in an unconditional RAISE is still used here, matching
  -- this engagement's own convention, purely to surface the multi-line result text through the
  -- Management API's query endpoint in one readable block.
  raise exception E'POST-APPLY-VERIFY:%', res;
end
$verify$;
