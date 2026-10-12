-- Rolled-back DB tests for migration 20261016160000_rental_generator_scheduling (rental generator fix).
-- Run with the migration applied in the same transaction. One transaction ending in RAISE; throwaway __TEST_ org only.
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
  v_org uuid; v_master uuid; v_tp1 uuid; v_tech1 uuid; v_cust uuid; v_addr uuid; v_brand uuid; v_model uuid; v_prod uuid; v_plan uuid;
  v_start date; v_r jsonb; v_contract uuid; v_vticket uuid; v_vis uuid; v_ws time; v_we time; v_first date; v_rec record;
  v_next_ticket uuid; v_nd date; fp text;
begin
  select md5(coalesce(string_agg(id::text||status::text||coalesce(next_service_date::text,''), ',' order by id), '')) into fp from public.rental_contracts
    where org_id not in (select id from organizations where name like '\_\_TEST\_%');

  insert into organizations (name) values ('__TEST_b17_rental') returning id into v_org;
  insert into settings (org_id, work_start, work_end, late_cutoff) values (v_org, '10:30', '18:15', '10:45') on conflict (org_id) do update set work_start = '10:30', work_end = '18:15', late_cutoff = '10:45';
  select work_start, work_end into v_ws, v_we from settings where org_id = v_org;
  v_master := pg_temp.mkuser('master', v_org);
  v_tp1 := pg_temp.mkuser('technician', v_org);
  insert into technicians (org_id, profile_id, is_active) values (v_org, v_tp1, true) returning id into v_tech1;
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ Renter', '9400000061') returning id into v_cust;
  insert into addresses (org_id, customer_id, address_type, is_primary) values (v_org, v_cust, 'residential', true) returning id into v_addr;
  insert into brands (org_id, name, category) values (v_org, '__TEST_ brand', 'ro') returning id into v_brand;
  insert into models (org_id, brand_id, name) values (v_org, v_brand, '__TEST_ model') returning id into v_model;
  insert into products (org_id, name, category, brand_id, model_id, price) values (v_org, '__TEST_ RO rent', 'ro', v_brand, v_model, 10000) returning id into v_prod;
  insert into inventory (org_id, item_type, item_id, stock_qty, location) values (v_org, 'product', v_prod, 5, 'warehouse');
  -- 7 visits a year: the old integer division gave 1 month, the corrected rounding gives 2
  insert into rental_plans (org_id, name, visits_per_year, yearly_rate, duration_years) values (v_org, '__TEST_ plan', 7, 12000, 1) returning id into v_plan;

  -- pick a start date whose +2 months lands on a non-working day, when the default week has one
  v_start := current_date + 3;
  for i in 1..200 loop
    if not public._lead_is_working_day(v_org, (current_date + i + interval '2 months')::date) then v_start := current_date + i; exit; end if;
  end loop;

  perform pg_temp.as_user(v_master);
  v_r := public.create_rental(v_org, v_cust, v_prod, v_plan, v_addr, v_start, 'cash', null, null);
  perform pg_temp.as_pg();
  v_contract := (v_r ->> 'contract_id')::uuid;
  select t.id into v_vticket from service_tickets t where t.rental_contract_id = v_contract and t.type::text = 'rental';
  select a.* into v_rec from appointments a where a.ticket_id = v_vticket;
  v_first := (v_rec.scheduled_at at time zone 'Asia/Kolkata')::date;

  perform pg_temp.chk('first visit starts at the master working-hours start, not 09:00',
    (v_rec.scheduled_at at time zone 'Asia/Kolkata')::time = v_ws, ((v_rec.scheduled_at at time zone 'Asia/Kolkata')::time)::text || ' vs ' || v_ws::text);
  perform pg_temp.chk('the working window is carried', v_rec.available_from = v_ws and v_rec.available_to = v_we);
  perform pg_temp.chk('first visit is 2 months out (7 visits/year rounds to 2, not integer-divided 1)',
    v_first >= (v_start + interval '2 months')::date and v_first <= (v_start + interval '2 months')::date + 7, v_first::text || ' for start ' || v_start::text);
  perform pg_temp.chk('visit date is a working day', public._lead_is_working_day(v_org, v_first));
  perform pg_temp.chk('contract next_service_date equals the visit date', (select next_service_date from rental_contracts where id = v_contract) = v_first);
  perform pg_temp.chk('installation ticket still created', exists (select 1 from service_tickets where invoice_id = (v_r ->> 'invoice_id')::uuid and type::text = 'installation'));
  perform pg_temp.chk('assigned visit SLA is counted from the visit time, never already breached',
    not exists (select 1 from service_tickets t join appointments a on a.ticket_id = t.id where t.id = v_vticket and a.technician_id is not null and t.sla_due_at <= a.scheduled_at));

  -- completing the rental visit schedules the next one with the same rules
  insert into service_visits (org_id, ticket_id, technician_id, timer_start, timer_end) values (v_org, v_vticket, v_tech1, now() - interval '2 hours', now() - interval '1 hour') returning id into v_vis;
  insert into appointments (org_id, ticket_id, mode, technician_id, status) values (v_org, v_vticket, 'always', v_tech1, 'in_progress')
    on conflict do nothing;
  perform pg_temp.as_user(v_tp1);
  perform public.create_service_invoice(v_org, v_vis, 0, 0, '[]'::jsonb, 'cash', null, null, false, 0, '[]'::jsonb);
  perform pg_temp.as_pg();
  select t.id into v_next_ticket from service_tickets t where t.rental_contract_id = v_contract and t.type::text = 'rental' and t.id <> v_vticket;
  select a.* into v_rec from appointments a where a.ticket_id = v_next_ticket;
  v_nd := (v_rec.scheduled_at at time zone 'Asia/Kolkata')::date;
  perform pg_temp.chk('next visit is created', v_next_ticket is not null);
  perform pg_temp.chk('next visit: working-hours start, window, working day, 2 months from today',
    (v_rec.scheduled_at at time zone 'Asia/Kolkata')::time = v_ws and v_rec.available_from = v_ws and v_rec.available_to = v_we
    and public._lead_is_working_day(v_org, v_nd)
    and v_nd >= ((now() at time zone 'Asia/Kolkata')::date + interval '2 months')::date and v_nd <= ((now() at time zone 'Asia/Kolkata')::date + interval '2 months')::date + 7,
    v_nd::text);
  perform pg_temp.chk('contract next_service_date follows', (select next_service_date from rental_contracts where id = v_contract) = v_nd);

  perform pg_temp.chk('real rental contracts unchanged', fp = (select md5(coalesce(string_agg(id::text||status::text||coalesce(next_service_date::text,''), ',' order by id), '')) from public.rental_contracts
    where org_id not in (select id from organizations where name like '\_\_TEST\_%')));

  raise exception 'RESULTS%', E'\n' || (select string_agg(r.line, E'\n' order by r.n) from pg_temp.res r);
end $t$;
