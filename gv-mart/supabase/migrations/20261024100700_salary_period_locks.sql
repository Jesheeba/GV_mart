-- Salary period finalization (2026-10-23 payroll-integrity review, raised
-- while building the Monthly Expenses feature). Investigation found:
--   * compute_salary is permanently recomputable — no period was ever closed.
--   * A real technician's July salaries row (Karthik Raja, net -46.20 against
--     a zero base — no tier assigned that month) was later DELETED from the
--     live database with no DELETE row in audit_log, despite audit_salaries
--     correctly covering DELETE and being enabled throughout. Confirmed this
--     is NOT a missing-trigger-coverage problem (every audit_master_change
--     trigger on every one of its 46 tables covers INSERT/UPDATE/DELETE, all
--     enabled) — the mechanism is a known, already-used bypass
--     (`set local session_replication_role = replica`, used elsewhere in
--     this codebase for legitimate column backfills) that disables every
--     trigger for a transaction and leaves no trace that it ran. The row is
--     gone and unprovable; this migration does not attempt to restore it.
--
-- WHAT THIS DOES NOT PROTECT AGAINST — read this before trusting the lock:
-- the guard below is a trigger, exactly like audit_salaries. A caller with
-- enough privilege to run `set local session_replication_role = replica`
-- (or `alter table ... disable trigger ...`) around a write defeats this
-- lock exactly the same way the same technique already defeated
-- audit_salaries for Karthik's row. This is a guard against the accidental
-- path — a recompute, a direct RLS-permitted UPDATE, an ordinary DELETE —
-- which is the common case. It is not tamper-proofing against a privileged
-- session that deliberately works around it, and anyone reading this in six
-- months should not mistake it for one.

-- ── 1. The lock itself ──────────────────────────────────────────────────
create table public.salary_period_locks (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  period date not null,
  locked boolean not null default true,
  locked_by uuid references public.profiles (id) on delete set null,
  locked_at timestamptz not null default now(),
  -- null while locked; set to the reopen reason when locked = false. Master
  -- only, same reason-required convention as every other admin-entered
  -- amount/decision in this codebase.
  reason text,
  unique (org_id, period)
);

alter table public.salary_period_locks enable row level security;

create policy salary_period_locks_select_master on public.salary_period_locks
  for select using (org_id = public.current_org_id() and public.is_master());
create policy salary_period_locks_write_master on public.salary_period_locks for all
  using (org_id = public.current_org_id() and public.is_master())
  with check (org_id = public.current_org_id() and public.is_master());

create trigger audit_salary_period_locks after insert or update or delete on public.salary_period_locks
  for each row execute function public.audit_master_change();

create or replace function public.is_salary_period_locked(p_org_id uuid, p_period date)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.salary_period_locks
    where org_id = p_org_id and period = date_trunc('month', p_period)::date and locked
  );
$$;

grant execute on function public.is_salary_period_locked(uuid, date) to authenticated;
revoke execute on function public.is_salary_period_locked(uuid, date) from public, anon;

-- ── 2. The guard, enforced at the table — not just inside compute_salary ──
-- salaries_write_master already lets a master UPDATE/DELETE this table
-- directly via RLS, so a check only inside compute_salary's own body would
-- leave that door open. One BEFORE trigger closes both paths at once, and
-- covers INSERT too (addition a): a locked period must not gain a brand
-- new salaries row either — there is no legitimate reason a technician's
-- payroll for an already-finalized month should first appear after the
-- fact, and allowing INSERT while blocking UPDATE/DELETE would just move
-- the hole rather than close it.
create or replace function public._guard_locked_salary_period()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
  v_period date;
begin
  if TG_OP = 'DELETE' then
    v_org_id := old.org_id;
    v_period := old.period;
  else
    v_org_id := new.org_id;
    v_period := new.period;
  end if;

  if public.is_salary_period_locked(v_org_id, v_period) then
    raise exception '%: period % is finalized for this organisation; reopen it first', TG_TABLE_NAME, v_period;
  end if;

  if TG_OP = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

