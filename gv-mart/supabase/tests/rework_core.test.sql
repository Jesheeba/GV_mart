-- Rolled-back DB tests for 20270101100100_rework_core.sql (feature doc build-docs/features/rework.md).
-- Preconditions: 20270101100000_rework_enums.sql COMMITTED. The runner concatenates the core migration in
-- front of this file inside ONE transaction; this file ends in RAISE so everything rolls back.
-- Throwaway __TEST_ org only. Test names map to the feature doc's acceptance criteria (AC1..AC10).
create temp table res (n serial, line text);
grant all on res to public;
grant usage on sequence res_n_seq to public;
do $g$ begin execute format('alter default privileges in schema %s grant execute on functions to public', pg_my_temp_schema()::regnamespace); end $g$;
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
-- Runs p_sql as p_uid; returns the error message, or '' when it succeeded.
create function pg_temp.try_as(p_uid uuid, p_sql text) returns text language plpgsql as $f$
begin
  perform pg_temp.as_user(p_uid);
  begin
    execute p_sql;
  exception when others then
    perform pg_temp.as_pg();
    return sqlerrm;
  end;
  perform pg_temp.as_pg();
  return '';
end $f$;
-- A completed original job: ticket + finished visit by p_tech + invoice created by that technician.
create function pg_temp.mkdone(p_org uuid, p_cust uuid, p_prod uuid, p_brand uuid, p_model uuid, p_tech uuid, p_tech_user uuid, p_label text)
returns uuid language plpgsql as $f$
declare v_tk uuid; v_vis uuid;
begin
  insert into public.service_tickets (org_id, customer_id, product_id, brand_id, model_id, type, name_of_complaint)
    values (p_org, p_cust, p_prod, p_brand, p_model, 'paid', '__TEST_ ' || p_label) returning id into v_tk;
  insert into public.service_visits (org_id, ticket_id, technician_id, timer_start, timer_end)
    values (p_org, v_tk, p_tech, now() - interval '2 hours', now() - interval '1 hour') returning id into v_vis;
  perform pg_temp.as_user(p_tech_user);
  perform public.create_service_invoice(p_org, v_vis, 300, 0, '[]'::jsonb, 'cash'::payment_method, null, null, true);
  perform pg_temp.as_pg();
  return v_tk;
end $f$;

