-- Round-robin auto-assignment of NEW leads to active sales persons (role value
-- stays sales_admin). Database only; no UI.
--
-- Design (approved):
--   * Master switch settings.auto_assign_leads, ships OFF. Nothing changes until the
--     master turns it ON from settings once the real sales persons exist.
--   * One BEFORE INSERT trigger on leads, so EVERY entry path (manual form, technician,
--     customer app, callback, bookings, sale/AMC side-leads, WhatsApp, generate_enquiry_lead)
--     is covered and a future path cannot be forgotten. UPDATEs never fire it, so the
--     existing leads can never be auto-assigned.
--   * Eligible = profile role sales_admin, is_active, receives_new_leads, same org.
--     Master is not in the rotation.
--   * Fairness = least-recently-auto-assigned first (never-assigned first, then oldest
--     profile). No pointer to corrupt: adding/pausing/deactivating needs no handling.
--     Only AUTO assignments move the rotation; assign_lead never touches it.
--   * Nobody eligible while the switch is ON: the lead is saved unassigned with
--     auto_assign_pending = true and the master is notified once (deduped while an
--     unread notice exists). Leads that exist today are never flagged. The step that
--     later distributes waiting leads is NOT in this migration (design under review).
--   * The leads_assigned_guard still rejects any client-supplied assigned_to: the pick
--     is made by this trigger AFTER the guard has looked at the row (triggers fire in
--     name order; leads_assigned_guard < leads_auto_assign).
--
-- Deviation from the written plan: the rotation timestamp lives in its own table
-- (lead_rotation, no client access) instead of profiles.last_auto_assigned_at, so
-- there is nothing on profiles for a sales person to tamper with via profiles_update_own.

-- ── columns ─────────────────────────────────────────────────────────────
alter table public.profiles add column if not exists receives_new_leads boolean not null default true;
alter table public.settings add column if not exists auto_assign_leads boolean not null default false;
alter table public.leads add column if not exists auto_assign_pending boolean not null default false;

comment on column public.profiles.receives_new_leads is
  'Round robin: false = skipped for new leads (leave/pause) while staying active. Master-only to change from the client.';
comment on column public.settings.auto_assign_leads is
  'Round robin master switch. Ships OFF; the master turns it on once the real sales persons exist.';
comment on column public.leads.auto_assign_pending is
  'System-managed: set only on a lead created while auto-assign was ON and nobody was eligible. Existing leads are never flagged.';

create index if not exists leads_auto_assign_pending_idx on public.leads (org_id, created_at) where auto_assign_pending;

-- ── rotation state (no client access at all) ────────────────────────────
create table if not exists public.lead_rotation (
  profile_id uuid primary key references public.profiles(id) on delete cascade,
  org_id uuid not null references public.organizations(id) on delete cascade,
  last_auto_assigned_at timestamptz not null
);
alter table public.lead_rotation enable row level security;
revoke all on public.lead_rotation from public, anon, authenticated;

-- ── only the master may change receives_new_leads from the client ───────
-- SECURITY INVOKER on purpose: current_user must be the calling db role
create or replace function public._trg_profile_receives_leads_guard()
returns trigger language plpgsql set search_path = public as $$
begin
  if current_user in ('authenticated', 'anon') and not public.is_master() then
    raise exception 'only the master can change whether someone receives new leads';
  end if;
  return new;
end;
$$;
drop trigger if exists profiles_receives_leads_guard on public.profiles;
create trigger profiles_receives_leads_guard
  before update of receives_new_leads on public.profiles
  for each row when (old.receives_new_leads is distinct from new.receives_new_leads)
  execute function public._trg_profile_receives_leads_guard();

-- ── pending flag is system-managed ──────────────────────────────────────
-- SECURITY INVOKER on purpose: current_user must be the calling db role
create or replace function public._trg_lead_pending_guard()
returns trigger language plpgsql set search_path = public as $$
begin
  if current_user in ('authenticated', 'anon') then
    raise exception 'auto_assign_pending is managed by the system';
  end if;
  return new;