create trigger guard_locked_salary_period before insert or update or delete on public.salaries
  for each row execute function public._guard_locked_salary_period();

-- Addition (b): checked what the payslip and the Incentives tab actually
-- read. The payslip (SalaryTab.tsx) reads only the salaries row, so locking
-- salaries alone would freeze its total correctly. But IncentivesTab.tsx
-- reads `incentives_earned` DIRECTLY (its own doc comment: "read view of
-- incentives_earned ... NOT [salaries]") — a separate, live screen into the
-- exact detail that salaries.incentives sums. If only `salaries` were
-- locked, compute_incentives could keep moving that detail (it already
-- recomputes installation-ticket credits and per-unit rates on every run,
-- by design, for unrelated reasons) while the frozen total sat there
-- silently disagreeing with it. The lock extends to incentives_earned too,
-- for exactly the same reason and via the same guard function —
-- incentives_earned already carries its own org_id/period columns, so no
-- join is needed.
create trigger guard_locked_salary_period before insert or update or delete on public.incentives_earned
  for each row execute function public._guard_locked_salary_period();

-- ── 3. Master-only RPCs ────────────────────────────────────────────────
create or replace function public.lock_salary_period(p_org_id uuid, p_period date)
returns public.salary_period_locks
language plpgsql
security definer
set search_path = public
as $$
declare
  v_period date := date_trunc('month', p_period)::date;
  v_row public.salary_period_locks;
begin
  if not public.is_master() then
    raise exception 'lock_salary_period: master role required';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'lock_salary_period: org mismatch';
  end if;

  insert into public.salary_period_locks (org_id, period, locked, locked_by, locked_at, reason)
  values (p_org_id, v_period, true, auth.uid(), now(), null)
  on conflict (org_id, period) do update set
    locked = true, locked_by = auth.uid(), locked_at = now(), reason = null
  returning * into v_row;

  return v_row;
end;
$$;

-- Reopening is a correction, not routine — reason is mandatory, same as
-- every other reason-required action in this feature. The before/after on
-- `locked` (true -> false) is captured by audit_salary_period_locks above
-- with no new audit mechanism; re-locking afterward goes through
-- lock_salary_period again and is captured the same way, so the full
-- lock/reopen/re-lock history for a period lives in audit_log using the
-- pattern that already exists everywhere else in this codebase.
create or replace function public.reopen_salary_period(p_org_id uuid, p_period date, p_reason text)
returns public.salary_period_locks
language plpgsql
security definer
set search_path = public
as $$
declare
  v_period date := date_trunc('month', p_period)::date;
  v_row public.salary_period_locks;
begin
  if not public.is_master() then
    raise exception 'reopen_salary_period: master role required';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'reopen_salary_period: org mismatch';
  end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception 'reopen_salary_period: a reason is required';
  end if;

  update public.salary_period_locks
  set locked = false, locked_by = auth.uid(), locked_at = now(), reason = btrim(p_reason)
  where org_id = p_org_id and period = v_period
  returning * into v_row;

  if v_row.id is null then
    raise exception 'reopen_salary_period: period % is not locked', v_period;
  end if;

  return v_row;
end;
$$;

grant execute on function public.lock_salary_period(uuid, date) to authenticated;
grant execute on function public.reopen_salary_period(uuid, date, text) to authenticated;
revoke execute on function public.lock_salary_period(uuid, date) from public, anon;
revoke execute on function public.reopen_salary_period(uuid, date, text) from public, anon;

-- ── 4. verify_expense_claim rejects loudly against a locked period ───────
-- Answered properly rather than left to the UI: a claim verified after its
-- period is finalized is REJECTED, not silently redirected to next month
-- and not auto-reopening the period. Verification is a bill-review action;
-- forcing a reopen automatically would undermine the entire point of
-- locking (any late bill would silently unlock history). The admin must
-- make a deliberate choice: reopen the month (itself audited) or leave the
-- claim sitting unverified.
--
-- Verbatim live body (20261024100300_expense_claims.sql) with one check
-- added, placed right after the claim is found (so the error names the
-- actual period, not a generic failure).
create or replace function public.verify_expense_claim(
  p_claim_id uuid,
  p_verified_amount numeric,
  p_reason text default null
)
returns public.expense_claims
language plpgsql
security definer
set search_path = public
as $$
declare
  v_claim public.expense_claims;
begin
  if not public.is_ops_staff() then
    raise exception 'verify_expense_claim: master or operation_admin role required';
  end if;
  select * into v_claim from public.expense_claims where id = p_claim_id and org_id = public.current_org_id();
  if v_claim.id is null then
    raise exception 'verify_expense_claim: claim % not found', p_claim_id;
  end if;
  if public.is_salary_period_locked(v_claim.org_id, v_claim.period) then
    raise exception 'verify_expense_claim: period % is finalized for this organisation; reopen it to verify this claim', v_claim.period;
  end if;
  if p_verified_amount is null or p_verified_amount < 0 then
    raise exception 'verify_expense_claim: verified_amount must be a non-negative number';
  end if;
  if p_verified_amount is distinct from v_claim.submitted_amount and nullif(btrim(p_reason), '') is null then
    raise exception 'verify_expense_claim: reason is required when the verified amount differs from the submitted amount';
  end if;

  update public.expense_claims
  set verified_amount = p_verified_amount,
      verified_by = auth.uid(),
      verified_at = now(),
      reason = nullif(btrim(p_reason), '')
  where id = p_claim_id
  returning * into v_claim;

  return v_claim;
end;
$$;

grant execute on function public.verify_expense_claim(uuid, numeric, text) to authenticated;
revoke execute on function public.verify_expense_claim(uuid, numeric, text) from public, anon;

-- ── 5. compute_salary: refuse a locked period early, and floor net at zero ─
-- (a) Early guard purely for a clean error message before any work is done
-- — the table trigger in §2 would catch it regardless on the INSERT/UPDATE
-- below, but with a less specific error. Redundant by design, not relied
-- on alone.
-- (b) Addition (d): Karthik Raja's July net was -46.20 — late_deduction
-- (46.20) exceeded base+revenue+incentives (0) because he had no tier
-- assigned that month. Chose FLOOR AT ZERO over blocking the computation:
-- blocking would stop that technician's row from being written at all
-- until an admin fixes the tier assignment, which (a) is a bigger behaviour
-- change for a payroll run that's otherwise fine for every other
-- technician, since "Compute All" calls compute_salary once per technician
-- independently and a hard block only ever affects that one row anyway, and
-- (b) a missing tier is already visible in the breakdown as base=0 without
-- needing to block anything. Flooring never pays negative money (the actual
-- problem) while leaving the underlying "no tier assigned" data gap exactly
-- as visible as it already was — this does not fix that gap, it only
-- stops it from producing a nonsensical negative salary.
create or replace function public.compute_salary(
  p_org_id uuid,
  p_technician_id uuid,
  p_period date
)
returns salaries
language plpgsql
security definer
set search_path = public
as $$
declare
  v_period date := date_trunc('month', p_period)::date;
  v_base numeric(12, 2);
  v_revenue numeric(12, 2);
  v_late_hours numeric(12, 2);
  v_late_deduction numeric(12, 2);
  v_incentives numeric(12, 2);
  v_row salaries;
  -- Unit 6 additions.
  v_profile_id uuid;
  v_recharge numeric(12, 2);
  v_recharge_reason text;
  v_km numeric(12, 2);
  v_rate numeric(12, 2);
  v_petrol_reference numeric(12, 2);
  v_petrol numeric(12, 2);
  v_maintenance numeric(12, 2);
  v_bike_row incentives_earned;
  v_bike_base numeric(12, 2);
  v_bike_extra numeric(12, 2);
  v_bike_reason text;
  v_bike_amount numeric(12, 2);
  v_net numeric(12, 2);
begin
  if not public.is_master() then
    raise exception 'compute_salary: master role required';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'compute_salary: org mismatch';
  end if;
  if not exists (select 1 from public.technicians where id = p_technician_id and org_id = p_org_id) then
    raise exception 'compute_salary: technician % not found in org %', p_technician_id, p_org_id;
  end if;
  if public.is_salary_period_locked(p_org_id, v_period) then
    raise exception 'compute_salary: period % is finalized for this organisation; reopen it first', v_period;
  end if;

  select tt.monthly_salary into v_base
  from public.technicians t
  join public.technician_tiers tt on tt.id = t.tier_id
  where t.id = p_technician_id;
  if v_base is null then
    select tt.monthly_salary into v_base
    from public.technician_tiers tt
    where tt.org_id = p_org_id and tt.rank = 1;
  end if;
  v_base := coalesce(v_base, 0);

  v_revenue := public.technician_attributed_revenue(p_org_id, p_technician_id, v_period);
  v_late_hours := public.technician_late_hours(p_org_id, p_technician_id, v_period);
  -- v2.2: "late deduction hours x 2" — see original definition.
  v_late_deduction := round(v_late_hours * 2, 2);

  select coalesce(sum(amount), 0) into v_incentives
  from public.incentives_earned
  where org_id = p_org_id and technician_id = p_technician_id and period = v_period;

  -- ── Monthly Expenses itemised lines ──────────────────────────────────
  select profile_id into v_profile_id from public.technicians where id = p_technician_id;

  -- Recharge: a flat allowance set per person; no amount set is the whole
  -- scoping rule (§1.1). Still uses monthly_adjustments (recharge was never
  -- part of the petrol/maintenance revision).
  select coalesce(recharge_amount, 0) into v_recharge
  from public.person_allowance_on(p_org_id, v_profile_id, v_period);
  v_recharge := coalesce(v_recharge, 0);
  if public.monthly_adjustment_excluded(p_org_id, v_profile_id, v_period, 'recharge') then
    v_recharge := 0;
  end if;
  v_recharge := v_recharge + public.monthly_adjustment_top_up(p_org_id, v_profile_id, v_period, 'recharge');
  select reason into v_recharge_reason from public.monthly_adjustments
    where org_id = p_org_id and profile_id = v_profile_id and period = v_period and adjustment_target = 'recharge'
    order by created_at desc limit 1;

  -- Petrol — owner revision: the verified claim amount is what is paid,
  -- exactly like maintenance (see technician_expense_claims_total, Unit 3).
  -- km/rate/reference are informational only, shown so the admin can see
  -- what they checked the verified amount against; `petrol_rate` is the
  -- technician's currently-effective rate for context, while
  -- petrol_reference_amount is priced per log entry at whatever rate was
  -- effective on that entry's own date (handles a rate that changed
  -- mid-month correctly — see technician_petrol_reference_amount).
  v_km := public.technician_km_log_sum(p_org_id, p_technician_id, v_period);
  select coalesce(petrol_rate_per_km, 0) into v_rate
  from public.technician_vehicle_on(p_org_id, p_technician_id, (v_period + interval '1 month' - interval '1 day')::date);
  v_rate := coalesce(v_rate, 0);
  v_petrol_reference := public.technician_petrol_reference_amount(p_org_id, p_technician_id, v_period);
  v_petrol := public.technician_expense_claims_total(p_org_id, p_technician_id, v_period, 'petrol');

  -- Maintenance: only a verified claim reaches salary (§1.4) —
  -- technician_expense_claims_total already excludes unverified rows. No
  -- monthly_adjustments involvement (Fix 4): verifying at zero is the
  -- refusal, the verified amount is the correction.
  v_maintenance := public.technician_expense_claims_total(p_org_id, p_technician_id, v_period, 'maintenance');

  -- Own-bike allowance: display only — the figure is already inside
  -- v_incentives above via Unit 5, never added twice.
  select * into v_bike_row from public.incentives_earned
    where technician_id = p_technician_id and period = v_period and is_bike_allowance;
  select own_bike_allowance_base into v_bike_base from public.settings where org_id = p_org_id;
  v_bike_base := coalesce(v_bike_base, 0);
  v_bike_extra := public.monthly_adjustment_top_up(p_org_id, v_profile_id, v_period, 'bike_allowance');
  select reason into v_bike_reason from public.monthly_adjustments
    where org_id = p_org_id and profile_id = v_profile_id and period = v_period and adjustment_target = 'bike_allowance'
    order by created_at desc limit 1;
  v_bike_amount := coalesce(v_bike_row.amount, 0);

  -- Addition (d): never pay negative money.
  v_net := greatest(v_base + v_revenue - v_late_deduction + v_incentives + v_recharge + v_petrol + v_maintenance, 0);

  insert into public.salaries (
    org_id, technician_id, period, base, revenue_component, late_deduction, incentives, net,
    recharge_amount, recharge_reason, petrol_km, petrol_rate, petrol_reference_amount, petrol_amount,
    maintenance_amount, bike_allowance_base, bike_allowance_extra, bike_allowance_reason, bike_allowance_amount
  )
  values (
    p_org_id, p_technician_id, v_period, v_base, v_revenue, v_late_deduction, v_incentives, v_net,
    v_recharge, v_recharge_reason, v_km, v_rate, v_petrol_reference, v_petrol,
    v_maintenance, v_bike_base, v_bike_extra, v_bike_reason, v_bike_amount
  )
  on conflict (technician_id, period) do update set
    base = excluded.base,
    revenue_component = excluded.revenue_component,
    late_deduction = excluded.late_deduction,
    incentives = excluded.incentives,
    net = excluded.net,
    recharge_amount = excluded.recharge_amount,
    recharge_reason = excluded.recharge_reason,
    petrol_km = excluded.petrol_km,
    petrol_rate = excluded.petrol_rate,
    petrol_reference_amount = excluded.petrol_reference_amount,
    petrol_amount = excluded.petrol_amount,
    maintenance_amount = excluded.maintenance_amount,
    bike_allowance_base = excluded.bike_allowance_base,
    bike_allowance_extra = excluded.bike_allowance_extra,
    bike_allowance_reason = excluded.bike_allowance_reason,
    bike_allowance_amount = excluded.bike_allowance_amount
  returning * into v_row;

  return v_row;
