-- Lead follow-ups, outcomes and activity authorship — schema (Phase 1, commit 2a).
--
-- * lead_activities: WHO did it (created_by / is_system), which outcome, and
--   structured from/to status for stage-change rows.
-- * lead_outcomes: master-editable list of call outcomes (EN + TA labels,
--   default follow-up rule, optional stage effect, counts_as_postpone).
-- * lead_followups: one row per follow-up task. Never edited except to close
--   it (done / cancelled), so rescheduling keeps full history.
-- * leads.postpone_count / next_followup_at (kept in sync by triggers in the
--   functions migration).
-- * settings.lead_*: working days/hours (IST) and stuck threshold.
--
-- All writes to lead_followups / lead_activities go through SECURITY DEFINER
-- RPCs (next migration); there are intentionally no client write policies.
-- No assigned_to column yet — created_by/completed_by carry the "who" so
-- per-person assignment can be added later without redesign.

-- ── enums ────────────────────────────────────────────────────────────────
create type public.lead_followup_type as enum ('call', 'whatsapp', 'visit', 'send_quote');
create type public.lead_followup_status as enum ('open', 'done', 'cancelled');

-- ── settings: working schedule (IST) ─────────────────────────────────────
-- Separate from settings.work_start/work_end (9:00–19:30), which other
-- modules (attendance, WhatsApp office hours) depend on.
alter table public.settings
  add column lead_work_days smallint[] not null default '{1,2,3,4,5,6}'
    check (cardinality(lead_work_days) between 1 and 7 and lead_work_days <@ array[1, 2, 3, 4, 5, 6, 7]::smallint[]),
  add column lead_work_start time not null default '09:30',
  add column lead_work_end time not null default '19:00',
  add column lead_stuck_postpones integer not null default 3 check (lead_stuck_postpones >= 1),
  add column lead_reminder_minutes integer not null default 15 check (lead_reminder_minutes >= 1);

alter table public.settings
  add constraint settings_lead_work_hours_check check (lead_work_end > lead_work_start);

-- ── lead_outcomes ────────────────────────────────────────────────────────
create table public.lead_outcomes (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  code text not null,
  label_en text not null,
  label_ta text not null,
  -- How the next follow-up is pre-filled in the Log Outcome sheet:
  --   none = no follow-up (Won/Lost), offset = N days from today,
  --   ask_date = no default, staff must pick, exact_time = ask for a time.
  followup_mode text not null default 'offset' check (followup_mode in ('none', 'offset', 'ask_date', 'exact_time')),
  default_offset_days integer check (default_offset_days >= 0),
  default_followup_type public.lead_followup_type not null default 'call',
  requires_followup boolean not null default true,
  stage_effect public.lead_status,
  -- Pre-filled lost reason for outcomes whose stage effect is Lost.
  lost_reason_hint text,
  -- Postpone-type outcomes ("call me later") add 1 to leads.postpone_count;
  -- progress outcomes reset it to 0.
  counts_as_postpone boolean not null default false,
  is_active boolean not null default true,
  is_system boolean not null default false,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (org_id, code),
  constraint lead_outcomes_closing_has_no_followup check (stage_effect not in ('won', 'lost') or requires_followup = false),
  constraint lead_outcomes_mode_matches_requirement check ((followup_mode = 'none') = (requires_followup = false)),
  constraint lead_outcomes_stage_effect_valid check (stage_effect is null or stage_effect in ('contacted', 'quoted', 'won', 'lost'))
);

create index lead_outcomes_org_id_idx on public.lead_outcomes (org_id, sort_order);

alter table public.lead_outcomes enable row level security;

create policy lead_outcomes_select_sales on public.lead_outcomes
  for select using (org_id = public.current_org_id() and public.is_sales_staff());
create policy lead_outcomes_write_master on public.lead_outcomes for all
  using (org_id = public.current_org_id() and public.is_master())
  with check (org_id = public.current_org_id() and public.is_master());

create trigger set_updated_at before update on public.lead_outcomes for each row execute function public.set_updated_at();
create trigger audit_lead_outcomes after insert or update or delete on public.lead_outcomes for each row execute function public.audit_master_change();

