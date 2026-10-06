-- Lead follow-up Phase 2, gap 2: append-only stage history + funnel RPC.
--
-- * lead_stage_log: one row per stage change, written ONLY by database
--   triggers on public.leads (so no code path — stage buttons, log_lead_outcome,
--   reopen_lead, create_sale's direct "won" update, direct table updates — can
--   skip it). No client write policies; UPDATE/DELETE are rejected by trigger.
-- * Existing leads get ONE honest backfill row: from_status NULL, to_status =
--   the status they have right now, source 'backfill', changed_at = the time of
--   this migration. It says "this is what we know today", never a guessed
--   history. A lead lost before this migration therefore stays "stage unknown".
-- * get_lead_funnel: same numbers as the old client-side funnel for leads with
--   no richer history; lost leads that DO have logged history are placed at the
--   furthest stage they reached.
-- * Stage-change context (source, reason) is passed from the RPCs to the
--   trigger through transaction-local settings app.lead_stage_source /
--   app.lead_stage_reason (set_config(..., true)); an unset source is 'other'.

create table public.lead_stage_log (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  lead_id uuid not null references public.leads (id) on delete cascade,
  -- NULL from_status = no earlier stage known (creation, or backfilled history).
  from_status public.lead_status,
  to_status public.lead_status not null,
  changed_by uuid references public.profiles (id) on delete set null,
  changed_at timestamptz not null default clock_timestamp(),
  reason text,
  -- creation | outcome | stage_button | reopen | backfill | other
  source text not null default 'other' check (source in ('creation', 'outcome', 'stage_button', 'reopen', 'backfill', 'other'))
);

create index lead_stage_log_lead_idx on public.lead_stage_log (lead_id, changed_at);
create index lead_stage_log_org_idx on public.lead_stage_log (org_id, changed_at);

alter table public.lead_stage_log enable row level security;
create policy lead_stage_log_select_master on public.lead_stage_log
  for select using (org_id = public.current_org_id() and public.is_master());
-- no insert/update/delete policies: only the SECURITY DEFINER triggers below write.

-- Append-only. A lead's own deletion cascades to its log rows, so a DELETE is
-- allowed only once the parent lead no longer exists.
create or replace function public._trg_lead_stage_log_immutable()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'DELETE' and not exists (select 1 from public.leads where id = old.lead_id) then
    return old;
  end if;
  raise exception 'lead_stage_log is append-only';
end;
$$;
revoke execute on function public._trg_lead_stage_log_immutable() from public, anon, authenticated;

create trigger lead_stage_log_immutable
  before update or delete on public.lead_stage_log
  for each row execute function public._trg_lead_stage_log_immutable();

-- ── writers (both on public.leads) ───────────────────────────────────────

create or replace function public._trg_lead_stage_log_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.lead_stage_log (org_id, lead_id, from_status, to_status, changed_by, source)
  values (new.org_id, new.id, null, new.status, auth.uid(), 'creation');
  return null;
end;
$$;
revoke execute on function public._trg_lead_stage_log_insert() from public, anon, authenticated;

create trigger leads_stage_log_insert
  after insert on public.leads
  for each row execute function public._trg_lead_stage_log_insert();

-- Redefined from 20261006210000: still writes the lead_activities timeline row,
-- and now also the stage log. For a reopen the timeline note is the reason.
create or replace function public._trg_lead_status_history()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_source text := coalesce(nullif(current_setting('app.lead_stage_source', true), ''), 'other');
  v_reason text := nullif(btrim(coalesce(current_setting('app.lead_stage_reason', true), '')), '');
begin
  if v_source not in ('outcome', 'stage_button', 'reopen') then
    v_source := 'other';
  end if;

  insert into public.lead_activities (org_id, lead_id, type, note, at, from_status, to_status)
  values (
    new.org_id, new.id, 'status_change',
    case
      when v_source = 'reopen' then v_reason
      when new.status = 'lost' then new.lost_reason
      else new.status::text
    end,
    clock_timestamp(), old.status, new.status
  );

  insert into public.lead_stage_log (org_id, lead_id, from_status, to_status, changed_by, reason, source)
  values (
    new.org_id, new.id, old.status, new.status, auth.uid(),
    case when new.status = 'lost' then coalesce(new.lost_reason, v_reason) else v_reason end,
    v_source
  );
  return null;
