-- Rolled-back DB tests for 20261027100000_followup_questions.
-- NOT RUN (written for review). Run only through the rehearsal wrapper the owner approves: the wrapper applies the migration and
-- then this file in ONE request; this file ends in an unconditional RAISE, so nothing is committed. Throwaway __TEST_
-- organisations only; nothing is sent; no real customer, ticket or number is touched.
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
create function pg_temp.as_anon() returns void language plpgsql as $f$
begin perform set_config('request.jwt.claims', '', true); execute 'set local role anon'; end $f$;
create function pg_temp.as_pg() returns void language plpgsql as $f$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $f$;
create function pg_temp.raises(p_sql text) returns text language plpgsql as $f$
begin execute p_sql; return null;
exception when others then return sqlerrm; end $f$;
-- a completed paid/amc ticket gives a post-service follow-up through the real trigger
create function pg_temp.ticket(p_org uuid, p_cust uuid, p_type text) returns uuid language plpgsql as $f$
declare t uuid; f uuid;
begin
  insert into public.service_tickets (org_id, customer_id, type, name_of_complaint) values (p_org, p_cust, p_type::public.ticket_type, '__TEST_ complaint') returning id into t;
  update public.service_tickets set status = 'completed' where id = t;
  select id into f from public.lead_followups where ticket_id = t;
  return f;
end $f$;

do $t$
declare
  v_org uuid; v_org2 uuid; v_master uuid; v_master2 uuid; v_sales uuid; v_ops uuid; v_custrole uuid;
  v_c1 uuid; v_c_test uuid;
  q_yn uuid; q_rate uuid; q_txt uuid; q_ch uuid; q_req uuid; q_amc uuid; q_other uuid;
  o_sat uuid; o_issue uuid; o_retry uuid; o_later uuid; o_noneed uuid;
  f1 uuid; f2 uuid; f3 uuid; f4 uuid; f5 uuid; f6 uuid; f7 uuid; f_amc uuid;
  r jsonb; s text; n int; rec record; v_due timestamptz := now() + interval '3 days'; v_call uuid;
  v_ratings_before int; v_ratings_after int; v_reviews_before int;
