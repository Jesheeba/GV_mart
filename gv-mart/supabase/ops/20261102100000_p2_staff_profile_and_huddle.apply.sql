-- GO APPLY script for migration 20261102100000_p2_staff_profile_and_huddle.sql (P2: staff profile fields,
-- private address table, forced password change, task colours, huddle attribution/notification,
-- technician-raised huddle issues), commit 6603794 on integration/p-series.
--
-- WRITTEN ONLY -- never executed against any database by the agent that produced this file (standing hard
-- rule: no DB access of any kind). The owner runs this by hand, after 11:00 IST, once satisfied the
-- sha256-pinned migration text embedded below is byte-for-byte the reviewed migration file (sha256
-- 17538d3073a53eb23ed65ee4f2e333f7f1aeb64a35a6b854920c63a5c704067e), and that the live rehearsal of this
-- exact migration (rehearsal_20261102100000_p2_staff_profile_and_huddle.sql, wrapper sha256
-- ab58ffee0b16f46dec98bb138b405c638a97de3acbbc30578384fb96e98b6a27) came back clean.
--
-- Structure: no top-level BEGIN;/COMMIT; -- a single standalone DO block run under autocommit is already
-- atomic. Three statements total: (1) CREATE TEMP TABLE for the status row, autocommitted on its own;
-- (2) the DO block itself; (3) a read-only SELECT from that temp table. Unlike the rehearsal wrapper, THIS
-- SCRIPT IS MEANT TO COMMIT -- no embedded test, no forced closing RAISE.
--
-- UPDATE/BACKFILL: YES -- public.profiles.task_color. Section 5 of the migration numbers every existing
-- non-customer profile per organisation (by created_at, id) and backfills a deterministic golden-angle-hue
-- colour via a single `update ... from (select row_number() ...) ranked`. This is the ONLY row-data write
-- in the whole migration. Everything else is schema (3 new columns on profiles, 2 new columns on
-- meeting_issues, 2 brand-new tables) or new/redefined objects (10 brand-new functions, 1 redefined
-- function, several new triggers and RLS policies). Because of this backfill, the real-table fingerprint
-- below -- same formula the rehearsal used -- deliberately EXCLUDES task_color (and designation,
-- must_change_password, solution_by, solved_by -- the other new columns, which stay at their defaults for
-- existing rows and so are not expected to change, but are excluded anyway for exact parity with the
-- rehearsal's own baseline formula) so the check still proves nothing else about these rows moved.
--
-- Order of operations inside the DO block:
--   0. ORG CHECK    -- md5(id||'|'||name) of the oldest real (non __TEST_) organisation must equal the
--      pinned fingerprint 6f891cf85011f08c2f22fb4a208d21bd.
--   1. LOCK         -- lock_timeout = 5s for this transaction only.
--   2. GATE         -- refuses before 11:00 IST (owner decision, 2026-10-28, applies to every GO APPLY
--      script in this release window).
--   3. ALREADY-REGISTERED CHECK -- if supabase_migrations.schema_migrations already has a row for version
--      20261102100000, refuse immediately.
--   4. LIVE-DEFINITION PRE-CHECK -- public.wa_send_huddle_reminder(uuid) is the ONE function this
--      migration redefines (created by 20260929100000_daily_huddle_log.sql; the only change is the
--      not-exists test for what counts as "huddle held"). GV_PRECHECK_PROBE pattern: hash the live
--      definition, apply the pinned pre-P2 text inside a sub-block that always rolls back, hash again,
--      compare.
--   5. NEW-OBJECT PRE-CHECK -- this migration creates 10 brand-new functions via `create or replace
--      function`, which (unlike a bare `create function`) would silently OVERWRITE an unexpected
--      pre-existing function of the same name/signature rather than erroring. Each of the 10 is checked
--      with to_regprocedure() and must be NULL (not already exist) before RUN. The 2 brand-new tables
--      (profile_password_markers, staff_private) use plain `create table` with no IF NOT EXISTS, so
--      Postgres's own DDL would already refuse and roll the whole block back if either existed -- no
--      explicit pre-check needed for those two, but to_regclass() is still used defensively in the status
--      row / snapshot for visibility.
--   6. REAL-TABLE FINGERPRINT (BEFORE) -- profiles (id/org_id/role/is_active/full_name/phone, excluding the
--      new columns) + meeting_issues (id/status/description/raised_by/solution, excluding the new
--      solution_by/solved_by columns) + huddle-type notifications count + meeting_logs count, over REAL
--      organisations only -- the exact formula the rehearsal used for its baseline.
--   7. LEAK SNAPSHOT (BEFORE) -- the full list of public-schema functions already executable by
--      PUBLIC/anon.
--   8. PIN         -- CR-tolerant sha256 of the embedded migration text must equal the pinned LF hash.
--   9. RUN         -- EXECUTE the pinned migration text verbatim (CR-tolerant). This single EXECUTE
--      includes the task_color backfill UPDATE described above.
--   10. REGISTER   -- INSERT the version row into supabase_migrations.schema_migrations, in the same
--      transaction as the migration itself.
--   11. POST-APPLY CHECKS (read-only, each raises immediately if wrong):
--      11a. all 10 new functions AND the 2 new tables now exist;
--      11b. DIFF-BASED leak check -- recompute the PUBLIC/anon-executable function list and diff it
--          against the BEFORE snapshot. Only functions NEWLY present fail this check;
--      11c. ABSOLUTE anon-exec check -- anon/PUBLIC must not be able to execute ANY of the 11 functions
--          this migration creates or redefines (the 10 new ones plus wa_send_huddle_reminder), regardless
--          of what 11b finds. complete_forced_password_change/raise_huddle_issue/propose_huddle_solution
--          ARE meant to be callable by `authenticated` (checked separately, informationally, in the status
--          row) -- only the anon/PUBLIC grant is an absolute refusal;
--      11d. the real profiles/meeting_issues/notifications/meeting_logs fingerprint (same fields as step 6)
--          is unchanged from step 6.
--   12. On success, INSERT the one status row into pg_temp.p2_staff_profile_and_huddle_apply_status.
--
-- No test file is embedded and there is no rollback script invoked here: the rollback for this migration
-- already exists separately at supabase/rollbacks/20261102100000_p2_staff_profile_and_huddle.rollback.sql
-- and is run by hand, outside this script, only if the owner decides afterwards to undo the change.

-- 1. Status table -- autocommitted on its own, independent of the DO block's outcome.
drop table if exists pg_temp.p2_staff_profile_and_huddle_apply_status;
create temp table p2_staff_profile_and_huddle_apply_status (
  migration_version               text,
  version_registered              boolean,
  new_objects_exist                boolean,
  functions_executable_by_anon     boolean,
  client_functions_executable_by_authenticated  boolean,
  newly_leaked_functions           text[],
  table_fingerprint_before         text,
  table_fingerprint_after          text,
  table_fingerprint_unchanged      boolean,
  applied_at                       timestamptz
);

-- 2. The apply itself -- one DO block, atomic as a whole.
do $apply$
declare
  v_ist_hour                 int;
  v_expected_org_fingerprint text := '6f891cf85011f08c2f22fb4a208d21bd';
  v_org_fingerprint          text;
  v_expected_migration_hash  text := '17538d3073a53eb23ed65ee4f2e333f7f1aeb64a35a6b854920c63a5c704067e';
  v_actual_migration_hash    text;
  v_migration_version        text := '20261102100000';
  v_already_registered       boolean;
  v_text                     text;
  v_hash                     text;
  v_live                     text;
  v_orig                     text;
  v_sig                      text;
  v_new_sigs                 text[] := array[
    'public.guard_profile_staff_fields()',
    'public._trg_profile_password_marker()',
    'public.arm_forced_password_change(uuid)',
    'public.complete_forced_password_change()',
    'public._hsl_hex(numeric, numeric, numeric)',
    'public._trg_profile_assign_color()',
    'public._trg_meeting_issue_stamp()',
    'public._trg_meeting_issue_notify()',
    'public.raise_huddle_issue(text)',
    'public.propose_huddle_solution(uuid, text)'
  ];
  v_all_sigs_for_anon_check  text[];
  v_new_objects_exist        boolean := true;
  v_anon_exec                boolean := false;
  v_auth_exec                boolean := true;
  v_leaked_before            text[];
  v_leaked_after             text[];
  v_newly_leaked             text[];
  v_fp_before                text;
  v_fp_after                 text;
  v_embedded_migration       text := $p2mig$-- P2 (client list 12-10-2026 items 3 and 7). Design: gv-mart/docs/design-p2-staff-profile-huddle.md
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
$p2mig$;
begin
  -- 0. ORG CHECK
  select md5(o.id::text || '|' || o.name) into v_org_fingerprint
  from public.organizations o
  where o.name not like '\_\_TEST%' escape '\'
  order by o.created_at asc
  limit 1;

  if v_org_fingerprint is distinct from v_expected_org_fingerprint then
    raise exception 'APPLY_REFUSED: organisation fingerprint mismatch (expected %, got %)',
      v_expected_org_fingerprint, v_org_fingerprint;
  end if;

  -- 1. LOCK: scoped to this transaction only.
  perform set_config('lock_timeout', '5s', true);

  -- 2. GATE -- 11:00 IST (owner decision, 2026-10-28).
  v_ist_hour := extract(hour from (now() at time zone 'Asia/Kolkata'))::int;
  if v_ist_hour < 11 then
    raise exception 'APPLY_REFUSED: this script only runs after 11:00 IST (current IST hour=%)', v_ist_hour;
  end if;

  -- 3. ALREADY-REGISTERED CHECK
  select exists(
    select 1 from supabase_migrations.schema_migrations where version = v_migration_version
  ) into v_already_registered;

  if v_already_registered then
    raise exception 'APPLY_REFUSED: migration % is already registered in supabase_migrations.schema_migrations -- stop, nothing applied',
      v_migration_version;
  end if;

  -- 4. LIVE-DEFINITION PRE-CHECK -- public.wa_send_huddle_reminder(uuid) must still be the definition the
  -- last migration (20260929100000) gave it.
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
  v_hash := encode(sha256(convert_to(replace(v_text, E'\r', ''), 'UTF8')), 'hex');
  if v_hash <> 'd65d7395d458ac117593cedf6c1e61638b261e0e8204773cf57b03f6ecf90bfc' then
    raise exception 'APPLY_REFUSED: pre-check snippet hash mismatch (wa_send_huddle_reminder): %', v_hash;
  end if;
  v_live := md5(pg_get_functiondef('public.wa_send_huddle_reminder(uuid)'::regprocedure));
  begin
    execute replace(v_text, E'\r', '');
    v_orig := md5(pg_get_functiondef('public.wa_send_huddle_reminder(uuid)'::regprocedure));
    raise exception 'GV_PRECHECK_PROBE';
  exception when others then
    if sqlerrm <> 'GV_PRECHECK_PROBE' then raise; end if;
  end;
  if v_orig is distinct from v_live then
    raise exception 'APPLY_REFUSED: live public.wa_send_huddle_reminder(uuid) (md5 %) differs from its last migration definition (md5 %) -- something else changed it since this script was approved',
      v_live, v_orig;
  end if;

  -- 5. NEW-OBJECT PRE-CHECK -- none of the 10 brand-new functions this migration creates via
  -- `create or replace function` may already exist (that statement would silently overwrite an unexpected
  -- pre-existing function of the same name/signature rather than erroring).
  foreach v_sig in array v_new_sigs loop
    if to_regprocedure(v_sig) is not null then
      raise exception 'APPLY_REFUSED: % already exists live before this migration ran (expected: does not exist yet)', v_sig;
    end if;
  end loop;
  if to_regclass('public.profile_password_markers') is not null then
    raise exception 'APPLY_REFUSED: public.profile_password_markers already exists live before this migration ran';
  end if;
  if to_regclass('public.staff_private') is not null then
    raise exception 'APPLY_REFUSED: public.staff_private already exists live before this migration ran';
  end if;

  -- 6. REAL-TABLE FINGERPRINT (BEFORE) -- profiles + meeting_issues + huddle notifications + meeting_logs,
  -- REAL organisations only, excluding every column this migration adds (same formula the rehearsal used).
  select md5(coalesce((select string_agg(p.id::text || ':' || p.org_id::text || ':' || p.role::text || ':' || p.is_active::text || ':' || p.full_name || ':' || coalesce(p.phone, ''), ',' order by p.id)
                     from public.profiles p where p.org_id in (select o.id from public.organizations o where o.name not like '\_\_TEST\_%')), ''))
         || '|' || md5(coalesce((select string_agg(i.id::text || ':' || i.status || ':' || i.description || ':' || coalesce(i.raised_by::text, '-') || ':' || coalesce(i.solution, ''), ',' order by i.id)
                     from public.meeting_issues i where i.org_id in (select o.id from public.organizations o where o.name not like '\_\_TEST\_%')), ''))
         || '|' || (select count(*)::text from public.notifications n where n.org_id in (select o.id from public.organizations o where o.name not like '\_\_TEST\_%') and n.type like 'huddle\_%')
         || '|' || (select count(*)::text from public.meeting_logs m where m.org_id in (select o.id from public.organizations o where o.name not like '\_\_TEST\_%'))
    into v_fp_before;

  -- 7. LEAK SNAPSHOT (BEFORE) -- every public-schema function already executable by PUBLIC/anon.
  select coalesce(array_agg(sig order by sig), array[]::text[]) into v_leaked_before
  from (
    select distinct (p.oid::regprocedure)::text as sig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
    where n.nspname = 'public'
      and a.privilege_type = 'EXECUTE'
      and (a.grantee = 0 or a.grantee = (select oid from pg_roles where rolname = 'anon'))
  ) s;

  -- 8. PIN -- CR-tolerant sha256 of the embedded migration text must equal the pinned LF hash.
  v_actual_migration_hash := encode(sha256(convert_to(replace(v_embedded_migration, E'\r', ''), 'UTF8')), 'hex');
  if v_actual_migration_hash is distinct from v_expected_migration_hash then
    raise exception 'APPLY_REFUSED: embedded migration text does not match its pinned sha256 (expected %, got %)',
      v_expected_migration_hash, v_actual_migration_hash;
  end if;

  -- 9. RUN -- apply the pinned migration text verbatim (CR-tolerant). Includes the task_color backfill.
  execute replace(v_embedded_migration, E'\r', '');

  -- 10. REGISTER -- record this migration as applied, in the same transaction as the migration itself.
  insert into supabase_migrations.schema_migrations (version, name, statements)
  values (v_migration_version, 'p2_staff_profile_and_huddle', array[replace(v_embedded_migration, E'\r', '')]);

  -- 11a. all 10 new functions and the 2 new tables now exist.
  foreach v_sig in array v_new_sigs loop
    if to_regprocedure(v_sig) is null then
      v_new_objects_exist := false;
      raise exception 'APPLY_REFUSED: post-apply check failed -- % does not exist after the migration ran', v_sig;
    end if;
  end loop;
  if to_regclass('public.profile_password_markers') is null then
    raise exception 'APPLY_REFUSED: post-apply check failed -- public.profile_password_markers does not exist after the migration ran';
  end if;
  if to_regclass('public.staff_private') is null then
    raise exception 'APPLY_REFUSED: post-apply check failed -- public.staff_private does not exist after the migration ran';
  end if;

  -- 11b. DIFF-BASED leak check -- only entries NEW (present after, absent before) fail this check.
  select coalesce(array_agg(sig order by sig), array[]::text[]) into v_leaked_after
  from (
    select distinct (p.oid::regprocedure)::text as sig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
    where n.nspname = 'public'
      and a.privilege_type = 'EXECUTE'
      and (a.grantee = 0 or a.grantee = (select oid from pg_roles where rolname = 'anon'))
  ) s;

  select coalesce(array_agg(x order by x), array[]::text[]) into v_newly_leaked
  from (
    select unnest(v_leaked_after) as x
    except
    select unnest(v_leaked_before)
  ) d;

  if array_length(v_newly_leaked, 1) is not null then
    raise exception 'APPLY_REFUSED: post-apply check failed -- this migration newly exposed % function(s) to PUBLIC/anon that were not executable before it ran: %',
      array_length(v_newly_leaked, 1), v_newly_leaked;
  end if;

  -- 11c. ABSOLUTE anon-exec check -- anon/PUBLIC must not execute ANY of the 11 functions this migration
  -- creates or redefines, independent of 11b.
  v_all_sigs_for_anon_check := v_new_sigs || array['public.wa_send_huddle_reminder(uuid)'];
  foreach v_sig in array v_all_sigs_for_anon_check loop
    if has_function_privilege('anon', v_sig, 'EXECUTE') then
      v_anon_exec := true;
      raise exception 'APPLY_REFUSED: post-apply check failed -- % is executable by anon/PUBLIC', v_sig;
    end if;
  end loop;
  -- informational only (not enforced as a refusal): the three client-facing functions must still be
  -- callable by `authenticated`, i.e. the migration's own grants took effect.
  select has_function_privilege('authenticated', 'public.complete_forced_password_change()', 'EXECUTE')
         and has_function_privilege('authenticated', 'public.raise_huddle_issue(text)', 'EXECUTE')
         and has_function_privilege('authenticated', 'public.propose_huddle_solution(uuid, text)', 'EXECUTE')
    into v_auth_exec;

  -- 11d. the real profiles/meeting_issues/notifications/meeting_logs fingerprint is unchanged.
  select md5(coalesce((select string_agg(p.id::text || ':' || p.org_id::text || ':' || p.role::text || ':' || p.is_active::text || ':' || p.full_name || ':' || coalesce(p.phone, ''), ',' order by p.id)
                     from public.profiles p where p.org_id in (select o.id from public.organizations o where o.name not like '\_\_TEST\_%')), ''))
         || '|' || md5(coalesce((select string_agg(i.id::text || ':' || i.status || ':' || i.description || ':' || coalesce(i.raised_by::text, '-') || ':' || coalesce(i.solution, ''), ',' order by i.id)
                     from public.meeting_issues i where i.org_id in (select o.id from public.organizations o where o.name not like '\_\_TEST\_%')), ''))
         || '|' || (select count(*)::text from public.notifications n where n.org_id in (select o.id from public.organizations o where o.name not like '\_\_TEST\_%') and n.type like 'huddle\_%')
         || '|' || (select count(*)::text from public.meeting_logs m where m.org_id in (select o.id from public.organizations o where o.name not like '\_\_TEST\_%'))
    into v_fp_after;

  if v_fp_after is distinct from v_fp_before then
    raise exception 'APPLY_REFUSED: post-apply check failed -- real profiles/meeting_issues/notifications/meeting_logs fingerprint changed (before %, after %)',
      v_fp_before, v_fp_after;
  end if;

  -- 12. Every step above passed -- record the one status row.
  insert into pg_temp.p2_staff_profile_and_huddle_apply_status (
    migration_version, version_registered, new_objects_exist, functions_executable_by_anon,
    client_functions_executable_by_authenticated, newly_leaked_functions,
    table_fingerprint_before, table_fingerprint_after, table_fingerprint_unchanged, applied_at
  )
  values (
    v_migration_version, true, v_new_objects_exist, v_anon_exec,
    v_auth_exec, v_newly_leaked, v_fp_before, v_fp_after,
    (v_fp_after = v_fp_before), now()
  );
end
$apply$;

-- 3. The actual thing to look at: one row on success, zero rows if the DO block raised and rolled back.
select * from pg_temp.p2_staff_profile_and_huddle_apply_status;
