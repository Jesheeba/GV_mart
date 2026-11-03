-- POST-APPLY VERIFICATION for 20261204170000_address_sub_area_field.sql
-- NOT part of the apply -- read-only, run by the owner right after the real apply, against
-- the real post-apply state. No role impersonation writes anything; no churn (no index
-- creation, no ANALYZE, no INSERT/UPDATE/DELETE of any kind). Scoped only to public.addresses
-- (the only table this migration touches) and real organisations -- audit_log is never
-- queried, matching this stream's standing check-scope rule.
--
-- This migration adds one nullable column and changes no RLS policy (addresses_write_sales/
-- addresses_write_own/addresses_select_staff/addresses_select_own already govern the whole
-- row, not per-column, so sub_area is covered by them automatically) -- there is deliberately
-- less to verify here than the Dec-4 RLS/SECURITY-DEFINER migration's own post_apply_verify.
-- This still exercises real-role SELECT access to the new column for every relevant role, as
-- the standing pipeline requires, rather than assuming row-level RLS extends to it untested.
do $verify$
declare
  v_org uuid;
  v_master uuid; v_sales uuid; v_tech uuid; v_cust uuid;
  v_rec record;
  res text := '';
  v_column_exists boolean;
  v_column_nullable boolean;
  v_addr_count bigint;
  v_addr_md5 text;
begin
  select o.id into v_org from public.organizations o where o.name not like '\_\_TEST\_%' escape '\' order by o.created_at asc limit 1;
  select p.id into v_master from public.profiles p join auth.users u on u.id = p.id where u.email = 'master@gvmart.test';
  select p.id into v_sales from public.profiles p join auth.users u on u.id = p.id where u.email = 'sales_admin@gvmart.test';
  select p.id into v_tech from public.profiles p join auth.users u on u.id = p.id where u.email = 'technician@gvmart.test';
  select p.id into v_cust from public.profiles p join auth.users u on u.id = p.id where u.email = 'customer@gvmart.test';

  -- ── 1. column shape ──────────────────────────────────────────────────────────────────
  select true, is_nullable = 'YES' into v_column_exists, v_column_nullable
  from information_schema.columns
  where table_schema = 'public' and table_name = 'addresses' and column_name = 'sub_area' and data_type = 'text';

  res := res || E'\n' || case when coalesce(v_column_exists, false) then 'PASS sub_area exists on public.addresses with data_type text' else 'FAIL sub_area missing or wrong type' end;
  res := res || E'\n' || case when coalesce(v_column_nullable, false) then 'PASS sub_area is nullable (no default, no backfill, as designed)' else 'FAIL sub_area is NOT nullable' end;

  -- ── 2. a stable snapshot of public.addresses (real orgs only) for the owner's own record ──
  select count(*), md5(coalesce(string_agg(a.id::text || a.updated_at::text, '' order by a.id), ''))
    into v_addr_count, v_addr_md5
  from public.addresses a
  where a.org_id not in (select id from public.organizations where name like '\_\_TEST\_%' escape '\');
  res := res || E'\nINFO addresses snapshot (real orgs) count=' || v_addr_count || ' md5=' || v_addr_md5;

  -- ── 3. real-role SELECT access to the new column, 4 roles + anon -- read-only, no writes ──
  for v_rec in
    select * from (values
      ('master', v_master), ('sales_admin', v_sales), ('technician', v_tech), ('customer', v_cust), ('anon', null::uuid)
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
      res := res || E'\nINFO select sub_area role=' || v_rec.role_label || ' visible_rows=' || (select count(*) from public.addresses)::text
        || ' non_null_sub_area=' || (select count(sub_area) from public.addresses)::text;
    exception when others then
      res := res || E'\nINFO select sub_area role=' || v_rec.role_label || ' DENIED (' || sqlstate || ': ' || left(sqlerrm, 80) || ')';
    end;

    execute 'reset role';
    perform set_config('request.jwt.claims', '', true);
  end loop;
  res := res || E'\nINFO expected shape: master/sales_admin see every row in their org via addresses_select_staff (is_staff() -- master/operation_admin/active sales_admin, technician is NOT part of is_staff()); technician sees ONLY rows tied to a ticket/appointment they are assigned to, via addresses_select_own_technician (job-scoped) -- the org-wide addresses_select_technician_search policy was created in 20260704130000 but deliberately DROPPED (not replaced) by 20260716100000_restrict_technician_customer_search_rls.sql as a privacy/data-exposure fix, so no org-wide technician grant exists today; customer sees only their own via addresses_select_own; anon sees none. None of these policies are touched by this migration -- RLS here is row-level, not per-column, so sub_area inherits exactly this shape automatically.';

  raise exception E'POST-APPLY-VERIFY:%', res;
end
$verify$;
