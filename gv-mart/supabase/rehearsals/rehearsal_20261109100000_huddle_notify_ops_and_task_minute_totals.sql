-- REHEARSAL (NOT RUN; for the owner's approval of this exact text): huddle notify to operation_admin + task/person minute totals
-- (migration 20261109100000), chained ON TOP OF P2 (20261102100000) and P3 (20261103100000), whose migrations this depends on
-- (_trg_meeting_issue_notify, task_logs). P2 and P3's own test files are not re-run here (that is each one's own wrapper's job);
-- only their migration DDL is chained.
-- One request, one DO block. It: (1) refuses to run before 18:00 IST, (2) stores a baseline fingerprint of the REAL organisations,
-- (3) chains P2, (4) pre-checks the live _trg_meeting_issue_notify against P2's own definition before this migration redefines it,
-- (5) chains P3, (6) recomputes the sha256 of every embedded file and refuses on any mismatch with the pinned value, (7) executes
-- this migration then its test file, (8) always ends in an unconditional RAISE EXCEPTION, so nothing is ever committed.
-- No top-level begin / commit / savepoint / rollback. No schema_migrations row is written. Never concatenated with test code outside
-- this wrapper. Expected error text starts with RESULTS (or TIMING); anything else is a failure and also rolls back.
-- Pinned (sha256 of the LF blob at the commit this wrapper was generated from):
--   7387ca52f06923b1e083eb6c30293a09fd91ab6f587ff2e0492b32091521cf4a  (pre-check snippet: public._trg_meeting_issue_notify() as last defined in gv-mart/supabase/migrations/20261102100000_p2_staff_profile_and_huddle.sql)
--   17538d3073a53eb23ed65ee4f2e333f7f1aeb64a35a6b854920c63a5c704067e  gv-mart/supabase/migrations/20261102100000_p2_staff_profile_and_huddle.sql (P2, chained)
--   99990dde17cceb8485d5adc12bc4776906557a615341a4c0dbd04bf65238d6d5  gv-mart/supabase/migrations/20261103100000_task_logs_and_visibility.sql (P3, chained)
--   37d499edf565f3c140341888956c8341d45e73900b62b0a12a04baa7a9fed678  gv-mart/supabase/migrations/20261109100000_huddle_notify_ops_and_task_minute_totals.sql
--   21a2b92549424730f1fdb60449117dffae8f8575791e1c5ffac7e3812814aafa  gv-mart/supabase/tests/huddle_notify_ops_and_task_minute_totals.test.sql
-- Pre-check: the live public._trg_meeting_issue_notify() must equal what P2's migration (20261102100000) defined, before this
-- migration redefines it. The wrapper re-creates the pinned snippet inside a sub-block, takes md5(pg_get_functiondef()) of it,
-- rolls the sub-block back, and refuses if it differs from the live md5.
-- LIMITATION OF THIS PRE-CHECK IN A REHEARSAL: because P2 is CHAINED a few lines above (not applied for real), the "live" value this
-- pre-check compares against is only the function P2's own text just created inside THIS rehearsal's own rolled-back transaction —
-- it proves P2's text is internally self-consistent, not that it matches whatever is actually live in production right now. The
-- GO APPLY version of this wrapper (run only after P2 has genuinely been applied to the target database) must drop the "chain P2"
-- step entirely and run this same pre-check directly against the real live public._trg_meeting_issue_notify(), the way P2's own
-- wrapper's wa_send_huddle_reminder pre-check and P3's own wrapper's current_technician_id pre-check already do against their targets.
-- Real-organisation check: before anything else runs, the wrapper confirms it is pointed at the expected database by hashing the
-- oldest non-__TEST organisation's id and name and refusing on any mismatch with the pinned value below.
-- Baseline: before anything runs, the wrapper stores this fingerprint of the REAL organisations in gv.baseline; the test file
-- recomputes it at the end and checks it is unchanged (a relative comparison, not an absolute count). Fingerprint SQL:
--   select md5(coalesce((select string_agg(n.id::text || ':' || n.type || ':' || coalesce(n.user_id::text,'-'), ',' order by n.id)
--                      from public.notifications n where n.org_id in (select o.id from public.organizations o where o.name not like '\_\_TEST\_%') and n.type like 'huddle\_%'), ''))
--          || '|' || md5(coalesce((select string_agg(i.id::text || ':' || i.status || ':' || coalesce(i.solution,'-'), ',' order by i.id)
--                      from public.meeting_issues i where i.org_id in (select o.id from public.organizations o where o.name not like '\_\_TEST\_%')), ''))
--          || '|' || (select count(*)::text from public.task_logs l where l.org_id in (select o.id from public.organizations o where o.name not like '\_\_TEST\_%'))

do $rehearsal$
declare
  v_ist time := (clock_timestamp() at time zone 'Asia/Kolkata')::time;
  v_text text;
  v_hash text;
  v_live text;
  v_orig text;
  v_orgcheck text;
begin
  perform set_config('lock_timeout', '5s', true);

  select md5(o.id::text || '|' || o.name) into v_orgcheck
    from public.organizations o
   where o.name not like '\_\_TEST%'
   order by o.created_at asc
   limit 1;
  if v_orgcheck is distinct from '6f891cf85011f08c2f22fb4a208d21bd' then
    raise exception 'REHEARSAL_REFUSED: organisation fingerprint mismatch';
  end if;

  if v_ist < time '18:00' then
    raise exception 'REHEARSAL_REFUSED: the clock reads % IST, before 18:00 IST', to_char(v_ist, 'HH24:MI:SS');
  end if;

  -- gv_fingerprint() is plpgsql here (not plain sql) and guards the task_logs count behind to_regclass, because this wrapper's
  -- baseline is captured BEFORE P3 (chained below) creates task_logs: on a live database where P3 has not actually been applied yet,
  -- the table genuinely does not exist, and a plain `language sql` function referencing it would fail validation at CREATE time.
  -- The three parts of the string keep the same order and format: when task_logs exists and has no rows for real organisations, the
  -- value still ends in |0, exactly as it would have under the old definition, so the before/after comparison in the test is unaffected.
  execute $gvfp$create function pg_temp.gv_fingerprint() returns text language plpgsql stable as $fpb$
declare
  v_notif text;
  v_issues text;
  v_logs text := '0';
begin
  select md5(coalesce((select string_agg(n.id::text || ':' || n.type || ':' || coalesce(n.user_id::text,'-'), ',' order by n.id)
                     from public.notifications n where n.org_id in (select o.id from public.organizations o where o.name not like '\_\_TEST\_%') and n.type like 'huddle\_%'), ''))
    into v_notif;
  select md5(coalesce((select string_agg(i.id::text || ':' || i.status || ':' || coalesce(i.solution,'-'), ',' order by i.id)
                     from public.meeting_issues i where i.org_id in (select o.id from public.organizations o where o.name not like '\_\_TEST\_%')), ''))
    into v_issues;
  if to_regclass('public.task_logs') is not null then
    execute $dyn$select count(*)::text from public.task_logs l where l.org_id in (select o.id from public.organizations o where o.name not like '\_\_TEST\_%')$dyn$ into v_logs;
  end if;
  return v_notif || '|' || v_issues || '|' || v_logs;
end;
$fpb$$gvfp$;
  perform set_config('gv.baseline', pg_temp.gv_fingerprint(), true);

  -- chain P2 (meeting_issues notify, task_color, forced password change) so this migration redefines what P2 actually created.
  v_text := $p2$-- P2 (client list 12-10-2026 items 3 and 7). Design: gv-mart/docs/design-p2-staff-profile-huddle.md
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
$p2$;
  v_hash := encode(sha256(convert_to(replace(v_text, E'\r', ''), 'UTF8')), 'hex');
  if v_hash <> '17538d3073a53eb23ed65ee4f2e333f7f1aeb64a35a6b854920c63a5c704067e' then
    raise exception 'REHEARSAL_REFUSED: hash mismatch for 20261102100000_p2_staff_profile_and_huddle.sql (P2): %', v_hash;
  end if;
  execute replace(v_text, E'\r', '');

  -- pre-check: the live _trg_meeting_issue_notify (just created by the P2 chain above) is exactly P2's own definition, before this
  -- migration redefines it.
  v_text := $orig$create or replace function public._trg_meeting_issue_notify()
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
$orig$;
  v_hash := encode(sha256(convert_to(replace(v_text, E'\r', ''), 'UTF8')), 'hex');
  if v_hash <> '7387ca52f06923b1e083eb6c30293a09fd91ab6f587ff2e0492b32091521cf4a' then
    raise exception 'REHEARSAL_REFUSED: pre-check snippet hash mismatch: %', v_hash;
  end if;
  v_live := md5(pg_get_functiondef('public._trg_meeting_issue_notify()'::regprocedure));
  begin
    execute replace(v_text, E'\r', '');
    v_orig := md5(pg_get_functiondef('public._trg_meeting_issue_notify()'::regprocedure));
    raise exception 'GV_PRECHECK_PROBE';
  exception when others then
    if sqlerrm <> 'GV_PRECHECK_PROBE' then raise; end if;
  end;
  if v_orig is distinct from v_live then
    raise exception 'REHEARSAL_REFUSED: live public._trg_meeting_issue_notify() (md5 %) differs from its last migration definition (md5 %)', v_live, v_orig;
  end if;

  -- chain P3 (task_logs) so this migration's views have something real to select from.
  v_text := $p3$-- P3 (client list 12-10-2026 items 4, 5, 6): who sees which task, and a work log on every task. Design: gv-mart/docs/design-p3-task-log-visibility.md
--
--   1. task_logs            work log per task: a note, minutes spent, what is planned next and when (written by a person), and
--                           automatic entries for every reassignment, status change and due-date move (written by the database).
--                           Append-only: nobody can edit or delete an entry through the API.
--   2. tasks_select_internal narrowed: master and operation_admin see every task of the organisation; everyone else sees the tasks
--                           assigned to them and the tasks they assigned.
--
-- Depends on P1a (20261101100000: guard_task_completion, tasks_update_assign), P1b and P2 (20261102100000: profiles.task_color is
-- read by the screens, not by this file). Nothing here alters those objects.
--
-- Rollback: supabase/rollbacks/20261103100000_task_logs_and_visibility.rollback.sql

-- 1. the work log ---------------------------------------------------------------------------------------------------------
create table public.task_logs (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  task_id uuid not null references public.tasks (id) on delete cascade,
  kind text not null default 'note' check (kind in ('note', 'reassigned', 'status', 'due_moved')),
  created_by uuid references public.profiles (id) on delete set null,
  actor_name text,
  note text check (note is null or char_length(btrim(note)) between 1 and 2000),
  minutes_spent integer check (minutes_spent is null or minutes_spent between 0 and 1440),
  next_planned_date date,
  next_planned_note text check (next_planned_note is null or char_length(btrim(next_planned_note)) between 1 and 500),
  from_user uuid references public.profiles (id) on delete set null,
  to_user uuid references public.profiles (id) on delete set null,
  from_name text,
  to_name text,
  from_value text,
  to_value text,
  created_at timestamptz not null default now(),
  constraint task_logs_note_has_content check (
    kind <> 'note' or note is not null or minutes_spent is not null or next_planned_date is not null or next_planned_note is not null
  )
);
create index task_logs_task_idx on public.task_logs (task_id, created_at);
create index task_logs_org_idx on public.task_logs (org_id);

alter table public.task_logs enable row level security;
revoke all on public.task_logs from public, anon, authenticated;
grant select, insert on public.task_logs to authenticated;
grant select, insert, update, delete on public.task_logs to service_role;

-- A person sees the log of a task they can see: the subquery runs under the caller's own tasks policy (section 2), so the two rules
-- cannot drift apart.
create policy task_logs_select on public.task_logs for select
  using (org_id = public.current_org_id() and exists (select 1 from public.tasks t where t.id = task_logs.task_id));
create policy task_logs_insert on public.task_logs for insert
  with check (org_id = public.current_org_id() and exists (select 1 from public.tasks t where t.id = task_logs.task_id and t.org_id = task_logs.org_id));
-- no update or delete policy, and no update or delete privilege: an entry is corrected by adding another one

-- What a client can write is a note by themselves: the database stamps who and when and clears the system-only columns.
-- SECURITY INVOKER on purpose: it tells a client from a trusted path by current_user, which inside a SECURITY DEFINER function is the
-- owner. The only thing it reads is the caller's own profile name, which profiles_select_own (id = auth.uid()) allows.
create or replace function public._trg_task_log_client_insert()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  if current_user in ('authenticated', 'anon') then
    new.kind := 'note';
    new.created_by := auth.uid();
    new.actor_name := (select p.full_name from public.profiles p where p.id = auth.uid());
    new.from_user := null;
    new.to_user := null;
    new.from_name := null;
    new.to_name := null;
    new.from_value := null;
    new.to_value := null;
    new.created_at := now();
  end if;
  return new;
end;
$$;
revoke all on function public._trg_task_log_client_insert() from public, anon, authenticated;
create trigger task_logs_client_insert before insert on public.task_logs
  for each row execute function public._trg_task_log_client_insert();

create or replace function public._trg_task_log_immutable()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  if current_user in ('authenticated', 'anon') then
    raise exception 'task_logs: a log entry cannot be changed or removed';
  end if;
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;
revoke all on function public._trg_task_log_immutable() from public, anon, authenticated;
create trigger task_logs_immutable before update or delete on public.task_logs
  for each row execute function public._trg_task_log_immutable();

-- 2. automatic entries ----------------------------------------------------------------------------------------------------
-- Every reassignment (who, from whom, to whom), status change and due-date move is written by the database, whoever made it and
-- through whatever path. P1 accepted that an assigner may reassign a task to themselves and finish it; this is how that stays visible.
-- A path with no signed-in user (service role, scheduled job) is logged with no actor.
create or replace function public._trg_task_log_changes()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor text := (select p.full_name from public.profiles p where p.id = auth.uid());
begin
  if new.assignee_id is distinct from old.assignee_id then
    insert into public.task_logs (org_id, task_id, kind, created_by, actor_name, from_user, to_user, from_name, to_name)
    values (new.org_id, new.id, 'reassigned', auth.uid(), v_actor, old.assignee_id, new.assignee_id,
            (select p.full_name from public.profiles p where p.id = old.assignee_id),
            (select p.full_name from public.profiles p where p.id = new.assignee_id));
  end if;
  if new.status is distinct from old.status then
    insert into public.task_logs (org_id, task_id, kind, created_by, actor_name, from_value, to_value)
    values (new.org_id, new.id, 'status', auth.uid(), v_actor, old.status::text, new.status::text);
  end if;
  if new.due_date is distinct from old.due_date then
    insert into public.task_logs (org_id, task_id, kind, created_by, actor_name, from_value, to_value)
    values (new.org_id, new.id, 'due_moved', auth.uid(), v_actor, old.due_date::text, new.due_date::text);
  end if;
  return new;
end;
$$;
revoke all on function public._trg_task_log_changes() from public, anon, authenticated;
drop trigger if exists zz_tasks_log_changes on public.tasks;
create trigger zz_tasks_log_changes
  after update of assignee_id, status, due_date on public.tasks
  for each row execute function public._trg_task_log_changes();

-- 3. who sees a task ------------------------------------------------------------------------------------------------------
-- Master and operation_admin: every task of the organisation. Everyone else (sales_admin, technician): the tasks assigned to
-- them and the tasks they assigned. The base condition (staff, or an active technician) is unchanged. Insert, update and delete
-- policies are not touched here.
drop policy if exists tasks_select_internal on public.tasks;
create policy tasks_select_internal on public.tasks
  for select using (
    org_id = public.current_org_id()
    and (public.is_staff() or public.current_technician_id() is not null)
    and (public.is_ops_staff() or assignee_id = auth.uid() or assigned_by = auth.uid())
  );

notify pgrst, 'reload schema';
$p3$;
  v_hash := encode(sha256(convert_to(replace(v_text, E'\r', ''), 'UTF8')), 'hex');
  if v_hash <> '99990dde17cceb8485d5adc12bc4776906557a615341a4c0dbd04bf65238d6d5' then
    raise exception 'REHEARSAL_REFUSED: hash mismatch for 20261103100000_task_logs_and_visibility.sql (P3): %', v_hash;
  end if;
  execute replace(v_text, E'\r', '');

  v_text := $rh0$-- Window P, Step 3 verification follow-up (client items 3 and 5).
--
--   1. _trg_meeting_issue_notify (20261102100000) notified the master only when a huddle problem was raised,
--      a solution given, or an issue solved. The acceptance criterion is master AND operation_admin. Fixes the
--      role filter from = 'master' to in ('master', 'operation_admin').
--   2. task_minute_totals / person_minute_totals: plain views over task_logs so a screen can show total time
--      logged per task and cumulative per person, without pulling every log row client-side. These are views,
--      not functions, and carry no privilege of their own to leak: WITH (security_invoker = true) makes
--      Postgres evaluate task_logs' and tasks' row security as the CALLING role, not the view owner (the
--      migration runs as postgres, which bypasses RLS — without security_invoker a view created here would
--      silently show every organisation's data to every caller. PG15+, which this project runs on Supabase).
--
-- Rollback: supabase/rollbacks/20261109100000_huddle_notify_ops_and_task_minute_totals.rollback.sql

-- 1. the master AND operation_admin are told --------------------------------------------------------------------------
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
  where p.org_id = new.org_id and p.role::text in ('master', 'operation_admin') and p.is_active and p.id is distinct from auth.uid();
  return new;
end;
$$;
revoke all on function public._trg_meeting_issue_notify() from public, anon, authenticated;

-- 2. time totals --------------------------------------------------------------------------------------------------------
create view public.task_minute_totals
  with (security_invoker = true)
as
  select task_id, sum(minutes_spent) as total_minutes
  from public.task_logs
  where minutes_spent is not null
  group by task_id;
revoke all on public.task_minute_totals from public, anon, authenticated;
grant select on public.task_minute_totals to authenticated;

create view public.person_minute_totals
  with (security_invoker = true)
as
  select t.assignee_id as profile_id, sum(l.minutes_spent) as total_minutes
  from public.task_logs l
  join public.tasks t on t.id = l.task_id
  where l.minutes_spent is not null and t.assignee_id is not null
  group by t.assignee_id;
revoke all on public.person_minute_totals from public, anon, authenticated;
grant select on public.person_minute_totals to authenticated;

notify pgrst, 'reload schema';
$rh0$;
  v_hash := encode(sha256(convert_to(replace(v_text, E'\r', ''), 'UTF8')), 'hex');
  if v_hash <> '37d499edf565f3c140341888956c8341d45e73900b62b0a12a04baa7a9fed678' then
    raise exception 'REHEARSAL_REFUSED: hash mismatch for 20261109100000_huddle_notify_ops_and_task_minute_totals.sql: %', v_hash;
  end if;
  execute replace(v_text, E'\r', '');

  v_text := $rh1$-- DB tests for 20261109100000_huddle_notify_ops_and_task_minute_totals. NOT RUN (written for review). Run only through the approved
-- rehearsal wrapper (migration then this file, one request, ends in an unconditional RAISE). Throwaway __TEST_ organisation only.
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
create function pg_temp.as_pg() returns void language plpgsql as $f$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $f$;
create function pg_temp.raises(p_sql text) returns text language plpgsql as $f$
begin execute p_sql; return null;
exception when others then return sqlerrm; end $f$;

do $t$
declare
  v_org uuid; v_org2 uuid; v_master uuid; v_ops uuid; v_sales uuid; v_tp uuid; v_tech uuid; v_m2 uuid;
  v_issue uuid; v_task uuid; v_task2 uuid; s text; n int; v_base text; v_now text;
begin
  insert into organizations (name) values ('__TEST_huddlenotify') returning id into v_org;
  insert into organizations (name) values ('__TEST_huddlenotify_other') returning id into v_org2;
  insert into settings (org_id) values (v_org) on conflict (org_id) do nothing;
  v_master := pg_temp.mkuser('master', v_org);
  v_ops := pg_temp.mkuser('operation_admin', v_org);
  v_sales := pg_temp.mkuser('sales_admin', v_org);
  v_tp := pg_temp.mkuser('technician', v_org);
  v_m2 := pg_temp.mkuser('master', v_org2);
  insert into technicians (org_id, profile_id, is_active) values (v_org, v_tp, true) returning id into v_tech;

  -- ---------- structure ----------
  perform pg_temp.chk('_trg_meeting_issue_notify is SECURITY DEFINER with a fixed search_path (unchanged privilege shape)',
    (select prosecdef and coalesce(proconfig::text like '%search_path=%', false) from pg_proc where pronamespace = 'public'::regnamespace and proname = '_trg_meeting_issue_notify'));
  perform pg_temp.chk('the two new views exist and are not directly writable by anyone',
    to_regclass('public.task_minute_totals') is not null and to_regclass('public.person_minute_totals') is not null
    and not has_table_privilege('authenticated', 'public.task_minute_totals', 'INSERT')
    and not has_table_privilege('authenticated', 'public.person_minute_totals', 'INSERT')
    and not has_table_privilege('anon', 'public.task_minute_totals', 'SELECT')
    and not has_table_privilege('anon', 'public.person_minute_totals', 'SELECT'));
  perform pg_temp.chk('both views are security_invoker (so RLS on task_logs/tasks runs as the caller, not the view owner)',
    (select count(*) from pg_class where relname in ('task_minute_totals', 'person_minute_totals') and relnamespace = 'public'::regnamespace
       and reloptions is not null and array_to_string(reloptions, ',') like '%security_invoker=true%') = 2);

  -- ---------- item 3: raising a problem notifies BOTH master and operation_admin, not sales_admin ----------
  perform pg_temp.as_user(v_tp);
  select public.raise_huddle_issue('  The van GPS keeps dropping off during jobs  ') into v_issue;
  perform pg_temp.as_pg();
  select count(*) into n from notifications where org_id = v_org and user_id = v_master and type = 'huddle_problem_raised' and ref_id = v_issue;
  perform pg_temp.chk('master is notified when a problem is raised', n = 1, n::text);
  select count(*) into n from notifications where org_id = v_org and user_id = v_ops and type = 'huddle_problem_raised' and ref_id = v_issue;
  perform pg_temp.chk('REGRESSION FIX item 3: operation_admin is ALSO notified when a problem is raised (was master-only)', n = 1, n::text);
  select count(*) into n from notifications where org_id = v_org and user_id = v_sales and type = 'huddle_problem_raised' and ref_id = v_issue;
  perform pg_temp.chk('sales_admin is not notified (only master and operation_admin)', n = 0, n::text);

  -- ---------- a solution and then solved: both master and operation_admin are told each time ----------
  perform pg_temp.as_user(v_sales);
  perform public.propose_huddle_solution(v_issue, 'Replaced the GPS unit and retested on a 20km route');
  perform pg_temp.as_pg();
  select count(*) into n from notifications where org_id = v_org and user_id = v_ops and type = 'huddle_solution_given' and ref_id = v_issue;
  perform pg_temp.chk('operation_admin is notified when a solution is given', n = 1, n::text);
  perform pg_temp.as_user(v_sales);
  s := pg_temp.raises(format($q$update meeting_issues set status = 'solved' where id = %L$q$, v_issue));
  perform pg_temp.as_pg();
  perform pg_temp.chk('the update itself succeeds', s is null, coalesce(s, 'ok'));
  select count(*) into n from notifications where org_id = v_org and user_id = v_ops and type = 'huddle_issue_solved' and ref_id = v_issue;
  perform pg_temp.chk('operation_admin is notified when the issue is marked solved', n = 1, n::text);
  select count(*) into n from notifications where org_id = v_org and user_id = v_master and type = 'huddle_issue_solved' and ref_id = v_issue;
  perform pg_temp.chk('master is still notified when the issue is marked solved', n = 1, n::text);
  perform pg_temp.chk('raised_by/solved_by/solution_by are stamped (acceptance criteria 3)',
    (select raised_by = v_tp and solution_by = v_sales and solved_by = v_sales from meeting_issues where id = v_issue));

  -- ---------- item 5: total minutes, per task and per person ----------
  insert into tasks (org_id, assignee_id, assigned_by, title) values (v_org, v_tp, v_master, '__TEST_ task A') returning id into v_task;
  insert into tasks (org_id, assignee_id, assigned_by, title) values (v_org, v_tp, v_master, '__TEST_ task B') returning id into v_task2;
  insert into task_logs (org_id, task_id, kind, minutes_spent) values (v_org, v_task, 'note', 30), (v_org, v_task, 'note', 45), (v_org, v_task2, 'note', 20);
  perform pg_temp.as_user(v_ops);
  select total_minutes into n from task_minute_totals where task_id = v_task;
  perform pg_temp.chk('per-task total sums every log entry for that task', n = 75, n::text);
  select total_minutes into n from person_minute_totals where profile_id = v_tp;
  perform pg_temp.chk('per-person total sums every task the person is assigned', n = 95, n::text);
  perform pg_temp.as_pg();

  -- ---------- security_invoker actually isolates by org (the reason it was added) ----------
  perform pg_temp.as_user(v_m2);
  select count(*) into n from task_minute_totals;
  perform pg_temp.chk('a different organisation''s master sees no task_minute_totals rows at all (security_invoker; views do not bypass RLS)', n = 0, n::text);
  select count(*) into n from person_minute_totals;
  perform pg_temp.chk('and no person_minute_totals rows either', n = 0, n::text);
  perform pg_temp.as_pg();

  -- ---------- org scope on the huddle notification itself ----------
  perform pg_temp.as_user(v_m2);
  select count(*) into n from notifications where ref_id = v_issue;
  perform pg_temp.chk('another organisation''s master was never notified about this organisation''s huddle issue', n = 0, n::text);
  perform pg_temp.as_pg();

  -- ---------- real data: relative to the baseline the wrapper took before the migration ----------
  begin
    v_base := current_setting('gv.baseline', true);
    v_now := pg_temp.gv_fingerprint();
    perform pg_temp.chk('the REAL organisations'' notifications/meeting_issues/task_logs are unchanged by the migration and these tests',
      v_base is not null and v_base = v_now, coalesce(left(v_base, 40), 'no baseline') || ' / ' || coalesce(left(v_now, 40), '-'));
  exception when undefined_function then
    perform pg_temp.chk('real-data fingerprint skipped: this file was not run through the wrapper (no baseline)', true);
  end;

  raise exception 'RESULTS%', E'\n' || (select string_agg(r2.line, E'\n' order by r2.n) from pg_temp.res r2);
end $t$;
$rh1$;
  v_hash := encode(sha256(convert_to(replace(v_text, E'\r', ''), 'UTF8')), 'hex');
  if v_hash <> '21a2b92549424730f1fdb60449117dffae8f8575791e1c5ffac7e3812814aafa' then
    raise exception 'REHEARSAL_REFUSED: hash mismatch for huddle_notify_ops_and_task_minute_totals.test.sql: %', v_hash;
  end if;
  execute replace(v_text, E'\r', '');

  raise exception 'REHEARSAL_DID_NOT_RAISE: the test file should have raised RESULTS';
end
$rehearsal$;
