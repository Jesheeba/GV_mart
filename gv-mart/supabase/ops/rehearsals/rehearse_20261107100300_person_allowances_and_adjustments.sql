-- Rehearsal wrapper for 20261107100300_person_allowances_and_adjustments.sql (Unit 4).
-- Refuses before 18:00 IST, refuses if the embedded migration text has been
-- edited since this wrapper was written (pinned sha256 of the LF blob),
-- fingerprints the real organisation's salaries/incentives_earned before
-- and after, EXECUTEs the migration verbatim, and ends in an unconditional
-- RAISE so nothing persists regardless of outcome. Run through the
-- Management API (database/query), never psql -- the whole call is one
-- implicit transaction and the final RAISE is what rolls it all back.
-- Read RESULTS in the error. No BEGIN/COMMIT here: that would defeat the
-- rollback.
do $wrap_allowances$
declare
  res text := '';
  v_mig text := $mig_allowances$
-- Monthly Expenses spec, Unit 4 — recharge allowances, the generic
-- adjustment mechanism, and the own-bike allowance org setting
-- (§1.1/§1.6/§1.7/§3.4/§3.5/§3.6).
--
-- `monthly_adjustments` is the one mechanism for every top-up and exclusion
-- (§3.5), scoped to `recharge` and `bike_allowance` only. Petrol and
-- maintenance do NOT use this table — the owner's revision (superseding the
-- "override" idea originally built here) is that the verified claim amount
-- (Unit 3) already IS the figure that pays, and verifying at zero already
-- IS how an admin refuses one. A separate adjustment row on top of that
-- would be a second way to say the same thing, so this table carries no
-- `petrol`/`maintenance` target at all.

