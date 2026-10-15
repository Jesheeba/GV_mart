-- REHEARSAL (NOT RUN; for the owner's approval of this exact text): P2 staff profile and huddle: migration 20261102100000 + its tests
-- One request, one DO block. It: (1) refuses to run before 18:00 IST (the clock is read from clock_timestamp()), (2) recomputes
-- the sha256 of every embedded file and refuses on any mismatch with the pinned value, (3) executes the migration text(s) and then the
-- test file in order, (4) always ends in an unconditional RAISE EXCEPTION, so nothing is ever committed.
-- No top-level begin / commit / savepoint / rollback. No schema_migrations row is written. Never concatenated with test code outside
-- this wrapper. Expected error text starts with RESULTS (or TIMING); anything else is a failure and also rolls back.
-- Pinned (sha256 of the LF blob at the commit this wrapper was generated from):
--   71fb634f651d9947c6c0a6c2b146a0b01634ae35ea338e6f342c1a97c0c38c2f  gv-mart/supabase/migrations/20261102100000_p2_staff_profile_and_huddle.sql
--   9091021f9945b69309d4540572370a3496b3f769453bdc8156825e71480fb543  gv-mart/supabase/tests/p2_staff_profile_and_huddle.test.sql

do $rehearsal$
declare
  v_ist time := (clock_timestamp() at time zone 'Asia/Kolkata')::time;
  v_text text;
  v_hash text;
begin
  if v_ist < time '18:00' then
    raise exception 'REHEARSAL_REFUSED: the clock reads % IST, before 18:00 IST', to_char(v_ist, 'HH24:MI:SS');
  end if;

  v_text := $rh0$-- P2 (client list 12-10-2026 items 3 and 7). Design: gv-mart/docs/design-p2-staff-profile-huddle.md
--
--   profiles.designation, profiles.address        taken when a staff member is created; master-only to change
--   profiles.must_change_password                 new staff (and a staff password reset) must change the password at first login
--   profiles.password_marker                      md5 of the password hash at the moment the flag was set (never the password)
--   profiles.task_color                           one colour per person, assigned automatically, master can change
--   meeting_issues.solution_by, solved_by         who gave the solution, who marked it solved (stamped by the database)
--   notifications to the master                   when a problem is raised, a solution is given, or an issue is solved
--   raise_huddle_issue / propose_huddle_solution  technicians may raise a problem and propose a solution (not edit others')
--
-- Existing staff are NOT forced to change their password: the flag defaults to false and is only ever set for new staff
-- (admin-create-staff) and after a master's password reset (admin-reset-staff-password), both service-role paths.
-- A client can never set or clear the flag: it is cleared only by complete_forced_password_change(), which clears it only when the
-- password hash differs from the one recorded when the flag was set.
--
-- Rollback: supabase/rollbacks/20261102100000_p2_staff_profile_and_huddle.rollback.sql

-- 1. profile columns --------------------------------------------------------------------------------------------------
alter table public.profiles
  add column designation text check (designation is null or char_length(btrim(designation)) between 1 and 80),
  add column address text check (address is null or char_length(btrim(address)) between 1 and 400),
  add column must_change_password boolean not null default false,
  add column password_marker text,
  add column task_color text check (task_color is null or task_color ~ '^#[0-9a-fA-F]{6}$');

-- 2. who may write them -------------------------------------------------------------------------------------------------
create or replace function public.guard_profile_staff_fields()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  -- service role, SECURITY DEFINER functions and the owner connection are trusted
  if current_user not in ('authenticated', 'anon') then
    return new;
  end if;
  if tg_op = 'INSERT' then
    if new.must_change_password or new.password_marker is not null then
      raise exception 'profiles: the forced password change flag can only be set by the system';
    end if;
    return new;
  end if;
  if new.must_change_password is distinct from old.must_change_password
     or new.password_marker is distinct from old.password_marker then
    raise exception 'profiles: the forced password change flag can only be set by the system';
  end if;
  if (new.designation is distinct from old.designation
      or new.address is distinct from old.address
      or new.task_color is distinct from old.task_color)
     and not public.is_master() then
    raise exception 'profiles: only the master can change designation, address or colour';
  end if;
  return new;
end;
$$;
revoke all on function public.guard_profile_staff_fields() from public, anon, authenticated;
drop trigger if exists guard_profile_staff_fields on public.profiles;
create trigger guard_profile_staff_fields
  before insert or update on public.profiles
  for each row execute function public.guard_profile_staff_fields();

-- 3. the password marker ---------------------------------------------------------------------------------------------------
-- Computed when the flag is turned on (or turned on again with no marker): md5 of the current password hash. SECURITY DEFINER
-- because auth.users is not readable by the API roles. Named zz_ so it fires after the guard above (the guard must see the
-- client's own values, not the marker this trigger fills in).
create or replace function public._trg_profile_password_marker()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.must_change_password then
    if tg_op = 'INSERT' or old.must_change_password is not true or new.password_marker is null then
      select md5(coalesce(u.encrypted_password, '')) into new.password_marker from auth.users u where u.id = new.id;
    end if;
  else
    new.password_marker := null;
  end if;
  return new;
end;
$$;
revoke all on function public._trg_profile_password_marker() from public, anon, authenticated;
drop trigger if exists zz_profile_password_marker on public.profiles;
create trigger zz_profile_password_marker
  before insert or update on public.profiles
  for each row execute function public._trg_profile_password_marker();

-- 4. clearing the flag ------------------------------------------------------------------------------------------------------
create or replace function public.complete_forced_password_change()
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_marker text;
  v_now text;
begin
  if auth.uid() is null then
    raise exception 'not signed in';
  end if;
  select p.password_marker into v_marker from public.profiles p where p.id = auth.uid() and p.must_change_password;
  if not found then
    return true;                         -- nothing to do
  end if;
  select md5(coalesce(u.encrypted_password, '')) into v_now from auth.users u where u.id = auth.uid();
  if v_marker is not null and v_now = v_marker then
    raise exception 'the password has not been changed yet';
  end if;
  update public.profiles set must_change_password = false, password_marker = null where id = auth.uid();
  return true;
end;
$$;
revoke all on function public.complete_forced_password_change() from public, anon, authenticated;
grant execute on function public.complete_forced_password_change() to authenticated, service_role;

-- 5. one colour per person -------------------------------------------------------------------------------------------------
create or replace function public._hsl_hex(p_h numeric, p_s numeric, p_l numeric)
returns text
language plpgsql
immutable
as $$
declare
  c numeric; x numeric; m numeric; r numeric; g numeric; b numeric; hp numeric;
begin
  c := (1 - abs(2 * p_l - 1)) * p_s;
  hp := mod(p_h, 360) / 60;
  x := c * (1 - abs(mod(hp, 2) - 1));
  if hp < 1 then r := c; g := x; b := 0;
  elsif hp < 2 then r := x; g := c; b := 0;
  elsif hp < 3 then r := 0; g := c; b := x;
  elsif hp < 4 then r := 0; g := x; b := c;
  elsif hp < 5 then r := x; g := 0; b := c;
  else r := c; g := 0; b := x;
  end if;
  m := p_l - c / 2;
  return '#' || lpad(to_hex(round((r + m) * 255)::int), 2, '0') || lpad(to_hex(round((g + m) * 255)::int), 2, '0')
             || lpad(to_hex(round((b + m) * 255)::int), 2, '0');
end;
$$;
revoke all on function public._hsl_hex(numeric, numeric, numeric) from public, anon, authenticated;

-- golden-angle hue steps: the n-th person in an organisation gets a hue 137.5 degrees from the previous one, so any number of people
-- get clearly different colours. The master can overwrite a colour.
create or replace function public._trg_profile_assign_color()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_n integer;
begin
  if new.task_color is null and new.role::text <> 'customer' then
    select count(*) into v_n from public.profiles p where p.org_id = new.org_id and p.role::text <> 'customer' and p.task_color is not null;
    new.task_color := public._hsl_hex(v_n * 137.508, 0.62, 0.42);
  end if;
  return new;
end;
$$;
revoke all on function public._trg_profile_assign_color() from public, anon, authenticated;
drop trigger if exists zy_profile_assign_color on public.profiles;
create trigger zy_profile_assign_color
  before insert on public.profiles
  for each row execute function public._trg_profile_assign_color();

-- existing staff and technicians: numbered per organisation by creation time (set-based; the guard is bypassed because this runs as owner)
with ranked as (
  select p.id, row_number() over (partition by p.org_id order by p.created_at, p.id) - 1 as n
  from public.profiles p
  where p.role::text <> 'customer' and p.task_color is null
)
update public.profiles p set task_color = public._hsl_hex(r.n * 137.508, 0.62, 0.42) from ranked r where r.id = p.id;

-- 6. huddle: who gave the solution, who solved it --------------------------------------------------------------------------
alter table public.meeting_issues
  add column solution_by uuid references public.profiles (id) on delete set null,
  add column solved_by uuid references public.profiles (id) on delete set null;

create or replace function public._trg_meeting_issue_stamp()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_client boolean := current_user in ('authenticated', 'anon');
begin
  if tg_op = 'INSERT' then
    if new.raised_by is null then new.raised_by := auth.uid(); end if;
    if btrim(coalesce(new.solution, '')) <> '' and new.solution_by is null then new.solution_by := auth.uid(); end if;
    if new.status = 'solved' and new.solved_by is null then new.solved_by := auth.uid(); end if;
    return new;
  end if;

  -- a client cannot write these two columns directly: they are what the database observed
  if v_client then
    new.solution_by := old.solution_by;
    new.solved_by := old.solved_by;
  end if;
  if new.solution is distinct from old.solution then
    if btrim(coalesce(new.solution, '')) <> '' then
      new.solution_by := coalesce(auth.uid(), new.solution_by);
    else
      new.solution_by := null;
    end if;
  end if;
  if new.status = 'solved' and old.status is distinct from 'solved' then
    new.solved_by := coalesce(auth.uid(), new.solved_by);
  elsif new.status = 'open' and old.status = 'solved' then
    new.solved_by := null;
  end if;
  return new;
end;
$$;
revoke all on function public._trg_meeting_issue_stamp() from public, anon, authenticated;
drop trigger if exists meeting_issues_stamp on public.meeting_issues;
create trigger meeting_issues_stamp
  before insert or update on public.meeting_issues
  for each row execute function public._trg_meeting_issue_stamp();

-- 7. the master is told ----------------------------------------------------------------------------------------------------
create or replace function public._trg_meeting_issue_notify()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_type text;
  v_title text;
  v_who text;
begin
  if tg_op = 'INSERT' then
    v_type := 'huddle_problem_raised';
    v_title := 'Problem raised in the huddle';
  elsif new.status = 'solved' and old.status is distinct from 'solved' then
    v_type := 'huddle_issue_solved';
    v_title := 'Huddle problem marked solved';
  elsif new.solution is distinct from old.solution and btrim(coalesce(new.solution, '')) <> '' then
    v_type := 'huddle_solution_given';
    v_title := 'Solution given for a huddle problem';
  else
    return new;
  end if;

  select full_name into v_who from public.profiles where id = auth.uid();
  insert into public.notifications (org_id, user_id, type, title, body, ref_id)
  select new.org_id, p.id, v_type, v_title,
         left(new.description, 140) || case when v_who is not null then ' (' || v_who || ')' else '' end,
         new.id
  from public.profiles p
  where p.org_id = new.org_id and p.role::text = 'master' and p.is_active and p.id is distinct from auth.uid();
  return new;
end;
$$;
revoke all on function public._trg_meeting_issue_notify() from public, anon, authenticated;
drop trigger if exists meeting_issues_notify on public.meeting_issues;
create trigger meeting_issues_notify
  after insert or update on public.meeting_issues
  for each row execute function public._trg_meeting_issue_notify();

-- 8. technicians raise and propose (they still cannot edit anyone else's issue) ---------------------------------------------
create or replace function public.raise_huddle_issue(p_description text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid := public.current_org_id();
  v_date date := (now() at time zone 'Asia/Kolkata')::date;
  v_meeting uuid;
  v_id uuid;
  v_desc text := btrim(coalesce(p_description, ''));
begin
  if auth.uid() is null or not (public.is_staff() or public.current_technician_is_active()) then
    raise exception 'not permitted: only staff or an active technician can raise a huddle problem';
  end if;
  if char_length(v_desc) < 3 or char_length(v_desc) > 1000 then
    raise exception 'describe the problem in 3 to 1000 characters';
  end if;
  insert into public.meeting_logs (org_id, meeting_date, recorded_by)
  values (v_org, v_date, case when public.is_staff() then auth.uid() end)
  on conflict (org_id, meeting_date) do nothing;
  select id into v_meeting from public.meeting_logs where org_id = v_org and meeting_date = v_date;
  insert into public.meeting_issues (org_id, meeting_id, description, raised_by, date_raised)
  values (v_org, v_meeting, v_desc, auth.uid(), v_date)
  returning id into v_id;
  return v_id;
end;
$$;
revoke all on function public.raise_huddle_issue(text) from public, anon, authenticated;
grant execute on function public.raise_huddle_issue(text) to authenticated, service_role;

create or replace function public.propose_huddle_solution(p_issue_id uuid, p_solution text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sol text := btrim(coalesce(p_solution, ''));
  v_issue public.meeting_issues;
begin
  if auth.uid() is null or not (public.is_staff() or public.current_technician_is_active()) then
    raise exception 'not permitted: only staff or an active technician can propose a solution';
  end if;
  if char_length(v_sol) < 3 or char_length(v_sol) > 2000 then
    raise exception 'describe the solution in 3 to 2000 characters';
  end if;
  select * into v_issue from public.meeting_issues where id = p_issue_id and org_id = public.current_org_id() for update;
  if not found then
    raise exception 'huddle problem not found';
  end if;
  if v_issue.status <> 'open' then
    raise exception 'this problem is already solved';
  end if;
  if btrim(coalesce(v_issue.solution, '')) <> '' then
    raise exception 'a solution is already recorded for this problem';
  end if;
  update public.meeting_issues set solution = v_sol where id = p_issue_id;
end;
$$;
revoke all on function public.propose_huddle_solution(uuid, text) from public, anon, authenticated;
grant execute on function public.propose_huddle_solution(uuid, text) to authenticated, service_role;

notify pgrst, 'reload schema';
$rh0$;
  v_hash := encode(sha256(convert_to(v_text, 'UTF8')), 'hex');
  if v_hash <> '71fb634f651d9947c6c0a6c2b146a0b01634ae35ea338e6f342c1a97c0c38c2f' then
    raise exception 'REHEARSAL_REFUSED: hash mismatch for 20261102100000_p2_staff_profile_and_huddle.sql: %', v_hash;
  end if;
  execute v_text;

  v_text := $rh1$-- DB tests for 20261102100000_p2_staff_profile_and_huddle. NOT RUN (written for review). Run only through the approved rehearsal
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
$rh1$;
  v_hash := encode(sha256(convert_to(v_text, 'UTF8')), 'hex');
  if v_hash <> '9091021f9945b69309d4540572370a3496b3f769453bdc8156825e71480fb543' then
    raise exception 'REHEARSAL_REFUSED: hash mismatch for p2_staff_profile_and_huddle.test.sql: %', v_hash;
  end if;
  execute v_text;

  raise exception 'REHEARSAL_DID_NOT_RAISE: the test file should have raised RESULTS';
end
$rehearsal$;
