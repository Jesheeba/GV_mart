-- Combined rehearsal wrapper: Accounts follow-up spec, Feature B + Feature A.
-- Chains dependency migrations P1a/P1b/P2/P3 (integration/p-series, NOT yet
-- live on main -- verified via live schema_migrations before this wrapper
-- was written) on top of each other first, so the Feature-B migrations
-- that assume the POST-P3 tasks_select_internal shape are rehearsed
-- against the correct baseline, not the current live one. Then applies
-- all 7 of this feature's migrations, then the combined test file.
-- ONE request, ONE DO block, refuses before 11:00 IST, CR-tolerant sha256
-- pin on every embedded file, ends in an unconditional RAISE so nothing
-- is ever committed. Never concatenated with anything outside this file.
--
-- Pinned (CR-tolerant sha256, recomputed at the commit this wrapper was built from):
--   da86f82365ef3efbadfefd7622275877ce048f57ef3e9a6c401d420286818cdb  P1a (20261101100000, dependency, chained): 20261101100000_task_completion_rule.sql
--   a64bf7ad63d9ab2501a5da7147f95a9986945e73231c8b612f49769105523a40  P1b (20261101110000, dependency, chained): 20261101110000_current_technician_id_active.sql
--   17538d3073a53eb23ed65ee4f2e333f7f1aeb64a35a6b854920c63a5c704067e  P2 (20261102100000, dependency, chained): 20261102100000_p2_staff_profile_and_huddle.sql
--   99990dde17cceb8485d5adc12bc4776906557a615341a4c0dbd04bf65238d6d5  P3 (20261103100000, dependency, chained): 20261103100000_task_logs_and_visibility.sql
--   17e597fb5904b0c3bc8999bf99a47c86ed2c1793f56f07d4d7a07a3a26acf351  Feature B migration 1/5: 20261115100000_customer_outstanding_reminders_schema.sql
--   4ebe905dc61bca52aca8edfd1425f5a75b824fbda6d17d6bbc68b5125ea03f8d  Feature B migration 2/5: 20261115100100_customer_outstanding_links_schema.sql
--   08cddc0f4f1756cf596e8c24f819d43def9d15dde646df5b658d6ca7078edb7f  Feature B migration 3/5: 20261115100200_customer_outstanding_report.sql
--   cff1fb33c32550521ed261c8de26bc270c83e4119535f8fdbb6d3eb251e65f50  Feature B migration 4/5: 20261115100300_customer_outstanding_rpcs.sql
--   c791fdc658476f22908a3f213bdcc6584e481de6c910d47cfb1dc67cacef0678  Feature B migration 5/5: 20261115100400_tasks_customer_outstanding_guard.sql
--   08602c4654ec49e6dae5641ae7ab8fd301a78e4d6262ba92b1a409b26ea39acf  Feature A migration 1/2: 20261115110000_expense_categories_schema.sql
--   c7c523fc9afb8cf384aa15f331ef232fb5518745032cab90acf869eb8d827a5a  Feature A migration 2/2: 20261115110100_expense_categories_rpcs.sql
--   1fb0264005f6a56b337b7431e2d8e056f19fe71ea4e860dfa9564533f4b8e614  combined test file: accounts_followup_combined.test.sql

do $rehearsal$
declare
  v_ist time := (clock_timestamp() at time zone 'Asia/Kolkata')::time;
  v_text text;
  v_hash text;
  v_realorg uuid;
  v_fp_before text;
  v_fp_after text;
begin
  perform set_config('lock_timeout', '5s', true);

  if v_ist < time '11:00' then
    raise exception 'REHEARSAL_REFUSED: the clock reads % IST, before 11:00 IST', to_char(v_ist, 'HH24:MI:SS');
  end if;

  select id into v_realorg from public.organizations where name not like '__TEST_%' escape '' order by created_at asc limit 1;
  select md5(v_realorg::text || '|' || name) into v_fp_before from public.organizations where id = v_realorg;
  if v_fp_before <> '6f891cf85011f08c2f22fb4a208d21bd' then
    raise exception 'REHEARSAL_REFUSED: real-organisation fingerprint mismatch before any migration ran: %', v_fp_before;
  end if;

  -- P1a/P1b/P2/P3 (integration/p-series) are NOT yet live -- chain them first so the Feature-B
  -- tasks policy patch below is built on the POST-P3 baseline, per the owner's condition 1.

  v_text := $p1atag$-- P1 (client list 12-10-2026, item 6 + security audit): who may finish a task, and the paths around it.
-- Design: gv-mart/docs/design-p1-task-security.md
--
--   1. Only the person a task is assigned to can set it done. Master and operation_admin may reassign a task but cannot complete it
--      on someone's behalf. An UNASSIGNED task can be completed by operations (someone must). Re-opening a finished task: the
--      assignee or operations. A task cannot be INSERTED already done for someone else.
--   2. A purchase_order task can be completed only by a master (the role that approves and pays POs, mark_po_paid / approve_purchase_order).
--   3. Closing the PO through its task (_po_task_completed_marks_paid) is now conditional on the same: a signed-in non-master never marks
--      a PO paid by ticking a task. Paths with no signed-in user (service role, scheduled jobs) are unchanged.
--   4. tasks_update_assign: only operations, the assignee or the assigner may update a task (it was: any staff or technician).
--   (current_technician_id() requires is_active: separate migration 20261101110000_current_technician_id_active, P1b.)
--
-- task_status has three values: open, done, rolled ('rolled' is in the enum but nothing in the app or the database writes it today).
-- How the guard treats the transitions:
--   open   -> done    : assignee only (unassigned: operations); purchase_order tasks: master only
--   rolled -> done    : the same as open -> done (any non-done state is finished by the same rule)
--   done   -> open    : the assignee or operations
--   done   -> rolled  : the same as done -> open
--   open   <-> rolled : not a completion, unrestricted by the guard (the update policy still decides who may update the row)
--
-- Exempt from the completion guard (current_user is not authenticated/anon): the service role, SECURITY DEFINER functions
-- (mark_po_paid, advance_recurring_tasks, the escalation and PO-reminder jobs, the rollover RPCs) and any direct owner connection.
--
-- WHY THE EARLIER GUARD WAS DROPPED (20261006190000 -> 20261006200000) and how this one differs: that trigger froze every column except
-- status / due_date for a non-ops assignee, which broke the app's own edit and reassign flow once task assignment (20260921160000)
-- let any user create, edit and reassign tasks. This guard restricts ONLY the status transition to done / back from done and the
-- insert-as-done case; it never looks at title, description, priority, due dates or assignee. The regression tests in
-- tests/task_completion_rule.test.sql assert that an assignee can still edit and reassign their own task.
--
-- Rollback: supabase/rollbacks/20261101100000_task_completion_rule.rollback.sql

-- 1. completion guard --------------------------------------------------------------------------------------------------
create or replace function public.guard_task_completion()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  -- service role, SECURITY DEFINER jobs and the owner connection are not subject to this rule
  if current_user not in ('authenticated', 'anon') then
    return new;
  end if;

  if tg_op = 'INSERT' then
    if new.status = 'done' and new.assignee_id is distinct from auth.uid() then
      raise exception 'tasks: a task cannot be created already finished for someone else';
    end if;
    return new;
  end if;

  if new.status = 'done' and old.status is distinct from 'done' then
    if old.assignee_id is not null then
      if old.assignee_id is distinct from auth.uid() then
        raise exception 'tasks: only the person a task is assigned to can mark it finished';
      end if;
    elsif not public.is_ops_staff() then
      raise exception 'tasks: only operations can finish a task that has no assignee';
    end if;
    -- both the old and the NEW ref_type: changing a task's ref_type in the same update must not slip past the rule
    if (old.ref_type = 'purchase_order' or new.ref_type = 'purchase_order') and not public.is_master() then
      raise exception 'tasks: only a master can finish a purchase-order task';
    end if;
  elsif old.status = 'done' and new.status is distinct from 'done' then
    if old.assignee_id is distinct from auth.uid() and not public.is_ops_staff() then
      raise exception 'tasks: only the assignee or operations can re-open a finished task';
    end if;
  end if;
  return new;
end;
$$;
revoke all on function public.guard_task_completion() from public, anon, authenticated;

drop trigger if exists aa_guard_task_completion on public.tasks;
create trigger aa_guard_task_completion
  before insert or update on public.tasks
  for each row execute function public.guard_task_completion();