create table public.person_allowances (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  -- Deliberately `profiles`, not `technicians` — §1.1: "not restricted to
  -- technicians". A profile with no row here receives no recharge, which is
  -- the whole scoping rule.
  profile_id uuid not null references public.profiles (id) on delete cascade,
  recharge_amount numeric(12, 2) not null check (recharge_amount >= 0),
  effective_from date not null,
  effective_to date,
  created_by uuid references public.profiles (id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  check (effective_to is null or effective_to >= effective_from),
  exclude using gist (
    profile_id with =,
    daterange(effective_from, coalesce(effective_to, 'infinity'::date), '[]') with &&
  )
);

create index person_allowances_org_id_idx on public.person_allowances (org_id);
create index person_allowances_profile_id_idx on public.person_allowances (profile_id, effective_from);

alter table public.person_allowances enable row level security;

create policy person_allowances_select_ops on public.person_allowances
  for select using (org_id = public.current_org_id() and public.is_ops_staff());
create policy person_allowances_write_ops on public.person_allowances for all
  using (org_id = public.current_org_id() and public.is_ops_staff())
  with check (org_id = public.current_org_id() and public.is_ops_staff());

create trigger audit_person_allowances after insert or update or delete on public.person_allowances
  for each row execute function public.audit_master_change();

create or replace function public.person_allowance_on(
  p_org_id uuid,
  p_profile_id uuid,
  p_date date
)
returns public.person_allowances
language sql
stable
security definer
set search_path = public
as $$
  select *
  from public.person_allowances
  where org_id = p_org_id
    and profile_id = p_profile_id
    and effective_from <= p_date
    and coalesce(effective_to, 'infinity'::date) >= p_date
  limit 1;
$$;

grant execute on function public.person_allowance_on(uuid, uuid, date) to authenticated;
revoke execute on function public.person_allowance_on(uuid, uuid, date) from public, anon;

-- ── monthly_adjustments ────────────────────────────────────────────────────

create table public.monthly_adjustments (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  profile_id uuid not null references public.profiles (id) on delete cascade,
  period date not null,
  adjustment_target text not null check (adjustment_target in ('recharge', 'bike_allowance')),
  adjustment_type text not null check (adjustment_type in ('top_up', 'exclude')),
  amount numeric(12, 2),
  reason text not null check (btrim(reason) <> ''),
  created_by uuid references public.profiles (id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  check (
    (adjustment_type = 'exclude' and amount is null)
    or (adjustment_type = 'top_up' and amount is not null and amount > 0)
  )
);

create index monthly_adjustments_org_id_idx on public.monthly_adjustments (org_id);
create index monthly_adjustments_lookup_idx on public.monthly_adjustments (profile_id, period, adjustment_target);

alter table public.monthly_adjustments enable row level security;

create policy monthly_adjustments_select_ops on public.monthly_adjustments
  for select using (org_id = public.current_org_id() and public.is_ops_staff());
create policy monthly_adjustments_write_ops on public.monthly_adjustments for all
  using (org_id = public.current_org_id() and public.is_ops_staff())
  with check (org_id = public.current_org_id() and public.is_ops_staff());

create trigger audit_monthly_adjustments after insert or update or delete on public.monthly_adjustments
  for each row execute function public.audit_master_change();

create or replace function public.monthly_adjustment_top_up(
  p_org_id uuid,
  p_profile_id uuid,
  p_period date,
  p_target text
)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(sum(amount), 0)
  from public.monthly_adjustments
  where org_id = p_org_id
    and profile_id = p_profile_id
    and period = date_trunc('month', p_period)::date
    and adjustment_target = p_target
    and adjustment_type = 'top_up';
$$;

create or replace function public.monthly_adjustment_excluded(
  p_org_id uuid,
  p_profile_id uuid,
  p_period date,
  p_target text
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.monthly_adjustments
    where org_id = p_org_id
      and profile_id = p_profile_id
      and period = date_trunc('month', p_period)::date
      and adjustment_target = p_target
      and adjustment_type = 'exclude'
  );
$$;

grant execute on function public.monthly_adjustment_top_up(uuid, uuid, date, text) to authenticated;
grant execute on function public.monthly_adjustment_excluded(uuid, uuid, date, text) to authenticated;
revoke execute on function public.monthly_adjustment_top_up(uuid, uuid, date, text) from public, anon;
revoke execute on function public.monthly_adjustment_excluded(uuid, uuid, date, text) from public, anon;

-- ── Org setting: own-bike allowance base (§1.6/§3.6) ──────────────────────
-- Appended to the existing single-row-per-org `settings` table, matching
-- every other org-wide numeric config in this codebase
-- (20260701091100_system.sql's own header: "one typed row per org, not a
-- generic key/value table"). `settings_write_master` (20260701091300_rls.sql)
-- is already master-only, matching §1.6's "editable by master" exactly — no
-- RLS change needed here.
-- `audit_settings` (20260702090000_audit_triggers.sql) already covers the
-- whole row on every insert/update/delete — adding a second trigger here
-- would double-write audit_log on every settings change, so this column
-- just rides the existing trigger, no new one.
alter table public.settings
  add column own_bike_allowance_base numeric(12, 2) not null default 1000 check (own_bike_allowance_base >= 0);
$mig_allowances$;
  v_expected_sha256 text := 'f1c326ad447025e497b562c35491603d51043947a49eb457b37bcec9da0b8e23';
  v_actual_sha256 text;
  v_now_ist timestamptz := now() at time zone 'Asia/Kolkata';
  v_org uuid;
  v_org_count int;
  v_fp_before text;
  v_fp_after text;
begin
  if (v_now_ist::time) < '18:00:00' then
    raise exception 'rehearsal refused: run after 18:00 IST, current IST time is %', v_now_ist::time;
  end if;

  v_actual_sha256 := encode(digest(v_mig, 'sha256'), 'hex');
  if v_actual_sha256 is distinct from v_expected_sha256 then
    raise exception 'rehearsal refused: embedded migration text does not match the pinned sha256 (expected %, got %)', v_expected_sha256, v_actual_sha256;
  end if;
  res := res || E'\n' || format('sha256 pinned and verified: %s', v_actual_sha256);

  select count(*) into v_org_count from organizations where name not ilike '\_\_TEST%';
  if v_org_count <> 1 then
    raise exception 'rehearsal refused: expected exactly 1 real organisation, found %', v_org_count;
  end if;
  select id into v_org from organizations where name not ilike '\_\_TEST%' limit 1;

  select format('salaries=%s rows sum(net)=%s | incentives_earned=%s rows sum(amount)=%s',
      (select count(*) from salaries where org_id = v_org),
      (select coalesce(sum(net), 0) from salaries where org_id = v_org),
      (select count(*) from incentives_earned where org_id = v_org),
      (select coalesce(sum(amount), 0) from incentives_earned where org_id = v_org))
    into v_fp_before;
  res := res || E'\n' || format('fingerprint before: %s', v_fp_before);

  execute v_mig;
  res := res || E'\n' || 'migration executed';

  select format('salaries=%s rows sum(net)=%s | incentives_earned=%s rows sum(amount)=%s',
      (select count(*) from salaries where org_id = v_org),
      (select coalesce(sum(net), 0) from salaries where org_id = v_org),
      (select count(*) from incentives_earned where org_id = v_org),
      (select coalesce(sum(amount), 0) from incentives_earned where org_id = v_org))
    into v_fp_after;
  res := res || E'\n' || format('fingerprint after (expect identical, this migration touches neither table): %s -- unchanged: %s', v_fp_after, v_fp_after = v_fp_before);

  raise exception E'RESULTS%', res;
end
$wrap_allowances$;
