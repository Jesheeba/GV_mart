-- Rolled-back DB tests for 20261114100000_spare_handover_completion_gaps.sql.
-- Run with the migration applied in the same transaction (the runner concatenates it in
-- front of this file -- never concatenate them into one file). Throwaway __TEST_ org only.
-- NOT run against any database by this agent -- this file has never been executed.
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
  v_org uuid; v_master uuid; v_ops uuid; v_sales uuid;
  v_tp1 uuid; v_tp2 uuid; v_tech1 uuid; v_tech2 uuid;
  v_cust uuid; v_spare1 uuid; v_spare2 uuid; v_tk uuid; v_visit uuid;
  v_handover_id uuid; v_item1_id uuid; v_item_check uuid;
  v_given_by uuid; v_received_qty integer; v_dispute_note text;
  v_notif_count integer; v_rows integer;
  v_wh1 integer; v_wh2 integer; v_wh2_after integer;
  v_ledger_handed integer; v_ledger_used integer; v_ledger_returned integer; v_ledger_balance integer;
  v_ledger_rowcount integer;
  fp_handovers_before text; fp_handovers_after text; fp_notif_before bigint; fp_notif_after bigint;
begin
  -- fingerprint real (non-test) data before touching anything, re-checked at the end.
  select md5(coalesce(string_agg(id::text || coalesce(given_by::text,'') , ',' order by id), '')) into fp_handovers_before
    from public.spare_handovers where org_id not in (select id from public.organizations where name like '\_\_TEST\_%' escape '\');
  select count(*) into fp_notif_before from public.notifications
    where org_id not in (select id from public.organizations where name like '\_\_TEST\_%' escape '\');

  insert into public.organizations (name) values ('__TEST_spare_handover_gaps') returning id into v_org;
  insert into public.settings (org_id) values (v_org) on conflict (org_id) do nothing;

  v_master := pg_temp.mkuser('master', v_org);
  v_ops := pg_temp.mkuser('operation_admin', v_org);
  v_sales := pg_temp.mkuser('sales_admin', v_org);
  v_tp1 := pg_temp.mkuser('technician', v_org);
  v_tp2 := pg_temp.mkuser('technician', v_org);
  insert into public.technicians (org_id, profile_id, is_active) values (v_org, v_tp1, true) returning id into v_tech1;
  insert into public.technicians (org_id, profile_id, is_active) values (v_org, v_tp2, true) returning id into v_tech2;

  insert into public.customers (org_id, name, mobile) values (v_org, '__TEST_ Cust', '9500000001') returning id into v_cust;
  insert into public.spares (org_id, name, sku, price) values (v_org, '__TEST_ Spare One', 'T-SP1', 100) returning id into v_spare1;
  insert into public.spares (org_id, name, sku, price) values (v_org, '__TEST_ Spare Two', 'T-SP2', 200) returning id into v_spare2;
  insert into public.inventory (org_id, item_type, item_id, stock_qty, location) values (v_org, 'spare', v_spare1, 20, 'warehouse');
  insert into public.inventory (org_id, item_type, item_id, stock_qty, location) values (v_org, 'spare', v_spare2, 10, 'warehouse');

  insert into public.service_tickets (org_id, customer_id, type, name_of_complaint) values (v_org, v_cust, 'paid', '__TEST_ ticket') returning id into v_tk;
  insert into public.service_visits (org_id, ticket_id, technician_id) values (v_org, v_tk, v_tech1) returning id into v_visit;

  -- ── requirement 2: given_by ────────────────────────────────────────────────────────────
  perform pg_temp.as_user(v_ops);
  v_handover_id := public.create_spare_handover(v_org, v_tech1, current_date, jsonb_build_array(jsonb_build_object('spare_id', v_spare1, 'qty_given', 5)));
  perform pg_temp.as_pg();
  select given_by into v_given_by from public.spare_handovers where id = v_handover_id;
  perform pg_temp.chk('create_spare_handover records given_by = calling ops staff', v_given_by = v_ops, v_given_by::text);
  select id into v_item1_id from public.spare_handover_items where handover_id = v_handover_id and spare_id = v_spare1;
  perform pg_temp.chk('hand-over item line created', v_item1_id is not null);

  select stock_qty into v_wh1 from public.inventory where org_id = v_org and item_type = 'spare' and item_id = v_spare1 and location = 'warehouse';
  perform pg_temp.chk('warehouse decremented by the hand-over (unchanged behavior)', v_wh1 = 15, v_wh1::text);

  -- sales_admin may not hand over spares (requirement 1, unchanged -- re-verified here since
  -- this migration redefines create_spare_handover).
  perform pg_temp.as_user(v_sales);
  begin
    perform public.create_spare_handover(v_org, v_tech1, current_date, jsonb_build_array(jsonb_build_object('spare_id', v_spare1, 'qty_given', 1)));
    perform pg_temp.chk('sales_admin cannot create a hand-over', false);
  exception when others then
    perform pg_temp.chk('sales_admin cannot create a hand-over', sqlerrm like '%not ops staff%', sqlerrm);
  end;
  perform pg_temp.as_pg();

  -- ── requirement 2: dispute flagging ────────────────────────────────────────────────────
  perform pg_temp.as_user(v_tp1);
  perform public.report_spare_handover_discrepancy(v_org, v_item1_id, 3, '__TEST_ only received 3');
  perform pg_temp.as_pg();
  select received_qty, dispute_note into v_received_qty, v_dispute_note from public.spare_handover_items where id = v_item1_id;
  perform pg_temp.chk('dispute recorded on the item', v_received_qty = 3 and v_dispute_note = '__TEST_ only received 3');
  select count(*) into v_notif_count from public.notifications
    where org_id = v_org and role = 'operation_admin' and type = 'spare_handover_disputed' and ref_id = v_handover_id;
  perform pg_temp.chk('staff notified of the dispute', v_notif_count = 1, v_notif_count::text);

  -- disputing with received_qty equal to the original qty_given is refused as a no-op
  -- (the comparison is always against qty_given, so this is refused on every call, not just
  -- the first).
  perform pg_temp.as_user(v_tp1);
  begin
    perform public.report_spare_handover_discrepancy(v_org, v_item1_id, 5, 'matches qty_given');
    perform pg_temp.chk('disputing with received_qty = qty_given is refused', false);
  exception when others then
    perform pg_temp.chk('disputing with received_qty = qty_given is refused', sqlerrm like '%nothing to flag%', sqlerrm);
  end;
  perform pg_temp.as_pg();

  -- another technician cannot dispute someone else's item.
  perform pg_temp.as_user(v_tp2);
  begin
    perform public.report_spare_handover_discrepancy(v_org, v_item1_id, 1, 'not mine');
    perform pg_temp.chk('technician2 cannot dispute technician1''s item', false);
  exception when others then
    perform pg_temp.chk('technician2 cannot dispute technician1''s item', sqlerrm like '%does not belong to the calling technician%', sqlerrm);
  end;
  -- ── requirement 3: a technician cannot even SELECT another technician's hand-over item
  -- (RLS filters it out silently -- zero rows, no exception).
  v_item_check := null;
  select id into v_item_check from public.spare_handover_items where id = v_item1_id;
  get diagnostics v_rows = row_count;
  perform pg_temp.chk('technician2 sees zero rows for technician1''s hand-over item (RLS)', v_rows = 0, v_rows::text);
  perform pg_temp.as_pg();

  -- technician1 can still see (and only) their own item.
  perform pg_temp.as_user(v_tp1);
  v_item_check := null;
  select id into v_item_check from public.spare_handover_items where id = v_item1_id;
  get diagnostics v_rows = row_count;
  perform pg_temp.chk('technician1 can see their own hand-over item', v_rows = 1);
  perform pg_temp.as_pg();

  -- ── requirement 6: a service-use shortfall (no recorded van stock for spare2) is flagged
  perform pg_temp.as_user(v_tp1);
  perform public.create_service_invoice(
    v_org, v_visit, 0, 0, jsonb_build_array(jsonb_build_object('spare_id', v_spare2, 'qty', 2)),
    'cash'::payment_method, null, null, true
  );
  perform pg_temp.as_pg();

  select count(*) into v_notif_count from public.notifications
    where org_id = v_org and role = 'operation_admin' and type = 'spare_use_shortfall' and ref_id = v_visit;
  perform pg_temp.chk('staff notified of the service-use shortfall', v_notif_count = 1, v_notif_count::text);
  perform pg_temp.chk('inventory_movements tags the shortfall correctly (unchanged behavior)',
    exists (select 1 from public.inventory_movements where org_id = v_org and item_id = v_spare2 and technician_id = v_tech1 and reason = 'service_use_shortfall' and change_qty = -2));
  select stock_qty into v_wh2_after from public.inventory where org_id = v_org and item_type = 'spare' and item_id = v_spare2 and location = 'warehouse';
  perform pg_temp.chk('warehouse decremented exactly once for the shortfall, not twice (requirement 4, unchanged)', v_wh2_after = 8, v_wh2_after::text);

  -- ── requirement 7: staff ledger aggregates handed-over / used / returned / balance ───────
  perform pg_temp.as_user(v_ops);
  select qty_handed_over, qty_used, qty_returned, balance
    into v_ledger_handed, v_ledger_used, v_ledger_returned, v_ledger_balance
    from public.technician_spare_ledger where org_id = v_org and technician_id = v_tech1 and spare_id = v_spare1;
  perform pg_temp.chk('ledger: spare1 handed over = 5, used = 0, balance = 5',
    v_ledger_handed = 5 and v_ledger_used = 0 and v_ledger_returned = 0 and v_ledger_balance = 5,
    format('handed=%s used=%s returned=%s balance=%s', v_ledger_handed, v_ledger_used, v_ledger_returned, v_ledger_balance));

  select qty_handed_over, qty_used, qty_returned, balance
    into v_ledger_handed, v_ledger_used, v_ledger_returned, v_ledger_balance
    from public.technician_spare_ledger where org_id = v_org and technician_id = v_tech1 and spare_id = v_spare2;
  perform pg_temp.chk('ledger: spare2 used = 2 (never handed over, balance stays 0)',
    v_ledger_handed = 0 and v_ledger_used = 2 and v_ledger_returned = 0 and v_ledger_balance = 0,
    format('handed=%s used=%s returned=%s balance=%s', v_ledger_handed, v_ledger_used, v_ledger_returned, v_ledger_balance));

  -- sales_admin is staff too (is_staff() includes it) and sees the same ledger rows.
  perform pg_temp.as_pg();
  perform pg_temp.as_user(v_sales);
  select count(*) into v_ledger_rowcount from public.technician_spare_ledger where org_id = v_org and technician_id = v_tech1;
  perform pg_temp.chk('sales_admin (staff) can read the ledger', v_ledger_rowcount = 2, v_ledger_rowcount::text);
  perform pg_temp.as_pg();

  -- a technician gets zero rows from the staff ledger (inventory_movements grants them no
  -- SELECT at all) -- the technician's own balance comes from technician_stock_levels
  -- directly (the "My spares" screen), not from this view.
  perform pg_temp.as_user(v_tp1);
  select count(*) into v_ledger_rowcount from public.technician_spare_ledger where org_id = v_org and technician_id = v_tech1;
  perform pg_temp.chk('technician sees zero rows on the staff ledger (RLS)', v_ledger_rowcount = 0, v_ledger_rowcount::text);
  select stock_qty into v_rows from public.technician_stock_levels where org_id = v_org and technician_id = v_tech1 and item_type = 'spare' and item_id = v_spare1;
  perform pg_temp.chk('technician still reads their own balance directly from technician_stock_levels', v_rows = 5, v_rows::text);
  perform pg_temp.as_pg();

  -- ── grants: no anon/public access to the new objects ──────────────────────────────────
  perform pg_temp.chk('anon has no EXECUTE on report_spare_handover_discrepancy',
    not has_function_privilege('anon', 'public.report_spare_handover_discrepancy(uuid,uuid,integer,text)', 'execute'));
  perform pg_temp.chk('authenticated has EXECUTE on report_spare_handover_discrepancy',
    has_function_privilege('authenticated', 'public.report_spare_handover_discrepancy(uuid,uuid,integer,text)', 'execute'));
  perform pg_temp.chk('anon has no SELECT on technician_spare_ledger',
    not has_table_privilege('anon', 'public.technician_spare_ledger', 'select'));
  perform pg_temp.chk('authenticated has SELECT on technician_spare_ledger',
    has_table_privilege('authenticated', 'public.technician_spare_ledger', 'select'));

  -- ── real-org data is untouched ─────────────────────────────────────────────────────────
  select md5(coalesce(string_agg(id::text || coalesce(given_by::text,'') , ',' order by id), '')) into fp_handovers_after
    from public.spare_handovers where org_id not in (select id from public.organizations where name like '\_\_TEST\_%' escape '\');
  select count(*) into fp_notif_after from public.notifications
    where org_id not in (select id from public.organizations where name like '\_\_TEST\_%' escape '\');
  perform pg_temp.chk('real spare_handovers rows unchanged', fp_handovers_before = fp_handovers_after);
  perform pg_temp.chk('real notifications count unchanged', fp_notif_before = fp_notif_after, format('%s -> %s', fp_notif_before, fp_notif_after));

  raise exception 'RESULTS%', E'\n' || (select string_agg(r.line, E'\n' order by r.n) from pg_temp.res r);
end $t$;