begin
  -- ---------- schema, seeds, grants ----------
  perform pg_temp.chk('the three new tables exist with RLS on',
    (select count(*) from pg_class c where c.relnamespace = 'public'::regnamespace and c.relrowsecurity
       and c.relname in ('followup_questions', 'followup_question_ticket_types', 'post_service_call_answers')) = 3);
  perform pg_temp.chk('post_service_calls.followup_needed is a nullable boolean',
    (select data_type || '/' || is_nullable from information_schema.columns
      where table_schema = 'public' and table_name = 'post_service_calls' and column_name = 'followup_needed') = 'boolean/YES');
  perform pg_temp.chk('anon has no privilege on the new tables; authenticated cannot write answers or delete questions',
    not exists (select 1 from unnest(array['followup_questions', 'followup_question_ticket_types', 'post_service_call_answers']) t,
                     unnest(array['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE']) pr where has_table_privilege('anon', 'public.' || t, pr))
    and not has_table_privilege('authenticated', 'public.post_service_call_answers', 'INSERT')
    and not has_table_privilege('authenticated', 'public.post_service_call_answers', 'UPDATE')
    and not has_table_privilege('authenticated', 'public.post_service_call_answers', 'DELETE')
    and not has_table_privilege('authenticated', 'public.followup_questions', 'DELETE')
    and has_table_privilege('authenticated', 'public.post_service_call_answers', 'SELECT'));
  perform pg_temp.chk('functions: the old 4-argument log_post_service_call is gone, the 6-argument one exists, one of each',
    to_regprocedure('public.log_post_service_call(uuid,uuid,text,timestamptz)') is null
    and to_regprocedure('public.log_post_service_call(uuid,uuid,text,timestamptz,jsonb,boolean)') is not null
    and (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname = 'log_post_service_call') = 1);
  perform pg_temp.chk('log_post_service_call grants: authenticated and service_role yes, anon and PUBLIC no',
    has_function_privilege('authenticated', 'public.log_post_service_call(uuid,uuid,text,timestamptz,jsonb,boolean)', 'execute')
    and has_function_privilege('service_role', 'public.log_post_service_call(uuid,uuid,text,timestamptz,jsonb,boolean)', 'execute')
    and not has_function_privilege('anon', 'public.log_post_service_call(uuid,uuid,text,timestamptz,jsonb,boolean)', 'execute')
    and not exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                     where p.pronamespace = 'public'::regnamespace and a.grantee = 0
                       and p.proname in ('log_post_service_call', 'get_post_service_questions', 'report_followup_question_answers',
                                         '_post_service_questions_for', 'seed_followup_questions', 'trg_seed_followup_questions',
                                         '_trg_followup_question_guard')));
  perform pg_temp.chk('read functions: authenticated yes, anon no; internal helpers not callable by clients',
    has_function_privilege('authenticated', 'public.get_post_service_questions(uuid)', 'execute')
    and has_function_privilege('authenticated', 'public.report_followup_question_answers(date,date)', 'execute')
    and not has_function_privilege('anon', 'public.get_post_service_questions(uuid)', 'execute')
    and not has_function_privilege('anon', 'public.report_followup_question_answers(date,date)', 'execute')
    and not has_function_privilege('authenticated', 'public._post_service_questions_for(uuid,text)', 'execute')
    and not has_function_privilege('authenticated', 'public.seed_followup_questions(uuid)', 'execute')
    and not has_function_privilege('authenticated', 'public._trg_followup_question_guard()', 'execute'));
  perform pg_temp.chk('definer functions have a fixed search_path',
    not exists (select 1 from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prosecdef
                 and p.proname in ('log_post_service_call', 'get_post_service_questions', 'report_followup_question_answers',
                                   '_post_service_questions_for', 'seed_followup_questions', 'trg_seed_followup_questions', '_trg_followup_question_guard')
                 and not coalesce(p.proconfig::text like '%search_path=%', false)));
  perform pg_temp.chk('no foreign key from the new tables to ratings or any review table',
    not exists (select 1 from pg_constraint c where c.contype = 'f'
                 and c.conrelid in ('public.followup_questions'::regclass, 'public.followup_question_ticket_types'::regclass, 'public.post_service_call_answers'::regclass)
                 and c.confrelid = 'public.ratings'::regclass));
  perform pg_temp.chk('every pre-existing organisation was seeded with 6 inactive example questions',
    not exists (select 1 from organizations o where o.name not like '\_\_TEST\_%'
                 and (select count(*) from public.followup_questions q where q.org_id = o.id and not q.is_active and q.scope = 'post_service') <> 6));

  insert into organizations (name) values ('__TEST_followupq') returning id into v_org;
  insert into organizations (name) values ('__TEST_followupq_other') returning id into v_org2;
  insert into settings (org_id) values (v_org) on conflict (org_id) do nothing;
  insert into settings (org_id) values (v_org2) on conflict (org_id) do nothing;
  v_master := pg_temp.mkuser('master', v_org);
  v_master2 := pg_temp.mkuser('master', v_org2);
  v_sales := pg_temp.mkuser('sales_admin', v_org);
  v_ops := pg_temp.mkuser('operation_admin', v_org);
  v_custrole := pg_temp.mkuser('customer', v_org);
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ c1', '9400000091') returning id into v_c1;
  insert into customers (org_id, name, mobile, is_test) values (v_org, '__TEST_ flagged', '9400000092', true) returning id into v_c_test;
  update settings set post_service_followup_enabled = true, post_service_ticket_types = array['paid', 'warranty', 'amc'] where org_id = v_org;
  select id into o_sat from post_service_outcomes where org_id = v_org and code = 'satisfied';
  select id into o_issue from post_service_outcomes where org_id = v_org and code = 'issue_remaining';
  select id into o_retry from post_service_outcomes where org_id = v_org and code = 'not_reachable';
  select id into o_later from post_service_outcomes where org_id = v_org and code = 'call_later';
  select id into o_noneed from post_service_outcomes where org_id = v_org and code = 'no_answer_needed';

  perform pg_temp.chk('new organisation: 6 example questions, all inactive, scope post_service, Tamil blank, none required',
    (select count(*) from followup_questions where org_id = v_org) = 6
    and not exists (select 1 from followup_questions where org_id = v_org and (is_active or is_required or scope is distinct from 'post_service' or text_ta <> '')));
  perform pg_temp.chk('seed types: 4 yes/no, 1 rating, 1 free text',
    (select count(*) from followup_questions where org_id = v_org and answer_type = 'yes_no') = 4
    and (select count(*) from followup_questions where org_id = v_org and answer_type = 'rating') = 1
    and (select count(*) from followup_questions where org_id = v_org and answer_type = 'text') = 1);

  -- ---------- RLS and master-only writes ----------
  perform pg_temp.as_user(v_sales);
  select count(*) into n from followup_questions;
  perform pg_temp.chk('sales_admin can read the questions of its own organisation only', n = 6, n::text);
  s := pg_temp.raises(format($q$insert into followup_questions (org_id, text_en, answer_type) values (%L, 'x', 'yes_no')$q$, v_org));
  perform pg_temp.chk('sales_admin cannot write questions', s is not null, coalesce(s, 'accepted'));
  perform pg_temp.as_user(v_custrole);
  select count(*) into n from followup_questions;
  perform pg_temp.chk('a customer-role user sees no questions', n = 0, n::text);
  perform pg_temp.as_user(v_master2);
  select count(*) into n from followup_questions where org_id = v_org;
  perform pg_temp.chk('another organisation''s master cannot see these questions', n = 0, n::text);
  perform pg_temp.as_anon();
  s := pg_temp.raises('select count(*) from public.followup_questions');
  perform pg_temp.chk('anon is refused', s like '%permission denied%', coalesce(s, 'accepted'));

  perform pg_temp.as_user(v_master);
  insert into followup_questions (org_id, text_en, answer_type, is_required, sort_order) values (v_org, 'Working?', 'yes_no', false, 10) returning id into q_yn;
  insert into followup_questions (org_id, text_en, answer_type, sort_order) values (v_org, 'Rate', 'rating', 11) returning id into q_rate;
  insert into followup_questions (org_id, text_en, answer_type, sort_order) values (v_org, 'Comments', 'text', 12) returning id into q_txt;
  insert into followup_questions (org_id, text_en, answer_type, choices, sort_order)
    values (v_org, 'Which day suits?', 'choice', '[{"value":"am","label_en":"Morning"},{"value":"pm","label_en":"Afternoon","label_ta":""}]'::jsonb, 13) returning id into q_ch;
  insert into followup_questions (org_id, text_en, answer_type, is_required, sort_order) values (v_org, 'Must answer', 'yes_no', true, 14) returning id into q_req;
  perform pg_temp.chk('master can create questions of all four types', q_yn is not null and q_rate is not null and q_txt is not null and q_ch is not null and q_req is not null);
  s := pg_temp.raises(format($q$delete from followup_questions where id = %L$q$, q_yn));
  perform pg_temp.chk('a question cannot be deleted (soft delete only)', s is not null, coalesce(s, 'deleted'));
  s := pg_temp.raises(format($q$update followup_questions set answer_type = 'text' where id = %L$q$, q_yn));
  perform pg_temp.chk('answer_type is fixed after creation', s like '%answer_type cannot be changed%', coalesce(s, 'accepted'));
  s := pg_temp.raises(format($q$insert into followup_questions (org_id, text_en, answer_type, choices) values (%L, 'c', 'choice', '[{"value":"a","label_en":"A"}]'::jsonb)$q$, v_org));
  perform pg_temp.chk('a choice question needs at least two choices', s is not null, coalesce(s, 'accepted'));
  s := pg_temp.raises(format($q$insert into followup_questions (org_id, text_en, answer_type, choices) values (%L, 'c', 'choice', '[{"value":"a","label_en":"A"},{"value":"a","label_en":"B"}]'::jsonb)$q$, v_org));
  perform pg_temp.chk('choice values must be unique', s like '%unique%', coalesce(s, 'accepted'));
  s := pg_temp.raises(format($q$insert into followup_questions (org_id, text_en, answer_type, choices) values (%L, 'c', 'yes_no', '[]'::jsonb)$q$, v_org));
  perform pg_temp.chk('a non-choice question cannot carry choices', s is not null, coalesce(s, 'accepted'));
  update followup_questions set is_active = true where id in (q_yn, q_rate, q_txt, q_ch, q_req);
  perform pg_temp.chk('master can activate questions', (select count(*) from followup_questions where org_id = v_org and is_active) = 5);
  perform pg_temp.as_pg();
  perform pg_temp.chk('question edits are audited', exists (select 1 from audit_log where org_id = v_org and table_name = 'followup_questions'));

  -- ---------- which questions a call shows ----------
  f1 := pg_temp.ticket(v_org, v_c1, 'paid');
  perform pg_temp.as_user(v_sales);
  select count(*) into n from get_post_service_questions(f1);
  perform pg_temp.chk('an empty link table means all ticket types: the 5 active questions are offered', n = 5, n::text);
  perform pg_temp.as_pg();
  insert into followup_questions (org_id, text_en, answer_type, sort_order) values (v_org, 'AMC only', 'yes_no', 20) returning id into q_amc;
  insert into followup_question_ticket_types (org_id, question_id, ticket_type) values (v_org, q_amc, 'amc');
  f_amc := pg_temp.ticket(v_org, v_c1, 'amc');
  perform pg_temp.as_user(v_sales);
  select count(*) into n from get_post_service_questions(f1);
  perform pg_temp.chk('a question restricted to amc is NOT offered on a paid ticket', n = 5 and not exists (select 1 from get_post_service_questions(f1) where id = q_amc), n::text);
  select count(*) into n from get_post_service_questions(f_amc);
  perform pg_temp.chk('and IS offered on an amc ticket', n = 6 and exists (select 1 from get_post_service_questions(f_amc) where id = q_amc), n::text);
  perform pg_temp.as_pg();
  update followup_questions set scope = 'lead_call' where id = q_txt;
  perform pg_temp.as_user(v_sales);
  perform pg_temp.chk('a question with another scope is not offered on a post-service call',
    not exists (select 1 from get_post_service_questions(f1) where id = q_txt));
  perform pg_temp.as_pg();
  update followup_questions set scope = null where id = q_txt;
  perform pg_temp.as_user(v_sales);
  perform pg_temp.chk('a NULL scope is treated as post_service', exists (select 1 from get_post_service_questions(f1) where id = q_txt));
  perform pg_temp.as_pg();
  update followup_questions set is_active = false where id = q_amc;
  perform pg_temp.as_user(v_ops);
  s := pg_temp.raises(format($q$select * from get_post_service_questions(%L)$q$, f1));
  perform pg_temp.chk('operation_admin cannot fetch the call-sheet questions (sheet is for sales staff)', s like '%not permitted%', coalesce(s, 'accepted'));
  perform pg_temp.as_pg();

  -- ---------- backward compatibility: no answers, behaves as before ----------
  select count(*) into v_ratings_before from public.ratings where org_id = v_org;
  select count(*) into v_reviews_before from public.ratings where org_id = v_org and google_review_clicked;
  f2 := pg_temp.ticket(v_org, v_c1, 'paid');
  update followup_questions set is_required = false where id = q_req;
  perform pg_temp.as_user(v_sales);
  r := public.log_post_service_call(f2, o_sat);
  perform pg_temp.as_pg();
  perform pg_temp.chk('4-argument style call (positional two arguments) works and closes the follow-up',
    r ->> 'status' = 'done' and (r ->> 'answers_saved')::int = 0
    and (select status::text from lead_followups where id = f2) = 'done'
    and (select count(*) from post_service_calls where followup_id = f2) = 1
    and (select followup_needed from post_service_calls where followup_id = f2) is null);
  perform pg_temp.chk('no answer rows were written', (select count(*) from post_service_call_answers where ticket_id = (select ticket_id from lead_followups where id = f2)) = 0);

  -- ---------- answers: saved in one transaction with the call ----------
  update followup_questions set is_required = true where id = q_req;
  f3 := pg_temp.ticket(v_org, v_c1, 'paid');
  perform pg_temp.as_user(v_sales);
  r := public.log_post_service_call(f3, o_sat, 'all fine', null,
         jsonb_build_array(jsonb_build_object('question_id', q_yn, 'value', true),
                           jsonb_build_object('question_id', q_rate, 'value', 5),
                           jsonb_build_object('question_id', q_txt, 'value', '  Good work  '),
                           jsonb_build_object('question_id', q_ch, 'value', 'pm'),
                           jsonb_build_object('question_id', q_req, 'value', false)));
  perform pg_temp.as_pg();
  v_call := (r ->> 'call_id')::uuid;
  perform pg_temp.chk('five answers saved against the call, the ticket, the customer and the org',
    (r ->> 'answers_saved')::int = 5
    and (select count(*) from post_service_call_answers where call_id = v_call and org_id = v_org and customer_id = v_c1
          and ticket_id = (select ticket_id from lead_followups where id = f3)) = 5);
  perform pg_temp.chk('typed value columns: yes/no bool, rating int, text trimmed, choice code',
    (select answer_bool from post_service_call_answers where call_id = v_call and question_id = q_yn) is true
    and (select answer_int from post_service_call_answers where call_id = v_call and question_id = q_rate) = 5
    and (select answer_text from post_service_call_answers where call_id = v_call and question_id = q_txt) = 'Good work'
    and (select answer_text from post_service_call_answers where call_id = v_call and question_id = q_ch) = 'pm');
  perform pg_temp.chk('snapshot of question text, type and choices stored with the answer',
    (select question_text_en || '/' || answer_type from post_service_call_answers where call_id = v_call and question_id = q_ch) = 'Which day suits?/choice'
    and (select jsonb_array_length(question_choices) from post_service_call_answers where call_id = v_call and question_id = q_ch) = 2);
  -- a later edit of the question does not rewrite history
  update followup_questions set text_en = 'Which day suits you best?', is_active = false where id = q_ch;
  perform pg_temp.chk('editing or deactivating a question leaves the stored snapshot unchanged',
    (select question_text_en from post_service_call_answers where call_id = v_call and question_id = q_ch) = 'Which day suits?');
  update followup_questions set is_active = true where id = q_ch;
  perform pg_temp.chk('the unique index (call_id, question_id) exists',
    exists (select 1 from pg_indexes where tablename = 'post_service_call_answers' and indexdef like '%UNIQUE%' and indexdef like '%(call_id, question_id)%'));
  s := pg_temp.raises(format($q$insert into post_service_call_answers (org_id, call_id, question_id, ticket_id, question_text_en, answer_type, answer_bool)
        values (%L, %L, %L, (select ticket_id from post_service_calls where id = %L), 'dup', 'yes_no', true)$q$, v_org, v_call, q_yn, v_call));
  perform pg_temp.chk('a second answer for the same question on the same call is rejected', s like '%duplicate key%', coalesce(s, 'accepted'));
  s := pg_temp.raises(format($q$insert into post_service_call_answers (org_id, call_id, question_id, ticket_id, question_text_en, answer_type, answer_int)
        values (%L, %L, %L, (select ticket_id from post_service_calls where id = %L), 'bad', 'yes_no', 3)$q$, v_org, v_call, q_req, v_call));
  perform pg_temp.chk('the table itself rejects a value that does not match the snapshot type', s like '%value_matches_type%', coalesce(s, 'accepted'));

  -- ---------- the rating question never touches the Google-review flow ----------
  select count(*) into v_ratings_after from public.ratings where org_id = v_org;
  perform pg_temp.chk('ratings table untouched by a call with a rating answer', v_ratings_after = v_ratings_before and
    (select count(*) from public.ratings where org_id = v_org and google_review_clicked) = v_reviews_before);

  -- ---------- validation ----------
  f4 := pg_temp.ticket(v_org, v_c1, 'paid');
  perform pg_temp.as_user(v_sales);
  s := pg_temp.raises(format($q$select public.log_post_service_call(%L, %L, null, null, %L::jsonb)$q$, f4, o_sat,
        jsonb_build_array(jsonb_build_object('question_id', q_yn, 'value', 'yes'), jsonb_build_object('question_id', q_req, 'value', true))::text));
  perform pg_temp.chk('a yes/no question answered with a string is rejected (type mismatch)', s like '%type mismatch%', coalesce(s, 'accepted'));
  s := pg_temp.raises(format($q$select public.log_post_service_call(%L, %L, null, null, %L::jsonb)$q$, f4, o_sat,
        jsonb_build_array(jsonb_build_object('question_id', q_rate, 'value', 6), jsonb_build_object('question_id', q_req, 'value', true))::text));
  perform pg_temp.chk('a rating of 6 is rejected', s like '%1 to 5%', coalesce(s, 'accepted'));
  s := pg_temp.raises(format($q$select public.log_post_service_call(%L, %L, null, null, %L::jsonb)$q$, f4, o_sat,
        jsonb_build_array(jsonb_build_object('question_id', q_ch, 'value', 'evening'), jsonb_build_object('question_id', q_req, 'value', true))::text));
  perform pg_temp.chk('a value that is not one of the choices is rejected', s like '%not one of the choices%', coalesce(s, 'accepted'));
  s := pg_temp.raises(format($q$select public.log_post_service_call(%L, %L, null, null, %L::jsonb)$q$, f4, o_sat,
        jsonb_build_array(jsonb_build_object('question_id', q_req, 'value', true), jsonb_build_object('question_id', q_req, 'value', false))::text));
  perform pg_temp.chk('the same question twice is rejected', s like '%twice%', coalesce(s, 'accepted'));
  s := pg_temp.raises(format($q$select public.log_post_service_call(%L, %L, null, null, %L::jsonb)$q$, f4, o_sat,
        jsonb_build_array(jsonb_build_object('question_id', gen_random_uuid(), 'value', true), jsonb_build_object('question_id', q_req, 'value', true))::text));
  perform pg_temp.chk('an unknown question id is rejected', s like '%not active or does not apply%', coalesce(s, 'accepted'));
  s := pg_temp.raises(format($q$select public.log_post_service_call(%L, %L, null, null, %L::jsonb)$q$, f4, o_sat,
        jsonb_build_array(jsonb_build_object('question_id', q_amc, 'value', true), jsonb_build_object('question_id', q_req, 'value', true))::text));
  perform pg_temp.chk('an inactive (or non-applicable) question id is rejected', s like '%not active or does not apply%', coalesce(s, 'accepted'));
  s := pg_temp.raises(format($q$select public.log_post_service_call(%L, %L, null, null, '{"a":1}'::jsonb)$q$, f4, o_sat));
  perform pg_temp.chk('answers that are not a list are rejected', s like '%must be a list%', coalesce(s, 'accepted'));
  perform pg_temp.as_pg();
  perform pg_temp.chk('every rejection left no call row and the follow-up still open (one transaction)',
    (select count(*) from post_service_calls where followup_id = f4) = 0 and (select status::text from lead_followups where id = f4) = 'open');

  -- ---------- required questions: enforced server-side ----------
  f5 := pg_temp.ticket(v_org, v_c1, 'paid');
  perform pg_temp.as_user(v_sales);
  s := pg_temp.raises(format($q$select public.log_post_service_call(%L, %L)$q$, f4, o_sat));
  perform pg_temp.chk('a required question with no answer is refused', s like '%an answer is required: Must answer%', coalesce(s, 'accepted'));
  s := pg_temp.raises(format($q$select public.log_post_service_call(%L, %L, null, null, %L::jsonb)$q$, f4, o_sat,
        jsonb_build_array(jsonb_build_object('question_id', q_req, 'value', null))::text));
  perform pg_temp.chk('a null value counts as no answer', s like '%an answer is required%', coalesce(s, 'accepted'));
  r := public.log_post_service_call(f4, o_noneed);
  perform pg_temp.chk('outcome no_answer_needed does not require answers', r ->> 'status' = 'done', r::text);
  r := public.log_post_service_call(f5, o_retry, null, v_due);
  perform pg_temp.chk('outcome not_reachable does not require answers and keeps the follow-up open',
    r ->> 'status' = 'open' and (select due_at from lead_followups where id = f5) = v_due, r::text);
  perform pg_temp.as_pg();
  perform pg_temp.chk('a required-answers refusal for sales still allows the call to be logged once answered',
    exists (select 1 from post_service_calls where followup_id = f5));

  -- ---------- follow-up needed and retry: one task, never two ----------
  f6 := pg_temp.ticket(v_org, v_c1, 'paid');
  update followup_questions set is_required = false where id = q_req;
  perform pg_temp.as_user(v_sales);
  s := pg_temp.raises(format($q$select public.log_post_service_call(%L, %L, null, null, null, true)$q$, f6, o_sat));
  perform pg_temp.chk('follow-up needed = true without a new date is refused', s is not null, coalesce(s, 'accepted'));
  r := public.log_post_service_call(f6, o_sat, 'needs a visit', v_due, null, true);
  perform pg_temp.as_pg();
  perform pg_temp.chk('follow-up needed = true keeps the SAME follow-up open at the new date; the call stores true',
    r ->> 'status' = 'open' and (r ->> 'followup_needed')::boolean is true
    and (select status::text || '/' || due_at::text from lead_followups where id = f6) = 'open/' || v_due::text
    and (select followup_needed from post_service_calls where followup_id = f6) is true
    and (select reschedule_reason from lead_followups where id = f6) = 'Follow-up needed');
  perform pg_temp.chk('still exactly one follow-up row for that ticket',
    (select count(*) from lead_followups where ticket_id = (select ticket_id from lead_followups where id = f6)) = 1);
  f7 := pg_temp.ticket(v_org, v_c1, 'paid');
  perform pg_temp.as_user(v_sales);
  r := public.log_post_service_call(f7, o_sat, null, null, null, false);
  perform pg_temp.as_pg();
  perform pg_temp.chk('follow-up needed = false closes the task and stores false',
    r ->> 'status' = 'done' and (select followup_needed from post_service_calls where followup_id = f7) is false);
  -- a retry outcome with followup_needed = true is still ONE reschedule, and the stored column is NULL
  f1 := pg_temp.ticket(v_org, v_c1, 'paid');
  perform pg_temp.as_user(v_sales);
  r := public.log_post_service_call(f1, o_later, null, v_due, null, true);
  perform pg_temp.as_pg();
  perform pg_temp.chk('retry outcome plus follow-up needed: one reschedule, one follow-up row, column stored NULL',
    r ->> 'status' = 'open' and (select count(*) from lead_followups where ticket_id = (select ticket_id from lead_followups where id = f1)) = 1
    and (select followup_needed from post_service_calls where followup_id = f1) is null);

  -- ---------- alert outcome unchanged ----------
  f2 := pg_temp.ticket(v_org, v_c1, 'paid');
  perform pg_temp.as_user(v_sales);
  r := public.log_post_service_call(f2, o_issue, 'still leaking');
  perform pg_temp.as_pg();
  perform pg_temp.chk('an alert outcome still notifies master and operations', (r ->> 'alerted')::boolean
    and exists (select 1 from notifications where org_id = v_org and type = 'post_service_issue' and user_id = v_master));

  -- ---------- answers are not writable by clients ----------
  perform pg_temp.as_user(v_master);
  s := pg_temp.raises(format($q$insert into post_service_call_answers (org_id, call_id, question_id, ticket_id, question_text_en, answer_type, answer_bool)
        values (%L, %L, %L, (select ticket_id from post_service_calls where id = %L), 'x', 'yes_no', true)$q$, v_org, v_call, q_yn, v_call));
  perform pg_temp.chk('even a master cannot insert an answer directly', s like '%permission denied%', coalesce(s, 'accepted'));
  s := pg_temp.raises(format($q$update post_service_call_answers set answer_bool = false where call_id = %L$q$, v_call));
  perform pg_temp.chk('even a master cannot edit an answer directly', s like '%permission denied%', coalesce(s, 'accepted'));
  s := pg_temp.raises(format($q$delete from post_service_call_answers where call_id = %L$q$, v_call));
  perform pg_temp.chk('even a master cannot delete an answer directly', s like '%permission denied%', coalesce(s, 'accepted'));
  perform pg_temp.as_pg();

  -- ---------- readers ----------
  perform pg_temp.as_user(v_ops);
  select count(*) into n from post_service_call_answers where customer_id = v_c1;
  perform pg_temp.chk('operation_admin can read answers (customer and ticket cards)', n >= 5, n::text);
  perform pg_temp.as_user(v_custrole);
  select count(*) into n from post_service_call_answers;
  perform pg_temp.chk('a customer-role user cannot read answers', n = 0, n::text);
  perform pg_temp.as_user(v_master2);
  select count(*) into n from post_service_call_answers where org_id = v_org;
  perform pg_temp.chk('another organisation cannot read these answers', n = 0, n::text);
  perform pg_temp.as_pg();

  -- ---------- report ----------
  -- one answer from a flagged test customer must be left out
  update followup_questions set is_required = false where id = q_req;
  f3 := pg_temp.ticket(v_org, v_c_test, 'paid');
  perform pg_temp.as_user(v_sales);
  perform public.log_post_service_call(f3, o_sat, null, null, jsonb_build_array(jsonb_build_object('question_id', q_rate, 'value', 1)));
  perform pg_temp.as_user(v_master);
  select * into rec from report_followup_question_answers(current_date - 1, current_date + 1) where question_id = q_rate;
  perform pg_temp.chk('report: rating question has 1 real answer (the test customer''s is excluded), average 5.00',
    rec.answers = 1 and rec.rating_avg = 5.00 and (rec.rating_counts ->> '5')::int = 1 and (rec.rating_counts ->> '1')::int = 0,
    coalesce(rec.answers::text, 'no row') || '/' || coalesce(rec.rating_avg::text, '-'));
  select * into rec from report_followup_question_answers(current_date - 1, current_date + 1) where question_id = q_yn;
  perform pg_temp.chk('report: yes/no counts', rec.yes_count = 1 and rec.no_count = 0, coalesce(rec.yes_count::text, 'no row'));
  select * into rec from report_followup_question_answers(current_date - 1, current_date + 1) where question_id = q_ch;
  perform pg_temp.chk('report: choice counts use the stored codes', (rec.choice_counts ->> 'pm')::int = 1, coalesce(rec.choice_counts::text, 'no row'));
  select * into rec from report_followup_question_answers(current_date - 1, current_date + 1) where question_id = q_txt;
  perform pg_temp.chk('report: free-text questions report a count, never the text', rec.text_count = 1 and rec.choice_counts is null);
  select count(*) into n from report_followup_question_answers(current_date + 5, current_date + 6);
  perform pg_temp.chk('report: an empty range returns no rows', n = 0, n::text);
  s := pg_temp.raises($q$select * from report_followup_question_answers(current_date, current_date - 1)$q$);
  perform pg_temp.chk('report: reversed range refused', s like '%invalid date range%', coalesce(s, 'accepted'));
  s := pg_temp.raises($q$select * from report_followup_question_answers(current_date - 400, current_date)$q$);
  perform pg_temp.chk('report: range over 366 days refused', s like '%limited to 366%', coalesce(s, 'accepted'));
  perform pg_temp.as_user(v_sales);
  s := pg_temp.raises($q$select * from report_followup_question_answers(current_date - 1, current_date)$q$);
  perform pg_temp.chk('report: master only (sales_admin refused)', s like '%only the master%', coalesce(s, 'accepted'));
  perform pg_temp.as_user(v_master2);
  select count(*) into n from report_followup_question_answers(current_date - 1, current_date + 1);
  perform pg_temp.chk('report: another organisation''s master sees nothing of this organisation', n = 0, n::text);
  perform pg_temp.as_anon();
  s := pg_temp.raises($q$select * from public.report_followup_question_answers(current_date - 1, current_date)$q$);
  perform pg_temp.chk('report: anon refused', s like '%permission denied%', coalesce(s, 'accepted'));
  perform pg_temp.as_pg();

  -- ---------- a new organisation gets the seeds; nothing real is changed ----------
  perform pg_temp.chk('the second throwaway organisation was seeded too',
    (select count(*) from followup_questions where org_id = v_org2) = 6);
  perform pg_temp.chk('wa_dispatch_v2_enabled untouched; nothing queued to the outbox',
    not coalesce((select wa_dispatch_v2_enabled from settings where org_id = v_org), false)
    and not exists (select 1 from whatsapp_outbox where org_id = v_org));

  raise exception 'RESULTS%', E'\n' || (select string_agg(r2.line, E'\n' order by r2.n) from pg_temp.res r2);
end $t$;