end;
$$;

grant execute on function public.compute_salary(uuid, uuid, date) to authenticated;
revoke execute on function public.compute_salary(uuid, uuid, date) from public, anon;

-- ── 6. Detection signal: reconciliation report, not a cron job yet ───────
-- What was actually missing was not trigger coverage (confirmed complete)
-- but a second, independent signal that would catch a bypass after the
-- fact. Compares, per table carrying an audit_master_change trigger, the
-- live row count against audit_log's net INSERT minus DELETE for that
-- table. UPDATE never changes row count, so it's correctly excluded from
-- the formula — only INSERT/DELETE drift matters here. Any nonzero
-- difference means something changed row counts without the trigger firing
-- (a session_replication_role=replica window, a disabled trigger, or a
-- genuine code bug).
--
-- Deliberately NOT scoped to current_org_id() — the goal is catching drift
-- anywhere in the database, not organisation-scoped business reporting, so
-- a master from any org who can call this sees database-wide counts. That
-- is a real, known tradeoff for an operational integrity tool, not an
-- oversight — noted here so it isn't mistaken for one later.
--
-- Deliberately NOT a cron job: rows that predate a table's trigger (exactly
-- like Karthik's original INSERT, before audit_trigger_salaries existed)
-- will show drift here that is expected pre-trigger history, not
-- suspicious activity. Run it once, read the output with that in mind,
-- before deciding whether a recurring check is even the right next step.
create or replace function public.audit_reconciliation_report()
returns table (table_name text, live_count bigint, net_audit_count bigint, difference bigint)
language plpgsql
security definer
set search_path = public
as $$
declare
  r record;
  v_live bigint;
  v_net bigint;
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

    table_name := r.tbl;
    live_count := v_live;
    net_audit_count := v_net;
    difference := v_live - v_net;
    return next;
  end loop;
end;
$$;

grant execute on function public.audit_reconciliation_report() to authenticated;
revoke execute on function public.audit_reconciliation_report() from public, anon;
