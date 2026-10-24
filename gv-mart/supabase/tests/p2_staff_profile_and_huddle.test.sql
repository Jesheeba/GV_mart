-- DB tests for 20261102100000_p2_staff_profile_and_huddle. NOT RUN (written for review). Run only through the approved rehearsal
-- wrapper (migration then this file, one request, ends in an unconditional RAISE). Throwaway __TEST_ organisations only.
-- The last check compares a fingerprint of the REAL organisations taken by the wrapper BEFORE the migration with the same
-- fingerprint now (relative, not absolute counts).
create temp table res (n serial, line text);
grant all on res to public;
grant usage on sequence res_n_seq to public;
-- 20261024100000 (applied live) runs `alter default privileges for role postgres revoke execute on functions from public`, globally. That also
-- removes PUBLIC execute from the helper functions below, which live in pg_temp and are called after `set local role authenticated`. This default
-- makes every function created here executable again, including helpers added later. (pg_temp is not a name ALTER DEFAULT PRIVILEGES accepts, so
-- the session's real temporary schema is looked up. The setting is rolled back with the wrapper, and disappears with the session otherwise.)
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
create function pg_temp.as_anon() returns void language plpgsql as $f$
begin perform set_config('request.jwt.claims', '', true); execute 'set local role anon'; end $f$;
create function pg_temp.as_pg() returns void language plpgsql as $f$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $f$;
create function pg_temp.raises(p_sql text) returns text language plpgsql as $f$
begin execute p_sql; return null;
exception when others then return sqlerrm; end $f$;

do $t$
declare
  v_org uuid; v_org2 uuid; v_master uuid; v_master_b uuid; v_ops uuid; v_sales uuid; v_cr uuid; v_tp uuid; v_tp2 uuid; v_tp_off uuid; v_m2 uuid;
  v_staff uuid; v_issue uuid; v_issue2 uuid; v_meet uuid; v_log uuid; v_tech uuid;
  s text; n int; m1 text; v_today date := (now() at time zone 'Asia/Kolkata')::date; v_base text; v_now text; k int;
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
  v_tp2 := pg_temp.mkuser('technician', v_org);
  v_tp_off := pg_temp.mkuser('technician', v_org);
  v_m2 := pg_temp.mkuser('master', v_org2);
  insert into technicians (org_id, profile_id, is_active) values (v_org, v_tp, true) returning id into v_tech;
  insert into technicians (org_id, profile_id, is_active) values (v_org, v_tp2, true);
  insert into technicians (org_id, profile_id, is_active) values (v_org, v_tp_off, false);

  -- ---------- structure, grants ----------
  perform pg_temp.chk('profiles gained designation, must_change_password, task_color; there is NO address and NO marker column on profiles',
    (select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'profiles'
        and column_name in ('designation', 'must_change_password', 'task_color')) = 3
    and not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'profiles'
        and column_name in ('address', 'password_marker'))
    and (select column_default from information_schema.columns where table_schema = 'public' and table_name = 'profiles' and column_name = 'must_change_password') = 'false');
  perform pg_temp.chk('no real-organisation account was forced by the migration',
    not exists (select 1 from profiles where must_change_password and org_id not in (select id from organizations where name like '\_\_TEST\_%')));
  perform pg_temp.chk('the marker table has RLS on, NO policy, and no API role holds a privilege on it',
    exists (select 1 from pg_class c where c.relnamespace = 'public'::regnamespace and c.relname = 'profile_password_markers' and c.relrowsecurity)
    and not exists (select 1 from pg_policy p where p.polrelid = 'public.profile_password_markers'::regclass)
    and not exists (select 1 from unnest(array['anon', 'authenticated', 'service_role']) r, unnest(array['SELECT', 'INSERT', 'UPDATE', 'DELETE']) pr
                     where has_table_privilege(r, 'public.profile_password_markers', pr)));
  perform pg_temp.chk('the marker functions use an empty search_path',
    (select count(*) from pg_proc where pronamespace = 'public'::regnamespace
        and proname in ('_trg_profile_password_marker', 'arm_forced_password_change', 'complete_forced_password_change')
        and prosecdef and coalesce(proconfig @> array['search_path=""'], false)) = 3);
  perform pg_temp.chk('_trg_meeting_issue_stamp is SECURITY INVOKER (it tests current_user, which is the owner inside a definer function)',
    (select not prosecdef from pg_proc where pronamespace = 'public'::regnamespace and proname = '_trg_meeting_issue_stamp'));
  perform pg_temp.chk('functions: complete_forced_password_change, raise_huddle_issue, propose_huddle_solution: authenticated yes, anon and PUBLIC no',
    has_function_privilege('authenticated', 'public.complete_forced_password_change()', 'execute')
    and has_function_privilege('authenticated', 'public.raise_huddle_issue(text)', 'execute')
    and has_function_privilege('authenticated', 'public.propose_huddle_solution(uuid,text)', 'execute')
    and not has_function_privilege('anon', 'public.complete_forced_password_change()', 'execute')
    and not has_function_privilege('anon', 'public.raise_huddle_issue(text)', 'execute')
    and not has_function_privilege('anon', 'public.propose_huddle_solution(uuid,text)', 'execute')
    and not exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.pronamespace = 'public'::regnamespace and a.grantee = 0
                     and p.proname in ('complete_forced_password_change', 'arm_forced_password_change', 'raise_huddle_issue', 'propose_huddle_solution',
                                       'guard_profile_staff_fields', '_trg_profile_password_marker', '_trg_profile_assign_color', '_hsl_hex',
                                       '_trg_meeting_issue_stamp', '_trg_meeting_issue_notify')));
  perform pg_temp.chk('arm_forced_password_change is service_role only',
    has_function_privilege('service_role', 'public.arm_forced_password_change(uuid)', 'execute')
    and not has_function_privilege('authenticated', 'public.arm_forced_password_change(uuid)', 'execute')
    and not has_function_privilege('anon', 'public.arm_forced_password_change(uuid)', 'execute'));
  perform pg_temp.chk('trigger and helper functions are not client-callable',
    not has_function_privilege('authenticated', 'public.guard_profile_staff_fields()', 'execute')
    and not has_function_privilege('authenticated', 'public._trg_meeting_issue_notify()', 'execute')
    and not has_function_privilege('authenticated', 'public._trg_meeting_issue_stamp()', 'execute')
    and not has_function_privilege('authenticated', 'public._hsl_hex(numeric,numeric,numeric)', 'execute'));

  -- ---------- designation and colour: master only ----------
  perform pg_temp.as_user(v_master);
  s := pg_temp.raises(format($q$update profiles set designation = 'Sales executive' where id = %L$q$, v_sales));
  perform pg_temp.chk('master can set a designation', s is null and (select designation from profiles where id = v_sales) = 'Sales executive', coalesce(s, 'ok'));
  s := pg_temp.raises(format($q$update profiles set task_color = '#112233' where id = %L$q$, v_sales));
  perform pg_temp.chk('master can set a colour', s is null and (select task_color from profiles where id = v_sales) = '#112233', coalesce(s, 'ok'));
  s := pg_temp.raises(format($q$update profiles set task_color = 'red' where id = %L$q$, v_sales));
  perform pg_temp.chk('a colour must be #rrggbb', s like '%check constraint%', coalesce(s, 'accepted'));
  perform pg_temp.as_user(v_sales);
  s := pg_temp.raises(format($q$update profiles set designation = 'Director' where id = %L$q$, v_sales));
  perform pg_temp.chk('a non-master cannot change their own designation', s like '%only the master%', coalesce(s, 'accepted'));
  s := pg_temp.raises(format($q$update profiles set task_color = '#000000' where id = %L$q$, v_sales));
  perform pg_temp.chk('a non-master cannot change their own colour', s like '%only the master%', coalesce(s, 'accepted'));
  perform pg_temp.as_pg();
  perform pg_temp.chk('every non-customer profile in the test organisation got a #rrggbb colour; a customer did not',
    not exists (select 1 from profiles where org_id = v_org and role::text <> 'customer' and (task_color is null or task_color !~ '^#[0-9a-f]{6}$'))
    and (select task_color from profiles where id = v_cr) is null);
  select count(*) into n from profiles where org_id = v_org and role::text <> 'customer' and id <> v_sales;
  perform pg_temp.chk('colours are distinct between the people created automatically',
    n = (select count(distinct task_color) from profiles where org_id = v_org and role::text <> 'customer' and id <> v_sales), n::text);

  -- ---------- staff_private: who can read an address ----------
  insert into staff_private (profile_id, org_id, address) values (v_sales, v_org, '12 Main Road, Chennai 600001');
  insert into staff_private (profile_id, org_id, address) values (v_ops, v_org, '7 Lake View, Coimbatore 641001');
  perform pg_temp.as_user(v_sales);
  select count(*) into n from staff_private;
  perform pg_temp.chk('a person reads only their own row', n = 1 and (select profile_id from staff_private limit 1) = v_sales, n::text);
  perform pg_temp.as_user(v_ops);
  select count(*) into n from staff_private where org_id = v_org;
  perform pg_temp.chk('operation_admin reads every row of their organisation', n = 2, n::text);
  perform pg_temp.as_user(v_master);
  select count(*) into n from staff_private where org_id = v_org;
  perform pg_temp.chk('master reads every row of their organisation', n = 2, n::text);
  perform pg_temp.as_user(v_tp);
  select count(*) into n from staff_private;
  perform pg_temp.chk('a technician reads none (not even about colleagues)', n = 0, n::text);
  perform pg_temp.as_user(v_cr);
  select count(*) into n from staff_private;
  perform pg_temp.chk('a customer reads none', n = 0, n::text);
  perform pg_temp.as_user(v_m2);
  select count(*) into n from staff_private where org_id = v_org;
  perform pg_temp.chk('another organisation''s master reads none of it', n = 0, n::text);
  perform pg_temp.as_user(v_sales);
  s := pg_temp.raises(format($q$update staff_private set address = 'moved' where profile_id = %L$q$, v_sales));
  perform pg_temp.as_pg();
  perform pg_temp.chk('a person cannot edit their own address (master-only)', (select address from staff_private where profile_id = v_sales) like '12 Main%', coalesce(s, 'filtered'));
  perform pg_temp.as_user(v_master);
  s := pg_temp.raises(format($q$update staff_private set address = '14 Main Road, Chennai 600001' where profile_id = %L$q$, v_sales));
  perform pg_temp.as_pg();
  perform pg_temp.chk('master can edit it', s is null and (select address from staff_private where profile_id = v_sales) like '14 Main%', coalesce(s, 'ok'));
  perform pg_temp.as_anon();
  s := pg_temp.raises('select count(*) from public.staff_private');
  perform pg_temp.as_pg();
  perform pg_temp.chk('anon is refused', s like '%permission denied%', coalesce(s, 'accepted'));
  perform pg_temp.chk('the address never appears in audit_log (no audit trigger on staff_private)',
    not exists (select 1 from audit_log where org_id = v_org and (before::text like '%Main Road%' or after::text like '%Main Road%')));

  -- ---------- forced password change ----------
  perform pg_temp.as_user(v_master);
  s := pg_temp.raises(format($q$update profiles set must_change_password = true where id = %L$q$, v_sales));
  perform pg_temp.chk('a client (even a master) cannot set the forced flag directly', s like '%set by the system%', coalesce(s, 'accepted'));
  perform pg_temp.as_pg();
  v_staff := pg_temp.mkuser('sales_admin', v_org);
  perform public.arm_forced_password_change(v_staff);
  select marker into m1 from profile_password_markers where profile_id = v_staff;
  perform pg_temp.chk('arming records a marker of the current password hash and turns the flag on',
    m1 = md5('x') and (select must_change_password from profiles where id = v_staff), coalesce(m1, 'null'));
  perform pg_temp.as_user(v_staff);
  s := pg_temp.raises($q$select public.complete_forced_password_change()$q$);
  perform pg_temp.as_pg();
  perform pg_temp.chk('the flag cannot be cleared before the password actually changed', s like '%not been changed yet%' and (select must_change_password from profiles where id = v_staff), coalesce(s, 'accepted'));
  perform pg_temp.as_user(v_staff);
  s := pg_temp.raises(format($q$update profiles set must_change_password = false where id = %L$q$, v_staff));
  perform pg_temp.as_pg();
  perform pg_temp.chk('and the user cannot clear it by updating their own row', s like '%set by the system%' and (select must_change_password from profiles where id = v_staff), coalesce(s, 'accepted'));
  perform pg_temp.as_user(v_staff);
  s := pg_temp.raises('select marker from public.profile_password_markers');
  perform pg_temp.as_pg();
  perform pg_temp.chk('the user cannot read the marker table', s like '%permission denied%', coalesce(s, 'accepted'));
  update auth.users set encrypted_password = 'changed' where id = v_staff;
  perform pg_temp.as_user(v_staff);
  s := pg_temp.raises($q$select public.complete_forced_password_change()$q$);
  perform pg_temp.as_pg();
  perform pg_temp.chk('after the password changed the flag is cleared and the marker row removed',
    s is null and not (select must_change_password from profiles where id = v_staff)
    and not exists (select 1 from profile_password_markers where profile_id = v_staff), coalesce(s, 'ok'));
  -- a reset: the password changes FIRST, then the flag is armed -> the marker is the NEW hash
  update auth.users set encrypted_password = 'reset-by-master' where id = v_staff;
  perform public.arm_forced_password_change(v_staff);
  perform pg_temp.chk('a reset re-arms the flag with a marker of the new hash',
    (select marker from profile_password_markers where profile_id = v_staff) = md5('reset-by-master') and (select must_change_password from profiles where id = v_staff));
  -- a second reset while still armed replaces the marker (the flag was already true)
  update auth.users set encrypted_password = 'second-reset' where id = v_staff;
  perform public.arm_forced_password_change(v_staff);
  perform pg_temp.chk('re-arming an already armed account replaces the marker with the newest hash',
    (select marker from profile_password_markers where profile_id = v_staff) = md5('second-reset'));
  perform pg_temp.chk('arming an unknown profile is refused',
    pg_temp.raises(format($q$select public.arm_forced_password_change(%L)$q$, gen_random_uuid())) like '%not found%');
  perform pg_temp.as_user(v_cr);
  -- flag on but no marker row (cannot happen through the system paths): never cleared on a guess
  perform pg_temp.as_pg();
  delete from profile_password_markers where profile_id = v_staff;
  perform pg_temp.as_user(v_staff);
  s := pg_temp.raises($q$select public.complete_forced_password_change()$q$);
  perform pg_temp.as_pg();
  perform pg_temp.chk('flag on and NO marker row: refused with "ask your administrator", flag NOT cleared',
    s like '%ask your administrator to reset your password%' and (select must_change_password from profiles where id = v_staff), coalesce(s, 'accepted'));
  perform pg_temp.as_user(v_cr);
  perform pg_temp.chk('a user with the flag off can call complete harmlessly', public.complete_forced_password_change() is true);
  perform pg_temp.as_pg();
  perform pg_temp.as_anon();
  s := pg_temp.raises($q$select public.complete_forced_password_change()$q$);
  perform pg_temp.as_pg();
  perform pg_temp.chk('anon cannot call complete', s like '%permission denied%', coalesce(s, 'accepted'));
  perform pg_temp.as_user(v_master);
  s := pg_temp.raises(format($q$select public.arm_forced_password_change(%L)$q$, v_sales));
  perform pg_temp.as_pg();
  perform pg_temp.chk('a master cannot call arm directly (service role only)', s like '%permission denied%', coalesce(s, 'accepted'));

  -- ---------- huddle: technicians raise, the master is told, names are stamped ----------
  perform pg_temp.as_user(v_tp);
  select public.raise_huddle_issue('  The van GPS keeps dropping off during jobs  ') into v_issue;
  perform pg_temp.as_pg();
  perform pg_temp.chk('a technician can raise a problem; it is attached to today''s log and raised_by is the technician',
    (select raised_by from meeting_issues where id = v_issue) = v_tp
    and (select date_raised from meeting_issues where id = v_issue) = v_today
    and (select description from meeting_issues where id = v_issue) = 'The van GPS keeps dropping off during jobs');
  select id into v_log from meeting_logs where org_id = v_org and meeting_date = v_today;
  perform pg_temp.chk('the auto-created log has recorded_by NULL and no notes', v_log is not null
    and (select recorded_by from meeting_logs where id = v_log) is null and (select general_notes from meeting_logs where id = v_log) is null);
  perform pg_temp.chk('every active master is notified, the raiser is not',
    (select count(*) from notifications where ref_id = v_issue and type = 'huddle_problem_raised' and user_id in (v_master, v_master_b)) = 2
    and not exists (select 1 from notifications where ref_id = v_issue and user_id = v_tp));
  -- huddle reminder: that log does NOT count as "huddle held"
  update settings set huddle_reminder_time = '00:00', huddle_reminder_last_date = null where org_id = v_org;
  perform pg_temp.chk('the reminder still fires when the only log is the technician-created one', public.wa_send_huddle_reminder(v_org) = 1);
  update settings set huddle_reminder_last_date = null where org_id = v_org;
  update meeting_logs set recorded_by = v_ops where id = v_log;
  perform pg_temp.chk('and does not fire once staff recorded the huddle', public.wa_send_huddle_reminder(v_org) = 0);
  update meeting_logs set recorded_by = null where id = v_log;
  update settings set huddle_reminder_last_date = null where org_id = v_org;
  update meeting_logs set general_notes = 'Attendance and targets discussed' where id = v_log;
  perform pg_temp.chk('and does not fire when the log carries notes', public.wa_send_huddle_reminder(v_org) = 0);
  update meeting_logs set general_notes = null where id = v_log;

  -- technicians cannot edit or solve
  perform pg_temp.as_user(v_tp);
  update meeting_issues set description = 'edited by technician' where id = v_issue;
  update meeting_issues set status = 'solved', date_solved = v_today where id = v_issue;
  perform pg_temp.as_pg();
  perform pg_temp.chk('a technician can neither edit nor mark solved (staff-only update policy)',
    (select description from meeting_issues where id = v_issue) like 'The van GPS%' and (select status from meeting_issues where id = v_issue) = 'open');
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
  perform pg_temp.chk('staff marking it solved stamps solved_by with the person who did it',
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
  -- insert path: a client cannot choose the three names
  perform pg_temp.as_user(v_sales);
  insert into meeting_issues (org_id, meeting_id, description, date_raised, raised_by, solution, solution_by, status, solved_by, date_solved)
  values (v_org, v_meet, 'Forged names attempt one', v_today, v_master, 'Some solution', v_master, 'solved', v_master, v_today) returning id into v_issue2;
  perform pg_temp.chk('INSERT: a client passing someone else''s raised_by / solution_by / solved_by gets its own id',
    (select raised_by from meeting_issues where id = v_issue2) = v_sales and (select solution_by from meeting_issues where id = v_issue2) = v_sales
    and (select solved_by from meeting_issues where id = v_issue2) = v_sales);
  insert into meeting_issues (org_id, meeting_id, description, date_raised, raised_by, solution_by, solved_by)
  values (v_org, v_meet, 'Forged names attempt two', v_today, v_master, v_master, v_master) returning id into v_issue2;
  perform pg_temp.chk('INSERT: with no solution and status open, solution_by and solved_by are NULL whatever the client sent',
    (select raised_by from meeting_issues where id = v_issue2) = v_sales and (select solution_by from meeting_issues where id = v_issue2) is null
    and (select solved_by from meeting_issues where id = v_issue2) is null);
  -- update path: editing an existing solution keeps the original name
  update meeting_issues set solution = 'Replace the roller and clean the feed path' where id = v_issue2;
  perform pg_temp.as_user(v_ops);
  update meeting_issues set solution = 'Replace the roller and clean the feed path, then test' where id = v_issue2;
  perform pg_temp.as_pg();
  perform pg_temp.chk('UPDATE: blank -> non-blank stamps the writer; a later edit by someone else keeps the ORIGINAL name',
    (select solution_by from meeting_issues where id = v_issue2) = v_sales);
  perform pg_temp.as_user(v_ops);
  update meeting_issues set solution = '' where id = v_issue2;
  perform pg_temp.as_pg();
  perform pg_temp.chk('UPDATE: clearing the solution clears solution_by', (select solution_by from meeting_issues where id = v_issue2) is null);
  perform pg_temp.as_user(v_ops);
  update meeting_issues set solution = 'Fresh solution after clearing' where id = v_issue2;
  perform pg_temp.as_pg();
  perform pg_temp.chk('UPDATE: blank -> non-blank again stamps the new writer', (select solution_by from meeting_issues where id = v_issue2) = v_ops);
  -- staff path of the screen: the log a technician created has recorded_by NULL; staff taking it over sets recorded_by (huddle.ts ensureMeetingLog)
  update meeting_logs set recorded_by = null where id = v_meet;
  perform pg_temp.as_user(v_ops);
  update meeting_logs set recorded_by = v_ops where id = v_meet and recorded_by is null;
  perform pg_temp.as_pg();
  perform pg_temp.chk('STAFF PATH: staff can claim a technician-created log (recorded_by NULL -> themselves) through the normal update policy',
    (select recorded_by from meeting_logs where id = v_meet) = v_ops);

  -- ---------- 10 problems a day for a technician ----------
  perform pg_temp.as_user(v_tp2);
  for k in 1..10 loop
    perform public.raise_huddle_issue('Recurring problem number ' || k);
  end loop;
  s := pg_temp.raises($q$select public.raise_huddle_issue('the eleventh problem today')$q$);
  perform pg_temp.as_pg();
  perform pg_temp.chk('a technician can raise 10 problems a day and the 11th is refused', s like '%already raised 10%', coalesce(s, 'accepted'));
  perform pg_temp.as_user(v_tp);
  s := pg_temp.raises($q$select public.raise_huddle_issue('the first technician has not reached the limit')$q$);
  perform pg_temp.as_pg();
  perform pg_temp.chk('the limit is per technician: another technician can still raise one', s is null, coalesce(s, 'ok'));
  perform pg_temp.as_user(v_sales);
  for k in 1..11 loop
    perform public.raise_huddle_issue('Staff problem number ' || k);
  end loop;
  perform pg_temp.as_pg();
  perform pg_temp.chk('staff are not limited', (select count(*) from meeting_issues where raised_by = v_sales and description like 'Staff problem number%') = 11);

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
  perform pg_temp.chk('no notification reached the other organisation''s master',
    not exists (select 1 from notifications where user_id = v_m2 and type like 'huddle_%'));

  -- ---------- real data: relative to the baseline the wrapper took before the migration ----------
  begin
    v_base := current_setting('gv.baseline', true);
    v_now := pg_temp.gv_fingerprint();
    perform pg_temp.chk('the REAL organisations are unchanged by the migration and these tests (fingerprint equals the pre-migration baseline)',
      v_base is not null and v_base = v_now, coalesce(left(v_base, 40), 'no baseline') || ' / ' || coalesce(left(v_now, 40), '-'));
  exception when undefined_function then
    perform pg_temp.chk('real-data fingerprint skipped: this file was not run through the wrapper (no baseline)', true);
  end;

  raise exception 'RESULTS%', E'\n' || (select string_agg(r2.line, E'\n' order by r2.n) from pg_temp.res r2);
end $t$;