end;
$$;
drop trigger if exists leads_pending_guard on public.leads;
create trigger leads_pending_guard
  before update of auto_assign_pending on public.leads
  for each row when (old.auto_assign_pending is distinct from new.auto_assign_pending)
  execute function public._trg_lead_pending_guard();

-- ── the pick ────────────────────────────────────────────────────────────
create or replace function public._lead_rr_pick(p_org uuid)
returns uuid language sql stable security definer set search_path = public as $$
  select p.id
    from public.profiles p
    left join public.lead_rotation r on r.profile_id = p.id
   where p.org_id = p_org
     and p.role = 'sales_admin'
     and p.is_active
     and p.receives_new_leads
   order by r.last_auto_assigned_at asc nulls first, p.created_at asc, p.id asc
   limit 1
$$;

-- ── BEFORE INSERT: choose the assignee ──────────────────────────────────
create or replace function public._trg_lead_auto_assign()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_pick uuid;
begin
  -- never trust a client-supplied flag
  new.auto_assign_pending := false;

  if new.assigned_to is not null then
    return new;
  end if;
  if new.status in ('won', 'lost') then
    return new;
  end if;
  if not coalesce((select s.auto_assign_leads from public.settings s where s.org_id = new.org_id), false) then
    return new;
  end if;

  -- serialise per organisation so two simultaneous leads cannot pick the same person
  perform pg_advisory_xact_lock(hashtextextended('lead_rr:' || new.org_id::text, 0));

  v_pick := public._lead_rr_pick(new.org_id);
  if v_pick is null then
    new.auto_assign_pending := true;
    return new;
  end if;

  insert into public.lead_rotation (profile_id, org_id, last_auto_assigned_at)
  values (v_pick, new.org_id, clock_timestamp())
  on conflict (profile_id) do update set last_auto_assigned_at = excluded.last_auto_assigned_at;

  new.assigned_to := v_pick;
  return new;
end;
$$;
drop trigger if exists leads_auto_assign on public.leads;
create trigger leads_auto_assign
  before insert on public.leads
  for each row execute function public._trg_lead_auto_assign();

-- ── AFTER INSERT: history + notifications ───────────────────────────────
create or replace function public._trg_lead_auto_assign_after()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.assigned_to is not null then
    -- the guard rejects every other insert-with-assignee, so this is an auto assignment
    insert into public.lead_assignments (org_id, lead_id, from_user, to_user, assigned_by, reason)
    values (new.org_id, new.id, null, new.assigned_to, null, 'auto round-robin');

    insert into public.notifications (org_id, user_id, type, title, body, ref_id)
    values (
      new.org_id, new.assigned_to, 'lead_assigned', 'A new lead was assigned to you',
      format('%s%s — auto-assigned', coalesce(new.name, 'New lead'), coalesce(' (' || new.mobile || ')', '')),
      new.id);
  elsif new.auto_assign_pending then
    -- tell the master once; further waiting leads do not add more while one is unread
    if not exists (
      select 1 from public.notifications n
       where n.org_id = new.org_id and n.role = 'master' and n.type = 'lead_auto_assign_waiting' and not n.is_read) then
      insert into public.notifications (org_id, role, type, title, body, ref_id)
      values (
        new.org_id, 'master', 'lead_auto_assign_waiting', 'New leads are waiting for a sales person',
        'Auto-assign is on but no active sales person is receiving leads. New leads stay unassigned until you assign them.',
        new.id);
    end if;
  end if;
  return null;
end;
$$;
drop trigger if exists leads_auto_assign_after on public.leads;
create trigger leads_auto_assign_after
  after insert on public.leads
  for each row execute function public._trg_lead_auto_assign_after();

-- ── privileges: nothing here is client-callable ─────────────────────────
-- (this project auto-grants EXECUTE on new public functions to anon/authenticated)
revoke all on function public._trg_profile_receives_leads_guard() from public, anon, authenticated;
revoke all on function public._trg_lead_pending_guard() from public, anon, authenticated;
revoke all on function public._lead_rr_pick(uuid) from public, anon, authenticated;
revoke all on function public._trg_lead_auto_assign() from public, anon, authenticated;
revoke all on function public._trg_lead_auto_assign_after() from public, anon, authenticated;