end;
$$;
revoke execute on function public._trg_lead_status_history() from public, anon, authenticated;

-- ── honest backfill ──────────────────────────────────────────────────────
-- changed_by stays NULL (nobody is credited), source 'backfill', from_status NULL.
insert into public.lead_stage_log (org_id, lead_id, from_status, to_status, changed_by, changed_at, source)
select l.org_id, l.id, null, l.status, null, now(), 'backfill'
from public.leads l
where not exists (select 1 from public.lead_stage_log g where g.lead_id = l.id);

-- ── pre-closing stage (used by reopen in the next migration) ─────────────
-- The stage the lead was in just before its most recent close. NULL = unknown
-- (no logged transition into won/lost, e.g. closed before this log existed).
create or replace function public._lead_pre_close_stage(p_lead_id uuid)
returns public.lead_status
language sql
stable
security definer
set search_path = public
as $$
  select g.from_status
  from public.lead_stage_log g
  where g.lead_id = p_lead_id and g.to_status in ('won', 'lost') and g.from_status in ('new', 'contacted', 'quoted')
  order by g.changed_at desc, g.id desc
  limit 1
$$;
revoke execute on function public._lead_pre_close_stage(uuid) from public, anon, authenticated;

-- ── funnel ───────────────────────────────────────────────────────────────
-- reached_rank per lead = furthest of new(1) < contacted(2) < quoted(3) < won(4)
-- seen in the log (as a to_status or from_status). Lost is not a rank, so a lost
-- lead with only a backfill row has no rank = "stage unknown".
create or replace function public.get_lead_funnel(p_from timestamptz, p_to timestamptz)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_org uuid := public.current_org_id();
  v_result jsonb;
begin
  if not public.is_staff() then
    raise exception 'not permitted: only staff can view the lead funnel';
  end if;

  with lr as (
    select l.id, l.status, l.source,
      (select max(case s when 'new' then 1 when 'contacted' then 2 when 'quoted' then 3 when 'won' then 4 end)
         from public.lead_stage_log g, lateral (values (g.to_status), (g.from_status)) v(s)
         where g.lead_id = l.id) as rank
    from public.leads l
    where l.org_id = v_org and l.created_at >= p_from and l.created_at <= p_to
  )
  select jsonb_build_object(
    'total', (select count(*) from lr),
    'by_status', jsonb_build_object(
      'new', (select count(*) from lr where status = 'new'),
      'contacted', (select count(*) from lr where status = 'contacted'),
      'quoted', (select count(*) from lr where status = 'quoted'),
      'won', (select count(*) from lr where status = 'won'),
      'lost', (select count(*) from lr where status = 'lost')),
    'reached', jsonb_build_object(
      'created', (select count(*) from lr where rank >= 1),
      'contacted', (select count(*) from lr where rank >= 2),
      'quoted', (select count(*) from lr where rank >= 3),
      'won', (select count(*) from lr where rank >= 4)),
    'lost_stage_known', (select count(*) from lr where status = 'lost' and rank is not null),
    'lost_stage_unknown', (select count(*) from lr where status = 'lost' and rank is null),
    'by_source', coalesce((
      select jsonb_agg(jsonb_build_object('source', source, 'total', total, 'won', won) order by total desc, source)
      from (select source, count(*) as total, count(*) filter (where status = 'won') as won from lr group by source) s
    ), '[]'::jsonb)
  ) into v_result;
  return v_result;
end;
$$;

revoke execute on function public.get_lead_funnel(timestamptz, timestamptz) from public, anon;
grant execute on function public.get_lead_funnel(timestamptz, timestamptz) to authenticated;
