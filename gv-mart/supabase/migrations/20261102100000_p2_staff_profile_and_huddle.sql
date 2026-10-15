-- P2 (client list 12-10-2026 items 3 and 7). Design: gv-mart/docs/design-p2-staff-profile-huddle.md
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
  if v_marker is not null and v_now = v_marker then
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