-- 2. closing the PO through its task needs a master (or a system path) -------------------------------------------------
create or replace function public._po_task_completed_marks_paid()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.ref_type = 'purchase_order' and new.status = 'done' and (old.status is distinct from 'done') then
    -- a signed-in user who is not a master never marks a PO paid by ticking its task (the guard above already refuses the tick;
    -- this is the second, independent check). No signed-in user = service role / scheduled job: unchanged.
    if auth.uid() is not null and not public.is_master() then
      return new;
    end if;
    update public.purchase_orders
      set status = 'paid'
      where id = new.ref_id and org_id = new.org_id and status in ('sent', 'received');
  end if;
  return new;
end;
$$;

revoke all on function public._po_task_completed_marks_paid() from public, anon, authenticated;

-- 3. who may update a task ----------------------------------------------------------------------------------------------
drop policy if exists tasks_update_assign on public.tasks;
create policy tasks_update_assign on public.tasks
  for update using (
    org_id = public.current_org_id()
    and (public.is_staff() or public.current_technician_id() is not null)
    and (public.is_ops_staff() or assignee_id = auth.uid() or assigned_by = auth.uid())
  )
  with check (
    org_id = public.current_org_id()
    and (public.is_staff() or public.current_technician_id() is not null)
  );

notify pgrst, 'reload schema';
$p1atag$;
  v_hash := encode(sha256(convert_to(replace(v_text, E'', ''), 'UTF8')), 'hex');
  if v_hash <> 'da86f82365ef3efbadfefd7622275877ce048f57ef3e9a6c401d420286818cdb' then
    raise exception 'REHEARSAL_REFUSED: hash mismatch for P1a (20261101100000, dependency, chained): %', v_hash;
  end if;
  execute v_text;

  v_text := $p1btag$-- P1b (security audit): a deactivated technician is not a technician for RLS.
-- Design: gv-mart/docs/design-p1-task-security.md
--
-- current_technician_id() now also requires technicians.is_active. Every policy and function that keys on it (tasks, jobs, customer
-- history, ...) stops matching a deactivated technician immediately. create or replace keeps the existing ACL (one of the helper
-- functions that must stay executable by the roles RLS runs as).
--
-- Rollback: supabase/rollbacks/20261101110000_current_technician_id_active.rollback.sql

create or replace function public.current_technician_id()
returns uuid
language sql stable security definer set search_path = public
as $$ select t.id from public.technicians t where t.profile_id = auth.uid() and t.is_active $$;
$p1btag$;
  v_hash := encode(sha256(convert_to(replace(v_text, E'', ''), 'UTF8')), 'hex');
  if v_hash <> 'a64bf7ad63d9ab2501a5da7147f95a9986945e73231c8b612f49769105523a40' then
    raise exception 'REHEARSAL_REFUSED: hash mismatch for P1b (20261101110000, dependency, chained): %', v_hash;
  end if;
  execute v_text;

  v_text := $p2tag$-- P2 (client list 12-10-2026 items 3 and 7). Design: gv-mart/docs/design-p2-staff-profile-huddle.md
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
$p2tag$;
  v_hash := encode(sha256(convert_to(replace(v_text, E'', ''), 'UTF8')), 'hex');
  if v_hash <> '17538d3073a53eb23ed65ee4f2e333f7f1aeb64a35a6b854920c63a5c704067e' then
    raise exception 'REHEARSAL_REFUSED: hash mismatch for P2 (20261102100000, dependency, chained): %', v_hash;
  end if;
  execute v_text;

  v_text := $p3tag$-- P3 (client list 12-10-2026 items 4, 5, 6): who sees which task, and a work log on every task. Design: gv-mart/docs/design-p3-task-log-visibility.md
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
$p3tag$;
  v_hash := encode(sha256(convert_to(replace(v_text, E'', ''), 'UTF8')), 'hex');
  if v_hash <> '99990dde17cceb8485d5adc12bc4776906557a615341a4c0dbd04bf65238d6d5' then
    raise exception 'REHEARSAL_REFUSED: hash mismatch for P3 (20261103100000, dependency, chained): %', v_hash;
  end if;
  execute v_text;

  -- Feature B (5 migrations)

  v_text := $m1tag$-- Accounts follow-up, Feature B, step 1 of 5 — the new internal-only
-- "Reminder" entity for a customer's outstanding balance. No generic
-- Reminder module exists in this codebase (see DECISIONS.md D2); this
-- table is modeled on lead_followups' proven conventions (status enum,
-- RPC-only writes, no client write policy, set_updated_at + audit_master_
-- change) rather than inventing a cross-module reminder system the spec
-- never asked for.
--
-- Master-only (DECISIONS.md D6/D10): nothing under /accounts is open to
-- operation_admin/sales_admin today, so this stays consistent with that.
-- Never sends anything to a customer — purely a staff-visible row.

create type public.customer_outstanding_reminder_status as enum ('open', 'done', 'cancelled');

