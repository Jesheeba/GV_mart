-- Rolled-back DB tests for migration 20261016130000_ratings_no_direct_writes (batch-2 item 6, first fix).
-- Run with the migration applied in the same transaction (the runner concatenates it in front). Throwaway __TEST_ org only.
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
  v_org uuid; v_master uuid; v_ops uuid; v_tp1 uuid; v_tp2 uuid; v_tech1 uuid; v_tech2 uuid;
  v_cust uuid; v_t1 uuid; v_vis1 uuid; v_vis2 uuid; v_t2 uuid; v_rating uuid; v_gc boolean; v_stars numeric;
  fp text;
begin
  select md5(coalesce(string_agg(id::text||stars::text||google_review_clicked::text, ',' order by id), '')) into fp from public.ratings
    where org_id not in (select id from organizations where name like '\_\_TEST\_%');

  insert into organizations (name) values ('__TEST_b17_ratingshole') returning id into v_org;
  insert into settings (org_id) values (v_org) on conflict (org_id) do nothing;
  v_master := pg_temp.mkuser('master', v_org);
  v_ops := pg_temp.mkuser('operation_admin', v_org);
  v_tp1 := pg_temp.mkuser('technician', v_org);
  v_tp2 := pg_temp.mkuser('technician', v_org);
  insert into technicians (org_id, profile_id, is_active) values (v_org, v_tp1, true) returning id into v_tech1;
  insert into technicians (org_id, profile_id, is_active) values (v_org, v_tp2, true) returning id into v_tech2;
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ Cust', '9400000031') returning id into v_cust;
  insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (v_org, v_cust, 'paid', 'a') returning id into v_t1;
  insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (v_org, v_cust, 'paid', 'b') returning id into v_t2;
  insert into service_visits (org_id, ticket_id, technician_id) values (v_org, v_t1, v_tech1) returning id into v_vis1;
  insert into service_visits (org_id, ticket_id, technician_id) values (v_org, v_t2, v_tech2) returning id into v_vis2;

  -- grants / policies
  perform pg_temp.chk('no INSERT/UPDATE/DELETE privilege on ratings for anon/authenticated',
    not has_table_privilege('authenticated','public.ratings','insert') and not has_table_privilege('authenticated','public.ratings','update')
    and not has_table_privilege('authenticated','public.ratings','delete') and not has_table_privilege('anon','public.ratings','insert')
    and not has_table_privilege('anon','public.ratings','update'));
  perform pg_temp.chk('no write policy left on ratings',
    not exists (select 1 from pg_policy where polrelid = 'public.ratings'::regclass and polcmd in ('a','w','d','*')));
  perform pg_temp.chk('mark_google_review_clicked is definer and not executable by anon/PUBLIC',
    (select prosecdef from pg_proc where proname = 'mark_google_review_clicked') and not has_function_privilege('anon','public.mark_google_review_clicked(uuid,uuid)','execute')
    and has_function_privilege('authenticated','public.mark_google_review_clicked(uuid,uuid)','execute'));

  -- the RPC path still works
  perform pg_temp.as_user(v_tp1);
  v_rating := public.submit_rating(v_org, v_vis1, 4, 'ok', null);
  perform pg_temp.chk('submit_rating still creates the rating', v_rating is not null);
  perform pg_temp.chk('technician can read own rating', (select count(*) from public.ratings where id = v_rating) = 1);
  perform public.mark_google_review_clicked(v_org, v_vis1);
  perform pg_temp.as_pg();
  select google_review_clicked into v_gc from public.ratings where id = v_rating;
  perform pg_temp.chk('mark_google_review_clicked sets the flag for the owner', v_gc);

  -- direct writes are refused for the technician
  perform pg_temp.as_user(v_tp1);
  begin
    update public.ratings set stars = 5 where id = v_rating;
    perform pg_temp.chk('technician direct UPDATE refused', false);
  exception when insufficient_privilege then
    perform pg_temp.chk('technician direct UPDATE refused', true);
  end;
  begin
    insert into public.ratings (org_id, visit_id, stars, google_review_clicked) values (v_org, v_vis2, 5, true);
    perform pg_temp.chk('technician direct INSERT refused', false);
  exception when insufficient_privilege then
    perform pg_temp.chk('technician direct INSERT refused', true);
  end;
  begin
    delete from public.ratings where id = v_rating;
    perform pg_temp.chk('technician direct DELETE refused', false);
  exception when insufficient_privilege then
    perform pg_temp.chk('technician direct DELETE refused', true);
  end;
  -- ... and for ops staff
  perform pg_temp.as_user(v_ops);
  begin
    update public.ratings set google_review_clicked = true where id = v_rating;
    perform pg_temp.chk('ops direct UPDATE refused', false);
  exception when insufficient_privilege then
    perform pg_temp.chk('ops direct UPDATE refused', true);
  end;
  perform pg_temp.chk('staff can still read ratings', (select count(*) from public.ratings where id = v_rating) = 1);

  -- another technician cannot see or flag it
  perform pg_temp.as_user(v_tp2);
  perform pg_temp.chk('another technician cannot read it', (select count(*) from public.ratings where id = v_rating) = 0);
  begin
    perform public.mark_google_review_clicked(v_org, v_vis1);
    perform pg_temp.chk('another technician cannot flag it', false);
  exception when others then
    perform pg_temp.chk('another technician cannot flag it', sqlerrm like '%no rating found%', sqlerrm);
  end;
  begin
    perform public.mark_google_review_clicked(gen_random_uuid(), v_vis2);
    perform pg_temp.chk('wrong organisation rejected', false);
  exception when others then
    perform pg_temp.chk('wrong organisation rejected', sqlerrm like '%org mismatch%', sqlerrm);
  end;
  perform pg_temp.as_pg();

  -- values unchanged by the refused attempts
  select stars, google_review_clicked into v_stars, v_gc from public.ratings where id = v_rating;
  perform pg_temp.chk('rating untouched by the refused writes', v_stars = 4 and v_gc);
  perform pg_temp.chk('real ratings unchanged', fp = (select md5(coalesce(string_agg(id::text||stars::text||google_review_clicked::text, ',' order by id), '')) from public.ratings
    where org_id not in (select id from organizations where name like '\_\_TEST\_%')));

  raise exception 'RESULTS%', E'\n' || (select string_agg(r.line, E'\n' order by r.n) from pg_temp.res r);
end $t$;
