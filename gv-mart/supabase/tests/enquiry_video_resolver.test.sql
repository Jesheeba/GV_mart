-- DB tests for 20261028100000_enquiry_video_resolver. NOT RUN (written for review).
-- Run only through the rehearsal wrapper the owner approves: it executes the migration and then this file in ONE request, and
-- this file ends in an unconditional RAISE, so nothing is committed. Throwaway __TEST_ organisations only; nothing is sent.
create temp table res (n serial, line text);
grant all on res to public;
grant usage on sequence res_n_seq to public;
create function pg_temp.chk(p_name text, p_ok boolean, p_info text default '') returns void language plpgsql as $f$
begin insert into pg_temp.res(line) values (case when coalesce(p_ok,false) then 'PASS  ' else 'FAIL  ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end); end $f$;

do $t$
declare
  v_org uuid; v_org2 uuid; v_brand uuid; v_model uuid; v_brand2 uuid; v_model2 uuid;
  p1 uuid; p2 uuid; p3 uuid; p4 uuid; p_other uuid; s1 uuid; s2 uuid; s_other uuid;
  v_ta uuid; v_en uuid; v_neu uuid; v_off uuid; v_c1 uuid; v_c2 uuid;
  l_prod uuid; l_spare uuid; l_none uuid; l_other uuid;
  r record; n1 int; n2 int; n3 int; n4 int; n5 int; n6 int; n7 int; n8 int;
begin
  insert into organizations (name) values ('__TEST_videoresolver_a') returning id into v_org;
  insert into organizations (name) values ('__TEST_videoresolver_b') returning id into v_org2;
  insert into brands (org_id, name, category) values (v_org, '__TEST_ brand', 'ro') returning id into v_brand;
  insert into models (org_id, brand_id, name) values (v_org, v_brand, '__TEST_ model') returning id into v_model;
  insert into brands (org_id, name, category) values (v_org2, '__TEST_ brand b', 'ro') returning id into v_brand2;
  insert into models (org_id, brand_id, name) values (v_org2, v_brand2, '__TEST_ model b') returning id into v_model2;

  -- p1: messy name, several videos; p2: no videos; p3: only a Tamil video; p4: unusable links only
  insert into products (org_id, brand_id, model_id, name, category, price)
    values (v_org, v_brand, v_model, E'  __TEST_  RO\tPurifier\n  Model   X  ', 'ro', 100) returning id into p1;
  insert into products (org_id, brand_id, model_id, name, category, price) values (v_org, v_brand, v_model, '__TEST_ no video', 'ro', 100) returning id into p2;
  insert into products (org_id, brand_id, model_id, name, category, price) values (v_org, v_brand, v_model, '__TEST_ tamil only', 'ro', 100) returning id into p3;
  insert into products (org_id, brand_id, model_id, name, category, price) values (v_org, v_brand, v_model, '__TEST_ bad links', 'ro', 100) returning id into p4;
  insert into products (org_id, brand_id, model_id, name, category, price) values (v_org2, v_brand2, v_model2, '__TEST_ other org', 'ro', 100) returning id into p_other;
  insert into spares (org_id, name, price) values (v_org, '__TEST_ spare with video', 10) returning id into s1;
  insert into spares (org_id, name, price) values (v_org, '__TEST_ spare no video', 10) returning id into s2;
  insert into spares (org_id, name, price) values (v_org2, '__TEST_ spare other org', 10) returning id into s_other;

  insert into product_videos (org_id, product_id, url, language, sort_order, is_active) values (v_org, p1, 'https://youtu.be/off1', 'ta', 0, false) returning id into v_off;
  insert into product_videos (org_id, product_id, url, language, sort_order) values (v_org, p1, 'https://youtu.be/neutral', null, 1) returning id into v_neu;
  insert into product_videos (org_id, product_id, url, language, sort_order) values (v_org, p1, 'https://youtu.be/ta2', 'ta', 2) returning id into v_ta;
  insert into product_videos (org_id, product_id, url, language, sort_order) values (v_org, p1, 'https://youtu.be/en3', 'en', 3) returning id into v_en;
  insert into product_videos (org_id, product_id, url, language, sort_order) values (v_org, p3, 'https://youtu.be/only-ta', 'ta', 1);
  insert into product_videos (org_id, product_id, url, language, sort_order) values (v_org2, p_other, 'https://youtu.be/other-org', null, 1);
  insert into spare_videos (org_id, spare_id, url, language, sort_order) values (v_org, s1, 'https://youtu.be/spare', null, 1);

  -- ---------- language order ----------
  select * into r from public._automation_enquiry_video(v_org, p1, null, 'ta');
  perform pg_temp.chk('Tamil customer: the active Tamil video wins (inactive one ignored)',
    r.ok and r.video_id = v_ta and r.video_language = 'ta' and not r.language_fallback and r.video_source = 'product_videos', coalesce(r.video_url, r.reason));
  select * into r from public._automation_enquiry_video(v_org, p1, null, 'en');
  perform pg_temp.chk('English customer: the English video wins over the language-neutral one', r.ok and r.video_id = v_en and not r.language_fallback, coalesce(r.video_url, r.reason));
  update product_videos set is_active = false where id = v_ta;
  select * into r from public._automation_enquiry_video(v_org, p1, null, 'ta');
  perform pg_temp.chk('no Tamil video: the language-neutral one is used and the caller is told it was a fallback',
    r.ok and r.video_id = v_neu and r.video_language is null and r.language_fallback, coalesce(r.video_url, r.reason));
  update product_videos set is_active = false where id = v_neu;
  select * into r from public._automation_enquiry_video(v_org, p1, null, 'ta');
  perform pg_temp.chk('no Tamil and no neutral video: English is used (never skipped for a missing Tamil video)',
    r.ok and r.video_id = v_en and r.language_fallback, coalesce(r.video_url, r.reason));
  update product_videos set is_active = false where id = v_en;
  select * into r from public._automation_enquiry_video(v_org, p1, null, 'ta');
  perform pg_temp.chk('no active video at all: ok = false, reason no_video', not r.ok and r.reason = 'no_video' and r.video_url is null, coalesce(r.reason, '-'));
  update product_videos set is_active = true where id in (v_ta, v_neu, v_en);

  select * into r from public._automation_enquiry_video(v_org, p1, null, 'hi');
  perform pg_temp.chk('an unknown language behaves as English', r.ok and r.video_id = v_en, coalesce(r.video_url, r.reason));
  select * into r from public._automation_enquiry_video(v_org, p1, null, null);
  perform pg_temp.chk('a NULL language behaves as English', r.ok and r.video_id = v_en, coalesce(r.video_url, r.reason));
  select * into r from public._automation_enquiry_video(v_org, p3, null, 'en');
  perform pg_temp.chk('an English customer is never sent a Tamil-only video', not r.ok and r.reason = 'no_video', coalesce(r.video_url, r.reason));
  select * into r from public._automation_enquiry_video(v_org, p3, null, 'ta');
  perform pg_temp.chk('a Tamil customer with a Tamil-only video gets it', r.ok and r.video_language = 'ta' and not r.language_fallback, coalesce(r.video_url, r.reason));

  -- ---------- order within a language, ties ----------
  insert into product_videos (org_id, product_id, url, language, sort_order, created_at) values (v_org, p2, 'https://youtu.be/second', 'en', 5, now());
  insert into product_videos (org_id, product_id, url, language, sort_order, created_at) values (v_org, p2, 'https://youtu.be/first', 'en', 5, now() - interval '1 day');
  select * into r from public._automation_enquiry_video(v_org, p2, null, 'en');
  perform pg_temp.chk('same language and sort_order: the older row wins (deterministic)', r.ok and r.video_url = 'https://youtu.be/first', coalesce(r.video_url, r.reason));
  insert into product_videos (org_id, product_id, url, language, sort_order) values (v_org, p2, 'https://youtu.be/lower-sort', 'en', 1);
  select * into r from public._automation_enquiry_video(v_org, p2, null, 'en');
  perform pg_temp.chk('lower sort_order wins inside a language', r.ok and r.video_url = 'https://youtu.be/lower-sort', coalesce(r.video_url, r.reason));
  delete from product_videos where product_id = p2;

  -- ---------- link rules ----------
  insert into product_videos (org_id, product_id, url, language, sort_order) values (v_org, p4, 'http://youtu.be/not-https', null, 1);
  select * into r from public._automation_enquiry_video(v_org, p4, null, 'en');
  perform pg_temp.chk('an http link is not used: reason url_unusable (not no_video)', not r.ok and r.reason = 'url_unusable', coalesce(r.reason, '-'));
  update product_videos set url = 'https://youtu.be/has space' where product_id = p4;
  select * into r from public._automation_enquiry_video(v_org, p4, null, 'en');
  perform pg_temp.chk('a link with whitespace inside is not used', not r.ok and r.reason = 'url_unusable', coalesce(r.reason, '-'));
  update product_videos set url = 'https://youtu.be/' || repeat('a', 61 - length('https://youtu.be/')) where product_id = p4;
  select * into r from public._automation_enquiry_video(v_org, p4, null, 'en');
  perform pg_temp.chk('a 61-character link is too long', not r.ok and r.reason = 'url_unusable', coalesce(r.reason, '-'));
  update product_videos set url = 'https://youtu.be/' || repeat('a', 60 - length('https://youtu.be/')) where product_id = p4;
  select * into r from public._automation_enquiry_video(v_org, p4, null, 'en');
  perform pg_temp.chk('a 60-character link is accepted', r.ok and char_length(r.video_url) = 60, coalesce(r.reason, '-'));
  update product_videos set url = '   https://youtu.be/padded   ' where product_id = p4;
  select * into r from public._automation_enquiry_video(v_org, p4, null, 'en');
  perform pg_temp.chk('surrounding spaces are trimmed', r.ok and r.video_url = 'https://youtu.be/padded', coalesce(r.video_url, r.reason));
  insert into product_videos (org_id, product_id, url, language, sort_order) values (v_org, p4, 'http://youtu.be/bad-but-first', null, 0);
  select * into r from public._automation_enquiry_video(v_org, p4, null, 'en');
  perform pg_temp.chk('an unusable link ahead of a good one is skipped, the good one is used', r.ok and r.video_url = 'https://youtu.be/padded', coalesce(r.video_url, r.reason));
  select * into r from public._automation_enquiry_video(v_org, p4, null, 'en', 20);
  perform pg_temp.chk('the maximum length is a parameter (20 characters makes this link unusable)', not r.ok and r.reason = 'url_unusable', coalesce(r.reason, '-'));

  -- ---------- item selection and org scope ----------
  select * into r from public._automation_enquiry_video(v_org, null, s1, 'en');
  perform pg_temp.chk('a spare uses spare_videos', r.ok and r.video_source = 'spare_videos' and r.item_kind = 'spare' and r.item_id = s1, coalesce(r.video_url, r.reason));
  select * into r from public._automation_enquiry_video(v_org, null, s2, 'en');
  perform pg_temp.chk('a spare without a video: no_video', not r.ok and r.reason = 'no_video' and r.item_kind = 'spare', coalesce(r.reason, '-'));
  select * into r from public._automation_enquiry_video(v_org, p1, s1, 'en');
  perform pg_temp.chk('product and spare both given: the product wins', r.ok and r.item_kind = 'product' and r.item_id = p1);
  select * into r from public._automation_enquiry_video(v_org, null, null, 'en');
  perform pg_temp.chk('no item: no_item', not r.ok and r.reason = 'no_item');
  select * into r from public._automation_enquiry_video(v_org, gen_random_uuid(), null, 'en');
  perform pg_temp.chk('unknown product id: item_not_found', not r.ok and r.reason = 'item_not_found');
  select * into r from public._automation_enquiry_video(v_org, p_other, null, 'en');
  perform pg_temp.chk('another organisation''s product is never read: item_not_found', not r.ok and r.reason = 'item_not_found' and r.video_url is null);
  select * into r from public._automation_enquiry_video(v_org2, p1, null, 'en');
  perform pg_temp.chk('and this organisation''s product is not readable as the other organisation', not r.ok and r.reason = 'item_not_found');
  select * into r from public._automation_enquiry_video(v_org, p1, null, 'en');
  perform pg_temp.chk('item name is cleaned: control characters and runs of spaces collapsed, trimmed',
    r.item_name = '__TEST_ RO Purifier Model X', coalesce(r.item_name, '-'));
  update products set name = repeat('word ', 30) where id = p1;
  select * into r from public._automation_enquiry_video(v_org, p1, null, 'en');
  perform pg_temp.chk('item name is at most 60 characters', char_length(r.item_name) <= 60 and char_length(r.item_name) > 40, char_length(r.item_name)::text);

  -- decision 2: the topic video library is never a fallback
  insert into video_library (org_id, topic, url) values (v_org, 'price', 'https://youtu.be/topic-fallback');
  select * into r from public._automation_enquiry_video(v_org, p2, null, 'en');
  perform pg_temp.chk('an item with no video is NOT given a topic video from video_library', not r.ok and r.reason = 'no_video' and r.video_url is null);

  -- ---------- from a lead ----------
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ c1', '9400000094') returning id into v_c1;
  insert into customers (org_id, name, mobile) values (v_org2, '__TEST_ c2', '9400000095') returning id into v_c2;
  insert into leads (org_id, customer_id, name, mobile, source, status, kind, product_id, qty) values (v_org, v_c1, '__TEST_ L product', '9400000094', 'customer_app', 'new', 'product', p1, 1) returning id into l_prod;
  insert into leads (org_id, customer_id, name, mobile, source, status, kind, spare_id) values (v_org, v_c1, '__TEST_ L spare', '9400000094', 'customer_app', 'new', 'spare', s1) returning id into l_spare;
  insert into leads (org_id, customer_id, name, mobile, source, status, kind) values (v_org, v_c1, '__TEST_ L none', '9400000094', 'walk_in', 'new', 'service') returning id into l_none;
  insert into leads (org_id, customer_id, name, mobile, source, status, kind, product_id) values (v_org2, v_c2, '__TEST_ L other', '9400000095', 'customer_app', 'new', 'product', p_other) returning id into l_other;
  select * into r from public._automation_lead_enquiry_video(v_org, l_prod, null, 'ta');
  perform pg_temp.chk('lead with a product: that product''s video', r.ok and r.item_kind = 'product' and r.item_id = p1, coalesce(r.video_url, r.reason));
  select * into r from public._automation_lead_enquiry_video(v_org, l_spare, null, 'en');
  perform pg_temp.chk('lead with a spare: that spare''s video', r.ok and r.item_kind = 'spare' and r.item_id = s1, coalesce(r.video_url, r.reason));
  select * into r from public._automation_lead_enquiry_video(v_org, l_none, null, 'en');
  perform pg_temp.chk('lead with no item: no_item', not r.ok and r.reason = 'no_item');
  select * into r from public._automation_lead_enquiry_video(v_org, l_prod, s1::text, 'en');
  perform pg_temp.chk('an item_key (enquiry.item_added) overrides the lead''s own first item', r.ok and r.item_kind = 'spare' and r.item_id = s1, coalesce(r.video_url, r.reason));
  select * into r from public._automation_lead_enquiry_video(v_org, l_prod, p3::text, 'ta');
  perform pg_temp.chk('an item_key naming a product works the same way', r.ok and r.item_id = p3, coalesce(r.video_url, r.reason));
  select * into r from public._automation_lead_enquiry_video(v_org, l_prod, 'not-a-uuid', 'en');
  perform pg_temp.chk('a malformed item_key: item_not_found', not r.ok and r.reason = 'item_not_found');
  select * into r from public._automation_lead_enquiry_video(v_org, l_prod, p_other::text, 'en');
  perform pg_temp.chk('an item_key of another organisation: item_not_found', not r.ok and r.reason = 'item_not_found');
  select * into r from public._automation_lead_enquiry_video(v_org, l_other, null, 'en');
  perform pg_temp.chk('a lead of another organisation: lead_not_found', not r.ok and r.reason = 'lead_not_found');
  select * into r from public._automation_lead_enquiry_video(v_org, gen_random_uuid(), null, 'en');
  perform pg_temp.chk('an unknown lead: lead_not_found', not r.ok and r.reason = 'lead_not_found');
  select * into r from public._automation_lead_enquiry_video(v_org, l_prod, '   ', 'en');
  perform pg_temp.chk('a blank item_key is ignored (lead item used)', r.ok and r.item_id = p1);

  -- ---------- grants, volatility, no writes ----------
  perform pg_temp.chk('both functions are STABLE, SECURITY DEFINER with a fixed search_path',
    (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname in ('_automation_enquiry_video', '_automation_lead_enquiry_video')
        and provolatile = 's' and prosecdef and coalesce(proconfig::text like '%search_path=%', false)) = 2);
  perform pg_temp.chk('EXECUTE: service_role yes; anon, authenticated and PUBLIC no',
    has_function_privilege('service_role', 'public._automation_enquiry_video(uuid,uuid,uuid,text,integer)', 'execute')
    and has_function_privilege('service_role', 'public._automation_lead_enquiry_video(uuid,uuid,text,text,integer)', 'execute')
    and not has_function_privilege('anon', 'public._automation_enquiry_video(uuid,uuid,uuid,text,integer)', 'execute')
    and not has_function_privilege('authenticated', 'public._automation_enquiry_video(uuid,uuid,uuid,text,integer)', 'execute')
    and not has_function_privilege('anon', 'public._automation_lead_enquiry_video(uuid,uuid,text,text,integer)', 'execute')
    and not has_function_privilege('authenticated', 'public._automation_lead_enquiry_video(uuid,uuid,text,text,integer)', 'execute')
    and not exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.pronamespace = 'public'::regnamespace and a.grantee = 0
                     and p.proname in ('_automation_enquiry_video', '_automation_lead_enquiry_video')));
  select count(*) into n1 from product_videos; select count(*) into n2 from spare_videos; select count(*) into n3 from video_library;
  select count(*) into n4 from audit_log; select count(*) into n5 from automation_queue; select count(*) into n6 from automation_audit;
  select count(*) into n7 from notifications; select count(*) into n8 from whatsapp_outbox;
  perform public._automation_lead_enquiry_video(v_org, l_prod, null, 'ta');
  perform public._automation_enquiry_video(v_org, p3, null, 'ta');
  perform pg_temp.chk('the resolver writes nothing (videos, audit, queue, notifications, outbox unchanged)',
    n1 = (select count(*) from product_videos) and n2 = (select count(*) from spare_videos) and n3 = (select count(*) from video_library)
    and n4 = (select count(*) from audit_log) and n5 = (select count(*) from automation_queue) and n6 = (select count(*) from automation_audit)
    and n7 = (select count(*) from notifications) and n8 = (select count(*) from whatsapp_outbox));
  perform pg_temp.chk('no new table, trigger or column came with this migration',
    not exists (select 1 from pg_class c where c.relnamespace = 'public'::regnamespace and c.relname ilike '%enquiry_video%'));

  raise exception 'RESULTS%', E'\n' || (select string_agg(r2.line, E'\n' order by r2.n) from pg_temp.res r2);
end $t$;
