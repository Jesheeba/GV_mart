-- Daily meeting (huddle) log: one meeting_logs row per org per day, with
-- meeting_issues tracking problems/root cause/solution. Open issues carry
-- forward by QUERY (status = 'open', any meeting_id) — no copy rows.
-- Action items are plain `tasks` rows with ref_type='meeting_issue'
-- (reuses assignment + _notify_task_assigned; nothing new there).
-- Performance numbers are rendered live from existing KPI queries, so no
-- snapshot table. NB: unrelated to attendance.meeting (the technician tick).
--
-- RLS: org-wide SELECT for every internal role (technicians read-only);
-- writes gated to is_staff(). Only master may delete.

create table public.meeting_logs (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  meeting_date date not null,
  recorded_by uuid references public.profiles (id) on delete set null,
  general_notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint meeting_logs_org_date_key unique (org_id, meeting_date)
);

create table public.meeting_issues (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  meeting_id uuid not null references public.meeting_logs (id) on delete cascade,
  description text not null check (length(btrim(description)) > 0),
  raised_by uuid references public.profiles (id) on delete set null,
  root_cause text,
  solution text,
  status text not null default 'open' check (status in ('open', 'solved')),
  owner_id uuid references public.profiles (id) on delete set null,
  date_raised date not null,
  date_solved date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint meeting_issues_solved_has_date check (status = 'open' or date_solved is not null)
);

create index meeting_issues_org_status_idx on public.meeting_issues (org_id, status);
create index meeting_issues_meeting_idx on public.meeting_issues (meeting_id);

create trigger set_updated_at before update on public.meeting_logs
  for each row execute function public.set_updated_at();
create trigger set_updated_at before update on public.meeting_issues
  for each row execute function public.set_updated_at();

alter table public.meeting_logs enable row level security;
alter table public.meeting_issues enable row level security;

create policy meeting_logs_select_org on public.meeting_logs
  for select using (org_id = public.current_org_id());
create policy meeting_logs_insert_staff on public.meeting_logs
  for insert with check (org_id = public.current_org_id() and public.is_staff());
create policy meeting_logs_update_staff on public.meeting_logs
  for update using (org_id = public.current_org_id() and public.is_staff())
  with check (org_id = public.current_org_id() and public.is_staff());
create policy meeting_logs_delete_master on public.meeting_logs
  for delete using (org_id = public.current_org_id() and public.is_master());

create policy meeting_issues_select_org on public.meeting_issues
  for select using (org_id = public.current_org_id());
create policy meeting_issues_insert_staff on public.meeting_issues
  for insert with check (org_id = public.current_org_id() and public.is_staff());
create policy meeting_issues_update_staff on public.meeting_issues
  for update using (org_id = public.current_org_id() and public.is_staff())
  with check (org_id = public.current_org_id() and public.is_staff());
create policy meeting_issues_delete_master on public.meeting_issues
  for delete using (org_id = public.current_org_id() and public.is_master());

-- Reminder config: null time = reminder off. last_date is the once-per-day
-- guard (same state-flip-as-lock idiom as open_monthly_quote_requests).
alter table public.settings
  add column if not exists huddle_reminder_time time,
  add column if not exists huddle_reminder_last_date date;

comment on column public.settings.huddle_reminder_time is
  'IST time-of-day after which staff are reminded if no huddle log exists for today. Null = reminder off.';
comment on column public.settings.huddle_reminder_last_date is
  'IST date the huddle reminder last fired — guards against re-sending on every 5-minute tick.';

-- Called every tick by wa-scheduled-tasks (service_role only). Returns 1 if
-- a reminder was sent, else 0.
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
$$;

revoke all on function public.wa_send_huddle_reminder(uuid) from public, anon, authenticated;
grant execute on function public.wa_send_huddle_reminder(uuid) to service_role;
