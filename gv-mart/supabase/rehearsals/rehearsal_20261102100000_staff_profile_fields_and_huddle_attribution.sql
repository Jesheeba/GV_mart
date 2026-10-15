-- REHEARSAL (NOT RUN; for the owner's approval of this exact text): staff profile fields, huddle attribution + notification (P2): migration 20261102100000 + its tests
-- One request, one DO block. It: (1) refuses to run before 18:00 IST (the clock is read from clock_timestamp()), (2) recomputes
-- the sha256 of every embedded file and refuses on any mismatch with the pinned value, (3) executes the migration text(s) and then the
-- test file in order, (4) always ends in an unconditional RAISE EXCEPTION, so nothing is ever committed.
-- No top-level begin / commit / savepoint / rollback. No schema_migrations row is written. Never concatenated with test code outside
-- this wrapper. Expected error text starts with RESULTS (or TIMING); anything else is a failure and also rolls back.
-- Pinned (sha256 of the LF blob at the commit this wrapper was generated from):
--   c31003df8304f0f5ccb737c2e273b1df7ec96c58abab72e06a9a8a105526c1a1  gv-mart/supabase/migrations/20261102100000_staff_profile_fields_and_huddle_attribution.sql
--   86dcebb4969413b4f9f4d632833cbeccc9b37b90b8b2ef39eb9c6bf3773609a7  gv-mart/supabase/tests/staff_profile_fields_and_huddle_attribution.test.sql

do $rehearsal$
declare
  v_ist time := (clock_timestamp() at time zone 'Asia/Kolkata')::time;
  v_text text;
  v_hash text;
begin
  if v_ist < time '18:00' then
    raise exception 'REHEARSAL_REFUSED: the clock reads % IST, before 18:00 IST', to_char(v_ist, 'HH24:MI:SS');
  end if;

  v_text := $rh0$-- P2: staff profile fields, forced first-login password change, per-user colour, huddle attribution + master notification,
-- and technicians raising huddle issues.
--
-- 1. profiles gains four nullable-or-defaulted columns (no backfill, no existing row changes):
--      designation          free text, 1..80 characters, set by master / operation_admin
--      address              free text, up to 300 characters, the person themself or master / operation_admin
--      must_change_password boolean NOT NULL DEFAULT false. Existing staff are NOT forced: only rows created or reset after
--                           this ships are set to true (by the two staff Edge Functions, as service role).
--      colour               '#rrggbb', NULL = automatic (the client derives a stable colour from the profile id)
--    Writes by the client are held by guard_profile_staff_fields. The first-login gate clears the flag through
--    acknowledge_password_change(), a definer RPC: the client cannot clear it by a direct update.
--
-- 2. meeting_issues gains solution_by and solved_by. They are maintained by a trigger from auth.uid() and are not writable
--    from the client: a client-supplied value is overwritten.
--
-- 3. A master notification (the same role-addressed notifications row the huddle reminder uses) when an issue is raised and
--    when a solution is first written, unless the actor is the master.
--
-- 4. raise_huddle_issue(p_description): an ACTIVE technician or staff member raises an issue for today's huddle. The table's
--    insert/update policies are unchanged (staff only); a technician has no UPDATE path, so cannot edit anyone's issue.
--
-- RLS stays org-scoped; no policy is added or loosened. Not touched: compute_incentives, any review column.

-- 1. profiles ---------------------------------------------------------------------------------------------------------
alter table public.profiles
  add column designation text check (designation is null or char_length(btrim(designation)) between 1 and 80),
  add column address text check (address is null or char_length(address) <= 300),
  add column must_change_password boolean not null default false,
  add column colour text check (colour is null or colour ~ '^#[0-9a-fA-F]{6}$');

create or replace function public.guard_profile_staff_fields()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  -- service role (Edge Functions), definer RPCs and migrations are trusted
  if current_user not in ('authenticated', 'anon') then
    return new;
  end if;
  if tg_op = 'INSERT' then
    return new;  -- client inserts are already limited to master by guard_profile_privileged_columns
  end if;

  if new.must_change_password is distinct from old.must_change_password and not public.is_master() then
    raise exception 'profiles: only master can set the change-password flag; use the password screen to clear it' using errcode = '42501';
  end if;
  if new.designation is distinct from old.designation and not public.is_ops_staff() then
    raise exception 'profiles: only master or operation admin can set a designation' using errcode = '42501';
  end if;
  if (new.address is distinct from old.address or new.colour is distinct from old.colour)
     and old.id is distinct from auth.uid() and not public.is_ops_staff() then
    raise exception 'profiles: you can only change your own address and colour' using errcode = '42501';
  end if;
  return new;
end;
$$;
revoke all on function public.guard_profile_staff_fields() from public, anon, authenticated;

drop trigger if exists guard_profile_staff_fields on public.profiles;
create trigger guard_profile_staff_fields
  before insert or update on public.profiles
  for each row execute function public.guard_profile_staff_fields();

-- The first-login gate calls this after supabase.auth.updateUser({ password }) succeeds. It cannot prove the password
-- changed (GoTrue exposes no hook to the database); it only clears the caller's OWN flag.
create or replace function public.acknowledge_password_change()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'acknowledge_password_change: not signed in';
  end if;
  update public.profiles set must_change_password = false where id = auth.uid() and must_change_password;
end;
$$;
revoke all on function public.acknowledge_password_change() from public, anon;
grant execute on function public.acknowledge_password_change() to authenticated;

-- 2. huddle attribution -----------------------------------------------------------------------------------------------
alter table public.meeting_issues
  add column solution_by uuid references public.profiles (id) on delete set null,
  add column solved_by uuid references public.profiles (id) on delete set null;

create or replace function public._meeting_issue_attribution()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  -- no signed-in user (service role / migration): leave whatever was written
  if v_uid is null then
    return new;
  end if;

  if tg_op = 'INSERT' then
    new.solution_by := case when coalesce(btrim(new.solution), '') <> '' then v_uid else null end;
    new.solved_by := case when new.status = 'solved' then v_uid else null end;
    return new;
  end if;

  -- UPDATE: who wrote the solution text, and who closed the issue, come from the session, never from the payload
  if new.solution is distinct from old.solution then
    new.solution_by := case when coalesce(btrim(new.solution), '') <> '' then v_uid else null end;
  else
    new.solution_by := old.solution_by;
  end if;
  if new.status is distinct from old.status then
    new.solved_by := case when new.status = 'solved' then v_uid else null end;
  else
    new.solved_by := old.solved_by;
  end if;
  return new;
end;
$$;
revoke all on function public._meeting_issue_attribution() from public, anon, authenticated;

drop trigger if exists aa_meeting_issue_attribution on public.meeting_issues;
create trigger aa_meeting_issue_attribution
  before insert or update on public.meeting_issues
  for each row execute function public._meeting_issue_attribution();

-- 3. master notification ----------------------------------------------------------------------------------------------
create or replace function public._meeting_issue_notify_master()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor_is_master boolean := coalesce((select p.role = 'master' from public.profiles p where p.id = auth.uid()), false);
begin
  if v_actor_is_master then
    return new;
  end if;

  if tg_op = 'INSERT' then
    insert into public.notifications (org_id, role, type, title, body, ref_id)
    values (new.org_id, 'master', 'huddle_issue_raised', 'New huddle issue',
            left(new.description, 140), new.id);
    if coalesce(btrim(new.solution), '') <> '' then
      insert into public.notifications (org_id, role, type, title, body, ref_id)
      values (new.org_id, 'master', 'huddle_solution_raised', 'Solution proposed for a huddle issue',
              left(new.description, 140), new.id);
    end if;
  elsif coalesce(btrim(old.solution), '') = '' and coalesce(btrim(new.solution), '') <> '' then
    insert into public.notifications (org_id, role, type, title, body, ref_id)
    values (new.org_id, 'master', 'huddle_solution_raised', 'Solution proposed for a huddle issue',
            left(new.description, 140), new.id);
  end if;
  return new;
end;
$$;
revoke all on function public._meeting_issue_notify_master() from public, anon, authenticated;

drop trigger if exists meeting_issue_notify_master_ins on public.meeting_issues;
create trigger meeting_issue_notify_master_ins
  after insert on public.meeting_issues
  for each row execute function public._meeting_issue_notify_master();
drop trigger if exists meeting_issue_notify_master_upd on public.meeting_issues;
create trigger meeting_issue_notify_master_upd
  after update of solution on public.meeting_issues
  for each row execute function public._meeting_issue_notify_master();

-- 4. raising an issue -------------------------------------------------------------------------------------------------
-- Creates today's meeting_logs row if nobody has yet (recorded_by stays NULL: a technician raising an issue did not record
-- the meeting). That row also stops the "no huddle logged yet" reminder for today, exactly as a staff member raising an
-- issue already does through ensureMeetingLog in the app.
create or replace function public.raise_huddle_issue(p_description text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid := public.current_org_id();
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_desc text := btrim(coalesce(p_description, ''));
  v_meeting uuid;
  v_id uuid;
begin
  if auth.uid() is null or v_org is null then
    raise exception 'raise_huddle_issue: not signed in';
  end if;
  if not (public.is_staff() or public.current_technician_is_active()) then
    raise exception 'raise_huddle_issue: only active staff or technicians can raise an issue';
  end if;
  if char_length(v_desc) < 1 or char_length(v_desc) > 1000 then
    raise exception 'raise_huddle_issue: describe the issue in 1 to 1000 characters';
  end if;

  insert into public.meeting_logs (org_id, meeting_date)
  values (v_org, v_today)
  on conflict (org_id, meeting_date) do nothing;
  select id into v_meeting from public.meeting_logs where org_id = v_org and meeting_date = v_today;

  insert into public.meeting_issues (org_id, meeting_id, description, raised_by, date_raised)
  values (v_org, v_meeting, v_desc, auth.uid(), v_today)
  returning id into v_id;
  return v_id;
end;
$$;
revoke all on function public.raise_huddle_issue(text) from public, anon;
grant execute on function public.raise_huddle_issue(text) to authenticated;
$rh0$;
  v_hash := encode(sha256(convert_to(v_text, 'UTF8')), 'hex');
  if v_hash <> 'c31003df8304f0f5ccb737c2e273b1df7ec96c58abab72e06a9a8a105526c1a1' then
    raise exception 'REHEARSAL_REFUSED: hash mismatch for 20261102100000_staff_profile_fields_and_huddle_attribution.sql: %', v_hash;
  end if;
  execute v_text;

  v_text := $rh1$-- Rolled-back DB tests for 20261102100000_staff_profile_fields_and_huddle_attribution (P2).
-- NOT RUN (written for review). Run only through the rehearsal wrapper: it applies the migration and then this file in ONE
-- request; this file ends in an unconditional RAISE, so nothing is committed. Throwaway __TEST_ organisations only.
create temp table res (n serial, line text);
grant all on res to public;
grant usage on sequence res_n_seq to public;
create function pg_temp.chk(p_name text, p_ok boolean, p_info text default '') returns void language plpgsql as $f$
begin insert into pg_temp.res(line) values (case when coalesce(p_ok,false) then 'PASS  ' else 'FAIL  ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end); end $f$;
create function pg_temp.mkuser(p_role text, p_org uuid, p_tech boolean default false, p_active boolean default true) returns uuid language plpgsql as $f$
declare v uuid := gen_random_uuid();
begin
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
  values (v, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '__t_' || p_role || '_' || v || '@test.invalid', 'x', now(), now(), now(), '{}', '{}');
  insert into public.profiles (id, org_id, full_name, role, is_active) values (v, p_org, '__TEST_ ' || p_role, p_role::public.user_role, true)
    on conflict (id) do update set role = excluded.role, is_active = true, org_id = excluded.org_id;
  if p_tech then insert into public.technicians (org_id, profile_id, is_active) values (p_org, v, p_active); end if;
  return v;
end $f$;
create function pg_temp.act(p_uid uuid, p_sql text) returns text language plpgsql as $f$
declare n int;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    execute p_sql;
    get diagnostics n = row_count;
    execute 'reset role';
    return 'ok:' || n;
  exception when others then
    execute 'reset role';
    return 'err:' || sqlerrm;
  end;
end $f$;

do $t$
declare
  v_org uuid; v_org2 uuid; m uuid; o uuid; s uuid; ta uuid; ti uuid; m2 uuid;
  x text; v_issue uuid; v_issue2 uuid; v_n int; r record; v_meet uuid;
begin
  insert into public.organizations(name) values ('__TEST_p2') returning id into v_org;
  insert into public.organizations(name) values ('__TEST_p2_other') returning id into v_org2;
  m := pg_temp.mkuser('master', v_org); o := pg_temp.mkuser('operation_admin', v_org); s := pg_temp.mkuser('sales_admin', v_org);
  ta := pg_temp.mkuser('technician', v_org, true, true); ti := pg_temp.mkuser('technician', v_org, true, false);
  m2 := pg_temp.mkuser('master', v_org2);

  -- C: columns and defaults
  perform pg_temp.chk('C1 profiles has the four new columns, must_change_password boolean NOT NULL default false',
    (select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'profiles'
        and column_name in ('designation', 'address', 'must_change_password', 'colour')) = 4
    and (select is_nullable || '/' || column_default from information_schema.columns
          where table_schema = 'public' and table_name = 'profiles' and column_name = 'must_change_password') = 'NO/false');
  perform pg_temp.chk('C2 existing profiles were not flagged (the migration changed no rows)',
    (select count(*) from public.profiles where must_change_password) = 0);
  perform pg_temp.chk('C3 meeting_issues has solution_by and solved_by',
    (select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'meeting_issues'
        and column_name in ('solution_by', 'solved_by')) = 2);

  -- G: guard on the new profile columns
  x := pg_temp.act(s, format('update public.profiles set must_change_password = false where id = %L', s));
  perform pg_temp.chk('G1 a user cannot flip their own change-password flag directly', x like 'err:profiles: only master can set the change-password flag%', x);
  update public.profiles set must_change_password = true where id = s;
  x := pg_temp.act(s, format('update public.profiles set must_change_password = false where id = %L', s));
  perform pg_temp.chk('G2 ...even to clear it', x like 'err:profiles: only master can set the change-password flag%', x);
  x := pg_temp.act(s, 'select public.acknowledge_password_change()');
  perform pg_temp.chk('G3 acknowledge_password_change clears the caller''s own flag',
    x = 'ok:1' and (select not must_change_password from public.profiles where id = s), x);
  x := pg_temp.act(s, format('select public.acknowledge_password_change(); update public.profiles set must_change_password = false where id = %L', o));
  perform pg_temp.chk('G3b acknowledge_password_change touches only the caller (another user''s flag is unchanged)',
    (select must_change_password from public.profiles where id = o) = false);
  update public.profiles set must_change_password = true where id = o;
  x := pg_temp.act(s, 'select public.acknowledge_password_change()');
  perform pg_temp.chk('G3c ...a different caller clearing their own flag leaves operation_admin flagged',
    (select must_change_password from public.profiles where id = o) = true);
  x := pg_temp.act(m, format('update public.profiles set must_change_password = true where id = %L', s));
  perform pg_temp.chk('G4 master can set the flag on staff', x = 'ok:1', x);
  x := pg_temp.act(s, format('update public.profiles set designation = ''Owner'' where id = %L', s));
  perform pg_temp.chk('G5 a sales_admin cannot set their own designation', x like 'err:profiles: only master or operation admin%', x);
  x := pg_temp.act(o, format('update public.profiles set designation = ''Service desk'' where id = %L', s));
  perform pg_temp.chk('G6 operation_admin can set a designation', x = 'ok:1' or x = 'ok:0', x);
  x := pg_temp.act(m, format('update public.profiles set designation = ''Accounts'', address = ''12 Test Street'' where id = %L', s));
  perform pg_temp.chk('G7 master sets designation and address', x = 'ok:1', x);
  x := pg_temp.act(s, format('update public.profiles set address = ''New address'', colour = ''#aa11cc'' where id = %L', s));
  perform pg_temp.chk('G8 a user can change their own address and colour', x = 'ok:1', x);
  x := pg_temp.act(s, format('update public.profiles set colour = ''#000000'' where id = %L', ti));
  perform pg_temp.chk('G9 ...but not someone else''s', x like 'err:%' or x = 'ok:0', x);
  x := pg_temp.act(m, format('update public.profiles set colour = ''red'' where id = %L', s));
  perform pg_temp.chk('G10 a colour must be #rrggbb', x like 'err:%', x);
  x := pg_temp.act(m, format('update public.profiles set designation = %L where id = %L', repeat('x', 81), s));
  perform pg_temp.chk('G11 a designation longer than 80 characters is refused', x like 'err:%', x);
  perform pg_temp.chk('G12 the guard and the RPCs are not callable by anon / PUBLIC',
    not has_function_privilege('anon', 'public.acknowledge_password_change()', 'execute')
    and not has_function_privilege('anon', 'public.raise_huddle_issue(text)', 'execute')
    and not has_function_privilege('authenticated', 'public.guard_profile_staff_fields()', 'execute')
    and not has_function_privilege('authenticated', 'public._meeting_issue_attribution()', 'execute')
    and not has_function_privilege('authenticated', 'public._meeting_issue_notify_master()', 'execute')
    and has_function_privilege('authenticated', 'public.raise_huddle_issue(text)', 'execute')
    and has_function_privilege('authenticated', 'public.acknowledge_password_change()', 'execute'));

  -- H: huddle attribution and notification
  insert into public.meeting_logs(org_id, meeting_date, recorded_by) values (v_org, (now() at time zone 'Asia/Kolkata')::date, m) returning id into v_meet;
  x := pg_temp.act(s, format('insert into public.meeting_issues(org_id, meeting_id, description, raised_by, date_raised, solution, solution_by, solved_by) values (%L, %L, ''__TEST_issue1'', %L, current_date, ''try this'', %L, %L)', v_org, v_meet, s, m, m));
  perform pg_temp.chk('H1 staff raise an issue with a solution', x = 'ok:1', x);
  select id into v_issue from public.meeting_issues where description = '__TEST_issue1';
  perform pg_temp.chk('H2 solution_by is the session user, not the payload; solved_by stays null while open',
    (select solution_by = s and solved_by is null from public.meeting_issues where id = v_issue));
  perform pg_temp.chk('H3 the master got a raised notification and a solution notification (role-addressed, ref_id = issue)',
    (select count(*) from public.notifications where org_id = v_org and role = 'master' and ref_id = v_issue and type = 'huddle_issue_raised') = 1
    and (select count(*) from public.notifications where org_id = v_org and role = 'master' and ref_id = v_issue and type = 'huddle_solution_raised') = 1);
  x := pg_temp.act(o, format('update public.meeting_issues set status = ''solved'', date_solved = current_date, solved_by = %L where id = %L', m, v_issue));
  perform pg_temp.chk('H4 solved_by is the closer (operation_admin), not the payload',
    x = 'ok:1' and (select solved_by = o and solution_by = s from public.meeting_issues where id = v_issue), x);
  x := pg_temp.act(s, format('update public.meeting_issues set status = ''open'', date_solved = null where id = %L', v_issue));
  perform pg_temp.chk('H5 reopening clears solved_by', x = 'ok:1' and (select solved_by is null from public.meeting_issues where id = v_issue), x);
  x := pg_temp.act(o, format('update public.meeting_issues set solution = ''better fix'' where id = %L', v_issue));
  perform pg_temp.chk('H6 changing the solution text re-attributes solution_by to the editor, and a changed solution that was not blank does not notify again',
    x = 'ok:1' and (select solution_by = o from public.meeting_issues where id = v_issue)
    and (select count(*) from public.notifications where ref_id = v_issue and type = 'huddle_solution_raised') = 1, x);
  x := pg_temp.act(m, format('insert into public.meeting_issues(org_id, meeting_id, description, raised_by, date_raised) values (%L, %L, ''__TEST_by_master'', %L, current_date)', v_org, v_meet, m));
  perform pg_temp.chk('H7 the master raising an issue does not notify themself',
    x = 'ok:1' and (select count(*) from public.notifications n join public.meeting_issues i on i.id = n.ref_id where i.description = '__TEST_by_master') = 0, x);

  -- T: technicians
  x := pg_temp.act(ta, 'select public.raise_huddle_issue(''__TEST_from_tech'')');
  perform pg_temp.chk('T1 an active technician can raise an issue', x = 'ok:1', x);
  select id into v_issue2 from public.meeting_issues where description = '__TEST_from_tech';
  perform pg_temp.chk('T2 raised_by is the technician; the issue sits on today''s meeting and carries no solution attribution',
    (select raised_by = ta and solution_by is null and status = 'open' and meeting_id = v_meet from public.meeting_issues where id = v_issue2));
  perform pg_temp.chk('T3 the master was notified',
    (select count(*) from public.notifications where ref_id = v_issue2 and role = 'master' and type = 'huddle_issue_raised') = 1);
  x := pg_temp.act(ta, format('update public.meeting_issues set description = ''hijacked'' where id = %L', v_issue));
  perform pg_temp.chk('T4 a technician cannot edit anyone''s issue (direct update)', x = 'ok:0' or x like 'err:%', x);
  x := pg_temp.act(ta, format('update public.meeting_issues set description = ''hijacked'' where id = %L', v_issue2));
  perform pg_temp.chk('T5 ...including their own: there is no technician update path', x = 'ok:0' or x like 'err:%', x);
  x := pg_temp.act(ta, format('insert into public.meeting_issues(org_id, meeting_id, description, raised_by, date_raised) values (%L, %L, ''__TEST_direct'', %L, current_date)', v_org, v_meet, ta));
  perform pg_temp.chk('T6 a technician cannot insert into the table directly (only through the RPC)', x like 'err:%', x);
  x := pg_temp.act(ti, 'select public.raise_huddle_issue(''__TEST_inactive'')');
  perform pg_temp.chk('T7 a deactivated technician cannot raise an issue', x like 'err:%only active staff or technicians%', x);
  x := pg_temp.act(ta, 'select public.raise_huddle_issue(''   '')');
  perform pg_temp.chk('T8 an empty description is refused', x like 'err:%1 to 1000 characters%', x);
  x := pg_temp.act(ta, format('select public.raise_huddle_issue(%L)', repeat('x', 1001)));
  perform pg_temp.chk('T9 an over-long description is refused', x like 'err:%1 to 1000 characters%', x);
  perform pg_temp.chk('T10 raising twice on the same day reuses the day''s meeting row',
    (select count(*) from public.meeting_logs where org_id = v_org) = 1);

  -- O: organisation scope
  x := pg_temp.act(m2, format('select count(*) from public.meeting_issues where org_id = %L', v_org));
  perform pg_temp.chk('O1 another organisation''s master cannot see this organisation''s issues',
    pg_temp.act(m2, format('select 1 from public.meeting_issues where id = %L', v_issue)) = 'ok:0');
  perform pg_temp.chk('O2 no notification leaked into the other organisation',
    (select count(*) from public.notifications where org_id = v_org2) = 0);

  raise exception 'RESULTS%', E'\n' || (select string_agg(r2.line, E'\n' order by r2.n) from pg_temp.res r2);
end $t$;
$rh1$;
  v_hash := encode(sha256(convert_to(v_text, 'UTF8')), 'hex');
  if v_hash <> '86dcebb4969413b4f9f4d632833cbeccc9b37b90b8b2ef39eb9c6bf3773609a7' then
    raise exception 'REHEARSAL_REFUSED: hash mismatch for staff_profile_fields_and_huddle_attribution.test.sql: %', v_hash;
  end if;
  execute v_text;

  raise exception 'REHEARSAL_DID_NOT_RAISE: the test file should have raised RESULTS';
end
$rehearsal$;
