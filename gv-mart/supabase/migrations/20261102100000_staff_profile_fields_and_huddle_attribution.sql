-- P2: staff profile fields, forced first-login password change, per-user colour, huddle attribution + master notification,
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
-- 5. profiles.address visibility. RLS on `profiles` is ROW-level only: profiles_select_staff (org_id match + is_staff(),
--    which is master/operation_admin/SALES_ADMIN) already lets ANY staff role read every column of every profile in the
--    org, and profiles_select_by_customer already lets a customer read their assigned TECHNICIAN's profile row. Both
--    policies pre-date this migration and are correctly scoped for the columns that existed before address — but address
--    is a home/postal address, and Postgres RLS cannot mask one column while allowing the rest of the same row (only a
--    full row match/no-match). The smallest fix that doesn't touch either policy or the single shared `authenticated`
--    client role's access to every other column: REVOKE the `address` column itself from anon/authenticated outright
--    (closing both leaks — sales_admin's broad profile read and the customer-sees-technician read — for every viewer,
--    including the row's own owner and master), then hand it back ONLY to the person themselves and ops (master /
--    operation_admin) through a SECURITY DEFINER function. Nothing today reads `.address` off a bare `select("*")` on
--    `profiles` (P2 only writes it, through the two staff Edge Functions as service_role, which this revoke does not
--    touch), so this closes the leak with no client code to migrate; a future staff-detail/edit screen reads the
--    address through get_profile_address() instead of the base table.

revoke select (address) on public.profiles from anon, authenticated;

create or replace function public.get_profile_address(p_profile_id uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select address from public.profiles
   where id = p_profile_id
     and org_id = public.current_org_id()
     and (id = auth.uid() or public.is_ops_staff())
$$;
revoke all on function public.get_profile_address(uuid) from public, anon;
grant execute on function public.get_profile_address(uuid) to authenticated;
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