do $t$
declare
  v_org uuid; v_master uuid; v_ops uuid; v_sales uuid;
  v_tp1 uuid; v_tp2 uuid; v_tp3 uuid; v_tech1 uuid; v_tech2 uuid; v_tech3 uuid;
  v_cust uuid; v_c1 uuid; v_c2 uuid; v_c5 uuid; v_brand uuid; v_model uuid; v_prod uuid; v_spare uuid;
  v_t0 uuid; v_t1 uuid; v_t2 uuid; v_t5 uuid; v_open uuid;
  v_r0 uuid; v_r1 uuid; v_r1b uuid; v_r2 uuid;
  v_res jsonb; v_err text; v_row public.service_tickets; v_cnt integer; v_txt text; v_num numeric;
  v_vis uuid; v_appr uuid; v_bool boolean;
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  fp_before text; fp_after text;
begin
  select md5(coalesce(string_agg(id::text || status::text || coalesce(type::text, ''), ',' order by id), ''))
       || (select count(*)::text from public.approvals where org_id not in (select id from public.organizations where name like '\_\_TEST\_%' escape '\'))
    into fp_before
    from public.service_tickets where org_id not in (select id from public.organizations where name like '\_\_TEST\_%' escape '\');

  insert into public.organizations (name) values ('__TEST_rework_core') returning id into v_org;
  insert into public.settings (org_id) values (v_org) on conflict (org_id) do nothing;
  v_master := pg_temp.mkuser('master', v_org);
  v_ops := pg_temp.mkuser('operation_admin', v_org);
  v_sales := pg_temp.mkuser('sales_admin', v_org);
  v_tp1 := pg_temp.mkuser('technician', v_org);
  v_tp2 := pg_temp.mkuser('technician', v_org);
  v_tp3 := pg_temp.mkuser('technician', v_org);
  insert into public.technicians (org_id, profile_id, is_active) values (v_org, v_tp1, true) returning id into v_tech1;
  insert into public.technicians (org_id, profile_id, is_active) values (v_org, v_tp2, true) returning id into v_tech2;
  insert into public.technicians (org_id, profile_id, is_active) values (v_org, v_tp3, true) returning id into v_tech3;
  -- One customer per original job, so the existing "customer already has a job then" check never interferes.
  insert into public.customers (org_id, name, mobile) values (v_org, '__TEST_ Cust0', '9500000091') returning id into v_cust;
  insert into public.customers (org_id, name, mobile) values (v_org, '__TEST_ Cust1', '9500000092') returning id into v_c1;
  insert into public.customers (org_id, name, mobile) values (v_org, '__TEST_ Cust2', '9500000093') returning id into v_c2;
  insert into public.customers (org_id, name, mobile) values (v_org, '__TEST_ Cust5', '9500000094') returning id into v_c5;
  insert into public.brands (org_id, name, category) values (v_org, '__TEST_ Brand', 'ro') returning id into v_brand;
  insert into public.models (org_id, brand_id, name) values (v_org, v_brand, '__TEST_ Model') returning id into v_model;
  insert into public.products (org_id, brand_id, model_id, name, category, price) values (v_org, v_brand, v_model, '__TEST_ RO', 'ro', 10000) returning id into v_prod;
  insert into public.spares (org_id, name, sku, price) values (v_org, '__TEST_ Filter', 'T-RW1', 400) returning id into v_spare;
  insert into public.inventory (org_id, item_type, item_id, stock_qty, location) values (v_org, 'spare', v_spare, 10, 'warehouse');

  v_t0 := pg_temp.mkdone(v_org, v_cust, v_prod, v_brand, v_model, v_tech1, v_tp1, 't0');
  v_t2 := pg_temp.mkdone(v_org, v_c2, v_prod, v_brand, v_model, v_tech1, v_tp1, 't2');
  v_t1 := pg_temp.mkdone(v_org, v_c1, v_prod, v_brand, v_model, v_tech3, v_tp3, 't1');
  v_t5 := pg_temp.mkdone(v_org, v_c5, v_prod, v_brand, v_model, v_tech1, v_tp1, 't5');
  insert into public.service_tickets (org_id, customer_id, product_id, type, name_of_complaint)
    values (v_org, v_cust, v_prod, 'paid', '__TEST_ open') returning id into v_open;
  perform pg_temp.chk('fixture: originals completed', (select count(*) from public.service_tickets where id in (v_t0, v_t1, v_t2, v_t5) and status = 'completed') = 4);

  -- ── AC1: who may mark, and the preconditions ───────────────────────────────────────────────
  v_err := pg_temp.try_as(v_tp1, format('select public.mark_ticket_rework(%L, %L, %L)', v_t0, 'came back again', v_today));
  perform pg_temp.chk('AC1 technician cannot mark rework', v_err like '%only master or operation_admin%', v_err);
  v_err := pg_temp.try_as(v_sales, format('select public.mark_ticket_rework(%L, %L, %L)', v_t0, 'came back again', v_today));
  perform pg_temp.chk('AC1 sales_admin cannot mark rework', v_err like '%only master or operation_admin%', v_err);
  v_err := pg_temp.try_as(v_ops, format('select public.mark_ticket_rework(%L, %L, %L)', v_t0, 'bad', v_today));
  perform pg_temp.chk('AC1 reason under 5 chars refused', v_err like '%at least 5 characters%', v_err);
  v_err := pg_temp.try_as(v_ops, format('select public.mark_ticket_rework(%L, %L, %L)', v_open, 'came back again', v_today));
  perform pg_temp.chk('AC1 open (not completed) ticket refused', v_err like '%only a completed ticket%', v_err);
  update public.invoices set created_at = now() - interval '31 days' where id = (select invoice_id from public.service_tickets where id = v_t5);
  v_err := pg_temp.try_as(v_ops, format('select public.mark_ticket_rework(%L, %L, %L)', v_t5, 'came back again', v_today));
  perform pg_temp.chk('AC1 outside the 30-day window refused', v_err like '%more than 30 days%', v_err);
  update public.settings set rework_window_days = 60 where org_id = v_org;
  v_err := pg_temp.try_as(v_ops, format('select public.mark_ticket_rework(%L, %L, %L)', v_t5, 'came back again', v_today));
  perform pg_temp.chk('AC1 master-raised window (60 days) lets the same ticket through', v_err = '', v_err);
  update public.settings set rework_window_days = 30 where org_id = v_org;

  -- ── AC2: linked ticket, auto-assigned to the original technician ───────────────────────────
  perform pg_temp.as_user(v_ops);
  v_res := public.mark_ticket_rework(v_t0, 'Leak is back after the repair', v_today);
  perform pg_temp.as_pg();
  v_r0 := (v_res ->> 'rework_ticket_id')::uuid;
  select * into v_row from public.service_tickets where id = v_r0;
  perform pg_temp.chk('AC2 rework ticket created with type rework', v_row.type::text = 'rework', coalesce(v_row.type::text, '<null>'));
  perform pg_temp.chk('AC2 linked to the original', v_row.rework_of_ticket_id = v_t0);
  perform pg_temp.chk('AC2 responsible = technician of the last finished visit', v_row.rework_responsible_technician_id = v_tech1);
  perform pg_temp.chk('AC2 reason + raised_by recorded', v_row.rework_reason = 'Leak is back after the repair' and v_row.rework_raised_by = v_ops);
  perform pg_temp.chk('AC2 assigned to the original technician',
    exists (select 1 from public.appointments where ticket_id = v_r0 and technician_id = v_tech1), v_res::text);
  perform pg_temp.chk('AC7 rework carries no AMC/warranty/rental link', v_row.contract_id is null and v_row.warranty_id is null and v_row.rental_contract_id is null);
  perform pg_temp.chk('AC8 original visit flagged needs_revisit',
    exists (select 1 from public.service_visits where ticket_id = v_t0 and needs_revisit));
  perform pg_temp.chk('original stays completed with its invoice',
    exists (select 1 from public.service_tickets where id = v_t0 and status = 'completed' and invoice_id is not null));

  v_err := pg_temp.try_as(v_ops, format('select public.mark_ticket_rework(%L, %L, %L)', v_t0, 'again and again', v_today));
  perform pg_temp.chk('AC1 second rework on the same original refused', v_err like '%already has rework%', v_err);

  -- ── Guard: rework fields cannot be edited directly ─────────────────────────────────────────
  v_err := pg_temp.try_as(v_ops, format('update public.service_tickets set rework_responsible_technician_id = %L where id = %L', v_tech2, v_r0));
  perform pg_temp.chk('AC3 ops cannot move the responsible technician by direct update', v_err like '%rework fields can only be changed%', v_err);
  v_err := pg_temp.try_as(v_ops, format('update public.service_tickets set type = %L where id = %L', 'paid', v_r0));
  perform pg_temp.chk('ops cannot turn a rework into another type directly', v_err like '%rework fields can only be changed%', v_err);
  v_err := pg_temp.try_as(v_ops, format('insert into public.service_tickets (org_id, customer_id, type, name_of_complaint) values (%L, %L, %L, %L)', v_org, v_cust, 'rework', 'x'));
  perform pg_temp.chk('ops cannot insert a rework ticket directly', v_err like '%use Mark as rework%', v_err);

  -- ── AC3: reassign keeps the responsible technician ─────────────────────────────────────────
  perform pg_temp.as_user(v_ops);
  v_res := public.assign_ticket_technician((select id from public.appointments where ticket_id = v_r0 limit 1), v_tech2, true);
  perform pg_temp.as_pg();
  perform pg_temp.chk('AC3 reassigned to technician 2', exists (select 1 from public.appointments where ticket_id = v_r0 and technician_id = v_tech2), v_res::text);
  perform pg_temp.chk('AC3 responsible still technician 1', (select rework_responsible_technician_id from public.service_tickets where id = v_r0) = v_tech1);
  perform pg_temp.as_user(v_ops);
  perform public.assign_ticket_technician((select id from public.appointments where ticket_id = v_r0 limit 1), v_tech1, true);
  perform pg_temp.as_pg();

  -- ── AC2: original technician inactive -> unassigned + ops told; pickers skip it ────────────
  update public.technicians set is_active = false where id = v_tech3;
  perform pg_temp.as_user(v_ops);
  v_res := public.mark_ticket_rework(v_t1, 'Noise returned within a week', v_today);
  perform pg_temp.as_pg();
  v_r1 := (v_res ->> 'rework_ticket_id')::uuid;
  perform pg_temp.chk('AC2 inactive original technician -> left unassigned',
    not exists (select 1 from public.appointments where ticket_id = v_r1 and technician_id is not null));
  perform pg_temp.chk('AC2 responsible still the inactive original technician', (select rework_responsible_technician_id from public.service_tickets where id = v_r1) = v_tech3);
  perform pg_temp.chk('AC2 ops notified to assign it',
    exists (select 1 from public.notifications where org_id = v_org and type = 'rework_unassigned' and ref_id = v_r1));
  insert into public.attendance (org_id, technician_id, date, check_in_at) values (v_org, v_tech2, v_today, now());
  perform pg_temp.chk('picker: next-ticket-available skips an unassigned rework', not public._next_ticket_available_for_technician(v_org, v_tech2));
  v_res := public._auto_assign_next_ticket_to_technician(v_org, v_tech2);
  perform pg_temp.chk('picker: auto-assign-next does not hand the rework to someone else',
    not exists (select 1 from public.appointments where ticket_id = v_r1 and technician_id is not null), v_res::text);

  -- ── AC8: cancel clears needs_revisit; the original can then be marked again ────────────────
  perform pg_temp.as_user(v_ops);
  perform public.cancel_service_ticket(v_r1, 'Marked by mistake');
  perform pg_temp.as_pg();
  perform pg_temp.chk('AC8 cancelling the rework clears needs_revisit on the original',
    not exists (select 1 from public.service_visits where ticket_id = v_t1 and needs_revisit));
  update public.technicians set is_active = true where id = v_tech3;
  v_err := pg_temp.try_as(v_ops, format('select public.mark_ticket_rework(%L, %L, %L, %L::jsonb, %L)', v_t1, 'Noise returned again', v_today, '[]', v_tech2));
  perform pg_temp.chk('AC1 after a cancelled rework the original can be marked again (explicit technician)', v_err = '', v_err);
  select id into v_r1b from public.service_tickets where rework_of_ticket_id = v_t1 and status <> 'cancelled';
  perform pg_temp.chk('AC3 explicit pick assigns technician 2, responsible stays technician 3',
    exists (select 1 from public.appointments where ticket_id = v_r1b and technician_id = v_tech2)
    and (select rework_responsible_technician_id from public.service_tickets where id = v_r1b) = v_tech3);

  -- ── AC4: free rework is 0 even when the app claims chargeable ──────────────────────────────
  insert into public.service_visits (org_id, ticket_id, technician_id, timer_start, timer_end)
    values (v_org, v_r0, v_tech1, now() - interval '50 minutes', now() - interval '10 minutes') returning id into v_vis;
  perform pg_temp.as_user(v_tp1);
  v_res := public.create_service_invoice(v_org, v_vis, 0, 0, '[]'::jsonb, 'cash'::payment_method, null, null, true);
  perform pg_temp.as_pg();
  select * into v_row from public.service_tickets where id = v_r0;
  perform pg_temp.chk('AC4 free rework invoice total is 0', (v_res ->> 'total')::numeric = 0, v_res::text);
  perform pg_temp.chk('AC4 outcome recorded as free', v_row.rework_outcome = 'free' and v_row.status = 'completed');
  perform pg_temp.chk('AC6 penalty-not-set flagged to master',
    exists (select 1 from public.notifications where org_id = v_org and role = 'master' and type = 'rework_penalty_not_set' and ref_id = v_r0));

  -- ── AC5 / Q2: any spare or charge => rework-paid, even when the app claims free ────────────
  perform pg_temp.as_user(v_ops);
  v_res := public.mark_ticket_rework(v_t2, 'Same leak again', v_today);
  perform pg_temp.as_pg();
  v_r2 := (v_res ->> 'rework_ticket_id')::uuid;
  insert into public.service_visits (org_id, ticket_id, technician_id, timer_start, timer_end)
    values (v_org, v_r2, v_tech1, now() - interval '40 minutes', now() - interval '5 minutes') returning id into v_vis;
  perform pg_temp.as_user(v_tp1);
  v_res := public.create_service_invoice(v_org, v_vis, 200, 0, jsonb_build_array(jsonb_build_object('spare_id', v_spare, 'qty', 1)),
    'cash'::payment_method, null, null, false);
  perform pg_temp.as_pg();
  perform pg_temp.chk('AC5 spare + charge on rework -> outcome paid', (select rework_outcome from public.service_tickets where id = v_r2) = 'paid');
  perform pg_temp.chk('AC5 rework-paid invoice charges charge + spare (>= 600 before GST)', (v_res ->> 'total')::numeric >= 600, v_res::text);
  perform pg_temp.chk('AC5 no approval row created for rework-paid', not exists (select 1 from public.approvals where ref_id = v_r2));
  perform pg_temp.chk('AC4 spare stock deducted on rework', (select stock_qty from public.inventory where org_id = v_org and item_id = v_spare and location = 'warehouse') = 9);

  -- ── AC6/P2 count: free counts, paid does not ───────────────────────────────────────────────
  perform pg_temp.chk('count: 1 free rework against technician 1 (paid one excluded)', public.technician_rework_count(v_org, v_tech1, v_today) = 1,
    public.technician_rework_count(v_org, v_tech1, v_today)::text);

  -- ── AC4/AC6 escalation ─────────────────────────────────────────────────────────────────────
  v_err := pg_temp.try_as(v_tp2, format('select public.request_rework_escalation(%L, %L)', v_r0, 'Customer misused the unit'));
  perform pg_temp.chk('escalation: only the responsible technician', v_err like '%only the technician held responsible%', v_err);
  v_err := pg_temp.try_as(v_tp1, format('select public.request_rework_escalation(%L, %L)', v_r0, 'short'));
  perform pg_temp.chk('escalation: reason under 10 chars refused', v_err like '%at least 10 characters%', v_err);
  v_err := pg_temp.try_as(v_tp1, format('select public.request_rework_escalation(%L, %L)', v_r2, 'Different part failed, not mine'));
  perform pg_temp.chk('escalation: rework-paid cannot be escalated', v_err like '%only a completed free rework%', v_err);
  v_err := pg_temp.try_as(v_ops, format('insert into public.approvals (org_id, type, ref_id, requested_by, status) values (%L, %L, %L, %L, %L)', v_org, 'rework', v_r0, v_ops, 'approved'));
  perform pg_temp.chk('escalation: staff cannot insert a pre-approved rework approval directly', v_err like '%row-level security%', v_err);

  perform pg_temp.as_user(v_tp1);
  v_appr := public.request_rework_escalation(v_r0, 'Customer cut the inlet pipe, photos on file');
  perform pg_temp.as_pg();
  perform pg_temp.chk('escalation: pending approval created', exists (select 1 from public.approvals where id = v_appr and type::text = 'rework' and status = 'pending' and ref_id = v_r0));
  perform pg_temp.chk('escalation: master notified', exists (select 1 from public.notifications where org_id = v_org and role = 'master' and type = 'rework_escalation' and ref_id = v_r0));
  v_err := pg_temp.try_as(v_tp1, format('select public.request_rework_escalation(%L, %L)', v_r0, 'Trying a second time here'));
  perform pg_temp.chk('escalation: only once per rework', v_err like '%already escalated%', v_err);
  perform pg_temp.chk('count: pending escalation still counts', public.technician_rework_count(v_org, v_tech1, v_today) = 1);

  perform pg_temp.as_user(v_ops);
  update public.approvals set status = 'approved', approver_id = v_ops where id = v_appr;
  get diagnostics v_cnt = row_count;
  perform pg_temp.as_pg();
  perform pg_temp.chk('escalation: operation_admin cannot decide (RLS, 0 rows)', v_cnt = 0 and (select status from public.approvals where id = v_appr) = 'pending');

  perform pg_temp.as_user(v_master);
  update public.approvals set status = 'approved', approver_id = v_master where id = v_appr;
  perform pg_temp.as_pg();
  perform pg_temp.chk('escalation: master approved', (select status from public.approvals where id = v_appr) = 'approved');
  perform pg_temp.chk('escalation: technician told the outcome',
    exists (select 1 from public.notifications where user_id = v_tp1 and type = 'rework_escalation_decided' and ref_id = v_r0));
  perform pg_temp.chk('count: approved escalation no longer counts', public.technician_rework_count(v_org, v_tech1, v_today) = 0);

  -- ── AC9 report ─────────────────────────────────────────────────────────────────────────────
  perform pg_temp.as_user(v_ops);
  select free_reworks, paid_reworks into v_cnt, v_num from public.report_rework_summary(v_today - 1, v_today) where technician_id = v_tech1;
  perform pg_temp.as_pg();
  perform pg_temp.chk('AC9 report: technician 1 has 1 free + 1 paid rework', v_cnt = 1 and v_num = 1, format('%s/%s', v_cnt, v_num));
  v_err := pg_temp.try_as(v_tp1, format('select * from public.report_rework_summary(%L, %L)', v_today, v_today));
  perform pg_temp.chk('AC9 report refused for technicians', v_err like '%master or operation_admin only%', v_err);

  -- ── grants ─────────────────────────────────────────────────────────────────────────────────
  perform pg_temp.chk('anon has no EXECUTE on mark_ticket_rework', not has_function_privilege('anon', 'public.mark_ticket_rework(uuid,text,date,jsonb,uuid)', 'execute'));
  perform pg_temp.chk('anon has no EXECUTE on request_rework_escalation', not has_function_privilege('anon', 'public.request_rework_escalation(uuid,text)', 'execute'));
  perform pg_temp.chk('anon has no EXECUTE on report_rework_summary', not has_function_privilege('anon', 'public.report_rework_summary(date,date)', 'execute'));
  perform pg_temp.chk('authenticated has no EXECUTE on technician_rework_count', not has_function_privilege('authenticated', 'public.technician_rework_count(uuid,uuid,date)', 'execute'));
  perform pg_temp.chk('authenticated keeps EXECUTE on create_service_invoice', has_function_privilege('authenticated', 'public.create_service_invoice(uuid,uuid,numeric,numeric,jsonb,payment_method,text,text,boolean,numeric,jsonb,boolean)', 'execute'));
  perform pg_temp.chk('anon has no EXECUTE on create_service_invoice', not has_function_privilege('anon', 'public.create_service_invoice(uuid,uuid,numeric,numeric,jsonb,payment_method,text,text,boolean,numeric,jsonb,boolean)', 'execute'));

  -- ── real data untouched ────────────────────────────────────────────────────────────────────
  select md5(coalesce(string_agg(id::text || status::text || coalesce(type::text, ''), ',' order by id), ''))
       || (select count(*)::text from public.approvals where org_id not in (select id from public.organizations where name like '\_\_TEST\_%' escape '\'))
    into fp_after
    from public.service_tickets where org_id not in (select id from public.organizations where name like '\_\_TEST\_%' escape '\');
  perform pg_temp.chk('real tickets + approvals unchanged', fp_before = fp_after);

  raise exception 'RESULTS%', E'\n' || (select string_agg(r.line, E'\n' order by r.n) from pg_temp.res r);
end $t$;
