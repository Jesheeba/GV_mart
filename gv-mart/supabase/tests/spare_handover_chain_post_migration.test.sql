-- Chained rehearsal test: proves the TRUE apply order (20261113100000 then 20261114100000)
-- leaves technician-facing spare hand-over flows working end to end, and the RLS hole closed.
-- Run only as part of the 20261114100000 rehearsal wrapper's chained rehearsal, AFTER both
-- migrations and both of their own test files have already executed in the same session.
-- Throwaway __TEST_ org only. NOT run against any database by this agent -- this file has
-- never been executed.
--
-- Covers the 2026-10-27 review's item 2(a)-(d):
--   (a) report_spare_handover_discrepancy (the technician dispute/report RPC) still works.
--   (b) confirm_spare_handover still works for the owning technician.
--   (c) the technician app's offline-sync queue calls the SAME RPC as (b) for a hand-over
--       acknowledgement -- see src/lib/offline/sync.ts, case 'spare_handover.confirm':
--       supabase.rpc('confirm_spare_handover', { p_handover_id, p_tech_sign_url,
--       p_admin_sign_url }). There is no separate "offline ack" RPC; the offline queue replays
--       the exact same call confirm_spare_handover's own online path makes (and its sibling
--       case 'spare_handover.report_discrepancy' replays report_spare_handover_discrepancy
--       verbatim -- (a) above already covers that one). So (b) and (c) are, by construction,
--       the same assertion against the same RPC; this file still records it as its own
--       numbered check per the review's wording, rather than silently folding it into (b).
--   (d) a technician's direct INSERT into spare_handovers is still refused with SQLSTATE
--       42501 -- re-confirmed here after BOTH migrations are chained, not just after
--       20261113100000 alone (20261114100000 does not touch RLS on spare_handovers, but this
--       re-proves it rather than assuming so).
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
  v_org uuid; v_ops uuid; v_tp1 uuid; v_tech1 uuid;
  v_cust uuid; v_spare1 uuid; v_handover_id uuid; v_item1_id uuid;
  v_status text; v_tech_sign text; v_received_qty integer; v_notif_count integer;
begin
  insert into public.organizations (name) values ('__TEST_spare_handover_chain') returning id into v_org;
  insert into public.settings (org_id) values (v_org) on conflict (org_id) do nothing;

  v_ops := pg_temp.mkuser('operation_admin', v_org);
  v_tp1 := pg_temp.mkuser('technician', v_org);
  insert into public.technicians (org_id, profile_id, is_active) values (v_org, v_tp1, true) returning id into v_tech1;

  insert into public.customers (org_id, name, mobile) values (v_org, '__TEST_ Cust', '9500000003') returning id into v_cust;
  insert into public.spares (org_id, name, sku, price) values (v_org, '__TEST_ Spare Chain', 'T-SPC1', 75) returning id into v_spare1;
  insert into public.inventory (org_id, item_type, item_id, stock_qty, location) values (v_org, 'spare', v_spare1, 10, 'warehouse');

  perform pg_temp.as_user(v_ops);
  v_handover_id := public.create_spare_handover(v_org, v_tech1, current_date, jsonb_build_array(jsonb_build_object('spare_id', v_spare1, 'qty_given', 4)));
  perform pg_temp.as_pg();
  select id into v_item1_id from public.spare_handover_items where handover_id = v_handover_id and spare_id = v_spare1;
  perform pg_temp.chk('chain: hand-over created after both migrations applied in order', v_handover_id is not null and v_item1_id is not null);

  -- (d) direct technician INSERT is still refused -- re-confirmed after BOTH migrations.
  perform pg_temp.as_user(v_tp1);
  begin
    insert into public.spare_handovers (org_id, technician_id, date, status) values (v_org, v_tech1, current_date, 'pending');
    perform pg_temp.chk('chain (d): technician direct INSERT into spare_handovers still refused (42501) after both migrations', false);
  exception when sqlstate '42501' then
    perform pg_temp.chk('chain (d): technician direct INSERT into spare_handovers still refused (42501) after both migrations', true, sqlerrm);
  end;
  perform pg_temp.as_pg();

  -- (a) report_spare_handover_discrepancy (dispute/report path) still works for a technician.
  perform pg_temp.as_user(v_tp1);
  perform public.report_spare_handover_discrepancy(v_org, v_item1_id, 2, '__TEST_ chain dispute');
  perform pg_temp.as_pg();
  select received_qty into v_received_qty from public.spare_handover_items where id = v_item1_id;
  perform pg_temp.chk('chain (a): report_spare_handover_discrepancy still works for a technician', v_received_qty = 2, v_received_qty::text);
  select count(*) into v_notif_count from public.notifications
    where org_id = v_org and role = 'operation_admin' and type = 'spare_handover_disputed' and ref_id = v_handover_id;
  perform pg_temp.chk('chain (a): staff is still notified of the dispute', v_notif_count = 1, v_notif_count::text);

  -- (b)/(c) confirm_spare_handover -- the exact RPC the offline-sync queue's
  -- 'spare_handover.confirm' case calls (src/lib/offline/sync.ts) -- still works for the
  -- owning technician.
  perform pg_temp.as_user(v_tp1);
  perform public.confirm_spare_handover(v_handover_id, 'data:image/png;base64,__TEST_chain_tech_sig', 'data:image/png;base64,__TEST_chain_admin_sig');
  perform pg_temp.as_pg();
  select status, tech_sign_url into v_status, v_tech_sign from public.spare_handovers where id = v_handover_id;
  perform pg_temp.chk('chain (b)/(c): confirm_spare_handover (offline-sync''s hand-over-ack RPC) still works for the owning technician', v_status = 'confirmed' and v_tech_sign is not null, coalesce(v_status, '<null>'));

  raise exception 'RESULTS%', E'\n' || (select string_agg(r.line, E'\n' order by r.n) from pg_temp.res r);
end $t$;
