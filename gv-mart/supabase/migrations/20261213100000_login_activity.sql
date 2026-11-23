-- Login Activity (HR tab), 2026-11-23. Design: build-docs/features/login-activity.md
--
-- Why triggers on auth.sessions: this project has no login history anywhere (auth.audit_log_entries is empty, and
-- GoTrue deletes an auth.sessions row on sign-out). Every sign-in method (password, Google, OTP, Android app) creates
-- exactly one auth.sessions row, so recording there covers all of them server-side and can't be skipped by a client.
--
-- Safety: every trigger body swallows its own errors (raise warning, never raise). A failing trigger on
-- auth.sessions would otherwise abort the session insert and block every login in the app.
--
-- Owner decisions: device (user agent) only, NO IP stored; 90-day retention; master-only read.

create table if not exists public.login_sessions (
  session_id   uuid primary key,                       -- = auth.sessions.id
  user_id      uuid not null references auth.users(id) on delete cascade,
  org_id       uuid references public.organizations(id) on delete cascade,
  role         text,                                   -- snapshot at login; role can change later
  started_at   timestamptz not null,
  last_seen_at timestamptz,
  ended_at     timestamptz,                            -- null = session still open
  user_agent   text
);

create index if not exists login_sessions_org_started_idx on public.login_sessions (org_id, started_at desc);
create index if not exists login_sessions_user_idx on public.login_sessions (user_id);
create index if not exists login_sessions_started_idx on public.login_sessions (started_at);

-- RPC-only access (house style, same as lead_followups): RLS on, no policies, no direct table privileges.
alter table public.login_sessions enable row level security;
revoke all on table public.login_sessions from public, anon, authenticated;

-- ── capture triggers on auth.sessions ─────────────────────────────────────────
create or replace function public._login_sessions_on_insert()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  begin
    insert into public.login_sessions (session_id, user_id, org_id, role, started_at, last_seen_at, user_agent)
    select new.id, new.user_id, p.org_id, p.role::text, coalesce(new.created_at, now()), coalesce(new.created_at, now()),
           left(new.user_agent, 300)
      from (select 1) x
      left join public.profiles p on p.id = new.user_id
    on conflict (session_id) do nothing;
  exception when others then
    raise warning '_login_sessions_on_insert: % (session %)', sqlerrm, new.id;
  end;
  return null;
end $$;

create or replace function public._login_sessions_on_update()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  begin
    update public.login_sessions set last_seen_at = now() where session_id = new.id;
  exception when others then
    raise warning '_login_sessions_on_update: % (session %)', sqlerrm, new.id;
  end;
  return null;
end $$;

create or replace function public._login_sessions_on_delete()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  begin
    update public.login_sessions set ended_at = now() where session_id = old.id and ended_at is null;
  exception when others then
    raise warning '_login_sessions_on_delete: % (session %)', sqlerrm, old.id;
  end;
  return null;
end $$;

revoke all on function public._login_sessions_on_insert() from public, anon, authenticated;
revoke all on function public._login_sessions_on_update() from public, anon, authenticated;
revoke all on function public._login_sessions_on_delete() from public, anon, authenticated;

drop trigger if exists login_sessions_capture_insert on auth.sessions;
drop trigger if exists login_sessions_capture_update on auth.sessions;
drop trigger if exists login_sessions_capture_delete on auth.sessions;
create trigger login_sessions_capture_insert after insert on auth.sessions
  for each row execute function public._login_sessions_on_insert();
create trigger login_sessions_capture_update after update of refreshed_at, updated_at on auth.sessions
  for each row execute function public._login_sessions_on_update();
create trigger login_sessions_capture_delete after delete on auth.sessions
  for each row execute function public._login_sessions_on_delete();

-- Backfill the sessions open right now (no earlier history exists anywhere to recover).
insert into public.login_sessions (session_id, user_id, org_id, role, started_at, last_seen_at, user_agent)
select s.id, s.user_id, p.org_id, p.role::text, s.created_at,
       greatest(s.created_at, s.updated_at, (s.refreshed_at at time zone 'UTC')), left(s.user_agent, 300)
  from auth.sessions s
  left join public.profiles p on p.id = s.user_id
 where s.created_at is not null
