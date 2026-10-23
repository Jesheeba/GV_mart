-- Baselines the audit_reconciliation_report() findings from
-- 20261024100700. The 2026-10 investigation explained the drift as it
-- stood then: positive on tables whose history predates their trigger,
-- negative on rows (311, confirmed by name — "DEBUG-TEST", "Tracking DoD
-- test ticket (temporary)") deleted with triggers bypassed between
-- 2026-07-02 and 2026-10-08, stopped since. That number is explained,
-- but repeating it every run buries any NEW drift inside noise that's
-- already understood. This stores it once as a reference point and
-- changes the report to lead with movement away from it.
--
-- Append-only, deliberately. An overwriting baseline is resettable by
-- the same privilege that could bypass the audit triggers in the first
-- place — delete rows with triggers off, re-capture, and the detector
-- goes quiet about exactly what it exists to find. What this needs to
-- preserve is not "what the baseline currently is" but "the baseline
-- moved on this date, by this person, for this reason" — every capture
-- is a new row, never an update, and `reason` is mandatory. The report
-- below reads the most recent row per table.
--
-- NOT a re-tamperproofing measure — same caveat as 20261024100700's own
-- comments: this only ever sees what the trigger recorded. A delete that
-- bypasses the trigger (session_replication_role, DISABLE TRIGGER) is
-- invisible to the live/net counts just as much as it always was; what
-- this adds is catching the NEXT one quickly instead of it sitting
-- unnoticed for three months, not making the underlying bypass harder.

create table public.audit_reconciliation_baseline (
  id uuid primary key default gen_random_uuid(),
  table_name text not null,
  live_count bigint not null,
  net_count bigint not null,
  diff bigint not null,
  captured_at timestamptz not null default now(),
  captured_by uuid references public.profiles (id) on delete set null,
  reason text not null check (nullif(btrim(reason), '') is not null)
);

create index audit_reconciliation_baseline_latest_idx
  on public.audit_reconciliation_baseline (table_name, captured_at desc);

alter table public.audit_reconciliation_baseline enable row level security;

-- Append-only in practice, not just in intent: master can insert and
-- select, nobody can update or delete (no such policies exist at all —
-- RLS defaults to deny, and there's no update/delete policy to grant
-- it). A correction needs a new row with its own reason, same as every
-- other append-only ledger in this codebase.
create policy audit_reconciliation_baseline_select_master on public.audit_reconciliation_baseline
  for select using (public.is_master());
create policy audit_reconciliation_baseline_insert_master on public.audit_reconciliation_baseline
  for insert with check (public.is_master());

-- Deliberately NOT wired to audit_master_change: that trigger assumes
-- every audited row carries an org_id, and this table's rows are
-- cross-org by design (one row per table_name, not per organisation).
-- The table is append-only and carries its own captured_by/reason, which
-- is sufficient provenance for an admin ledger that isn't itself
-- business data.

-- Master-run. p_reason has no default — the call site must always name
-- why a new baseline is being captured (expanding coverage to a newly
-- audited table, accepting a newly-investigated and understood drift,
-- correcting a prior capture). Every call inserts fresh rows; it never
-- updates or deletes anything.
create or replace function public.capture_audit_reconciliation_baseline(p_reason text)
returns setof public.audit_reconciliation_baseline
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_master() then
    raise exception 'capture_audit_reconciliation_baseline: master role required';
  end if;
  if nullif(btrim(p_reason), '') is null then
    raise exception 'capture_audit_reconciliation_baseline: a reason is required';
  end if;

  return query
  insert into public.audit_reconciliation_baseline (table_name, live_count, net_count, diff, captured_by, reason)
  select table_name, live_count, net_audit_count, difference, auth.uid(), p_reason
  from public.audit_reconciliation_report()
  returning *;
end;
$$;

grant execute on function public.capture_audit_reconciliation_baseline(text) to authenticated;
revoke execute on function public.capture_audit_reconciliation_baseline(text) from public, anon;

-- Replaces 20261024100700's version. Same table-discovery loop; adds the
-- baseline comparison and a moved_since_baseline flag so routine
-- scanning can filter to "where moved_since_baseline" and ignore
-- everything else. Compares against the MOST RECENT baseline row per
-- table (distinct on, ordered by captured_at desc) — never an average
-- or a sum across the append-only history, just the latest accepted
-- figure. A table with no baseline row at all reports baseline_difference
-- as null and moved_since_baseline as true by construction — an
-- unbaselined table has no "known-explained" figure to fall back on, so
-- any diff on it is new information by definition.
create or replace function public.audit_reconciliation_report()
returns table (
  table_name text,
  live_count bigint,
  net_audit_count bigint,
  difference bigint,
  baseline_difference bigint,
  moved_since_baseline boolean
)
language plpgsql
security definer
set search_path = public
as $$
declare
  r record;
  v_live bigint;
  v_net bigint;
  v_baseline bigint;
begin
  if not public.is_master() then
    raise exception 'audit_reconciliation_report: master role required';
  end if;

  for r in
    select distinct c.relname as tbl
    from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_proc p on p.oid = t.tgfoid
    where p.proname = 'audit_master_change'
      and not t.tgisinternal
    order by 1
  loop
    execute format('select count(*) from public.%I', r.tbl) into v_live;
    select coalesce(count(*) filter (where audit_log.action = 'INSERT'), 0) - coalesce(count(*) filter (where audit_log.action = 'DELETE'), 0)
      into v_net
    from public.audit_log
    where audit_log.table_name = r.tbl;

    select b.diff into v_baseline
    from public.audit_reconciliation_baseline b
    where b.table_name = r.tbl
    order by b.captured_at desc
    limit 1;

    table_name := r.tbl;
    live_count := v_live;
    net_audit_count := v_net;
    difference := v_live - v_net;
    baseline_difference := v_baseline;
    moved_since_baseline := (v_baseline is null) or (difference is distinct from v_baseline);
    return next;
  end loop;
end;
$$;

grant execute on function public.audit_reconciliation_report() to authenticated;
revoke execute on function public.audit_reconciliation_report() from public, anon;
