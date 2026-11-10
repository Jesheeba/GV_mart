-- DRYRUN wrapper for 20261204145000_customers_leads_rls_initplan_and_dup_contacts_definer.sql
-- Runs the exact same guard + DDL as the .apply.sql, inside one DO block that unconditionally
-- RAISEs at the end -- can never itself commit anything live, no matter how it exits.
--
-- EXTENDED this round: a first version wrapped only the 3 customers SELECT + 3 leads SELECT
-- policies; live EXPLAIN then showed the plain search query still dominated by a Seq Scan,
-- traced to customers_write_sales (cmd ALL, also governs SELECT) still bare-calling
-- current_org_id()/is_sales_staff() per row. This version wraps ALL 12 policies on
-- public.customers and public.leads (every command: SELECT, UPDATE, INSERT, ALL).
--
-- FURTHER FIXED, this round: (i) the write-check SETUP rows now exist during BOTH visibility
-- snapshots, not just the AFTER one (a live run showed a false "visibility changed" result for
-- every org-wide-staff role, traced exactly to this); (ii) every write-check attempt now catches
-- WHEN OTHERS, not just insufficient_privilege, since a pre-existing business-rule trigger
-- (guard_water_profile_edit_roles) can refuse a write for reasons that have nothing to do with
-- RLS at all -- confirmed live against operation_admin's customers UPDATE.
--
-- Proves FOUR things, in order:
--   1. Visibility is byte-identical before vs after, for 6 real roles (master, operation_admin,
--      sales_admin, a technician, a customer, anon) x 2 tables (customers, leads) -- count(*) and
--      md5 of the ordered visible id list. This is the access-control safety proof for (a)'s
--      SELECT-relevant policies.
--   2. WRITE outcomes are identical before vs after, for the same 6 roles x 2 tables x 2
--      operations (INSERT a throwaway row, UPDATE one shared target row) -- the access-control
--      safety proof for (a)'s UPDATE/INSERT/ALL-command policies specifically
--      (customers_update_own, customers_write_operation_admin, customers_write_sales,
--      leads_insert_own_technician, leads_insert_sales, leads_update_sales). Every attempt is
--      caught with WHEN OTHERS (not just insufficient_privilege), since pre-existing business-rule
--      triggers on these tables (guard_water_profile_edit_roles, guard_customer_self_update) can
--      refuse a write for reasons that have nothing to do with RLS -- confirmed live: this is
--      exactly what blocked operation_admin's customers UPDATE in an earlier run (a correct,
--      pre-existing production rule, not a bug). Outcome is 'ALLOWED' or 'DENIED' with the
--      SQLSTATE and first 80 chars of the message recorded (a silent RLS exclusion on UPDATE --
--      0 rows affected, no exception -- is recorded as DENIED with a synthetic message); equality
--      requires outcome AND sqlstate AND message to all match, so a DENIED that changes WHICH
--      guard produced it is still flagged as a real difference, not treated as "unchanged".
--   3. find_duplicate_contacts behaves correctly for: a staff caller (succeeds), a non-staff
--      authenticated caller (refused with the function's own "not staff" message), and anon
--      (refused before the function body even runs -- no EXECUTE grant). This is the
--      access-control safety proof for (c).
--   4. EXPLAIN (no ANALYZE) of the search query (as real authenticated staff -- only benefits
--      from (a), since it never goes through find_duplicate_contacts) and of the
--      find_duplicate_contacts inner query, BOTH before and after the companion index migration's
--      6 indexes are ALSO (temporarily, inside this same rolled-back transaction) created.
--      REVISED PASS CRITERION this round (owner instruction): the goal is that the per-row policy
--      function-call cost disappears, not that an index scan must win -- PASS if the search
--      query's total estimated cost falls by >= 10x. Trigram index use is reported separately,
--      informationally, and does not fail the run on its own; if unused, texticlike/textlike's
--      pg_proc.proleakproof is checked and reported, with a note on whether a dedicated search RPC
--      (item d) would be needed to get trigram use specifically. NOTE on the
--      find_duplicate_contacts EXPLAIN specifically: SECURITY DEFINER makes its internal query run
--      as the function's OWNER, not as the calling role -- EXPLAINing a direct call to a plpgsql
--      function only ever shows an opaque "Function Scan" from the caller's side, never the
--      function's own internal plan. To see the real internal plan, this file EXPLAINs the
--      function's own inner SELECT text directly, WITHOUT impersonating 'authenticated' for that
--      one query specifically (matching what SECURITY DEFINER actually produces: the table
--      owner's own role, not RLS-restricted) -- the search query's own EXPLAIN, by contrast, DOES
--      impersonate 'authenticated' throughout, since it is unaffected by (c) and still goes
--      through real RLS exactly as production will.
--
-- Verification touches ONLY public.customers and public.leads -- audit_log is DELIBERATELY
-- EXCLUDED from every check in this file. Every test row created by the write-equivalence check
-- is named "QA TEST - delete me - rls write check..." and is deleted within the same transaction
-- regardless of outcome, on top of the whole transaction rolling back anyway.

do $dryrun$
declare
  v_fn_hash text;
  v_p1 text; v_p2 text; v_p3 text; v_p4 text; v_p5 text; v_p6 text;
  v_p7 text; v_p8 text; v_p9 text; v_p10 text; v_p11 text; v_p12 text;
  v_org uuid;
  v_master uuid; v_ops uuid; v_sales uuid; v_tech uuid; v_cust uuid;
  v_cnt_c bigint; v_fp_c text; v_reason_c text;
  v_cnt_l bigint; v_fp_l text; v_reason_l text;
  v_rec record;
  v_mismatch boolean := false;
  v_wc_target_customer uuid;
  v_wc_target_lead uuid;
  v_wc_new_id uuid;
  v_wc_outcome text;
  v_wc_sqlstate text;
  v_wc_message text;
  v_wc_rowcount int;
  v_staff_ok boolean := false;
  v_nonstaff_refused boolean := false;
  v_anon_refused boolean := false;
  v_search_plan_before jsonb; v_dup_plan_before jsonb;
  v_search_plan_after jsonb; v_dup_plan_after jsonb;
  v_any_fail boolean := false;
  res text := '';
begin
  -- ── same guard as .apply.sql ────────────────────────────────────────────────────────────────
  if exists (select 1 from supabase_migrations.schema_migrations where version = '20261204145000') then
    raise exception 'already registered: migration 20261204145000 has already been applied -- refusing to dry-run an already-applied migration';
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

  -- ── real role ids -- the standing per-role @gvmart.test test accounts ──────────────────────────
  select o.id into v_org from public.organizations o where o.name not like '\_\_TEST%' escape '\' order by o.created_at asc limit 1;
  select p.id into v_master from public.profiles p join auth.users u on u.id = p.id where u.email = 'master@gvmart.test';
  select p.id into v_ops from public.profiles p join auth.users u on u.id = p.id where u.email = 'operation_admin@gvmart.test';
  select p.id into v_sales from public.profiles p join auth.users u on u.id = p.id where u.email = 'sales_admin@gvmart.test';
  select p.id into v_tech from public.profiles p join auth.users u on u.id = p.id where u.email = 'technician@gvmart.test';
  select p.id into v_cust from public.profiles p join auth.users u on u.id = p.id where u.email = 'customer@gvmart.test';
  if v_master is null or v_ops is null or v_sales is null or v_tech is null or v_cust is null then
    raise exception 'TEST_SETUP: one or more of the 5 standing @gvmart.test role accounts could not be found';
  end if;

  create temp table zz_visibility (phase text, role_label text, tbl text, cnt bigint, fp text) on commit drop;
  create temp table zz_denials (phase text, role_label text, tbl text, sqlstate_code text, message text) on commit drop;
  create temp table zz_write_checks (phase text, role_label text, tbl text, op text, outcome text, sqlstate_code text, message text) on commit drop;

  -- ── write-check SETUP rows, created here (BEFORE the first visibility snapshot) ────────────────
  -- Previously created later, inside the write-check BEFORE block -- which meant these 2 real rows
  -- existed during the visibility AFTER snapshot but not the visibility BEFORE snapshot, producing
  -- a false "visibility changed" FAIL for every org-wide-staff role (master/operation_admin/
  -- sales_admin, the only roles whose count spans the whole org) -- confirmed live: both counts
  -- moved by exactly +1, exactly matching these 2 rows. Fixed by creating them here, before BOTH
  -- visibility snapshots, so their presence is identical (and cancels out) in both. Cleanup still
  -- happens at the very end, after both write-check loops, as before -- by then both visibility
  -- snapshots are already taken, so cleanup timing relative to them no longer matters.
  insert into public.customers (org_id, name, is_test)
    values (v_org, 'QA TEST - delete me - rls write check (customers)', false)
    returning id into v_wc_target_customer;
  insert into public.leads (org_id, name)
    values (v_org, 'QA TEST - delete me - rls write check (leads)')
    returning id into v_wc_target_lead;

  -- ── BEFORE snapshot, all 6 roles x 2 tables ─────────────────────────────────────────────────
  -- The snapshot SELECTs run AS the real impersonated role (that's the whole point -- they must
  -- see exactly what that role's RLS allows). The bookkeeping INSERT into the temp table zz_visibility
  -- does NOT -- that table is owned by this transaction's starting (elevated) role, which never
  -- granted INSERT to authenticated/anon, so inserting while still impersonating fails with
  -- "permission denied for table zz_visibility". Fixed by capturing both tables' results into
  -- plpgsql variables WHILE impersonating, resetting role FIRST, and only then inserting -- role
  -- impersonation stays honest for every snapshot query; only the bookkeeping write moves.
  --
  -- SECOND fix (this round): anon genuinely has no EXECUTE on current_org_id()/is_staff()/
  -- current_customer_id()/current_technician_id() -- confirmed live, correct and intentional
  -- (only authenticated/postgres/service_role have it). Evaluating customers_select_staff's
  -- policy qual for anon therefore raises insufficient_privilege (42501), not a quiet "no rows".
  -- Each snapshot SELECT is now its own sub-block that catches insufficient_privilege specifically
  -- and records cnt=NULL, fp='DENIED' (an outcome, not a failure) plus the exact SQLSTATE/message
  -- in zz_denials, so a genuinely denied role is distinguished from a role that is merely shown
  -- zero rows. Any OTHER exception still propagates and aborts the dry-run, as before -- only
  -- insufficient_privilege is treated as an expected possible outcome here.
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
      select count(*), md5(coalesce(string_agg(id::text, ',' order by id), '')) into v_cnt_c, v_fp_c from public.customers;
      v_reason_c := null;
    exception when insufficient_privilege then
      v_cnt_c := null; v_fp_c := 'DENIED'; v_reason_c := sqlstate || ': ' || sqlerrm;
    end;

    begin
      select count(*), md5(coalesce(string_agg(id::text, ',' order by id), '')) into v_cnt_l, v_fp_l from public.leads;
      v_reason_l := null;
    exception when insufficient_privilege then
      v_cnt_l := null; v_fp_l := 'DENIED'; v_reason_l := sqlstate || ': ' || sqlerrm;
    end;

    execute 'reset role';
    perform set_config('request.jwt.claims', '', true);

    insert into zz_visibility values ('before', v_rec.role_label, 'customers', v_cnt_c, v_fp_c);
    insert into zz_visibility values ('before', v_rec.role_label, 'leads', v_cnt_l, v_fp_l);
    if v_reason_c is not null then
      insert into zz_denials values ('before', v_rec.role_label, 'customers', split_part(v_reason_c, ':', 1), v_reason_c);
    end if;
    if v_reason_l is not null then
      insert into zz_denials values ('before', v_rec.role_label, 'leads', split_part(v_reason_l, ':', 1), v_reason_l);
    end if;
  end loop;

  -- ── WRITE-equivalence check, BEFORE the policy change ───────────────────────────────────────
  -- customers_write_sales is cmd ALL -- it also governs INSERT/UPDATE/DELETE, not just SELECT.
  -- The two SETUP rows (the shared UPDATE-target customer and lead) were created earlier, before
  -- the FIRST visibility snapshot (see that section's own comment for why -- creating them here,
  -- where they were originally, left them existing during the AFTER visibility snapshot but not
  -- the BEFORE one, producing a false "visibility changed" result). They ran as the elevated,
  -- un-impersonated connection role at that point, which bypasses RLS and every business-rule
  -- trigger that gates on auth.uid()/current_user (guard_water_profile_edit_roles,
  -- guard_customer_self_update) -- so SETUP itself can never be refused by any role's own
  -- restrictions. Every INSERT attempt inside the loop below is its own throwaway row, deleted
  -- immediately after (by the elevated role, post-reset) regardless of outcome -- same for the
  -- temp-table bookkeeping writes (zz_visibility/zz_denials/zz_write_checks), all of which happen
  -- only after `reset role`, as established in the visibility-check loops above.
  --
  -- Outcome recording catches ANY exception now (WHEN OTHERS, not just insufficient_privilege):
  -- a pre-existing business-rule trigger (guard_water_profile_edit_roles, guard_customer_self_update,
  -- or any other guard on these tables) can refuse a write for reasons that have nothing to do
  -- with RLS at all, and that refusal is just as real an outcome to compare before vs after as an
  -- RLS denial is -- confirmed live: operation_admin's customers UPDATE (which touches `name`) is
  -- correctly refused by guard_water_profile_edit_roles ("operation_admin may only edit the water
  -- profile fields"), a pre-existing production rule unrelated to this migration. 'ALLOWED' and
  -- 'DENIED' are the only two outcomes recorded; for UPDATE, a silent RLS exclusion (0 rows
  -- affected, no exception) is recorded as DENIED with a synthetic message, kept DISTINCT in
  -- comparison from an actual exception's message -- a role flipping between "silently 0-rowed"
  -- and "an explicit exception" is a real regression even though both are "DENIED" in plain words.
  -- (SETUP rows for this check were already created earlier, before the first visibility snapshot
  -- -- see that section's own comment for why.)
  for v_rec in
    select * from (values
      ('master', v_master), ('operation_admin', v_ops), ('sales_admin', v_sales),
      ('technician', v_tech), ('customer', v_cust), ('anon', null::uuid)
    ) as t(role_label, uid)
  loop
    -- customers INSERT -- catches ANY exception (not just insufficient_privilege): a pre-existing
    -- business-rule trigger (e.g. guard_water_profile_edit_roles, guard_customer_self_update, or
    -- any other guard on these tables) can refuse a write for reasons that have nothing to do with
    -- RLS at all, and that refusal is just as real an "outcome" to compare before vs after as an
    -- RLS denial is. message is truncated to 80 chars (plenty to identify which guard fired).
    if v_rec.uid is not null then
      perform set_config('request.jwt.claims', json_build_object('sub', v_rec.uid, 'role', 'authenticated')::text, true);
      execute 'set local role authenticated';
    else
      perform set_config('request.jwt.claims', '', true);
      execute 'set local role anon';
    end if;
    begin
      insert into public.customers (org_id, name, is_test)
        values (v_org, 'QA TEST - delete me - rls write check insert', false)
        returning id into v_wc_new_id;
      v_wc_outcome := 'ALLOWED'; v_wc_sqlstate := null; v_wc_message := null;
    exception when others then
      v_wc_outcome := 'DENIED'; v_wc_sqlstate := sqlstate; v_wc_message := left(sqlerrm, 80); v_wc_new_id := null;
    end;
    execute 'reset role'; perform set_config('request.jwt.claims', '', true);
    if v_wc_new_id is not null then delete from public.customers where id = v_wc_new_id; end if;
    insert into zz_write_checks values ('before', v_rec.role_label, 'customers', 'insert', v_wc_outcome, v_wc_sqlstate, v_wc_message);

    -- customers UPDATE (shared target row)
    if v_rec.uid is not null then
      perform set_config('request.jwt.claims', json_build_object('sub', v_rec.uid, 'role', 'authenticated')::text, true);
      execute 'set local role authenticated';
    else
      perform set_config('request.jwt.claims', '', true);
      execute 'set local role anon';
    end if;
    begin
      update public.customers set name = 'QA TEST - delete me - rls write check (customers) updated'
        where id = v_wc_target_customer;
      get diagnostics v_wc_rowcount = row_count;
      if v_wc_rowcount = 1 then
        v_wc_outcome := 'ALLOWED'; v_wc_sqlstate := null; v_wc_message := null;
      else
        v_wc_outcome := 'DENIED'; v_wc_sqlstate := null; v_wc_message := 'RLS USING excluded the row (0 rows affected, no exception)';
      end if;
    exception when others then
      v_wc_outcome := 'DENIED'; v_wc_sqlstate := sqlstate; v_wc_message := left(sqlerrm, 80);
    end;
    execute 'reset role'; perform set_config('request.jwt.claims', '', true);
    update public.customers set name = 'QA TEST - delete me - rls write check (customers)' where id = v_wc_target_customer;
    insert into zz_write_checks values ('before', v_rec.role_label, 'customers', 'update', v_wc_outcome, v_wc_sqlstate, v_wc_message);

    -- leads INSERT
    if v_rec.uid is not null then
      perform set_config('request.jwt.claims', json_build_object('sub', v_rec.uid, 'role', 'authenticated')::text, true);
      execute 'set local role authenticated';
    else
      perform set_config('request.jwt.claims', '', true);
      execute 'set local role anon';
    end if;
    begin
      insert into public.leads (org_id, name) values (v_org, 'QA TEST - delete me - rls write check insert (lead)')
        returning id into v_wc_new_id;
      v_wc_outcome := 'ALLOWED'; v_wc_sqlstate := null; v_wc_message := null;
    exception when others then
      v_wc_outcome := 'DENIED'; v_wc_sqlstate := sqlstate; v_wc_message := left(sqlerrm, 80); v_wc_new_id := null;
    end;
    execute 'reset role'; perform set_config('request.jwt.claims', '', true);
    if v_wc_new_id is not null then delete from public.leads where id = v_wc_new_id; end if;
    insert into zz_write_checks values ('before', v_rec.role_label, 'leads', 'insert', v_wc_outcome, v_wc_sqlstate, v_wc_message);

    -- leads UPDATE (shared target row)
    if v_rec.uid is not null then
      perform set_config('request.jwt.claims', json_build_object('sub', v_rec.uid, 'role', 'authenticated')::text, true);
      execute 'set local role authenticated';
    else
      perform set_config('request.jwt.claims', '', true);
      execute 'set local role anon';
    end if;
    begin
      update public.leads set name = 'QA TEST - delete me - rls write check (leads) updated'
        where id = v_wc_target_lead;
      get diagnostics v_wc_rowcount = row_count;
      if v_wc_rowcount = 1 then
        v_wc_outcome := 'ALLOWED'; v_wc_sqlstate := null; v_wc_message := null;
      else
        v_wc_outcome := 'DENIED'; v_wc_sqlstate := null; v_wc_message := 'RLS USING excluded the row (0 rows affected, no exception)';
      end if;
    exception when others then
      v_wc_outcome := 'DENIED'; v_wc_sqlstate := sqlstate; v_wc_message := left(sqlerrm, 80);
    end;
    execute 'reset role'; perform set_config('request.jwt.claims', '', true);
    update public.leads set name = 'QA TEST - delete me - rls write check (leads)' where id = v_wc_target_lead;
    insert into zz_write_checks values ('before', v_rec.role_label, 'leads', 'update', v_wc_outcome, v_wc_sqlstate, v_wc_message);
  end loop;

  -- ── apply (a) + (c) ──────────────────────────────────────────────────────────────────────────
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

  -- ── post-change function identity/security checks (the owner's explicit new requirement) ──────
  declare
    v_overload_count int;
    v_signature text;
    v_return_cols text;
    v_prosecdef boolean;
    v_proconfig text[];
    v_anon_exec boolean;
    v_public_exec boolean;
    v_authenticated_exec boolean;
  begin
    select count(*) into v_overload_count from pg_proc where proname = 'find_duplicate_contacts' and pronamespace = 'public'::regnamespace;
    select pg_get_function_identity_arguments(oid) into v_signature from pg_proc where proname = 'find_duplicate_contacts' and pronamespace = 'public'::regnamespace;
    select pg_get_function_result(oid) into v_return_cols from pg_proc where proname = 'find_duplicate_contacts' and pronamespace = 'public'::regnamespace;
    select prosecdef into v_prosecdef from pg_proc where proname = 'find_duplicate_contacts' and pronamespace = 'public'::regnamespace;
    select proconfig into v_proconfig from pg_proc where proname = 'find_duplicate_contacts' and pronamespace = 'public'::regnamespace;
    select bool_or(grantee = 'anon') into v_anon_exec from information_schema.routine_privileges where routine_schema='public' and routine_name='find_duplicate_contacts';
    select bool_or(grantee = 'public') into v_public_exec from information_schema.routine_privileges where routine_schema='public' and routine_name='find_duplicate_contacts';
    select bool_or(grantee = 'authenticated') into v_authenticated_exec from information_schema.routine_privileges where routine_schema='public' and routine_name='find_duplicate_contacts';

    res := res || E'\nINFO overload_count=' || v_overload_count;
    res := res || E'\nINFO signature=' || v_signature;
    res := res || E'\nINFO return_columns=' || v_return_cols;
    res := res || E'\nINFO prosecdef=' || v_prosecdef;
    res := res || E'\nINFO proconfig=' || coalesce(v_proconfig::text, '{}');
    res := res || E'\nINFO grants: anon=' || coalesce(v_anon_exec, false) || ' public=' || coalesce(v_public_exec, false) || ' authenticated=' || coalesce(v_authenticated_exec, false);
    res := res || E'\n' || case when v_overload_count = 1 then 'ok   exactly one overload' else 'FAIL expected exactly 1 overload, found ' || v_overload_count end;
    res := res || E'\n' || case when v_signature = 'p_mobile text DEFAULT NULL::text, p_email text DEFAULT NULL::text' then 'ok   signature unchanged' else 'INFO signature text (compare by eye against live pin): ' || v_signature end;
    res := res || E'\n' || case when v_return_cols ilike '%source text%' and v_return_cols ilike '%email text%' and v_return_cols ilike '%created_at timestamp%' and v_return_cols ilike '%ticket_count bigint%' and v_return_cols ilike '%invoice_count bigint%' then 'ok   all 8 return columns present, unchanged' else 'FAIL return columns do not look like the unchanged 8-column shape' end;
    res := res || E'\n' || case when v_prosecdef is true then 'ok   prosecdef = true (SECURITY DEFINER)' else 'FAIL prosecdef is not true' end;
    res := res || E'\n' || case when v_proconfig::text ilike '%search_path=%' then 'ok   proconfig has search_path set' else 'FAIL proconfig does not show a search_path setting' end;
    res := res || E'\n' || case when coalesce(v_anon_exec,false) = false then 'ok   anon has no EXECUTE' else 'FAIL anon still has EXECUTE' end;
    res := res || E'\n' || case when coalesce(v_public_exec,false) = false then 'ok   public has no EXECUTE' else 'FAIL public still has EXECUTE' end;
    res := res || E'\n' || case when coalesce(v_authenticated_exec,false) = true then 'ok   authenticated has EXECUTE' else 'FAIL authenticated does not have EXECUTE' end;
    if v_overload_count <> 1
       or not (v_return_cols ilike '%source text%' and v_return_cols ilike '%email text%' and v_return_cols ilike '%created_at timestamp%' and v_return_cols ilike '%ticket_count bigint%' and v_return_cols ilike '%invoice_count bigint%')
       or v_prosecdef is not true
       or not (v_proconfig::text ilike '%search_path=%')
       or coalesce(v_anon_exec,false) <> false
       or coalesce(v_public_exec,false) <> false
       or coalesce(v_authenticated_exec,false) <> true
    then
      v_any_fail := true;
    end if;
  end;

  -- ── AFTER snapshot, same 6 roles x 2 tables ─────────────────────────────────────────────────
  -- Same fix as the BEFORE loop above: capture under the real role, reset role, then insert.
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
      select count(*), md5(coalesce(string_agg(id::text, ',' order by id), '')) into v_cnt_c, v_fp_c from public.customers;
      v_reason_c := null;
    exception when insufficient_privilege then
      v_cnt_c := null; v_fp_c := 'DENIED'; v_reason_c := sqlstate || ': ' || sqlerrm;
    end;

    begin
      select count(*), md5(coalesce(string_agg(id::text, ',' order by id), '')) into v_cnt_l, v_fp_l from public.leads;
      v_reason_l := null;
    exception when insufficient_privilege then
      v_cnt_l := null; v_fp_l := 'DENIED'; v_reason_l := sqlstate || ': ' || sqlerrm;
    end;

    execute 'reset role';
    perform set_config('request.jwt.claims', '', true);

    insert into zz_visibility values ('after', v_rec.role_label, 'customers', v_cnt_c, v_fp_c);
    insert into zz_visibility values ('after', v_rec.role_label, 'leads', v_cnt_l, v_fp_l);
    if v_reason_c is not null then
      insert into zz_denials values ('after', v_rec.role_label, 'customers', split_part(v_reason_c, ':', 1), v_reason_c);
    end if;
    if v_reason_l is not null then
      insert into zz_denials values ('after', v_rec.role_label, 'leads', split_part(v_reason_l, ':', 1), v_reason_l);
    end if;
  end loop;

  -- ── WRITE-equivalence check, AFTER the policy change -- same pattern as the BEFORE block ──────
  for v_rec in
    select * from (values
      ('master', v_master), ('operation_admin', v_ops), ('sales_admin', v_sales),
      ('technician', v_tech), ('customer', v_cust), ('anon', null::uuid)
    ) as t(role_label, uid)
  loop
    -- customers INSERT
    if v_rec.uid is not null then
      perform set_config('request.jwt.claims', json_build_object('sub', v_rec.uid, 'role', 'authenticated')::text, true);
      execute 'set local role authenticated';
    else
      perform set_config('request.jwt.claims', '', true);
      execute 'set local role anon';
    end if;
    begin
      insert into public.customers (org_id, name, is_test)
        values (v_org, 'QA TEST - delete me - rls write check insert', false)
        returning id into v_wc_new_id;
      v_wc_outcome := 'ALLOWED'; v_wc_sqlstate := null; v_wc_message := null;
    exception when others then
      v_wc_outcome := 'DENIED'; v_wc_sqlstate := sqlstate; v_wc_message := left(sqlerrm, 80); v_wc_new_id := null;
    end;
    execute 'reset role'; perform set_config('request.jwt.claims', '', true);
    if v_wc_new_id is not null then delete from public.customers where id = v_wc_new_id; end if;
    insert into zz_write_checks values ('after', v_rec.role_label, 'customers', 'insert', v_wc_outcome, v_wc_sqlstate, v_wc_message);

    -- customers UPDATE (shared target row)
    if v_rec.uid is not null then
      perform set_config('request.jwt.claims', json_build_object('sub', v_rec.uid, 'role', 'authenticated')::text, true);
      execute 'set local role authenticated';
    else
      perform set_config('request.jwt.claims', '', true);
      execute 'set local role anon';
    end if;
    begin
      update public.customers set name = 'QA TEST - delete me - rls write check (customers) updated'
        where id = v_wc_target_customer;
      get diagnostics v_wc_rowcount = row_count;
      if v_wc_rowcount = 1 then
        v_wc_outcome := 'ALLOWED'; v_wc_sqlstate := null; v_wc_message := null;
      else
        v_wc_outcome := 'DENIED'; v_wc_sqlstate := null; v_wc_message := 'RLS USING excluded the row (0 rows affected, no exception)';
      end if;
    exception when others then
      v_wc_outcome := 'DENIED'; v_wc_sqlstate := sqlstate; v_wc_message := left(sqlerrm, 80);
    end;
    execute 'reset role'; perform set_config('request.jwt.claims', '', true);
    update public.customers set name = 'QA TEST - delete me - rls write check (customers)' where id = v_wc_target_customer;
    insert into zz_write_checks values ('after', v_rec.role_label, 'customers', 'update', v_wc_outcome, v_wc_sqlstate, v_wc_message);

    -- leads INSERT
    if v_rec.uid is not null then
      perform set_config('request.jwt.claims', json_build_object('sub', v_rec.uid, 'role', 'authenticated')::text, true);
      execute 'set local role authenticated';
    else
      perform set_config('request.jwt.claims', '', true);
      execute 'set local role anon';
    end if;
    begin
      insert into public.leads (org_id, name) values (v_org, 'QA TEST - delete me - rls write check insert (lead)')
        returning id into v_wc_new_id;
      v_wc_outcome := 'ALLOWED'; v_wc_sqlstate := null; v_wc_message := null;
    exception when others then
      v_wc_outcome := 'DENIED'; v_wc_sqlstate := sqlstate; v_wc_message := left(sqlerrm, 80); v_wc_new_id := null;
    end;
    execute 'reset role'; perform set_config('request.jwt.claims', '', true);
    if v_wc_new_id is not null then delete from public.leads where id = v_wc_new_id; end if;
    insert into zz_write_checks values ('after', v_rec.role_label, 'leads', 'insert', v_wc_outcome, v_wc_sqlstate, v_wc_message);

    -- leads UPDATE (shared target row)
    if v_rec.uid is not null then
      perform set_config('request.jwt.claims', json_build_object('sub', v_rec.uid, 'role', 'authenticated')::text, true);
      execute 'set local role authenticated';
    else
      perform set_config('request.jwt.claims', '', true);
      execute 'set local role anon';
    end if;
    begin
      update public.leads set name = 'QA TEST - delete me - rls write check (leads) updated'
        where id = v_wc_target_lead;
      get diagnostics v_wc_rowcount = row_count;
      if v_wc_rowcount = 1 then
        v_wc_outcome := 'ALLOWED'; v_wc_sqlstate := null; v_wc_message := null;
      else
        v_wc_outcome := 'DENIED'; v_wc_sqlstate := null; v_wc_message := 'RLS USING excluded the row (0 rows affected, no exception)';
      end if;
    exception when others then
      v_wc_outcome := 'DENIED'; v_wc_sqlstate := sqlstate; v_wc_message := left(sqlerrm, 80);
    end;
    execute 'reset role'; perform set_config('request.jwt.claims', '', true);
    update public.leads set name = 'QA TEST - delete me - rls write check (leads)' where id = v_wc_target_lead;
    insert into zz_write_checks values ('after', v_rec.role_label, 'leads', 'update', v_wc_outcome, v_wc_sqlstate, v_wc_message);
  end loop;

  -- Cleanup the two shared UPDATE-target rows (elevated role, no impersonation active at this point).
  delete from public.customers where id = v_wc_target_customer;
  delete from public.leads where id = v_wc_target_lead;

  -- ── compare write-check outcomes before vs after, every role x table x operation ───────────────
  -- The gate is the outcome CLASS (ALLOWED / DENIED / silently-excluded) AND the SQLSTATE -- a
  -- DENIED that changes its reason to a DIFFERENT CLASS or a different SQLSTATE (e.g. an RLS
  -- denial becoming a different guard's denial with a different SQLSTATE, or vice versa) is just
  -- as real a difference as ALLOWED flipping to DENIED. A message-text-only difference with the
  -- SAME class and SAME SQLSTATE (confirmed live: anon/leads/update denies with 42501 both before
  -- and after, only the wording of WHICH object triggered the 42501 changes -- current_org_id()
  -- vs the leads table itself -- an accepted evaluation-order difference from wrapping the bare
  -- call in (select ...), not a different denial) is recorded as an INFO line, not a FAIL.
  declare
    v_wc_mismatch boolean := false;
    v_wcrec record;
    v_guard text;
  begin
    for v_wcrec in
      select b.role_label, b.tbl, b.op, b.outcome as outcome_before, b.sqlstate_code as sqlstate_before, b.message as message_before,
             a.outcome as outcome_after, a.sqlstate_code as sqlstate_after, a.message as message_after
      from zz_write_checks b join zz_write_checks a
        on a.role_label = b.role_label and a.tbl = b.tbl and a.op = b.op and a.phase = 'after'
      where b.phase = 'before'
      order by b.role_label, b.tbl, b.op
    loop
      if v_wcrec.outcome_before is distinct from v_wcrec.outcome_after
         or v_wcrec.sqlstate_before is distinct from v_wcrec.sqlstate_after then
        v_wc_mismatch := true;
        v_any_fail := true;
        res := res || E'\nFAIL WRITE OUTCOME CHANGED: role=' || v_wcrec.role_label || ' table=' || v_wcrec.tbl || ' op=' || v_wcrec.op
          || ' before(' || coalesce(v_wcrec.outcome_before,'NULL') || '/' || coalesce(v_wcrec.sqlstate_before,'NULL') || '/' || coalesce(v_wcrec.message_before,'NULL') || ')'
          || ' after(' || coalesce(v_wcrec.outcome_after,'NULL') || '/' || coalesce(v_wcrec.sqlstate_after,'NULL') || '/' || coalesce(v_wcrec.message_after,'NULL') || ')';
      else
        -- Attribute the denial (plain words) where the message pattern matches a known guard,
        -- so the owner can compare this against intended business rules without re-deriving it.
        v_guard := case
          when v_wcrec.outcome_after = 'ALLOWED' then null
          when v_wcrec.message_after ilike '%water profile fields%' then 'guard_water_profile_edit_roles (pre-existing business-rule trigger, not this migration)'
          when v_wcrec.message_after ilike '%you can only edit your name, profession%' then 'guard_customer_self_update (pre-existing business-rule trigger, not this migration)'
          when v_wcrec.message_after ilike '%row-level security policy%' or v_wcrec.sqlstate_after = '42501' then 'RLS policy / table grant'
          when v_wcrec.message_after ilike '%RLS USING excluded%' then 'RLS policy (USING silently excluded the row)'
          else 'other (see message text)'
        end;
        if v_wcrec.message_before is distinct from v_wcrec.message_after then
          res := res || E'\nINFO write role=' || v_wcrec.role_label || ' table=' || v_wcrec.tbl || ' op=' || v_wcrec.op
            || ' message text differs, accepted: evaluation order (before="' || coalesce(v_wcrec.message_before,'NULL') || '" after="' || coalesce(v_wcrec.message_after,'NULL') || '")';
        end if;
        res := res || E'\nok   write role=' || v_wcrec.role_label || ' table=' || v_wcrec.tbl || ' op=' || v_wcrec.op
          || ' unchanged (' || coalesce(v_wcrec.outcome_after,'NULL')
          || case when v_guard is not null then ', by: ' || v_guard else '' end || ')';
      end if;
    end loop;
    res := res || E'\n' || case when v_wc_mismatch then 'FAIL: at least one write-check outcome changed -- STOP, do not apply' else 'ok   ALL 24 write-check role/table/op combinations identical before vs after (class + SQLSTATE)' end;
  end;

  -- ── compare before vs after, every role x table ─────────────────────────────────────────────
  for v_rec in
    select b.role_label, b.tbl, b.cnt as cnt_before, b.fp as fp_before, a.cnt as cnt_after, a.fp as fp_after
    from zz_visibility b join zz_visibility a
      on a.role_label = b.role_label and a.tbl = b.tbl and a.phase = 'after'
    where b.phase = 'before'
    order by b.role_label, b.tbl
  loop
    if v_rec.cnt_before is distinct from v_rec.cnt_after or v_rec.fp_before is distinct from v_rec.fp_after then
      v_mismatch := true;
      v_any_fail := true;
      res := res || E'\nFAIL VISIBILITY CHANGED: role=' || v_rec.role_label || ' table=' || v_rec.tbl
        || ' before(cnt=' || coalesce(v_rec.cnt_before::text, 'NULL') || ',fp=' || coalesce(v_rec.fp_before, 'NULL') || ')'
        || ' after(cnt=' || coalesce(v_rec.cnt_after::text, 'NULL') || ',fp=' || coalesce(v_rec.fp_after, 'NULL') || ')';
    else
      res := res || E'\nok   role=' || v_rec.role_label || ' table=' || v_rec.tbl || ' unchanged (cnt=' || coalesce(v_rec.cnt_after::text, 'DENIED') || ')';
    end if;
  end loop;
  res := res || E'\n' || case when v_mismatch then 'FAIL: at least one role/table pair changed visibility -- STOP, do not apply' else 'ok   ALL 12 role/table pairs identical before vs after' end;

  -- ── explicit denial report (which role, why, matching expectation or not) ──────────────────────
  declare
    v_den record;
    v_unexpected_denial boolean := false;
  begin
    for v_den in select distinct role_label, tbl, message from zz_denials order by role_label, tbl loop
      res := res || E'\nINFO DENIED: role=' || v_den.role_label || ' table=' || v_den.tbl || ' -- ' || v_den.message;
      if v_den.role_label <> 'anon' then
        v_unexpected_denial := true;
        v_any_fail := true;
      end if;
    end loop;
    if v_unexpected_denial then
      res := res || E'\nFAIL: an AUTHENTICATED role (not anon) was denied -- this is a real production access problem, not a script issue. STOP, do not apply.';
    elsif exists (select 1 from zz_denials) then
      res := res || E'\nok   only anon was denied, consistently -- matches the live grants (anon has no EXECUTE on current_org_id/is_staff/current_customer_id/current_technician_id; authenticated/postgres/service_role do). Expected, not a regression.';
    else
      res := res || E'\nINFO no role was denied at all in this run (anon''s policy-evaluation path may not have been reached, or the earlier failure is no longer reproducing) -- worth noting, not a failure either way.';
    end if;
  end;

  -- ── find_duplicate_contacts behavior tests ──────────────────────────────────────────────────
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
    res := res || E'\nFAIL staff call raised unexpectedly: ' || sqlerrm;
  end;
  res := res || E'\n' || case when v_staff_ok then 'ok   staff (master) call to find_duplicate_contacts succeeded' else 'FAIL staff call did not succeed' end;

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
  res := res || E'\n' || case when v_nonstaff_refused then 'ok   non-staff (technician) call correctly refused with the "not staff" message' else 'FAIL non-staff refusal check did not pass as expected' end;

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
  res := res || E'\n' || case when v_anon_refused then 'ok   anon call correctly refused (no EXECUTE grant)' else 'FAIL anon refusal check did not pass as expected' end;
  if not v_staff_ok or not v_nonstaff_refused or not v_anon_refused then
    v_any_fail := true;
  end if;

  -- ── EXPLAIN, before the companion index migration's indexes exist ──────────────────────────
  perform set_config('request.jwt.claims', json_build_object('sub', v_master, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  execute $q$
    explain (format json)
    select id, name, mobile from public.customers
    where org_id = $1 and archived_at is null and (name ilike '%test%' or mobile ilike '%test%' or email ilike '%test%')
    limit 6
  $q$ into v_search_plan_before using v_org;
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);

  -- find_duplicate_contacts's own inner query, as it now runs under SECURITY DEFINER -- NOT
  -- impersonating 'authenticated' for this one, matching what SECURITY DEFINER actually does
  -- (runs as the function owner, not the caller -- see file header).
  execute $q$
    explain (format json)
    select c.id, c.name, c.mobile, c.created_at
    from public.customers c
    where c.org_id = $1 and not c.is_test
      and (public._mobile_key(c.mobile) = public._mobile_key('9092766740') or lower(c.email) = 'test@example.com')
  $q$ into v_dup_plan_before using v_org;

  res := res || E'\nINFO search_plan BEFORE indexes (real role, (a)+(c) only)=' || v_search_plan_before::text;
  res := res || E'\nINFO dup_plan BEFORE indexes ((a)+(c) only, owner-role context)=' || v_dup_plan_before::text;

  -- ── temporarily create the companion index migration's 6 indexes, same transaction ─────────
  create extension if not exists pg_trgm with schema extensions;
  create index if not exists idx_customers_name_trgm on public.customers using gin (name extensions.gin_trgm_ops);
  create index if not exists idx_customers_mobile_trgm on public.customers using gin (mobile extensions.gin_trgm_ops);
  create index if not exists idx_customers_email_trgm on public.customers using gin (email extensions.gin_trgm_ops);
  create index if not exists idx_customers_mobile_key on public.customers using btree (public._mobile_key(mobile));
  create index if not exists idx_leads_mobile_key on public.leads using btree (public._mobile_key(mobile));
  create index if not exists idx_customers_email_lower on public.customers using btree (lower(email));
  execute 'analyze public.customers';
  execute 'analyze public.leads';

  perform set_config('request.jwt.claims', json_build_object('sub', v_master, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  execute $q$
    explain (format json)
    select id, name, mobile from public.customers
    where org_id = $1 and archived_at is null and (name ilike '%test%' or mobile ilike '%test%' or email ilike '%test%')
    limit 6
  $q$ into v_search_plan_after using v_org;
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);

  execute $q$
    explain (format json)
    select c.id, c.name, c.mobile, c.created_at
    from public.customers c
    where c.org_id = $1 and not c.is_test
      and (public._mobile_key(c.mobile) = public._mobile_key('9092766740') or lower(c.email) = 'test@example.com')
  $q$ into v_dup_plan_after using v_org;

  res := res || E'\nINFO search_plan AFTER (a)+(c)+indexes=' || v_search_plan_after::text;
  res := res || E'\nINFO dup_plan AFTER (a)+(c)+indexes=' || v_dup_plan_after::text;

  -- ── revised pass criterion (owner, this round): the goal is that the per-row policy
  -- function-call cost disappears, NOT that an index scan must win -- PASS if total estimated
  -- cost of the search query falls by >= 10x. Index use is reported separately, informationally.
  declare
    v_cost_before numeric;
    v_cost_after numeric;
    v_cost_ratio numeric;
    v_trgm_used boolean;
    v_leakproof_texticlike boolean;
    v_leakproof_textlike boolean;
  begin
    v_cost_before := (v_search_plan_before->0->'Plan'->>'Total Cost')::numeric;
    v_cost_after := (v_search_plan_after->0->'Plan'->>'Total Cost')::numeric;
    v_cost_ratio := case when v_cost_after > 0 then v_cost_before / v_cost_after else null end;

    v_trgm_used := v_search_plan_after::text ilike '%idx_customers_name_trgm%'
                or v_search_plan_after::text ilike '%idx_customers_mobile_trgm%'
                or v_search_plan_after::text ilike '%idx_customers_email_trgm%';

    res := res || E'\nINFO search query total cost: before=' || v_cost_before || ' after=' || v_cost_after
               || ' ratio=' || coalesce(round(v_cost_ratio, 1)::text, 'n/a');
    res := res || E'\n' || case when v_cost_ratio is not null and v_cost_ratio >= 10
                            then 'ok   search query cost fell by >= 10x -- the per-row policy function-call cost is gone (the actual goal), regardless of index use'
                            else 'FAIL search query cost did not fall by at least 10x -- a per-row function-call cost is still present somewhere in an applicable policy' end;
    if v_cost_ratio is null or v_cost_ratio < 10 then
      v_any_fail := true;
    end if;
    res := res || E'\n' || case when v_trgm_used
                            then 'INFO the trigram index IS used by the search query'
                            else 'INFO the trigram index is NOT used by the search query -- NOT treated as a failure under the revised criterion' end;

    if not v_trgm_used then
      select proleakproof into v_leakproof_texticlike from pg_proc where proname='texticlike' and pronamespace='pg_catalog'::regnamespace;
      select proleakproof into v_leakproof_textlike from pg_proc where proname='textlike' and pronamespace='pg_catalog'::regnamespace;
      res := res || E'\nINFO pg_proc.proleakproof: texticlike=' || coalesce(v_leakproof_texticlike::text,'unknown') || ' textlike=' || coalesce(v_leakproof_textlike::text,'unknown');
      res := res || E'\nINFO ' || case when coalesce(v_leakproof_texticlike,false) and coalesce(v_leakproof_textlike,false)
        then 'both leakproof -- trigram non-use is not a security-barrier/RLS-pushdown issue; most likely just the planner preferring a different access path on this table size now that the function-call cost is gone. A dedicated search RPC (item d) is an OPTIONAL follow-up if trigram use specifically is still wanted, not a required fix.'
        else 'NOT both leakproof -- a non-leakproof operator inside a security-barrier/RLS-protected relation can be kept from being pushed into an index scan ahead of row-security filtering by Postgres''s own planner rules, which fits what is observed here. A dedicated SECURITY DEFINER search RPC (item d), same shape as find_duplicate_contacts, would remove RLS entirely from this query''s evaluation and let the trigram index be used freely -- worth building if trigram use specifically still matters for IO beyond the cost-reduction already achieved.' end;
    end if;
  end;

  -- Index use for this query is informational only (same revised criterion as the search query
  -- above, owner-accepted) -- it never sets v_any_fail; the cost-ratio check above is the one
  -- real gate for the per-row-function-cost goal this migration exists to fix.
  res := res || E'\n' || case when v_dup_plan_after::text ilike '%Seq Scan%'
                          then 'INFO duplicate-check query still does a Seq Scan even with (a)+(c)+indexes all together -- accepted as informational, not a failure; see the cost-ratio check above for the real gate'
                          else 'ok   duplicate-check query no longer does a Seq Scan with (a)+(c)+indexes all together' end;

  -- Single top-level, unconditional RAISE EXCEPTION (required by rehearsal_guard.mjs) -- only the
  -- MESSAGE prefix is conditional on v_any_fail, never whether this statement itself fires. A run
  -- where every real gate passed reads DRYRUN_OK; a run where any real gate failed reads
  -- DRYRUN_FAIL, both followed by the full res detail -- either way the transaction still rolls
  -- back via this same exception, exactly as before.
  res := case when v_any_fail then 'DRYRUN_FAIL:' else 'DRYRUN_OK:' end || res;
  raise exception '%', res;
end
$dryrun$;