on conflict (session_id) do nothing;

-- ── master-only read ──────────────────────────────────────────────────────────
-- Dates are IST calendar days, inclusive. p_role: 'all' | 'staff' | 'technician' | 'customer'.
-- org/role fall back to the current profile when the snapshot is null (e.g. a customer whose profile was created
-- after their first session row).
create or replace function public.list_login_activity(
  p_from   date,
  p_to     date,
  p_role   text default 'all',
  p_search text default null,
  p_limit  int  default 50,
  p_offset int  default 0
)
returns table (
  session_id   uuid,
  user_id      uuid,
  full_name    text,
  phone        text,
  role         text,
  started_at   timestamptz,
  last_seen_at timestamptz,
  ended_at     timestamptz,
  user_agent   text,
  total_count  bigint
)
language plpgsql stable security definer set search_path = '' as $$
#variable_conflict use_column
declare
  v_org uuid := public.current_org_id();
  v_search text := nullif(btrim(coalesce(p_search, '')), '');
begin
  if not public.is_master() or v_org is null then
    raise exception 'list_login_activity: only a master can view login activity' using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'list_login_activity: invalid date range' using errcode = '22023';
  end if;
  if p_to - p_from > 366 then
    raise exception 'list_login_activity: date range cannot exceed 366 days' using errcode = '22023';
  end if;
  if coalesce(p_role, 'all') not in ('all', 'staff', 'technician', 'customer') then
    raise exception 'list_login_activity: invalid role filter' using errcode = '22023';
  end if;
  if p_limit is null or p_limit < 1 or p_limit > 200 or p_offset is null or p_offset < 0 then
    raise exception 'list_login_activity: invalid page' using errcode = '22023';
  end if;
  if v_search is not null and length(v_search) > 100 then
    raise exception 'list_login_activity: search too long' using errcode = '22023';
  end if;
  -- escape LIKE wildcards so a search for "50%" matches literally
  v_search := replace(replace(replace(v_search, '\', '\\'), '%', '\%'), '_', '\_');

  return query
  with base as (
    select ls.session_id, ls.user_id, p.full_name, p.phone,
           coalesce(ls.role, p.role::text) as role,
           ls.started_at, ls.last_seen_at, ls.ended_at, ls.user_agent
      from public.login_sessions ls
      left join public.profiles p on p.id = ls.user_id
     where coalesce(ls.org_id, p.org_id) = v_org
       and ls.started_at >= (p_from::timestamp at time zone 'Asia/Kolkata')
       and ls.started_at <  ((p_to + 1)::timestamp at time zone 'Asia/Kolkata')
  )
  select b.session_id, b.user_id, b.full_name, b.phone, b.role,
         b.started_at, b.last_seen_at, b.ended_at, b.user_agent,
         count(*) over () as total_count
    from base b
   where (coalesce(p_role, 'all') = 'all'
          or (p_role = 'staff' and b.role in ('master', 'operation_admin', 'sales_admin'))
          or b.role = p_role)
     and (v_search is null or b.full_name ilike '%' || v_search || '%' or b.phone ilike '%' || v_search || '%')
   order by b.started_at desc, b.session_id
   limit p_limit offset p_offset;
end $$;

revoke all on function public.list_login_activity(date, date, text, text, int, int) from public, anon;
grant execute on function public.list_login_activity(date, date, text, text, int, int) to authenticated;

-- ── 90-day retention ──────────────────────────────────────────────────────────
create or replace function public.purge_login_sessions()
returns integer language plpgsql security definer set search_path = '' as $$
declare n integer;
begin
  delete from public.login_sessions where started_at < now() - interval '90 days';
  get diagnostics n = row_count;
  return n;
end $$;

revoke all on function public.purge_login_sessions() from public, anon, authenticated;

create extension if not exists pg_cron with schema pg_catalog;

-- daily 02:30 IST = 21:00 UTC; same unschedule-then-schedule idempotent shape as sync-outstanding-tasks
do $$
begin
  if exists (select 1 from cron.job where jobname = 'purge-login-sessions') then
    perform cron.unschedule('purge-login-sessions');
  end if;
  perform cron.schedule('purge-login-sessions', '0 21 * * *', 'select public.purge_login_sessions()');
end
$$;