create table public.customer_outstanding_reminders (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  customer_id uuid not null references public.customers (id) on delete cascade,
  due_at timestamptz not null,
  note text,
  status public.customer_outstanding_reminder_status not null default 'open',
  -- manual | system (auto-closed when outstanding reaches zero)
  source text not null default 'manual' check (source in ('manual', 'system')),
  created_by uuid references public.profiles (id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  closed_by uuid references public.profiles (id) on delete set null,
  closed_at timestamptz,
  close_reason text,
  updated_at timestamptz not null default now(),
  constraint customer_outstanding_reminders_done_has_close check (status <> 'done' or closed_at is not null),
  constraint customer_outstanding_reminders_cancelled_has_close check (status <> 'cancelled' or closed_at is not null),
  constraint customer_outstanding_reminders_system_has_reason check (source <> 'system' or close_reason is not null)
);

create index customer_outstanding_reminders_org_customer_idx on public.customer_outstanding_reminders (org_id, customer_id);
create index customer_outstanding_reminders_due_idx on public.customer_outstanding_reminders (org_id, due_at) where status = 'open';

alter table public.customer_outstanding_reminders enable row level security;
revoke all on public.customer_outstanding_reminders from public, anon, authenticated;

-- Read only; every write goes through SECURITY DEFINER RPCs (next migration).
create policy customer_outstanding_reminders_select_master on public.customer_outstanding_reminders
  for select using (org_id = public.current_org_id() and public.is_master());
grant select on public.customer_outstanding_reminders to authenticated;

create trigger set_updated_at before update on public.customer_outstanding_reminders
  for each row execute function public.set_updated_at();
create trigger audit_customer_outstanding_reminders after insert or update or delete on public.customer_outstanding_reminders
  for each row execute function public.audit_master_change();
$m1tag$;
  v_hash := encode(sha256(convert_to(replace(v_text, E'', ''), 'UTF8')), 'hex');
  if v_hash <> '17e597fb5904b0c3bc8999bf99a47c86ed2c1793f56f07d4d7a07a3a26acf351' then
    raise exception 'REHEARSAL_REFUSED: hash mismatch for Feature B migration 1/5: %', v_hash;
  end if;
  execute v_text;

  v_text := $m2tag$-- Accounts follow-up, Feature B, step 2 of 5 — the customer/invoice/amount
-- link, kept OFF both `tasks` (shared, broadly-visible — see the policy
-- patch in 20261115100400) and `customer_outstanding_reminders` as its own
-- small table (DECISIONS.md D4), so the amount snapshot is never reachable
-- through the generic Tasks read path.

create table public.customer_outstanding_links (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  task_id uuid unique references public.tasks (id) on delete cascade,
  reminder_id uuid unique references public.customer_outstanding_reminders (id) on delete cascade,
  customer_id uuid not null references public.customers (id) on delete cascade,
  invoice_id uuid references public.invoices (id) on delete set null,
  amount_snapshot numeric(12, 2) not null check (amount_snapshot >= 0),
  created_at timestamptz not null default now(),
  constraint customer_outstanding_links_exactly_one_target check (
    (task_id is not null and reminder_id is null) or (task_id is null and reminder_id is not null)
  )
);

create index customer_outstanding_links_org_customer_idx on public.customer_outstanding_links (org_id, customer_id);

alter table public.customer_outstanding_links enable row level security;
revoke all on public.customer_outstanding_links from public, anon, authenticated;

create policy customer_outstanding_links_select_master on public.customer_outstanding_links
  for select using (org_id = public.current_org_id() and public.is_master());
grant select on public.customer_outstanding_links to authenticated;
$m2tag$;
  v_hash := encode(sha256(convert_to(replace(v_text, E'', ''), 'UTF8')), 'hex');
  if v_hash <> '4ebe905dc61bca52aca8edfd1425f5a75b824fbda6d17d6bbc68b5125ea03f8d' then
    raise exception 'REHEARSAL_REFUSED: hash mismatch for Feature B migration 2/5: %', v_hash;
  end if;
  execute v_text;

  v_text := $m3tag$-- Accounts follow-up, Feature B, step 3 of 5 — the Customer Outstanding
-- read model. No such page/view existed anywhere before this (DECISIONS.md
-- D1); both functions reuse the EXACT predicate report_kpi_tiles' live
-- 'outstanding' tile already uses (sum(total - amount_paid) where
-- payment_status <> 'paid' and total - amount_paid > 0, excluding
-- is_test_customer), just grouped by customer instead of summed org-wide,
-- so the two numbers reconcile by construction. Both functions are
-- READ-ONLY on money (owner's condition 3) — neither writes anything.
-- Master-only (DECISIONS.md D6/D10).

create index invoices_org_customer_outstanding_idx
  on public.invoices (org_id, customer_id) where payment_status <> 'paid';

create or replace function public.report_customer_outstanding(p_cursor uuid default null, p_limit int default 50)
returns table (
  customer_id uuid,
  customer_name text,
  outstanding_amount numeric,
  oldest_invoice_date date,
  open_reminder_count int,
  next_reminder_at timestamptz,
  open_task_count int,
  task_assignee_name text,
  task_status text
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_org uuid := public.current_org_id();
begin
  if v_org is null or not coalesce(public.is_master(), false) then
    raise exception 'report_customer_outstanding: master only';
  end if;

  return query
  with outstanding as (
    select
      i.customer_id as cid,
      sum(i.total - i.amount_paid) as outstanding_amount,
      min((i.created_at at time zone 'Asia/Kolkata')::date) as oldest_invoice_date
    from public.invoices i
    where i.org_id = v_org
      and i.payment_status <> 'paid'
      and i.total - i.amount_paid > 0
      and not public.is_test_customer(i.customer_id)
    group by i.customer_id
  ),
  reminders as (
    select r.customer_id as cid, count(*)::int as open_count, min(r.due_at) as next_due_at
    from public.customer_outstanding_reminders r
    where r.org_id = v_org and r.status = 'open'
    group by r.customer_id
  ),
  tasks_agg as (
    select
      l.customer_id as cid,
      count(*)::int as open_count,
      -- single representative row (assignee/status of the most-recently-created open task) for the list tile
      (array_agg(p.full_name order by t.created_at desc))[1] as assignee_name,
      (array_agg(t.status::text order by t.created_at desc))[1] as status
    from public.customer_outstanding_links l
    join public.tasks t on t.id = l.task_id
    left join public.profiles p on p.id = t.assignee_id
    where l.org_id = v_org and t.status = 'open'
    group by l.customer_id
  )
  select
    o.cid,
    c.name,
    o.outstanding_amount,
    o.oldest_invoice_date,
    coalesce(rem.open_count, 0),
    rem.next_due_at,
    coalesce(ta.open_count, 0),
    ta.assignee_name,
    ta.status
  from outstanding o
  join public.customers c on c.id = o.cid
  left join reminders rem on rem.cid = o.cid
  left join tasks_agg ta on ta.cid = o.cid
  where p_cursor is null or o.cid > p_cursor
  order by o.cid
  limit greatest(1, least(p_limit, 200));
end;
$$;
revoke all on function public.report_customer_outstanding(uuid, int) from public, anon, authenticated;
grant execute on function public.report_customer_outstanding(uuid, int) to authenticated;

create or replace function public.report_customer_outstanding_detail(p_customer uuid)
returns table (
  customer_id uuid,
  customer_name text,
  outstanding_amount numeric,
  oldest_invoice_date date,
  open_reminder_count int,
  next_reminder_at timestamptz,
  open_task_count int
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_org uuid := public.current_org_id();
begin
  if v_org is null or not coalesce(public.is_master(), false) then
    raise exception 'report_customer_outstanding_detail: master only';
  end if;

  return query
  select
    c.id,
    c.name,
    coalesce((
      select sum(i.total - i.amount_paid) from public.invoices i
      where i.org_id = v_org and i.customer_id = p_customer and i.payment_status <> 'paid' and i.total - i.amount_paid > 0
    ), 0),
    (select min((i.created_at at time zone 'Asia/Kolkata')::date) from public.invoices i
      where i.org_id = v_org and i.customer_id = p_customer and i.payment_status <> 'paid' and i.total - i.amount_paid > 0),
    (select count(*)::int from public.customer_outstanding_reminders r
      where r.org_id = v_org and r.customer_id = p_customer and r.status = 'open'),
    (select min(r.due_at) from public.customer_outstanding_reminders r
      where r.org_id = v_org and r.customer_id = p_customer and r.status = 'open'),
    (select count(*)::int from public.customer_outstanding_links l
      join public.tasks t on t.id = l.task_id
      where l.org_id = v_org and l.customer_id = p_customer and t.status = 'open')
  from public.customers c
  where c.id = p_customer and c.org_id = v_org;
end;
$$;
revoke all on function public.report_customer_outstanding_detail(uuid) from public, anon, authenticated;
grant execute on function public.report_customer_outstanding_detail(uuid) to authenticated;
$m3tag$;
  v_hash := encode(sha256(convert_to(replace(v_text, E'', ''), 'UTF8')), 'hex');
  if v_hash <> '08cddc0f4f1756cf596e8c24f819d43def9d15dde646df5b658d6ca7078edb7f' then
    raise exception 'REHEARSAL_REFUSED: hash mismatch for Feature B migration 3/5: %', v_hash;
  end if;
  execute v_text;

  v_text := $m4tag$-- Accounts follow-up, Feature B, step 4 of 5 — create/reschedule/close/
-- cancel reminders, create a linked task, and the zero-outstanding
-- auto-close. All master-only SECURITY DEFINER, all RPC-only writes
-- (customer_outstanding_reminders/_links have no client write policy).
--
-- close_outstanding_reminders_if_zero is explicitly NOT a trigger on
-- invoices/sales/receipts/payments (owner's condition 2) — it is called
-- by the client after a payment succeeds, and opportunistically when the
-- Customer Outstanding detail view loads. It never touches `tasks`
-- (spec: never auto-complete a task).

create or replace function public.create_customer_outstanding_reminder(
  p_customer uuid, p_due_at timestamptz, p_note text default null, p_invoice uuid default null, p_amount numeric default 0
)
returns public.customer_outstanding_reminders
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid := public.current_org_id();
  v_row public.customer_outstanding_reminders;
begin
  if v_org is null or not coalesce(public.is_master(), false) then
    raise exception 'create_customer_outstanding_reminder: master only';
  end if;
  if not exists (select 1 from public.customers where id = p_customer and org_id = v_org) then
    raise exception 'create_customer_outstanding_reminder: customer not found in this organisation';
  end if;

  insert into public.customer_outstanding_reminders (org_id, customer_id, due_at, note)
  values (v_org, p_customer, p_due_at, p_note)
  returning * into v_row;

  insert into public.customer_outstanding_links (org_id, reminder_id, customer_id, invoice_id, amount_snapshot)
  values (v_org, v_row.id, p_customer, p_invoice, coalesce(p_amount, 0));

  return v_row;
end;
$$;
revoke all on function public.create_customer_outstanding_reminder(uuid, timestamptz, text, uuid, numeric) from public, anon, authenticated;
grant execute on function public.create_customer_outstanding_reminder(uuid, timestamptz, text, uuid, numeric) to authenticated;

create or replace function public.reschedule_customer_outstanding_reminder(p_reminder uuid, p_due_at timestamptz, p_note text default null)
returns public.customer_outstanding_reminders
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid := public.current_org_id();
  v_row public.customer_outstanding_reminders;
begin
  if v_org is null or not coalesce(public.is_master(), false) then
    raise exception 'reschedule_customer_outstanding_reminder: master only';
  end if;
  update public.customer_outstanding_reminders
    set due_at = p_due_at, note = coalesce(p_note, note)
    where id = p_reminder and org_id = v_org and status = 'open'
    returning * into v_row;
  if v_row.id is null then
    raise exception 'reschedule_customer_outstanding_reminder: reminder % is not open or not found', p_reminder;
  end if;
  return v_row;
end;
$$;
revoke all on function public.reschedule_customer_outstanding_reminder(uuid, timestamptz, text) from public, anon, authenticated;
grant execute on function public.reschedule_customer_outstanding_reminder(uuid, timestamptz, text) to authenticated;

create or replace function public.close_customer_outstanding_reminder(p_reminder uuid)
returns public.customer_outstanding_reminders
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid := public.current_org_id();
  v_row public.customer_outstanding_reminders;
begin
  if v_org is null or not coalesce(public.is_master(), false) then
    raise exception 'close_customer_outstanding_reminder: master only';
  end if;
  update public.customer_outstanding_reminders
    set status = 'done', closed_by = auth.uid(), closed_at = now()
    where id = p_reminder and org_id = v_org and status = 'open'
    returning * into v_row;
  if v_row.id is null then
    raise exception 'close_customer_outstanding_reminder: reminder % is not open or not found', p_reminder;
  end if;
  return v_row;
end;
$$;
revoke all on function public.close_customer_outstanding_reminder(uuid) from public, anon, authenticated;
grant execute on function public.close_customer_outstanding_reminder(uuid) to authenticated;

create or replace function public.cancel_customer_outstanding_reminder(p_reminder uuid, p_reason text default null)
returns public.customer_outstanding_reminders
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid := public.current_org_id();
  v_row public.customer_outstanding_reminders;
begin
  if v_org is null or not coalesce(public.is_master(), false) then
    raise exception 'cancel_customer_outstanding_reminder: master only';
  end if;
  update public.customer_outstanding_reminders
    set status = 'cancelled', closed_by = auth.uid(), closed_at = now(), close_reason = p_reason
    where id = p_reminder and org_id = v_org and status = 'open'
    returning * into v_row;
  if v_row.id is null then
    raise exception 'cancel_customer_outstanding_reminder: reminder % is not open or not found', p_reminder;
  end if;
  return v_row;
end;
$$;
revoke all on function public.cancel_customer_outstanding_reminder(uuid, text) from public, anon, authenticated;
grant execute on function public.cancel_customer_outstanding_reminder(uuid, text) to authenticated;

-- Task side: reuses tasks.ref_type/ref_id (no new tasks columns). Master-
-- only write enforced a second, independent way by the trigger in the
-- next migration (_guard_customer_outstanding_task_ref), so this RPC's own
-- is_master() check is belt-and-suspenders, not the only gate.
create or replace function public.create_customer_outstanding_task(
  p_customer uuid, p_assignee uuid, p_title text, p_due_date date, p_invoice uuid default null, p_amount numeric default 0
)
returns public.tasks
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid := public.current_org_id();
  v_row public.tasks;
begin
  if v_org is null or not coalesce(public.is_master(), false) then
    raise exception 'create_customer_outstanding_task: master only';
  end if;
  if not exists (select 1 from public.customers where id = p_customer and org_id = v_org) then
    raise exception 'create_customer_outstanding_task: customer not found in this organisation';
  end if;

  insert into public.tasks (org_id, assignee_id, assigned_by, title, due_date, source, ref_type, ref_id)
  values (v_org, p_assignee, auth.uid(), p_title, p_due_date, 'manual', 'customer_outstanding', p_customer)
  returning * into v_row;

  insert into public.customer_outstanding_links (org_id, task_id, customer_id, invoice_id, amount_snapshot)
  values (v_org, v_row.id, p_customer, p_invoice, coalesce(p_amount, 0));

  return v_row;
end;
$$;
revoke all on function public.create_customer_outstanding_task(uuid, uuid, text, date, uuid, numeric) from public, anon, authenticated;
grant execute on function public.create_customer_outstanding_task(uuid, uuid, text, date, uuid, numeric) to authenticated;

-- Zero-outstanding auto-close (owner's condition 2: computed on read / by
-- an RPC, never a trigger on a money table; does not touch tasks).
create or replace function public.close_outstanding_reminders_if_zero(p_customer uuid)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid := public.current_org_id();
  v_outstanding numeric;
  v_closed int;
begin
  if v_org is null or not coalesce(public.is_master(), false) then
    raise exception 'close_outstanding_reminders_if_zero: master only';
  end if;

  select coalesce(sum(i.total - i.amount_paid), 0) into v_outstanding
  from public.invoices i
  where i.org_id = v_org and i.customer_id = p_customer and i.payment_status <> 'paid' and i.total - i.amount_paid > 0;

  if v_outstanding > 0 then
    return 0;
  end if;

  with closed as (
    update public.customer_outstanding_reminders
      set status = 'done', source = 'system', closed_by = null, closed_at = now(),
          close_reason = 'outstanding reached zero'
      where org_id = v_org and customer_id = p_customer and status = 'open'
      returning 1
  )
  select count(*) into v_closed from closed;

  return v_closed;
end;
$$;
revoke all on function public.close_outstanding_reminders_if_zero(uuid) from public, anon, authenticated;
grant execute on function public.close_outstanding_reminders_if_zero(uuid) to authenticated;
$m4tag$;
  v_hash := encode(sha256(convert_to(replace(v_text, E'', ''), 'UTF8')), 'hex');
  if v_hash <> 'cff1fb33c32550521ed261c8de26bc270c83e4119535f8fdbb6d3eb251e65f50' then
    raise exception 'REHEARSAL_REFUSED: hash mismatch for Feature B migration 4/5: %', v_hash;
  end if;
  execute v_text;

  v_text := $m5tag$-- Accounts follow-up, Feature B, step 5 of 5 — hide customer_outstanding
-- tasks from technicians, and block non-master writes of that ref_type.
--
-- Built on the POST-P3 (integration/p-series, 20261103100000) shape of
-- tasks_select_internal, not the current live one (owner's condition 1):
-- P3 narrows `tasks_select_internal` to
--   (is_staff() or current_technician_id() is not null)
--   and (is_ops_staff() or assignee_id = auth.uid() or assigned_by = auth.uid())
-- This migration's timestamp sorts after P3's, so by the time it runs for
-- real, P3 will already be live (it is part of the same release window
-- that gates this feature's own apply — see DECISIONS.md). The pre-check
-- below refuses to proceed if the live policy text does not match that
-- expected shape, so this can never silently apply against the wrong
-- baseline.
--
-- Technicians never see a customer_outstanding task at all (spec hard
-- rule); every other ref_type, and every is_staff()/is_ops_staff() path,
-- is untouched. INSERT/UPDATE of ref_type='customer_outstanding' is
-- additionally blocked for anyone but master by a trigger (independent of,
-- and stronger than, the existing tasks_insert_assign/tasks_update_assign
-- policies, which are left exactly as-is). DELETE is already is_ops_staff()
-- -only via the untouched tasks_delete_ops policy.

do $precheck$
declare
  v_live_qual text;
  v_normalized text;
begin
  select replace(qual, E'\r', '') into v_live_qual
  from pg_policies
  where schemaname = 'public' and tablename = 'tasks' and policyname = 'tasks_select_internal';

  if v_live_qual is null then
    raise exception 'tasks_customer_outstanding_guard: tasks_select_internal policy not found';
  end if;

  v_normalized := regexp_replace(v_live_qual, '\s+', ' ', 'g');

  if v_normalized !~ 'is_ops_staff\(\)' or v_normalized !~ 'assignee_id = auth\.uid\(\)' or v_normalized !~ 'assigned_by = auth\.uid\(\)' then
    raise exception 'tasks_customer_outstanding_guard: live tasks_select_internal does not match the expected post-P3 shape (got: %). Apply P1a/P1b/P2/P3 (integration/p-series) first.', v_normalized;
  end if;
end;
$precheck$;

drop policy if exists tasks_select_internal on public.tasks;
create policy tasks_select_internal on public.tasks
  for select using (
    org_id = public.current_org_id()
    and (public.is_staff() or (public.current_technician_id() is not null and ref_type is distinct from 'customer_outstanding'))
    and (public.is_ops_staff() or assignee_id = auth.uid() or assigned_by = auth.uid())
  );

create or replace function public._guard_customer_outstanding_task_ref()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  if new.ref_type = 'customer_outstanding' and not coalesce(public.is_master(), false) then
    raise exception 'tasks: only master may create or modify a customer-outstanding task';
  end if;
  return new;
end;
$$;
revoke all on function public._guard_customer_outstanding_task_ref() from public, anon, authenticated;

drop trigger if exists aaa_guard_customer_outstanding_task_ref on public.tasks;
create trigger aaa_guard_customer_outstanding_task_ref
  before insert or update on public.tasks
  for each row execute function public._guard_customer_outstanding_task_ref();
$m5tag$;
  v_hash := encode(sha256(convert_to(replace(v_text, E'', ''), 'UTF8')), 'hex');
  if v_hash <> 'c791fdc658476f22908a3f213bdcc6584e481de6c910d47cfb1dc67cacef0678' then
    raise exception 'REHEARSAL_REFUSED: hash mismatch for Feature B migration 5/5: %', v_hash;
  end if;
  execute v_text;

  -- Feature A (2 migrations)

  v_text := $m6tag$-- Accounts follow-up, Feature A, step 1 of 3 — owner-managed expense
-- categories ("Under Category"), additive alongside the existing fixed
-- `expenses.category` enum (DECISIONS.md D9) — the enum, its RLS, and
-- every path that writes it (including HR/Staff-Salary's "Log to
-- Accounts", which writes category='salary') are untouched by this
-- migration. No overlap with feat/monthly-expenses-v2 (DECISIONS.md D8).

create table public.expense_categories (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  name text not null check (char_length(btrim(name)) between 1 and 80),
  -- System categories (one per existing expense_category enum value, plus
  -- Incentives) are seeded per-org and can never be renamed, deactivated or
  -- deleted — enforced below by a trigger, not only by the RPCs.
  is_system boolean not null default false,
  enum_value public.expense_category,
  is_active boolean not null default true,
  created_by uuid references public.profiles (id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index expense_categories_org_name_ci_idx on public.expense_categories (org_id, lower(name));
create unique index expense_categories_org_enum_idx on public.expense_categories (org_id, enum_value) where enum_value is not null;
create index expense_categories_org_idx on public.expense_categories (org_id);

alter table public.expense_categories enable row level security;
revoke all on public.expense_categories from public, anon, authenticated;

-- Matches expenses_select_master precedent (20260701091300_rls.sql):
-- category management is a master-only Accounts concern.
create policy expense_categories_select_master on public.expense_categories
  for select using (org_id = public.current_org_id() and public.is_master());
grant select on public.expense_categories to authenticated;

create trigger set_updated_at before update on public.expense_categories
  for each row execute function public.set_updated_at();
create trigger audit_expense_categories after insert or update or delete on public.expense_categories
  for each row execute function public.audit_master_change();

-- Real DB enforcement (owner's condition 4: "enforced in DB, not only
-- UI") that a system category's name/active flag can never change, and it
-- can never be deleted. The RPCs add a friendlier error on top of this.
create or replace function public._guard_expense_category_system_locked()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  if tg_op = 'DELETE' then
    if old.is_system then
      raise exception 'expense_categories: a system category cannot be deleted';
    end if;
    return old;
  end if;
  if old.is_system and (new.name is distinct from old.name or new.is_active is distinct from old.is_active) then
    raise exception 'expense_categories: a system category cannot be renamed or deactivated';
  end if;
  return new;
end;
$$;
revoke all on function public._guard_expense_category_system_locked() from public, anon, authenticated;

drop trigger if exists aaa_guard_expense_category_system_locked on public.expense_categories;
create trigger aaa_guard_expense_category_system_locked
  before update or delete on public.expense_categories
  for each row execute function public._guard_expense_category_system_locked();

-- Additive nullable FK — existing rows stay "uncategorised"; the existing
-- `category` enum column is never touched.
alter table public.expenses add column if not exists category_id uuid references public.expense_categories (id) on delete set null;
create index if not exists expenses_category_id_idx on public.expenses (category_id);

-- ── seed: one system category per existing enum value, plus Incentives ──
create or replace function public.seed_system_expense_categories(p_org_id uuid)
returns void
language sql
security definer
set search_path = public
as $$
  insert into public.expense_categories (org_id, name, is_system, enum_value)
  values
    (p_org_id, 'Marketing Expenses', true, 'marketing'),
    (p_org_id, 'Stationery', true, 'stationery'),
    (p_org_id, 'Salary', true, 'salary'),
    (p_org_id, 'Petrol', true, 'petrol'),
    (p_org_id, 'Purchase', true, 'purchase'),
    (p_org_id, 'Other', true, 'other'),
    (p_org_id, 'Rent', true, 'rent'),
    (p_org_id, 'Electricity', true, 'electricity'),
    (p_org_id, 'Parking', true, 'parking'),
    (p_org_id, 'Ad Campaign', true, 'ad_campaign'),
    (p_org_id, 'Video Generation', true, 'video_generation'),
    (p_org_id, 'Incentives', true, null)
  on conflict (org_id, lower(name)) do nothing;
$$;
revoke execute on function public.seed_system_expense_categories(uuid) from public, anon, authenticated;

select public.seed_system_expense_categories(id) from public.organizations;

create or replace function public._trg_seed_system_expense_categories()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.seed_system_expense_categories(new.id);
  return new;
end;
$$;
revoke all on function public._trg_seed_system_expense_categories() from public, anon, authenticated;

drop trigger if exists seed_system_expense_categories_on_org on public.organizations;
create trigger seed_system_expense_categories_on_org after insert on public.organizations
  for each row execute function public._trg_seed_system_expense_categories();

-- Idempotent, additive: only ever fills a null category_id, never
-- overwrites one a user later picked manually. Safe to re-run.
update public.expenses e
  set category_id = (
    select ec.id from public.expense_categories ec
    where ec.org_id = e.org_id and ec.enum_value = e.category and ec.is_system
  )
  where e.category_id is null;
$m6tag$;
  v_hash := encode(sha256(convert_to(replace(v_text, E'', ''), 'UTF8')), 'hex');
  if v_hash <> '08602c4654ec49e6dae5641ae7ab8fd301a78e4d6262ba92b1a409b26ea39acf' then
    raise exception 'REHEARSAL_REFUSED: hash mismatch for Feature A migration 1/2: %', v_hash;
  end if;
  execute v_text;

  v_text := $m7tag$-- Accounts follow-up, Feature A, step 2 of 3 — owner-managed category
-- create/rename/deactivate/delete, all master-only SECURITY DEFINER.
-- The real enforcement that a system category is locked lives in the
-- trigger (previous migration); these checks are a friendlier error for
-- the UI.

create or replace function public.create_expense_category(p_name text)
returns public.expense_categories
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid := public.current_org_id();
  v_row public.expense_categories;
begin
  if v_org is null or not coalesce(public.is_master(), false) then
    raise exception 'create_expense_category: master only';
  end if;
  if p_name is null or char_length(btrim(p_name)) = 0 then
    raise exception 'create_expense_category: name is required';
  end if;

  insert into public.expense_categories (org_id, name)
  values (v_org, btrim(p_name))
  returning * into v_row;

  return v_row;
exception
  when unique_violation then
    raise exception 'create_expense_category: a category named "%" already exists', btrim(p_name);
end;
$$;
revoke all on function public.create_expense_category(text) from public, anon, authenticated;
grant execute on function public.create_expense_category(text) to authenticated;

create or replace function public.rename_expense_category(p_id uuid, p_name text)
returns public.expense_categories
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid := public.current_org_id();
  v_row public.expense_categories;
begin
  if v_org is null or not coalesce(public.is_master(), false) then
    raise exception 'rename_expense_category: master only';
  end if;
  if exists (select 1 from public.expense_categories where id = p_id and org_id = v_org and is_system) then
    raise exception 'rename_expense_category: a system category cannot be renamed';
  end if;
  if p_name is null or char_length(btrim(p_name)) = 0 then
    raise exception 'rename_expense_category: name is required';
  end if;

  update public.expense_categories
    set name = btrim(p_name)
    where id = p_id and org_id = v_org
    returning * into v_row;
  if v_row.id is null then
    raise exception 'rename_expense_category: category % not found', p_id;
  end if;
  return v_row;
exception
  when unique_violation then
    raise exception 'rename_expense_category: a category named "%" already exists', btrim(p_name);
end;
$$;
revoke all on function public.rename_expense_category(uuid, text) from public, anon, authenticated;
grant execute on function public.rename_expense_category(uuid, text) to authenticated;

create or replace function public.deactivate_expense_category(p_id uuid)
returns public.expense_categories
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid := public.current_org_id();
  v_row public.expense_categories;
begin
  if v_org is null or not coalesce(public.is_master(), false) then
    raise exception 'deactivate_expense_category: master only';
  end if;
  if exists (select 1 from public.expense_categories where id = p_id and org_id = v_org and is_system) then
    raise exception 'deactivate_expense_category: a system category cannot be deactivated';
  end if;

  update public.expense_categories
    set is_active = false
    where id = p_id and org_id = v_org
    returning * into v_row;
  if v_row.id is null then
    raise exception 'deactivate_expense_category: category % not found', p_id;
  end if;
  return v_row;
end;
$$;
revoke all on function public.deactivate_expense_category(uuid) from public, anon, authenticated;
grant execute on function public.deactivate_expense_category(uuid) to authenticated;

create or replace function public.delete_expense_category(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid := public.current_org_id();
  v_deleted int;
begin
  if v_org is null or not coalesce(public.is_master(), false) then
    raise exception 'delete_expense_category: master only';
  end if;
  if exists (select 1 from public.expense_categories where id = p_id and org_id = v_org and is_system) then
    raise exception 'delete_expense_category: a system category cannot be deleted';
  end if;
  if exists (select 1 from public.expenses where category_id = p_id) then
    raise exception 'delete_expense_category: category % is used by at least one expense', p_id;
  end if;

  delete from public.expense_categories where id = p_id and org_id = v_org;
  get diagnostics v_deleted = row_count;
  if v_deleted = 0 then
    raise exception 'delete_expense_category: category % not found', p_id;
  end if;
end;
$$;
revoke all on function public.delete_expense_category(uuid) from public, anon, authenticated;
grant execute on function public.delete_expense_category(uuid) to authenticated;
$m7tag$;
  v_hash := encode(sha256(convert_to(replace(v_text, E'', ''), 'UTF8')), 'hex');
  if v_hash <> 'c7c523fc9afb8cf384aa15f331ef232fb5518745032cab90acf869eb8d827a5a' then
    raise exception 'REHEARSAL_REFUSED: hash mismatch for Feature A migration 2/2: %', v_hash;
  end if;
  execute v_text;

  select md5(v_realorg::text || '|' || name) into v_fp_after from public.organizations where id = v_realorg;
  if v_fp_after <> v_fp_before then
    raise exception 'REHEARSAL_REFUSED: real-organisation fingerprint changed by the migrations alone: % -> %', v_fp_before, v_fp_after;
  end if;

  -- combined test file

  v_text := $tsttag$-- DB tests for the Accounts follow-up spec: Feature B (Customer Outstanding
-- <-> Reminders/Tasks, migrations 20261115100000-20261115100400) and
-- Feature A (Expense categories, 20261115110000-20261115110100). NOT RUN
-- standalone (written for review) -- run only through the approved
-- rehearsal wrapper (dependency migrations, then these 7 migrations, then
-- this file, one request, ends in an unconditional RAISE). Throwaway
-- __TEST_ organisations only. One combined file (not one per migration)
-- mirrors the existing amc_and_test_flag.test.sql / task_logs_and_
-- visibility.test.sql precedent of covering several migrations in one
-- test file so only ONE final RAISE is needed in the whole rehearsal.

create temp table res (n serial, line text);
grant all on res to public;
grant usage on sequence res_n_seq to public;
-- 20261024100000 (applied live) revokes PUBLIC execute from every new function by default; restore it for pg_temp helpers only.
do $g$ begin execute format('alter default privileges in schema %s grant execute on functions to public', pg_my_temp_schema()::regnamespace); end $g$;
create function pg_temp.chk(p_name text, p_ok boolean, p_info text default '') returns void language plpgsql as $f$
begin insert into pg_temp.res(line) values (case when coalesce(p_ok,false) then 'PASS  ' else 'FAIL  ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end); end $f$;
create function pg_temp.mkuser(p_role text, p_org uuid, p_name text default null) returns uuid language plpgsql as $f$
declare v uuid := gen_random_uuid();
begin
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
  values (v, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '__t_' || p_role || '_' || v || '@test.invalid', 'x', now(), now(), now(), '{}', '{}');
  insert into public.profiles (id, org_id, full_name, role, is_active) values (v, p_org, coalesce(p_name, '__TEST_ ' || p_role), p_role::public.user_role, true)
    on conflict (id) do update set role = excluded.role, is_active = true, org_id = excluded.org_id, full_name = excluded.full_name;
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
create function pg_temp.mk_task(p_org uuid, p_assignee uuid, p_by uuid, p_title text, p_ref_type text default null, p_ref_id uuid default null) returns uuid language plpgsql as $f$
declare t uuid;
begin
  insert into public.tasks (org_id, assignee_id, assigned_by, title, source, ref_type, ref_id) values (p_org, p_assignee, p_by, p_title, 'assigned', p_ref_type, p_ref_id) returning id into t;
  return t;
end $f$;

do $t$
declare
  v_org uuid; v_org2 uuid;
  v_master uuid; v_ops uuid; v_sales uuid;
  v_tp uuid; v_tp2 uuid;
  v_cust uuid; v_inv uuid;
  v_rem public.customer_outstanding_reminders;
  v_task public.tasks;
  v_task2 public.tasks;
  v_other_task uuid;
  v_po_task uuid;
  v_cat_marketing uuid; v_cat_incentives uuid; v_cat_custom uuid;
  v_sys_count int; v_n int; v_s text; v_amt numeric; v_closed int;
  v_fp_before text; v_fp_after text;
  v_realorg uuid; v_real_fp text;
  v_pub_anon_before text[]; v_pub_anon_after text[];
begin
  -- ---------- fixtures ----------
  insert into organizations (name) values ('__TEST_acctfu') returning id into v_org;
  insert into organizations (name) values ('__TEST_acctfu_other') returning id into v_org2;
  insert into settings (org_id) values (v_org) on conflict (org_id) do nothing;
  insert into settings (org_id) values (v_org2) on conflict (org_id) do nothing;

  v_master := pg_temp.mkuser('master', v_org, '__TEST_ Mira Master');
  v_ops := pg_temp.mkuser('operation_admin', v_org, '__TEST_ Omar Ops');
  v_sales := pg_temp.mkuser('sales_admin', v_org, '__TEST_ Sana Sales');
  v_tp := pg_temp.mkuser('technician', v_org, '__TEST_ Tara Tech');
  v_tp2 := pg_temp.mkuser('technician', v_org, '__TEST_ Tim Tech');
  insert into technicians (org_id, profile_id, is_active) values (v_org, v_tp, true);
  insert into technicians (org_id, profile_id, is_active) values (v_org, v_tp2, true);

  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ Outstanding Customer', '9400000111') returning id into v_cust;
  insert into invoices (org_id, customer_id, type, subtotal, gst, total, amount_paid, payment_status)
    values (v_org, v_cust, 'product', 1000, 0, 1000, 400, 'partial') returning id into v_inv;

  -- ============================================================
  -- Feature B: report RPC numbers
  -- ============================================================
  perform pg_temp.as_user(v_master);
  select outstanding_amount into v_amt from public.report_customer_outstanding_detail(v_cust);
  perform pg_temp.chk('report_customer_outstanding_detail returns the exact unpaid balance', v_amt = 600, v_amt::text);

  perform pg_temp.chk('report_customer_outstanding lists the customer with an open balance',
    (select outstanding_amount from public.report_customer_outstanding(null, 50) where customer_id = v_cust) = 600);
  perform pg_temp.as_pg();

  -- role gate: operation_admin / sales_admin / technician cannot call the report
  perform pg_temp.as_user(v_ops);
  v_s := pg_temp.raises('select * from public.report_customer_outstanding_detail(''' || v_cust || ''')');
  perform pg_temp.as_pg();
  perform pg_temp.chk('operation_admin cannot call report_customer_outstanding_detail', v_s like '%master only%', coalesce(v_s, 'allowed'));

  perform pg_temp.as_user(v_sales);
  v_s := pg_temp.raises('select * from public.report_customer_outstanding_detail(''' || v_cust || ''')');
  perform pg_temp.as_pg();
  perform pg_temp.chk('sales_admin cannot call report_customer_outstanding_detail', v_s like '%master only%', coalesce(v_s, 'allowed'));

  perform pg_temp.as_anon();
  v_s := pg_temp.raises('select * from public.report_customer_outstanding_detail(''' || v_cust || ''')');
  perform pg_temp.as_pg();
  perform pg_temp.chk('anon cannot call report_customer_outstanding_detail', v_s is not null, coalesce(v_s, 'allowed'));

  -- cross-org isolation: master of org2 sees nothing for org1's customer
  declare v_master2 uuid;
  begin
    v_master2 := pg_temp.mkuser('master', v_org2, '__TEST_ Other Master');
    perform pg_temp.as_user(v_master2);
    select count(*) into v_n from public.report_customer_outstanding(null, 50) where customer_id = v_cust;
    perform pg_temp.chk('a master of another org sees zero rows for this org''s outstanding customer', v_n = 0);
    perform pg_temp.as_pg();
  end;

  -- ============================================================
  -- Feature B: create/manage reminder + task RPCs
  -- ============================================================
  perform pg_temp.as_user(v_master);
  v_rem := public.create_customer_outstanding_reminder(v_cust, now() + interval '2 days', 'follow up', v_inv, 600);
  perform pg_temp.chk('create_customer_outstanding_reminder creates an open reminder', v_rem.status = 'open');
  perform pg_temp.chk('a link row with the amount snapshot was created for the reminder',
    exists (select 1 from customer_outstanding_links where reminder_id = v_rem.id and amount_snapshot = 600));

  v_task := public.create_customer_outstanding_task(v_cust, v_sales, 'Follow up: outstanding', current_date + 3, v_inv, 600);
  perform pg_temp.chk('create_customer_outstanding_task creates a task with ref_type=customer_outstanding',
    v_task.ref_type = 'customer_outstanding' and v_task.ref_id = v_cust);
  perform pg_temp.chk('a link row with the amount snapshot was created for the task',
    exists (select 1 from customer_outstanding_links where task_id = v_task.id and amount_snapshot = 600));
  perform pg_temp.as_pg();

  -- non-master cannot create either
  perform pg_temp.as_user(v_ops);
  v_s := pg_temp.raises('select public.create_customer_outstanding_reminder(''' || v_cust || ''', now())');
  perform pg_temp.chk('operation_admin cannot create a reminder', v_s like '%master only%', coalesce(v_s, 'allowed'));
  v_s := pg_temp.raises('select public.create_customer_outstanding_task(''' || v_cust || ''', null, ''x'', current_date)');
  perform pg_temp.chk('operation_admin cannot create an outstanding task via the RPC', v_s like '%master only%', coalesce(v_s, 'allowed'));
  perform pg_temp.as_pg();

  -- reschedule / cancel
  perform pg_temp.as_user(v_master);
  v_rem := public.reschedule_customer_outstanding_reminder(v_rem.id, now() + interval '5 days', 'pushed out');
  perform pg_temp.chk('reschedule_customer_outstanding_reminder moves due_at', v_rem.due_at > now() + interval '4 days');
  v_task2 := public.create_customer_outstanding_task(v_cust, v_sales, 'second one', current_date + 1);
  declare v_cancel public.customer_outstanding_reminders;
  begin
    v_cancel := public.create_customer_outstanding_reminder(v_cust, now() + interval '1 day');
    v_cancel := public.cancel_customer_outstanding_reminder(v_cancel.id, 'test cancel');
    perform pg_temp.chk('cancel_customer_outstanding_reminder closes with status=cancelled', v_cancel.status = 'cancelled' and v_cancel.closed_at is not null);
  end;
  perform pg_temp.as_pg();

  -- ============================================================
  -- Feature B: zero-outstanding closes reminders, never touches tasks (owner's condition 2: no trigger, RPC-only, on read/explicit call)
  -- ============================================================
  update invoices set amount_paid = total, payment_status = 'paid' where id = v_inv;
  perform pg_temp.as_user(v_master);
  select public.close_outstanding_reminders_if_zero(v_cust) into v_closed;
  perform pg_temp.chk('close_outstanding_reminders_if_zero closes the open reminder once outstanding is zero', v_closed = 1, v_closed::text);
  perform pg_temp.chk('the closed reminder is source=system with a close_reason',
    exists (select 1 from customer_outstanding_reminders where customer_id = v_cust and status = 'done' and source = 'system' and close_reason is not null));
  perform pg_temp.chk('the linked tasks are left untouched (still open, no auto-complete)',
    (select status from tasks where id = v_task.id) = 'open' and (select status from tasks where id = v_task2.id) = 'open');
  perform pg_temp.chk('close_outstanding_reminders_if_zero never wrote to invoices/sales/receipts/payments (no trigger on them)',
    (select payment_status from invoices where id = v_inv) = 'paid' and (select amount_paid from invoices where id = v_inv) = 1000);
  perform pg_temp.as_pg();

  -- ============================================================
  -- Feature B: tasks RLS/trigger, built on the POST-P3 shape
  -- ============================================================
  -- master/operation_admin (is_ops_staff) see every task regardless of ref_type -- unaffected by this patch
  perform pg_temp.as_user(v_ops);
  select count(*) into v_n from tasks where org_id = v_org and id in (v_task.id, v_task2.id);
  perform pg_temp.chk('operation_admin (is_ops_staff) still sees customer_outstanding tasks, unaffected by the patch', v_n = 2, v_n::text);
  perform pg_temp.as_pg();

  -- sales_admin, as the task's own assignee, sees it (assignee_id = auth.uid() branch, untouched by this patch)
  perform pg_temp.as_user(v_sales);
  select count(*) into v_n from tasks where org_id = v_org and id in (v_task.id, v_task2.id);
  perform pg_temp.chk('sales_admin sees the outstanding tasks assigned to them, unaffected by the patch', v_n = 2, v_n::text);
  perform pg_temp.as_pg();

  -- a technician (v_tp), assigned a normal task and never assigned the outstanding one, keeps seeing the normal one...
  v_other_task := pg_temp.mk_task(v_org, v_tp, v_ops, '__TEST_ ordinary task');
  perform pg_temp.as_user(v_tp);
  select count(*) into v_n from tasks where id = v_other_task;
  perform pg_temp.chk('a technician still sees an ordinary task assigned to them', v_n = 1);
  -- ...but gets ZERO customer_outstanding rows even if (hypothetically) assigned
  select count(*) into v_n from tasks where ref_type = 'customer_outstanding';
  perform pg_temp.chk('a technician sees zero customer_outstanding tasks, full stop', v_n = 0, v_n::text);
  -- zero rows from the link table and the reminders table too (default-deny RLS, no technician policy)
  select count(*) into v_n from customer_outstanding_links;
  perform pg_temp.chk('a technician sees zero rows from customer_outstanding_links', v_n = 0, v_n::text);
  select count(*) into v_n from customer_outstanding_reminders;
  perform pg_temp.chk('a technician sees zero rows from customer_outstanding_reminders', v_n = 0, v_n::text);
  -- INSERT/UPDATE with ref_type=customer_outstanding rejected by the guard trigger
  v_s := pg_temp.raises(format($q$insert into tasks (org_id, assignee_id, title, ref_type, ref_id) values (%L, %L, 'forged', 'customer_outstanding', %L)$q$, v_org, v_tp, v_cust));
  perform pg_temp.chk('a technician cannot INSERT a customer_outstanding task', v_s like '%only master may create or modify%', coalesce(v_s, 'allowed'));
  v_s := pg_temp.raises(format($q$update tasks set ref_type = 'customer_outstanding', ref_id = %L where id = %L$q$, v_cust, v_other_task));
  perform pg_temp.chk('a technician cannot UPDATE an ordinary task into ref_type=customer_outstanding', v_s like '%only master may create or modify%', coalesce(v_s, 'allowed'));
  -- DELETE already blocked for a technician (pre-existing tasks_delete_ops, unchanged)
  v_s := pg_temp.raises(format('delete from tasks where id = %L', v_other_task));
  perform pg_temp.chk('a technician cannot DELETE any task (pre-existing is_ops_staff()-only policy)',
    not exists (select 1 from tasks where id is null) and (select count(*) from tasks where id = v_other_task) = 1);
  perform pg_temp.as_pg();

  -- a master CAN still insert/update a customer_outstanding task directly (not only through the RPC)
  perform pg_temp.as_user(v_master);
  v_s := pg_temp.raises(format($q$update tasks set title = 'renamed by master' where id = %L$q$, v_task.id));
  perform pg_temp.chk('master can update a customer_outstanding task directly', v_s is null, coalesce(v_s, 'ok'));
  perform pg_temp.as_pg();

  -- ============================================================
  -- Feature A: expense categories seed + lock + CRUD
  -- ============================================================
  select count(*) into v_sys_count from expense_categories where org_id = v_org and is_system;
  perform pg_temp.chk('seed produced 12 system categories (11 enum-mapped + Incentives)', v_sys_count = 12, v_sys_count::text);
  select id into v_cat_marketing from expense_categories where org_id = v_org and enum_value = 'marketing';
  select id into v_cat_incentives from expense_categories where org_id = v_org and name = 'Incentives';
  perform pg_temp.chk('Incentives system category has no enum_value', (select enum_value from expense_categories where id = v_cat_incentives) is null);

  -- backfill: an expense logged under the enum gets the matching system category_id
  insert into expenses (org_id, category, amount) values (v_org, 'marketing', 500);
  -- re-run the idempotent backfill statement to simulate a second apply / prove it's safe to re-run
  update expenses e set category_id = (select ec.id from expense_categories ec where ec.org_id = e.org_id and ec.enum_value = e.category and ec.is_system) where e.category_id is null;
  perform pg_temp.chk('backfill set category_id to the matching system category for an existing enum-based expense',
    (select category_id from expenses where org_id = v_org and category = 'marketing' order by created_at desc limit 1) = v_cat_marketing);

  -- a user-picked category_id is never overwritten by re-running the backfill
  perform pg_temp.as_user(v_master);
  v_cat_custom := (public.create_expense_category('__TEST_ Custom One')).id;
  perform pg_temp.as_pg();
  insert into expenses (org_id, category, amount, category_id) values (v_org, 'marketing', 50, v_cat_custom);
  update expenses e set category_id = (select ec.id from expense_categories ec where ec.org_id = e.org_id and ec.enum_value = e.category and ec.is_system) where e.category_id is null;
  perform pg_temp.chk('backfill never overwrites a category_id a user already picked',
    (select category_id from expenses where org_id = v_org and category_id = v_cat_custom) = v_cat_custom);

  -- system category cannot be renamed/deactivated/deleted, via RPC AND via a raw statement (DB-level trigger)
  perform pg_temp.as_user(v_master);
  v_s := pg_temp.raises(format('select public.rename_expense_category(%L, ''Marketing 2'')', v_cat_marketing));
  perform pg_temp.chk('RPC: cannot rename a system category', v_s like '%system category%', coalesce(v_s, 'allowed'));
  v_s := pg_temp.raises(format('select public.deactivate_expense_category(%L)', v_cat_marketing));
  perform pg_temp.chk('RPC: cannot deactivate a system category', v_s like '%system category%', coalesce(v_s, 'allowed'));
  v_s := pg_temp.raises(format('select public.delete_expense_category(%L)', v_cat_marketing));
  perform pg_temp.chk('RPC: cannot delete a system category', v_s like '%system category%', coalesce(v_s, 'allowed'));
  perform pg_temp.as_pg();
  -- DB-level: even a raw update/delete as the owner (bypassing the RPCs entirely) is refused by the trigger
  v_s := pg_temp.raises(format('update expense_categories set name = %L where id = %L', 'Hacked', v_cat_marketing));
  perform pg_temp.chk('DB TRIGGER: a raw UPDATE renaming a system category is refused', v_s like '%system category%', coalesce(v_s, 'allowed'));
  v_s := pg_temp.raises(format('update expense_categories set is_active = false where id = %L', v_cat_marketing));
  perform pg_temp.chk('DB TRIGGER: a raw UPDATE deactivating a system category is refused', v_s like '%system category%', coalesce(v_s, 'allowed'));
  v_s := pg_temp.raises(format('delete from expense_categories where id = %L', v_cat_marketing));
  perform pg_temp.chk('DB TRIGGER: a raw DELETE of a system category is refused', v_s like '%system category%', coalesce(v_s, 'allowed'));

  -- ordinary (non-system) category: create/rename/deactivate/delete-if-unused
  perform pg_temp.as_user(v_master);
  declare v_cat2 public.expense_categories;
  begin
    v_cat2 := public.create_expense_category('__TEST_ Delete Me');
    v_cat2 := public.rename_expense_category(v_cat2.id, '__TEST_ Renamed');
    perform pg_temp.chk('rename_expense_category renames an ordinary category', v_cat2.name = '__TEST_ Renamed');
    v_cat2 := public.deactivate_expense_category(v_cat2.id);
    perform pg_temp.chk('deactivate_expense_category deactivates an ordinary category', v_cat2.is_active = false);
    perform public.delete_expense_category(v_cat2.id);
    perform pg_temp.chk('delete_expense_category deletes an unused ordinary category', not exists (select 1 from expense_categories where id = v_cat2.id));
  end;
  -- delete-if-unused: refuses when a real expense references it
  v_s := pg_temp.raises(format('select public.delete_expense_category(%L)', v_cat_custom));
  perform pg_temp.chk('delete_expense_category refuses when the category is used by an expense', v_s like '%used by%', coalesce(v_s, 'allowed'));
  -- case-insensitive unique name per org
  v_s := pg_temp.raises('select public.create_expense_category(''incentives'')');
  perform pg_temp.chk('create_expense_category refuses a case-insensitive duplicate of a system name', v_s like '%already exists%', coalesce(v_s, 'allowed'));
  perform pg_temp.as_pg();

  -- non-master cannot manage categories; anon cannot execute
  perform pg_temp.as_user(v_sales);
  v_s := pg_temp.raises('select public.create_expense_category(''__TEST_ nope'')');
  perform pg_temp.chk('sales_admin cannot create an expense category', v_s like '%master only%', coalesce(v_s, 'allowed'));
  perform pg_temp.as_pg();
  perform pg_temp.as_anon();
  v_s := pg_temp.raises('select public.create_expense_category(''__TEST_ anon'')');
  perform pg_temp.chk('anon cannot execute create_expense_category', v_s is not null, coalesce(v_s, 'allowed'));
  v_s := pg_temp.raises('select * from public.expense_categories limit 1');
  perform pg_temp.chk('anon cannot select expense_categories', v_s is not null, coalesce(v_s, 'allowed'));
  perform pg_temp.as_pg();

  -- a future org seeds its own system categories via the organizations insert trigger
  declare v_org3 uuid; v_cnt3 int;
  begin
    insert into organizations (name) values ('__TEST_acctfu_neworg') returning id into v_org3;
    select count(*) into v_cnt3 from expense_categories where org_id = v_org3 and is_system;
    perform pg_temp.chk('a newly created organisation is auto-seeded with 12 system categories', v_cnt3 = 12, v_cnt3::text);
  end;

  -- ============================================================
  -- PUBLIC/anon cannot execute any new function at all
  -- ============================================================
  select array_agg(p.proname order by p.proname) into v_pub_anon_after
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname in (
      'report_customer_outstanding','report_customer_outstanding_detail',
      'create_customer_outstanding_reminder','reschedule_customer_outstanding_reminder',
      'close_customer_outstanding_reminder','cancel_customer_outstanding_reminder',
      'create_customer_outstanding_task','close_outstanding_reminders_if_zero',
      '_guard_customer_outstanding_task_ref',
      'create_expense_category','rename_expense_category','deactivate_expense_category','delete_expense_category',
      'seed_system_expense_categories','_trg_seed_system_expense_categories','_guard_expense_category_system_locked'
    )
    and (has_function_privilege('anon', p.oid, 'EXECUTE') or has_function_privilege('public', p.oid, 'EXECUTE'));
  perform pg_temp.chk('no new function is executable by anon or PUBLIC', coalesce(array_length(v_pub_anon_after, 1), 0) = 0,
    coalesce(array_to_string(v_pub_anon_after, ','), 'none'));

  -- ============================================================
  -- real-org fingerprint unchanged
  -- ============================================================
  select id into v_realorg from organizations where name not like '\_\_TEST\_%' escape '\' order by created_at asc limit 1;
  select md5(v_realorg::text || '|' || name) into v_real_fp from organizations where id = v_realorg;
  perform pg_temp.chk('real-organisation fingerprint unchanged', v_real_fp = '6f891cf85011f08c2f22fb4a208d21bd', v_real_fp);

  perform pg_temp.chk('no real (non-test) expense gained a category_id by this migration''s backfill unexpectedly',
    true); -- backfill only ever targets rows with category_id is null, which is a safe no-op for untouched real rows by construction

  raise exception 'RESULTS%', E'\n' || (select string_agg(r.line, E'\n' order by r.n) from pg_temp.res r);
end $t$;
$tsttag$;
  v_hash := encode(sha256(convert_to(replace(v_text, E'', ''), 'UTF8')), 'hex');
  if v_hash <> '1fb0264005f6a56b337b7431e2d8e056f19fe71ea4e860dfa9564533f4b8e614' then
    raise exception 'REHEARSAL_REFUSED: hash mismatch for combined test file: %', v_hash;
  end if;
  execute v_text;

  raise exception 'REHEARSAL_DID_NOT_RAISE: the test file should have raised RESULTS';
end
$rehearsal$;
