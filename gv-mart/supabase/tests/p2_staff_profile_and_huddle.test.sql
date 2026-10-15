-- DB tests for 20261102100000_p2_staff_profile_and_huddle. NOT RUN (written for review). Run only through the approved rehearsal
-- wrapper (migration then this file, one request, ends in an unconditional RAISE). Throwaway __TEST_ organisations only.
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

do $t$
declare
  v_org uuid; v_org2 uuid; v_master uuid; v_master_b uuid; v_ops uuid; v_sales uuid; v_cr uuid; v_tp uuid; v_tp_off uuid; v_m2 uuid;
  v_tech uuid; v_tech_off uuid; v_staff uuid; v_issue uuid; v_issue2 uuid; v_meet uuid;
  s text; n int; r record; c1 text; c2 text; m1 text; v_today date := (now() at time zone 'Asia/Kolkata')::date;
begin
  insert into organizations (name) values ('__TEST_p2') returning id into v_org;
  insert into organizations (name) values ('__TEST_p2_other') returning id into v_org2;
  insert into settings (org_id) values (v_org) on conflict (org_id) do nothing;
  v_master := pg_temp.mkuser('master', v_org);
  v_master_b := pg_temp.mkuser('master', v_org);
  v_ops := pg_temp.mkuser('operation_admin', v_org);
  v_sales := pg_temp.mkuser('sales_admin', v_org);
  v_cr := pg_temp.mkuser('customer', v_org);
  v_tp := pg_temp.mkuser('technician', v_org);
  v_tp_off := pg_temp.mkuser('technician', v_org);
  v_m2 := pg_temp.mkuser('master', v_org2);
  insert into technicians (org_id, profile_id, is_active) values (v_org, v_tp, true) returning id into v_tech;
  insert into technicians (org_id, profile_id, is_active) values (v_org, v_tp_off, false) returning id into v_tech_off;

  -- ---------- columns, guard and grants ----------
  perform pg_temp.chk('the five profile columns exist; the flag defaults to false (existing staff are not forced)',
    (select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'profiles'
        and column_name in ('designation', 'address', 'must_change_password', 'password_marker', 'task_color')) = 5
    and (select column_default from information_schema.columns where table_schema = 'public' and table_name = 'profiles' and column_name = 'must_change_password') = 'false'
    and not exists (select 1 from profiles where must_change_password and org_id in (v_org, v_org2)));
  perform pg_temp.chk('functions: complete_forced_password_change, raise_huddle_issue, propose_huddle_solution: authenticated yes, anon and PUBLIC no',
    has_function_privilege('authenticated', 'public.complete_forced_password_change()', 'execute')
    and has_function_privilege('authenticated', 'public.raise_huddle_issue(text)', 'execute')
    and has_function_privilege('authenticated', 'public.propose_huddle_solution(uuid,text)', 'execute')
    and not has_function_privilege('anon', 'public.complete_forced_password_change()', 'execute')
    and not has_function_privilege('anon', 'public.raise_huddle_issue(text)', 'execute')
    and not has_function_privilege('anon', 'public.propose_huddle_solution(uuid,text)', 'execute')
    and not exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.pronamespace = 'public'::regnamespace and a.grantee = 0
                     and p.proname in ('complete_forced_password_change', 'raise_huddle_issue', 'propose_huddle_solution', 'guard_profile_staff_fields',
                                       '_trg_profile_password_marker', '_trg_profile_assign_color', '_hsl_hex', '_trg_meeting_issue_stamp', '_trg_meeting_issue_notify')));
  perform pg_temp.chk('trigger and helper functions are not client-callable',
    not has_function_privilege('authenticated', 'public.guard_profile_staff_fields()', 'execute')
    and not has_function_privilege('authenticated', 'public._trg_meeting_issue_notify()', 'execute')
    and not has_function_privilege('authenticated', 'public._trg_meeting_issue_stamp()', 'execute')
    and not has_function_privilege('authenticated', 'public._hsl_hex(numeric,numeric,numeric)', 'execute'));

  -- ---------- designation, address, colour: master only ----------
  perform pg_temp.as_user(v_master);
  s := pg_temp.raises(format($q$update profiles set designation = 'Sales executive', address = '12 Main Road, Chennai 600001' where id = %L$q$, v_sales));
  perform pg_temp.chk('master can set designation and address', s is null and (select designation from profiles where id = v_sales) = 'Sales executive', coalesce(s, 'ok'));
  s := pg_temp.raises(format($q$update profiles set task_color = '#112233' where id = %L$q$, v_sales));
  perform pg_temp.chk('master can set a colour', s is null and (select task_color from profiles where id = v_sales) = '#112233', coalesce(s, 'ok'));
  s := pg_temp.raises(format($q$update profiles set task_color = 'red' where id = %L$q$, v_sales));
  perform pg_temp.chk('a colour must be #rrggbb', s like '%check constraint%', coalesce(s, 'accepted'));
  perform pg_temp.as_user(v_sales);
  s := pg_temp.raises(format($q$update profiles set designation = 'Director' where id = %L$q$, v_sales));
  perform pg_temp.chk('a non-master cannot change their own designation', s like '%only the master%', coalesce(s, 'accepted'));
  s := pg_temp.raises(format($q$update profiles set address = 'x' where id = %L$q$, v_sales));
  perform pg_temp.chk('a non-master cannot change their own address', s like '%only the master%', coalesce(s, 'accepted'));
  s := pg_temp.raises(format($q$update profiles set task_color = '#000000' where id = %L$q$, v_sales));
  perform pg_temp.chk('a non-master cannot change their own colour', s like '%only the master%', coalesce(s, 'accepted'));
  perform pg_temp.as_pg();

  -- ---------- colours are assigned and distinct ----------
  perform pg_temp.chk('every non-customer profile in the test organisation got a #rrggbb colour; a customer did not',
    not exists (select 1 from profiles where org_id = v_org and role::text <> 'customer' and (task_color is null or task_color !~ '^#[0-9a-f]{6}$'))
    and (select task_color from profiles where id = v_cr) is null);
  select count(*) into n from profiles where org_id = v_org and role::text <> 'customer' and id <> v_sales;
  perform pg_temp.chk('colours are distinct between the people created automatically', n = (select count(distinct task_color) from profiles where org_id = v_org and role::text <> 'customer' and id <> v_sales), n::text);

  -- ---------- forced password change ----------
  perform pg_temp.as_user(v_master);
  s := pg_temp.raises(format($q$update profiles set must_change_password = true where id = %L$q$, v_sales));
  perform pg_temp.chk('a client (even a master) cannot set the forced flag directly', s like '%set by the system%', coalesce(s, 'accepted'));
  perform pg_temp.as_pg();
  v_staff := pg_temp.mkuser('sales_admin', v_org);
  update profiles set must_change_password = true where id = v_staff;     -- as the service role / owner would
  select password_marker into m1 from profiles where id = v_staff;
  perform pg_temp.chk('turning the flag on records a marker of the current password hash', m1 is not null and m1 = md5('x'), coalesce(m1, 'null'));
  perform pg_temp.as_user(v_staff);
  s := pg_temp.raises($q$select public.complete_forced_password_change()$q$);
  perform pg_temp.as_pg();
  perform pg_temp.chk('the flag cannot be cleared before the password actually changed', s like '%not been changed yet%' and (select must_change_password from profiles where id = v_staff), coalesce(s, 'accepted'));
  perform pg_temp.as_user(v_staff);
  s := pg_temp.raises(format($q$update profiles set must_change_password = false where id = %L$q$, v_staff));
  perform pg_temp.as_pg();
  perform pg_temp.chk('and the user cannot clear it by updating their own row', s like '%set by the system%' and (select must_change_password from profiles where id = v_staff), coalesce(s, 'accepted'));
  update auth.users set encrypted_password = 'changed' where id = v_staff;
  perform pg_temp.as_user(v_staff);
  s := pg_temp.raises($q$select public.complete_forced_password_change()$q$);
  perform pg_temp.as_pg();
  perform pg_temp.chk('after the password changed the flag is cleared and the marker removed',
    s is null and not (select must_change_password from profiles where id = v_staff) and (select password_marker from profiles where id = v_staff) is null, coalesce(s, 'ok'));
  -- a reset: flag on again with the marker cleared by the service role -> a new marker for the NEW hash
  update profiles set must_change_password = true, password_marker = null where id = v_staff;
  perform pg_temp.chk('a reset re-arms the flag with a marker of the new hash', (select password_marker from profiles where id = v_staff) = md5('changed'));
  perform pg_temp.as_user(v_cr);
  perform pg_temp.chk('a user with the flag off can call it harmlessly', public.complete_forced_password_change() is true);
  perform pg_temp.as_pg();
  perform pg_temp.as_anon();
  s := pg_temp.raises($q$select public.complete_forced_password_change()$q$);
  perform pg_temp.as_pg();
  perform pg_temp.chk('anon cannot call it', s like '%permission denied%', coalesce(s, 'accepted'));

  -- ---------- huddle: technicians raise, the master is told, names are stamped ----------
  perform pg_temp.as_user(v_tp);
  select public.raise_huddle_issue('  The van GPS keeps dropping off during jobs  ') into v_issue;
  perform pg_temp.as_pg();
  perform pg_temp.chk('a technician can raise a problem; it is attached to today''s meeting log and raised_by is the technician',
    (select raised_by from meeting_issues where id = v_issue) = v_tp
    and (select date_raised from meeting_issues where id = v_issue) = v_today
    and (select description from meeting_issues where id = v_issue) = 'The van GPS keeps dropping off during jobs'
    and exists (select 1 from meeting_logs where org_id = v_org and meeting_date = v_today));
  perform pg_temp.chk('every active master is notified, the raiser is not',
    (select count(*) from notifications where ref_id = v_issue and type = 'huddle_problem_raised' and user_id in (v_master, v_master_b)) = 2
    and not exists (select 1 from notifications where ref_id = v_issue and user_id = v_tp));
  perform pg_temp.as_user(v_tp);
  s := pg_temp.raises(format($q$update meeting_issues set description = 'edited by technician' where id = %L$q$, v_issue));
  perform pg_temp.as_pg();
  perform pg_temp.chk('a technician cannot edit an issue directly (staff-only update policy)', (select description from meeting_issues where id = v_issue) like 'The van GPS%');
  perform pg_temp.as_user(v_tp);
  s := pg_temp.raises(format($q$select public.propose_huddle_solution(%L, 'Re-seat the tracker cable and update the app')$q$, v_issue));
  perform pg_temp.as_pg();
  perform pg_temp.chk('a technician can propose a solution; solution_by is stamped; the issue stays open',
    s is null and (select solution_by from meeting_issues where id = v_issue) = v_tp and (select status from meeting_issues where id = v_issue) = 'open', coalesce(s, 'ok'));
  perform pg_temp.chk('the master is told a solution was given', exists (select 1 from notifications where ref_id = v_issue and type = 'huddle_solution_given' and user_id = v_master));
  perform pg_temp.as_user(v_tp);
  s := pg_temp.raises(format($q$select public.propose_huddle_solution(%L, 'another idea')$q$, v_issue));
  perform pg_temp.as_pg();
  perform pg_temp.chk('a second proposal cannot overwrite the first', s like '%already recorded%', coalesce(s, 'accepted'));
  perform pg_temp.as_user(v_ops);
  update meeting_issues set status = 'solved', date_solved = v_today where id = v_issue;
  perform pg_temp.as_pg();
  perform pg_temp.chk('marking it solved stamps solved_by with the person who did it',
    (select solved_by from meeting_issues where id = v_issue) = v_ops and (select solution_by from meeting_issues where id = v_issue) = v_tp);
  perform pg_temp.chk('the master is told it was solved', exists (select 1 from notifications where ref_id = v_issue and type = 'huddle_issue_solved' and user_id = v_master));
  perform pg_temp.as_user(v_ops);
  update meeting_issues set solved_by = v_master, solution_by = v_master where id = v_issue;
  perform pg_temp.as_pg();
  perform pg_temp.chk('a client cannot forge solved_by or solution_by',
    (select solved_by from meeting_issues where id = v_issue) = v_ops and (select solution_by from meeting_issues where id = v_issue) = v_tp);
  perform pg_temp.as_user(v_ops);
  update meeting_issues set status = 'open', date_solved = null where id = v_issue;
  perform pg_temp.as_pg();
  perform pg_temp.chk('re-opening clears solved_by', (select solved_by from meeting_issues where id = v_issue) is null);

  -- staff direct writes still work and are stamped
  select id into v_meet from meeting_logs where org_id = v_org and meeting_date = v_today;
  perform pg_temp.as_user(v_sales);
  insert into meeting_issues (org_id, meeting_id, description, date_raised, solution) values (v_org, v_meet, 'Printer jam at counter', v_today, 'Replace the roller') returning id into v_issue2;
  perform pg_temp.as_pg();
  perform pg_temp.chk('a staff insert stamps raised_by and solution_by', (select raised_by from meeting_issues where id = v_issue2) = v_sales and (select solution_by from meeting_issues where id = v_issue2) = v_sales);

  -- ---------- who may use the RPCs ----------
  perform pg_temp.as_user(v_tp_off);
  s := pg_temp.raises($q$select public.raise_huddle_issue('should not be allowed')$q$);
  perform pg_temp.chk('an inactive technician cannot raise a problem', s like '%not permitted%', coalesce(s, 'accepted'));
  perform pg_temp.as_user(v_cr);
  s := pg_temp.raises($q$select public.raise_huddle_issue('customer problem')$q$);
  perform pg_temp.chk('a customer cannot raise a problem', s like '%not permitted%', coalesce(s, 'accepted'));
  perform pg_temp.as_user(v_tp);
  s := pg_temp.raises($q$select public.raise_huddle_issue('x')$q$);
  perform pg_temp.chk('a too-short description is refused', s like '%3 to 1000%', coalesce(s, 'accepted'));
  perform pg_temp.as_user(v_m2);
  s := pg_temp.raises(format($q$select public.propose_huddle_solution(%L, 'cross-org attempt')$q$, v_issue2));
  perform pg_temp.as_pg();
  perform pg_temp.chk('another organisation''s user cannot propose on this issue', s like '%not found%' or s like '%not permitted%', coalesce(s, 'accepted'));

  -- ---------- org scope of notifications ----------
  perform pg_temp.chk('no notification reached the other organisation''s master',
    not exists (select 1 from notifications where user_id = v_m2 and type like 'huddle_%'));

  raise exception 'RESULTS%', E'\n' || (select string_agg(r2.line, E'\n' order by r2.n) from pg_temp.res r2);
end $t$;
