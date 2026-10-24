-- REHEARSAL (NOT RUN; for the owner's approval of this exact text): P2 staff profile and huddle: migration 20261102100000 + its tests
-- One request, one DO block. It: (1) refuses to run before 18:00 IST (the clock is read from clock_timestamp()), (2) recomputes
-- the sha256 of every embedded file and refuses on any mismatch with the pinned value, (3) stores a baseline fingerprint of the REAL
-- organisations, (4) executes the migration text(s) and then the test file in order, (5) always ends in an unconditional
-- RAISE EXCEPTION, so nothing is ever committed.
-- No top-level begin / commit / savepoint / rollback. No schema_migrations row is written. Never concatenated with test code outside
-- this wrapper. Expected error text starts with RESULTS (or TIMING); anything else is a failure and also rolls back.
-- Pinned (sha256 of the LF blob at the commit this wrapper was generated from):
--   17538d3073a53eb23ed65ee4f2e333f7f1aeb64a35a6b854920c63a5c704067e  gv-mart/supabase/migrations/20261102100000_p2_staff_profile_and_huddle.sql
--   e577b8ce71149ceaf6584233eaa2a53b7af813e4115f958e31dd4468da87da3b  gv-mart/supabase/tests/p2_staff_profile_and_huddle.test.sql
--   d65d7395d458ac117593cedf6c1e61638b261e0e8204773cf57b03f6ecf90bfc  (pre-check snippet: public.wa_send_huddle_reminder(uuid) as last defined in gv-mart/supabase/migrations/20260929100000_daily_huddle_log.sql)
-- Pre-check: the live function must equal what that migration defined. The wrapper re-creates the pinned snippet inside a
-- sub-block, takes md5(pg_get_functiondef()) of it, rolls the sub-block back, and refuses if it differs from the live md5.
-- Baseline: before the migration the wrapper stores this fingerprint of the REAL organisations in gv.baseline; the test file
-- recomputes it at the end and checks it is unchanged (a relative comparison, not an absolute count). Fingerprint SQL:
--   select md5(coalesce((select string_agg(p.id::text || ':' || p.org_id::text || ':' || p.role::text || ':' || p.is_active::text || ':' || p.full_name || ':' || coalesce(p.phone, ''), ',' order by p.id)
--                      from public.profiles p where p.org_id in (select o.id from public.organizations o where o.name not like '\_\_TEST\_%')), ''))
--          || '|' || md5(coalesce((select string_agg(i.id::text || ':' || i.status || ':' || i.description || ':' || coalesce(i.raised_by::text, '-') || ':' || coalesce(i.solution, ''), ',' order by i.id)
--                      from public.meeting_issues i where i.org_id in (select o.id from public.organizations o where o.name not like '\_\_TEST\_%')), ''))
--          || '|' || (select count(*)::text from public.notifications n where n.org_id in (select o.id from public.organizations o where o.name not like '\_\_TEST\_%') and n.type like 'huddle\_%')
--          || '|' || (select count(*)::text from public.meeting_logs m where m.org_id in (select o.id from public.organizations o where o.name not like '\_\_TEST\_%'))

do $rehearsal$
declare
  v_ist time := (clock_timestamp() at time zone 'Asia/Kolkata')::time;
  v_text text;
  v_hash text;
  v_live text;
  v_orig text;
begin
  if v_ist < time '18:00' then
    raise exception 'REHEARSAL_REFUSED: the clock reads % IST, before 18:00 IST', to_char(v_ist, 'HH24:MI:SS');
  end if;

  -- pre-check: the live public.wa_send_huddle_reminder(uuid) is still the definition the last migration gave it
  v_text := $orig$create or replace function public.wa_send_huddle_reminder(p_org_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_now_ist timestamp := (now() at time zone 'Asia/Kolkata');
  v_today date := v_now_ist::date;
  v_claimed integer;
  v_role public.user_role;
begin
  -- Atomic claim: only one caller per day passes, and only when past the
  -- cutoff and no log exists yet.
  update public.settings s
     set huddle_reminder_last_date = v_today
   where s.org_id = p_org_id
     and s.huddle_reminder_time is not null
     and v_now_ist::time >= s.huddle_reminder_time
     and (s.huddle_reminder_last_date is null or s.huddle_reminder_last_date < v_today)
     and not exists (
       select 1 from public.meeting_logs m
        where m.org_id = p_org_id and m.meeting_date = v_today
     );
  get diagnostics v_claimed = row_count;
  if v_claimed = 0 then
    return 0;
  end if;

  foreach v_role in array array['master', 'operation_admin', 'sales_admin']::public.user_role[] loop
    insert into public.notifications (org_id, role, type, title, body)
    values (p_org_id, v_role, 'huddle_reminder', 'Daily huddle not logged yet',
            'No huddle log has been recorded for today. Open Daily Huddle to record it.');
  end loop;
  return 1;
end;
$$;$orig$;
  v_hash := encode(sha256(convert_to(v_text, 'UTF8')), 'hex');
  if v_hash <> 'd65d7395d458ac117593cedf6c1e61638b261e0e8204773cf57b03f6ecf90bfc' then
    raise exception 'REHEARSAL_REFUSED: pre-check snippet hash mismatch: %', v_hash;
  end if;
  v_live := md5(pg_get_functiondef('public.wa_send_huddle_reminder(uuid)'::regprocedure));
  begin
    execute v_text;
    v_orig := md5(pg_get_functiondef('public.wa_send_huddle_reminder(uuid)'::regprocedure));
    raise exception 'GV_PRECHECK_PROBE';
  exception when others then
    if sqlerrm <> 'GV_PRECHECK_PROBE' then raise; end if;
  end;
  if v_orig is distinct from v_live then
    raise exception 'REHEARSAL_REFUSED: live public.wa_send_huddle_reminder(uuid) (md5 %) differs from its last migration definition (md5 %)', v_live, v_orig;
  end if;

  execute $gvfp$create function pg_temp.gv_fingerprint() returns text language sql stable as $fpb$
select md5(coalesce((select string_agg(p.id::text || ':' || p.org_id::text || ':' || p.role::text || ':' || p.is_active::text || ':' || p.full_name || ':' || coalesce(p.phone, ''), ',' order by p.id)
                   from public.profiles p where p.org_id in (select o.id from public.organizations o where o.name not like '\_\_TEST\_%')), ''))
       || '|' || md5(coalesce((select string_agg(i.id::text || ':' || i.status || ':' || i.description || ':' || coalesce(i.raised_by::text, '-') || ':' || coalesce(i.solution, ''), ',' order by i.id)
                   from public.meeting_issues i where i.org_id in (select o.id from public.organizations o where o.name not like '\_\_TEST\_%')), ''))
       || '|' || (select count(*)::text from public.notifications n where n.org_id in (select o.id from public.organizations o where o.name not like '\_\_TEST\_%') and n.type like 'huddle\_%')
       || '|' || (select count(*)::text from public.meeting_logs m where m.org_id in (select o.id from public.organizations o where o.name not like '\_\_TEST\_%'))
$fpb$$gvfp$;
  perform set_config('gv.baseline', pg_temp.gv_fingerprint(), true);

  v_text := $rh0$-- P2 (client list 12-10-2026 items 3 and 7). Design: gv-mart/docs/design-p2-staff-profile-huddle.md
--
--   profiles.designation, profiles.task_color     non-personal profile fields (master-only to change)
--   profiles.must_change_password                 new staff (and a staff password reset) must change the password at first login
--   profile_password_markers                      PRIVATE: md5 of the password hash when the flag was armed (RLS on, no policy, no grant)
--   staff_private (address)                       PRIVATE: only the person, the master and operation_admin can read it
--   meeting_issues.solution_by, solved_by         who gave the solution, who marked it solved (stamped by the database)
--   notifications to the master                   when a problem is raised, a solution is given, or an issue is solved
--   raise_huddle_issue / propose_huddle_solution  technicians may raise a problem (10 a day) and propose a solution
--   wa_send_huddle_reminder                       a log that only holds technician-raised problems no longer counts as "huddle held"
--
-- Existing staff are NOT forced to change their password: the flag defaults to false and is only set for new staff
-- (admin-create-staff inserts the profile with the flag on, AFTER the password exists) and after a master's reset
-- (admin-reset-staff-password calls arm_forced_password_change AFTER the password was changed). A client can never set or clear
-- the flag: it is cleared only by complete_forced_password_change(), which clears it only when the password hash differs from
-- the one recorded when the flag was armed.
--
-- Rollback: supabase/rollbacks/20261102100000_p2_staff_profile_and_huddle.rollback.sql

-- 1. profile columns --------------------------------------------------------------------------------------------------
alter table public.profiles
  add column designation text check (designation is null or char_length(btrim(designation)) between 1 and 80),
  add column must_change_password boolean not null default false,
  add column task_color text check (task_color is null or task_color ~ '^#[0-9a-fA-F]{6}$');

-- 2. private tables ------------------------------------------------------------------------------------------------------
-- The password marker is never readable through the API: RLS is on and there is NO policy; no API role holds a privilege.
-- Only the SECURITY DEFINER functions below (owner) touch it.
create table public.profile_password_markers (
  profile_id uuid primary key references public.profiles (id) on delete cascade,
  marker text not null,
  armed_at timestamptz not null default now()
);
alter table public.profile_password_markers enable row level security;
revoke all on public.profile_password_markers from public, anon, authenticated, service_role;

-- Personal staff details. profiles is readable by every staff role and (for a technician's own row) by customers, so an address
-- must not live there. Readable by the person themselves, the master and operation_admin of the same organisation; writable by the
-- master only (and by the service role through admin-create-staff). Technicians and sales_admin cannot read other people's rows.
create table public.staff_private (
  profile_id uuid primary key references public.profiles (id) on delete cascade,
  org_id uuid not null references public.organizations (id) on delete cascade,
  address text check (address is null or char_length(btrim(address)) between 1 and 400),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index staff_private_org_idx on public.staff_private (org_id);
alter table public.staff_private enable row level security;
create policy staff_private_select on public.staff_private for select
  using (profile_id = auth.uid() or (org_id = public.current_org_id() and public.is_ops_staff()));
create policy staff_private_write_master on public.staff_private for all
  using (org_id = public.current_org_id() and public.is_master())
  with check (org_id = public.current_org_id() and public.is_master());
revoke all on public.staff_private from public, anon, authenticated;
grant select, insert, update on public.staff_private to authenticated;
grant select, insert, update, delete on public.staff_private to service_role;
create trigger set_updated_at before update on public.staff_private for each row execute function public.set_updated_at();
-- no audit_master_change trigger on purpose: it would copy the address into audit_log, which every staff role can read

-- 3. who may write the profile fields -------------------------------------------------------------------------------------
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
    if new.must_change_password then
      raise exception 'profiles: the forced password change flag can only be set by the system';
    end if;
    return new;
  end if;
  if new.must_change_password is distinct from old.must_change_password then
    raise exception 'profiles: the forced password change flag can only be set by the system';
  end if;
  if (new.designation is distinct from old.designation or new.task_color is distinct from old.task_color)
     and not public.is_master() then
    raise exception 'profiles: only the master can change designation or colour';
  end if;
  return new;
end;
$$;
revoke all on function public.guard_profile_staff_fields() from public, anon, authenticated;
drop trigger if exists guard_profile_staff_fields on public.profiles;
create trigger guard_profile_staff_fields
  before insert or update on public.profiles
  for each row execute function public.guard_profile_staff_fields();

-- 4. the password marker -----------------------------------------------------------------------------------------------------
-- search_path is EMPTY and every object is schema-qualified: these functions read auth.users.
create or replace function public._trg_profile_password_marker()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.must_change_password then
    if tg_op = 'INSERT' or old.must_change_password is not true then
      insert into public.profile_password_markers (profile_id, marker)
      select new.id, pg_catalog.md5(coalesce(u.encrypted_password, '')) from auth.users u where u.id = new.id
      on conflict (profile_id) do update set marker = excluded.marker, armed_at = pg_catalog.now();
    end if;
  else
    delete from public.profile_password_markers where profile_id = new.id;
  end if;
  return new;
end;
$$;
revoke all on function public._trg_profile_password_marker() from public, anon, authenticated;
drop trigger if exists zz_profile_password_marker on public.profiles;
create trigger zz_profile_password_marker
  after insert or update of must_change_password on public.profiles
  for each row execute function public._trg_profile_password_marker();

-- Arms (or re-arms) the flag for a person whose password was JUST set. Service role only: the Edge Functions call it after
-- updating the password, never before, so the recorded marker is the hash of the password that was shared.
create or replace function public.arm_forced_password_change(p_profile_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profile_password_markers (profile_id, marker)
  select p.id, pg_catalog.md5(coalesce(u.encrypted_password, ''))
    from public.profiles p join auth.users u on u.id = p.id
   where p.id = p_profile_id
  on conflict (profile_id) do update set marker = excluded.marker, armed_at = pg_catalog.now();
  if not found then
    raise exception 'arm_forced_password_change: profile % not found', p_profile_id;
  end if;
  update public.profiles set must_change_password = true where id = p_profile_id;
end;
$$;
revoke all on function public.arm_forced_password_change(uuid) from public, anon, authenticated;
grant execute on function public.arm_forced_password_change(uuid) to service_role;

create or replace function public.complete_forced_password_change()
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_marker text;
  v_now text;
begin
  if auth.uid() is null then
    raise exception 'not signed in';
  end if;
  if not exists (select 1 from public.profiles p where p.id = auth.uid() and p.must_change_password) then
    return true;                         -- nothing to do
  end if;
  select m.marker into v_marker from public.profile_password_markers m where m.profile_id = auth.uid();
  select pg_catalog.md5(coalesce(u.encrypted_password, '')) into v_now from auth.users u where u.id = auth.uid();
  if v_marker is null then
    -- the flag is on but nothing was recorded to compare with: never clear it on a guess
    raise exception 'ask your administrator to reset your password';
  end if;
  if v_now = v_marker then
    raise exception 'the password has not been changed yet';
  end if;
  update public.profiles set must_change_password = false where id = auth.uid();
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

-- golden-angle hue steps: the n-th person in an organisation gets a hue 137.5 degrees from the previous one. The master can overwrite it.
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

-- existing staff and technicians: numbered per organisation by creation time (runs as owner, so the guard does not apply)
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

-- SECURITY INVOKER on purpose: this function tells a client from a trusted path by current_user, and inside a SECURITY DEFINER
-- function current_user is the owner, never the client. It reads only auth.uid(), so it needs no elevated rights.
create or replace function public._trg_meeting_issue_stamp()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_client boolean := current_user in ('authenticated', 'anon');
begin
  if tg_op = 'INSERT' then
    if v_client then
      -- a client's own values are ignored: the three columns are what the database observed
      new.raised_by := auth.uid();
      new.solution_by := case when btrim(coalesce(new.solution, '')) <> '' then auth.uid() else null end;
      new.solved_by := case when new.status = 'solved' then auth.uid() else null end;
    else
      if new.raised_by is null then new.raised_by := auth.uid(); end if;
      if btrim(coalesce(new.solution, '')) <> '' and new.solution_by is null then new.solution_by := auth.uid(); end if;
      if new.status = 'solved' and new.solved_by is null then new.solved_by := auth.uid(); end if;
    end if;
    return new;
  end if;

  -- a client cannot write these two columns directly: they are what the database observed
  if v_client then
    new.solution_by := old.solution_by;
    new.solved_by := old.solved_by;
  end if;
  -- solution_by is stamped only when the solution goes from blank to non-blank; editing an existing solution keeps the original name
  if btrim(coalesce(new.solution, '')) = '' then
    new.solution_by := null;
  elsif btrim(coalesce(old.solution, '')) = '' then
    new.solution_by := coalesce(auth.uid(), new.solution_by);
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

-- 8. technicians raise and propose (they still cannot edit or solve anyone's issue) -------------------------------------------
-- A raised problem needs today's meeting log (meeting_id is NOT NULL), so the function creates one if there is none. That log is
-- created with recorded_by = NULL and no notes, and the huddle reminder (section 9) ignores such a log, so a technician raising a
-- problem at 9 a.m. does not silence the "huddle not logged yet" reminder.
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
  v_today integer;
begin
  if auth.uid() is null or not (public.is_staff() or public.current_technician_is_active()) then
    raise exception 'not permitted: only staff or an active technician can raise a huddle problem';
  end if;
  if char_length(v_desc) < 3 or char_length(v_desc) > 1000 then
    raise exception 'describe the problem in 3 to 1000 characters';
  end if;
  -- a technician may raise at most 10 problems a day (staff are not limited)
  if not public.is_staff() then
    select count(*) into v_today from public.meeting_issues i where i.org_id = v_org and i.raised_by = auth.uid() and i.date_raised = v_date;
    if v_today >= 10 then
      raise exception 'you have already raised 10 problems today; tell the office directly';
    end if;
  end if;
  insert into public.meeting_logs (org_id, meeting_date, recorded_by)
  values (v_org, v_date, null)
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

-- 9. the huddle reminder: a log holding only technician-raised problems is not "huddle held" ----------------------------------
-- Same function, same signature and grants as 20260929100000; the only change is the not-exists test: a log counts only when staff
-- recorded it (recorded_by set) or it carries notes.
create or replace function public.wa_send_huddle_reminder(p_org_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_now_ist timestamp := (now() at time zone 'Asia/Kolkata');
  v_today date := v_now_ist::date;
  v_claimed integer;
  v_role public.user_role;
begin
  -- Atomic claim: only one caller per day passes, and only when past the cutoff and no staff-recorded log exists yet.
  update public.settings s
     set huddle_reminder_last_date = v_today
   where s.org_id = p_org_id
     and s.huddle_reminder_time is not null
     and v_now_ist::time >= s.huddle_reminder_time
     and (s.huddle_reminder_last_date is null or s.huddle_reminder_last_date < v_today)
     and not exists (
       select 1 from public.meeting_logs m
        where m.org_id = p_org_id and m.meeting_date = v_today
          and (m.recorded_by is not null or btrim(coalesce(m.general_notes, '')) <> '')
     );
  get diagnostics v_claimed = row_count;
  if v_claimed = 0 then
    return 0;
  end if;

  foreach v_role in array array['master', 'operation_admin', 'sales_admin']::public.user_role[] loop
    insert into public.notifications (org_id, role, type, title, body)
    values (p_org_id, v_role, 'huddle_reminder', 'Daily huddle not logged yet',
            'No huddle log has been recorded for today. Open Daily Huddle to record it.');
  end loop;
  return 1;
end;
$$;

notify pgrst, 'reload schema';
$rh0$;
  v_hash := encode(sha256(convert_to(v_text, 'UTF8')), 'hex');
  if v_hash <> '17538d3073a53eb23ed65ee4f2e333f7f1aeb64a35a6b854920c63a5c704067e' then
    raise exception 'REHEARSAL_REFUSED: hash mismatch for 20261102100000_p2_staff_profile_and_huddle.sql: %', v_hash;
  end if;
  execute v_text;

  v_text := $rh1$-- DB tests for 20261102100000_p2_staff_profile_and_huddle. NOT RUN (written for review). Run only through the approved rehearsal
-- wrapper (migration then this file, one request, ends in an unconditional RAISE). Throwaway __TEST_ organisations only.
-- The last check compares a fingerprint of the REAL organisations taken by the wrapper BEFORE the migration with the same
-- fingerprint now (relative, not absolute counts).
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

-- 20261024100000 made `alter default privileges for role postgres revoke execute on functions from public` global, which also removes
-- PUBLIC execute from the helper functions above (they live in pg_temp and are called after `set local role authenticated`).
-- Granting on pg_temp only touches this session's own temporary schema.
grant execute on all functions in schema pg_temp to public;

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
$rh1$;
  v_hash := encode(sha256(convert_to(v_text, 'UTF8')), 'hex');
  if v_hash <> 'e577b8ce71149ceaf6584233eaa2a53b7af813e4115f958e31dd4468da87da3b' then
    raise exception 'REHEARSAL_REFUSED: hash mismatch for p2_staff_profile_and_huddle.test.sql: %', v_hash;
  end if;
  execute v_text;

  raise exception 'REHEARSAL_DID_NOT_RAISE: the test file should have raised RESULTS';
end
$rehearsal$;