create or replace function public.seed_lead_outcomes(p_org_id uuid)
returns void
language sql
security definer
set search_path = public
as $$
  insert into public.lead_outcomes
    (org_id, code, label_en, label_ta, followup_mode, default_offset_days, default_followup_type,
     requires_followup, stage_effect, lost_reason_hint, counts_as_postpone, is_system, sort_order)
  values
    (p_org_id, 'interested_send_details', 'Interested – send details', 'ஆர்வமுள்ளார் – விவரங்களை அனுப்பவும்', 'offset', 0, 'whatsapp', true, 'contacted', null, false, true, 1),
    (p_org_id, 'asked_price', 'Asked for price', 'விலை கேட்டார்', 'offset', 0, 'send_quote', true, 'contacted', null, false, true, 2),
    (p_org_id, 'will_buy_later', 'Will buy later', 'பிறகு வாங்குவார்', 'ask_date', null, 'call', true, 'contacted', null, true, true, 3),
    (p_org_id, 'callback_specific_time', 'Call back at specific time', 'குறிப்பிட்ட நேரத்தில் அழைக்கவும்', 'exact_time', 0, 'call', true, 'contacted', null, true, true, 4),
    (p_org_id, 'discussing_family', 'Discussing with family', 'குடும்பத்தினருடன் பேசுகிறார்', 'offset', 2, 'call', true, 'contacted', null, true, true, 5),
    (p_org_id, 'price_too_high', 'Price too high', 'விலை அதிகம்', 'offset', 1, 'call', true, 'contacted', null, false, true, 6),
    (p_org_id, 'not_reachable', 'Not reachable / busy / switched off', 'தொடர்பு கிடைக்கவில்லை / பிஸி / சுவிட்ச் ஆஃப்', 'offset', 1, 'call', true, null, null, true, true, 7),
    (p_org_id, 'wrong_number', 'Wrong number', 'தவறான எண்', 'none', null, 'call', false, 'lost', 'wrong_number', false, true, 8),
    (p_org_id, 'not_interested', 'Not interested', 'ஆர்வமில்லை', 'none', null, 'call', false, 'lost', 'no_longer_needs', false, true, 9),
    (p_org_id, 'bought_elsewhere', 'Bought elsewhere', 'வேறு இடத்தில் வாங்கினார்', 'none', null, 'call', false, 'lost', 'chose_competitor', false, true, 10),
    (p_org_id, 'bought_from_us', 'Bought from us', 'நம்மிடம் வாங்கினார்', 'none', null, 'call', false, 'won', null, false, true, 11)
  on conflict (org_id, code) do nothing;
$$;
revoke execute on function public.seed_lead_outcomes(uuid) from public, anon, authenticated;

select public.seed_lead_outcomes(id) from public.organizations;

create or replace function public.trg_seed_lead_outcomes()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.seed_lead_outcomes(new.id);
  return new;
end;
$$;
revoke execute on function public.trg_seed_lead_outcomes() from public, anon, authenticated;

create trigger seed_lead_outcomes_on_org after insert on public.organizations
  for each row execute function public.trg_seed_lead_outcomes();

-- ── lead_activities: authorship + outcome + structured stage change ──────
alter table public.lead_activities
  add column created_by uuid references public.profiles (id) on delete set null default auth.uid(),
  add column is_system boolean not null default false,
  add column outcome_id uuid references public.lead_outcomes (id) on delete restrict,
  add column from_status public.lead_status,
  add column to_status public.lead_status;

-- Existing rows keep created_by null + is_system false => "Before upgrade".
-- From now on a null auth.uid() (bot, trigger-less system writes) is "System".
alter table public.lead_activities alter column is_system set default (auth.uid() is null);

create index lead_activities_created_by_idx on public.lead_activities (created_by) where created_by is not null;

-- ── leads: postpone count + denormalised next follow-up ──────────────────
alter table public.leads
  add column postpone_count integer not null default 0 check (postpone_count >= 0),
  add column next_followup_at timestamptz;

create index leads_next_followup_idx on public.leads (org_id, next_followup_at) where status not in ('won', 'lost');

-- ── lead_followups ───────────────────────────────────────────────────────
create table public.lead_followups (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  lead_id uuid not null references public.leads (id) on delete cascade,
  due_at timestamptz not null,
  type public.lead_followup_type not null default 'call',
  -- True when staff picked an exact time (drives the 15-minute reminder).
  is_exact_time boolean not null default false,
  note text,
  status public.lead_followup_status not null default 'open',
  -- How this task came to exist: outcome | reschedule | initial_call | reopen | manual
  source text not null default 'manual',
  created_by uuid references public.profiles (id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  completed_by uuid references public.profiles (id) on delete set null,
  completed_at timestamptz,
  completing_activity_id uuid references public.lead_activities (id) on delete set null,
  cancelled_by uuid references public.profiles (id) on delete set null,
  cancelled_at timestamptz,
  -- rescheduled | lead_won | lead_lost
  cancel_reason text,
  -- Free-text reason staff gave when postponing without contacting the customer.
  reschedule_reason text,
  -- The task this one replaced (reschedule chain).
  replaces_followup_id uuid references public.lead_followups (id) on delete set null,
  updated_at timestamptz not null default now(),
  constraint lead_followups_done_has_completion check (status <> 'done' or completed_at is not null),
  constraint lead_followups_cancelled_has_cancellation check (status <> 'cancelled' or cancelled_at is not null)
);

-- Exactly ONE open follow-up per lead.
create unique index lead_followups_one_open_per_lead on public.lead_followups (lead_id) where status = 'open';
create index lead_followups_lead_id_idx on public.lead_followups (lead_id, created_at);
create index lead_followups_due_idx on public.lead_followups (org_id, due_at) where status = 'open';

alter table public.lead_followups enable row level security;

-- Read: master + sales_admin only. No client write policies — RPC only.
create policy lead_followups_select_sales on public.lead_followups
  for select using (org_id = public.current_org_id() and public.is_sales_staff());

create trigger set_updated_at before update on public.lead_followups for each row execute function public.set_updated_at();

-- Notification idempotency (digest once a day, reminder once per task, ...).
create table public.lead_notification_log (
  kind text not null,
  key text not null,
  created_at timestamptz not null default now(),
  primary key (kind, key)
);
alter table public.lead_notification_log enable row level security;
-- (no policies: only the SECURITY DEFINER runner touches it)
