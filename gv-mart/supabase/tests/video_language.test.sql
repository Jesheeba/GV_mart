-- Rolled-back DB tests for migration 20261023100000_video_language. NOT RUN (the migration is not applied).
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
  v_brand uuid; v_model uuid;
  v_org uuid; v_org2 uuid; v_master uuid; v_sales uuid; v_spare uuid; v_prod uuid; v_v uuid;
  v_rows_pv int; v_rows_vl int; n int; v_ok boolean;
begin
  select count(*) into v_rows_pv from public.product_videos where org_id not in (select id from organizations where name like '\_\_TEST\_%');
  select count(*) into v_rows_vl from public.video_library where org_id not in (select id from organizations where name like '\_\_TEST\_%');

  insert into organizations (name) values ('__TEST_videolang_a') returning id into v_org;
  insert into organizations (name) values ('__TEST_videolang_b') returning id into v_org2;
  insert into settings (org_id) values (v_org) on conflict (org_id) do nothing;
  v_master := pg_temp.mkuser('master', v_org);
  v_sales := pg_temp.mkuser('sales_admin', v_org);
  insert into spares (org_id, name, price) values (v_org, '__TEST_ spare', 10) returning id into v_spare;
  insert into brands (org_id, name, category) values (v_org, '__TEST_ brand', 'ro') returning id into v_brand;
  insert into models (org_id, brand_id, name) values (v_org, v_brand, '__TEST_ model') returning id into v_model;
  insert into products (org_id, brand_id, model_id, name, category, price) values (v_org, v_brand, v_model, '__TEST_ product', 'ro', 100) returning id into v_prod;

  -- language is nullable and defaults to NULL on all three tables (existing behaviour preserved)
  insert into product_videos (org_id, product_id, url) values (v_org, v_prod, 'https://youtu.be/a') returning id into v_v;
  perform pg_temp.chk('product_videos language defaults to NULL', (select language is null from product_videos where id = v_v));
  insert into video_library (org_id, topic, url) values (v_org, 'price', 'https://youtu.be/b');
  perform pg_temp.chk('video_library language defaults to NULL', (select language is null from video_library where org_id = v_org and url = 'https://youtu.be/b'));
  insert into spare_videos (org_id, spare_id, url) values (v_org, v_spare, 'https://youtu.be/c') returning id into v_v;
  perform pg_temp.chk('spare_videos language defaults to NULL, is_active true', (select language is null and is_active from spare_videos where id = v_v));

  -- only en / ta accepted
  update product_videos set language = 'ta' where org_id = v_org;
  update spare_videos set language = 'en' where org_id = v_org;
  perform pg_temp.chk('en and ta are accepted', (select count(*) = 1 from product_videos where org_id = v_org and language = 'ta')
    and (select count(*) = 1 from spare_videos where org_id = v_org and language = 'en'));
  v_ok := false;
  begin update product_videos set language = 'fr' where org_id = v_org; exception when check_violation then v_ok := true; end;
  perform pg_temp.chk('product_videos rejects an unknown language', v_ok);
  v_ok := false;
  begin update spare_videos set language = 'hi' where org_id = v_org; exception when check_violation then v_ok := true; end;
  perform pg_temp.chk('spare_videos rejects an unknown language', v_ok);
  v_ok := false;
  begin update video_library set language = 'EN' where org_id = v_org; exception when check_violation then v_ok := true; end;
  perform pg_temp.chk('video_library rejects a wrong-case language', v_ok);

  -- RLS: master writes, sales_admin reads, other org sees nothing, anon has no table privilege
  perform pg_temp.as_user(v_master);
  insert into spare_videos (org_id, spare_id, url, language) values (v_org, v_spare, 'https://youtu.be/d', 'ta');
  perform pg_temp.chk('master can write spare_videos', true);
  perform pg_temp.as_user(v_sales);
  select count(*) into n from spare_videos;
  perform pg_temp.chk('sales_admin can read the org spare_videos', n = 2, n::text);
  v_ok := false;
  begin insert into spare_videos (org_id, spare_id, url) values (v_org, v_spare, 'https://youtu.be/e'); exception when others then v_ok := true; end;
  perform pg_temp.chk('sales_admin cannot write spare_videos', v_ok);
  perform pg_temp.as_pg();
  perform pg_temp.chk('anon has no privilege on spare_videos', not has_table_privilege('anon', 'public.spare_videos', 'select'));

  -- a video row from another org cannot be inserted by this org's master
  perform pg_temp.as_user(v_master);
  v_ok := false;
  begin insert into spare_videos (org_id, spare_id, url) values (v_org2, v_spare, 'https://youtu.be/f'); exception when others then v_ok := true; end;
  perform pg_temp.chk('master cannot write another org''s spare_videos', v_ok);
  perform pg_temp.as_pg();

  -- cascade: deleting the spare removes its videos
  delete from spare_videos where org_id = v_org and url = 'https://youtu.be/d';
  delete from spares where id = v_spare;
  perform pg_temp.chk('deleting a spare removes its videos', (select count(*) = 0 from spare_videos where org_id = v_org));

  perform pg_temp.chk('real product_videos and video_library rows unchanged',
    v_rows_pv = (select count(*) from public.product_videos where org_id not in (select id from organizations where name like '\_\_TEST\_%'))
    and v_rows_vl = (select count(*) from public.video_library where org_id not in (select id from organizations where name like '\_\_TEST\_%')));

  raise exception 'RESULTS%', E'\n' || (select string_agg(r.line, E'\n' order by r.n) from pg_temp.res r);
end $t$;
