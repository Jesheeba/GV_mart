-- Referral incentives, DB package 1/3 (schema + anti-abuse guards + rates table).
-- Plan: _local_only/reports/referral_incentives/plan.md, corrections from owner
-- APPROVED message dated 2026-11-02. Nothing in this file changes any existing
-- function's behavior for any EXISTING row — every change is additive. The
-- generic incentive_rules/compute_incentives rule loop and IncentiveRulesTab
-- are deliberately left untouched (owner correction 4: no new incentive_type
-- enum value, to also avoid the "new enum value cannot be used in the same
-- transaction it was created in" Postgres restriction that would otherwise
-- block package 2's compute_incentives redefinition if it referenced a value
-- added here).
--
-- Resolution-order note (owner correction 1): the detection logic that reads
-- customers.referred_by_user_id OR the earliest legacy source='referral' lead
-- lives in package 2 (compute_incentives), not here — this file only adds the
-- column and its anti-abuse guard. create_sale / sell_amc_plan /
-- _create_complaint_ticket_internal are NOT touched by this migration, per
-- owner correction 1 ("do NOT modify").

-- ============================================================================
-- 1. customers.referred_by_user_id — additive column + anti-abuse guard.
-- ============================================================================

alter table public.customers
  add column if not exists referred_by_user_id uuid references public.profiles(id);

-- Owner correction 2: referred_at is the moment referred_by_user_id was FIRST established (set
-- once, never moved by a later correction — a correction changes WHO, not WHEN). Used by
-- resolve_referrer_for_customer (package 2) as the precise "referral captured at" timestamp,
-- replacing the earlier draft's imprecise reuse of customers.updated_at.
alter table public.customers
  add column if not exists referred_at timestamptz;

-- Owner correction 3: settable only (a) at creation, (b) by the master
-- correction RPC (correct_referral_attribution, below) with audit, (c) by the
-- lead->customer conversion carry-over (package 3, same escape hatch). A plain
-- UPDATE can never change it once set, and can never set it later on an
-- EXISTING customer by itself (i.e. a plain UPDATE from NULL -> non-null is
-- ALSO blocked) — attribution only ever arrives at INSERT time or via one of
-- the two audited/blessed paths above.
create or replace function public._guard_customers_referred_by_user_id()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    -- Owner correction 2: stamp referred_at the moment it is first established, including at
    -- plain row creation (create_customer_with_details, or any direct insert).
    if new.referred_by_user_id is not null and new.referred_at is null then
      new.referred_at := now();
    end if;
    return new;
  end if;

  -- UPDATE
  if new.referred_by_user_id is distinct from old.referred_by_user_id then
    if coalesce(current_setting('app.allow_referral_correction', true), '') <> 'on' then
      raise exception '_guard_customers_referred_by_user_id: customers.referred_by_user_id cannot be changed by a plain update; use correct_referral_attribution() or the lead conversion carry-over';
    end if;
    if old.referred_by_user_id is null and new.referred_by_user_id is not null then
      -- First-ever establishment via the carry-over path (package 3): stamp referred_at now.
      new.referred_at := now();
    end if;
    -- A correction changing an ALREADY-set referrer (old.referred_by_user_id is not null) leaves
    -- referred_at untouched — owner correction 2: "set once," a correction is about WHO, not WHEN.
  end if;
  return new;
end;
$$;
revoke all on function public._guard_customers_referred_by_user_id() from public, anon, authenticated;

drop trigger if exists aaa_guard_customers_referred_by_user_id on public.customers;
create trigger aaa_guard_customers_referred_by_user_id
  before insert or update of referred_by_user_id on public.customers
  for each row execute function public._guard_customers_referred_by_user_id();

comment on column public.customers.referred_by_user_id is
  'profiles.id of whoever referred this customer (technician''s own profile row or a staff
   profile). Set once, at customer creation or via the lead-conversion carry-over, or changed via
   correct_referral_attribution() (master-only, audited) — never by a plain UPDATE (see
   aaa_guard_customers_referred_by_user_id trigger). Independent of leads.owner_id/
   leads.source=''referral'' (the older, unrelated finder_credit mechanism) — see plan.md section 3.5.';
comment on column public.customers.referred_at is
  'When referred_by_user_id was FIRST established (set once by the guard trigger; a later
   correction via correct_referral_attribution does not move this). Used by
   resolve_referrer_for_customer to decide whether a qualifying event happened on/after the
   referral was captured.';


-- ============================================================================
-- 2. leads.referred_by_user_id — additive column, no guard needed (leads are
--    not re-attributed after creation in this design; the Lead form writes
--    this once, at insert, same as every other lead field).
-- ============================================================================

alter table public.leads
  add column if not exists referred_by_user_id uuid references public.profiles(id);

comment on column public.leads.referred_by_user_id is
  'Written directly by the new Lead-form "Referred by" field (plan.md section 3.2). Independent
   of leads.owner_id/leads.referral_type (the finder_credit mechanism) — both are left completely
   untouched by this feature. Copied onto customers.referred_by_user_id on lead->customer
   conversion by package 3 (move_lead_to_customer / _lead_apply_status), first-wins, never
   overwrites an existing value there.';


-- ============================================================================
-- 3. referral_bonus_rates — master-set amount(s), effective-dated, NO
--    incentive_rules/incentive_type involvement at all (owner correction 4).
-- ============================================================================

create table public.referral_bonus_rates (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  -- NULL = applies to all three referral sources; non-null = an override rate
  -- for just that source. Owner correction 3: ship ONE flat (null) row only;
  -- the owner may add source-specific rows later, no further migration needed.
  referral_source text check (referral_source in ('sale', 'amc', 'service')),
  amount numeric(12, 2) not null check (amount > 0),
  -- IST calendar date, matching this project's existing effective-dating
  -- idiom (technician_vehicles/person_allowances both use plain `date`
  -- columns compared against period boundaries, never a timestamptz here).
  effective_from date not null,
  effective_to date,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint referral_bonus_rates_date_order check (effective_to is null or effective_to >= effective_from)
);

-- No overlapping ACTIVE range per (org, source) — same gist-exclusion idiom already used by
-- technician_vehicles_technician_id_daterange_excl / person_allowances_profile_id_daterange_excl,
-- but HALF-OPEN ('[)', effective_to EXCLUSIVE) rather than those two's inclusive '[]' — found
-- necessary during rehearsal: an inclusive range makes a same-day rate edit (owner correction 3:
-- "editing closes the current row and adds a new one from today IST") mathematically impossible,
-- since the closed row's last covered day and the new row's first covered day would be the same
-- day, which an inclusive range always treats as an overlap. With effective_to exclusive, closing
-- the current open row at effective_to = <new row's effective_from> and starting the new row
-- there is a clean, non-overlapping same-day handoff — see set_referral_bonus_rate below.
-- coalesce(referral_source, '__all__') folds the "applies to everything" row into its own
-- equality bucket so a null-source row still excludes correctly against another null-source row,
-- independent of any source-specific rows.
create extension if not exists btree_gist;

alter table public.referral_bonus_rates
  add constraint referral_bonus_rates_no_overlap
  exclude using gist (
    org_id with =,
    coalesce(referral_source, '__all__') with =,
    daterange(effective_from, coalesce(effective_to, 'infinity'::date), '[)') with &&
  );

create trigger set_updated_at before update on public.referral_bonus_rates
  for each row execute function public.set_updated_at();

alter table public.referral_bonus_rates enable row level security;
revoke all on public.referral_bonus_rates from public, anon, authenticated;

-- Master-only read (history + current rate) via RLS; edits go through
-- set_referral_bonus_rate() below, never a direct UPDATE/INSERT/DELETE from the client
-- (editing = close current row + insert new one, enforced in the function, not just by
-- convention — there is no grant for update/insert/delete below, only select).
--
-- Security review finding 2 (2026-11-02, LOW/functional, fixed): the blanket `revoke all`
-- above left this SELECT policy unreachable -- Postgres checks the table-level ACL before RLS,
-- so `authenticated` needs an explicit SELECT grant for the policy below to ever apply at all.
-- (The revoke above still correctly removes UPDATE/INSERT/DELETE for authenticated/anon/public,
-- and everything for anon/public including SELECT.)
grant select on public.referral_bonus_rates to authenticated;

create policy referral_bonus_rates_master_select on public.referral_bonus_rates
  for select to authenticated
  using (org_id = public.current_org_id() and public.is_master());

create function public.set_referral_bonus_rate(p_org_id uuid, p_amount numeric, p_referral_source text default null, p_effective_from date default null)
returns public.referral_bonus_rates
language plpgsql
security definer
set search_path = public
as $$
declare
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_month_start date := date_trunc('month', v_today)::date;
  v_from date := coalesce(p_effective_from, v_today);
  v_row public.referral_bonus_rates;
  v_locked boolean;
begin
  if not public.is_master() then
    raise exception 'set_referral_bonus_rate: master role required';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'set_referral_bonus_rate: org mismatch';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'set_referral_bonus_rate: amount must be positive';
  end if;
  if p_referral_source is not null and p_referral_source not in ('sale', 'amc', 'service') then
    raise exception 'set_referral_bonus_rate: invalid referral_source %', p_referral_source;
  end if;
  -- Owner correction 3: effective_from may be any IST date not earlier than the first day of
  -- the current IST month (no more backdating than that), and never in a month that already
  -- has a locked salary for ANY technician in this org (a locked month's incentive math must
  -- never be disturbed by a rate change landing inside it).
  if v_from < v_month_start then
    raise exception 'set_referral_bonus_rate: effective_from cannot be earlier than the first day of the current month (%)', v_month_start;
  end if;
  select exists (
    select 1 from public.salaries s
    where s.org_id = p_org_id and s.locked_at is not null
      and date_trunc('month', s.period) = date_trunc('month', v_from)
  ) into v_locked;
  if v_locked then
    raise exception 'set_referral_bonus_rate: the month of % already has a locked salary for at least one technician — cannot set a rate effective in that month', v_from;
  end if;

  -- Close the currently-open row for this (org, source) bucket, if any, AT v_from itself (not
  -- v_from - 1) — "editing = close current row and insert a new one from today IST" (owner
  -- correction 4/3), never an in-place UPDATE of amount. effective_to is EXCLUSIVE (the
  -- referral_bonus_rates_no_overlap exclusion constraint uses '[)', not '[]' — see package 1's
  -- comment there for why), so closing at exactly v_from and opening the new row AT v_from is a
  -- clean, non-overlapping handoff that also correctly supports editing the rate again on the
  -- SAME day it was first set (found necessary during rehearsal — an inclusive range makes that
  -- case impossible). There is at most one open row per bucket (the exclusion constraint itself
  -- guarantees that), so "effective_to is null" alone identifies it; no effective_from
  -- comparison is needed or correct here.
  update public.referral_bonus_rates
    set effective_to = v_from
    where org_id = p_org_id
      and coalesce(referral_source, '__all__') = coalesce(p_referral_source, '__all__')
      and effective_to is null;

  insert into public.referral_bonus_rates (org_id, referral_source, amount, effective_from, created_by)
  values (p_org_id, p_referral_source, p_amount, v_from, auth.uid())
  returning * into v_row;

  insert into public.audit_log (org_id, actor_id, action, table_name, row_id, after)
  values (p_org_id, auth.uid(), 'referral_bonus_rate_set', 'referral_bonus_rates', v_row.id,
          jsonb_build_object('amount', v_row.amount, 'referral_source', v_row.referral_source, 'effective_from', v_row.effective_from));

  return v_row;
end;
$$;
revoke all on function public.set_referral_bonus_rate(uuid, numeric, text, date) from public, anon;
grant execute on function public.set_referral_bonus_rate(uuid, numeric, text, date) to authenticated;


-- ============================================================================
-- 4. referral_bonus_events — one row per qualifying referral, ever, per
--    customer (org_id, customer_id) unique — see plan.md section 3.1.4.
-- ============================================================================

create table public.referral_bonus_events (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  customer_id uuid not null references public.customers(id) on delete cascade,
  referred_by_user_id uuid not null references public.profiles(id),
  referrer_technician_id uuid references public.technicians(id),
  referral_type text not null default 'customer_referral',
  source text not null check (source in ('sale', 'amc', 'service')),
  qualifying_ref_id uuid not null,
  qualified_at timestamptz not null,
  rate_amount numeric(12, 2) not null check (rate_amount >= 0),
  status text not null default 'pending' check (status in ('pending', 'approved', 'paid', 'voided')),
  voided_at timestamptz,
  voided_by uuid references auth.users(id),
  void_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint referral_bonus_events_one_per_customer unique (org_id, customer_id)
);

create index referral_bonus_events_technician_period_idx
  on public.referral_bonus_events (referrer_technician_id, qualified_at)
  where referrer_technician_id is not null;

create index referral_bonus_events_status_idx
  on public.referral_bonus_events (org_id, status);

create trigger set_updated_at before update on public.referral_bonus_events
  for each row execute function public.set_updated_at();

alter table public.referral_bonus_events enable row level security;
-- No anon/authenticated direct table grants — every access goes through
-- security-definer RPCs built in package 2 (list_active_referrers /
-- referral_bonus_report / correct_referral_attribution / the new
-- compute_incentives block), matching v_referral_events/
-- technician_finder_conversions's existing posture.
revoke all on public.referral_bonus_events from public, anon, authenticated;


-- ============================================================================
-- 5. Master correction RPC (owner correction 9) — the ONLY legitimate way to
--    change customers.referred_by_user_id after creation, or to correct a
--    wrongly-attributed referral_bonus_events row.
-- ============================================================================

create function public.correct_referral_attribution(p_referral_bonus_event_id uuid, p_new_referred_by_user_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event public.referral_bonus_events;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_locked boolean;
begin
  if not public.is_master() then
    raise exception 'correct_referral_attribution: master role required';
  end if;
  if v_reason = '' then
    raise exception 'correct_referral_attribution: a reason is required';
  end if;

  select * into v_event from public.referral_bonus_events where id = p_referral_bonus_event_id;
  if v_event.id is null then
    raise exception 'correct_referral_attribution: event % not found', p_referral_bonus_event_id;
  end if;
  if v_event.org_id is distinct from public.current_org_id() then
    raise exception 'correct_referral_attribution: org mismatch';
  end if;
  if not exists (select 1 from public.profiles where id = p_new_referred_by_user_id and org_id = v_event.org_id) then
    raise exception 'correct_referral_attribution: profile % not found in this org', p_new_referred_by_user_id;
  end if;

  -- Owner correction 9: refuses if the existing event is paid in a locked
  -- month (must reopen first). "Paid" here means an incentives_earned row
  -- exists for it whose technician+period salary is locked (package 2 wires
  -- this check once incentives_earned.referral_bonus_event_id exists).
  select exists (
    select 1
    from public.incentives_earned ie
    join public.salaries s on s.technician_id = ie.technician_id and s.period = ie.period
    where ie.referral_bonus_event_id = v_event.id and s.locked_at is not null
  ) into v_locked;
  if v_locked then
    raise exception 'correct_referral_attribution: this referral''s month is locked — use reopen_salary_posting first';
  end if;

  perform set_config('app.allow_referral_correction', 'on', true);

  update public.customers
    set referred_by_user_id = p_new_referred_by_user_id
    where id = v_event.customer_id;

  update public.referral_bonus_events
    set referred_by_user_id = p_new_referred_by_user_id,
        referrer_technician_id = (select t.id from public.technicians t where t.profile_id = p_new_referred_by_user_id and t.org_id = v_event.org_id)
    where id = v_event.id;

  insert into public.audit_log (org_id, actor_id, action, table_name, row_id, before, after)
  values (v_event.org_id, auth.uid(), 'referral_attribution_corrected', 'referral_bonus_events', v_event.id,
          jsonb_build_object('referred_by_user_id', v_event.referred_by_user_id, 'reason', v_reason),
          jsonb_build_object('referred_by_user_id', p_new_referred_by_user_id));

  return jsonb_build_object('event_id', v_event.id, 'customer_id', v_event.customer_id, 'new_referred_by_user_id', p_new_referred_by_user_id);
end;
$$;
revoke all on function public.correct_referral_attribution(uuid, uuid, text) from public, anon;
grant execute on function public.correct_referral_attribution(uuid, uuid, text) to authenticated;


-- ============================================================================
-- 5b. void_referral_event — owner correction 4. Master-only, reason required,
--    refused if locked, idempotent (voiding an already-voided event is a
--    clean no-op, not an error), never deletes the row.
-- ============================================================================

create function public.void_referral_event(p_event_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event public.referral_bonus_events;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_locked boolean;
begin
  if not public.is_master() then
    raise exception 'void_referral_event: master role required';
  end if;
  if v_reason = '' then
    raise exception 'void_referral_event: a reason is required';
  end if;

  select * into v_event from public.referral_bonus_events where id = p_event_id;
  if v_event.id is null then
    raise exception 'void_referral_event: event % not found', p_event_id;
  end if;
  if v_event.org_id is distinct from public.current_org_id() then
    raise exception 'void_referral_event: org mismatch';
  end if;

  if v_event.status = 'voided' then
    -- Idempotent: already voided, clean no-op, not an error.
    return jsonb_build_object('event_id', v_event.id, 'status', 'voided', 'already_voided', true);
  end if;

  select exists (
    select 1
    from public.incentives_earned ie
    join public.salaries s on s.technician_id = ie.technician_id and s.period = ie.period
    where ie.referral_bonus_event_id = v_event.id and s.locked_at is not null
  ) into v_locked;
  if v_locked then
    raise exception 'void_referral_event: this referral''s month is locked — use reopen_salary_posting first';
  end if;

  update public.referral_bonus_events
    set status = 'voided', voided_at = now(), voided_by = auth.uid(), void_reason = v_reason
    where id = v_event.id;

  insert into public.audit_log (org_id, actor_id, action, table_name, row_id, before, after)
  values (v_event.org_id, auth.uid(), 'referral_event_voided', 'referral_bonus_events', v_event.id,
          jsonb_build_object('status', v_event.status),
          jsonb_build_object('status', 'voided', 'reason', v_reason));

  return jsonb_build_object('event_id', v_event.id, 'status', 'voided', 'already_voided', false);
end;
$$;
revoke all on function public.void_referral_event(uuid, text) from public, anon;
grant execute on function public.void_referral_event(uuid, text) to authenticated;


-- ============================================================================
-- 6. incentives_earned — add the referral traceability column, widen the
--    one-source constraint to 5-way. Owner correction 7: "nothing else."
-- ============================================================================

alter table public.incentives_earned
  add column if not exists referral_bonus_event_id uuid references public.referral_bonus_events(id) on delete restrict;

create unique index if not exists incentives_earned_referral_bonus_unique_idx
  on public.incentives_earned (technician_id, referral_bonus_event_id, period)
  where referral_bonus_event_id is not null;

-- Widen the existing 4-way exclusive-or check to 5-way. The EXACT current
-- constraint name/definition is re-read and reproduced byte-for-byte below
-- except for the added term — this file's rehearsal step confirms the DROP
-- matches what is actually live before the ADD runs, so a silent mismatch
-- can't go unnoticed.
do $$
declare
  v_def text;
begin
  select pg_get_constraintdef(oid) into v_def
  from pg_constraint
  where conrelid = 'public.incentives_earned'::regclass and conname = 'incentives_earned_one_source';

  if v_def is null then
    raise exception 'incentives_earned_one_source constraint not found — schema has drifted from what this migration assumed; stop and re-check before proceeding';
  end if;
  -- Exact live definition, confirmed via pg_get_constraintdef() immediately
  -- before writing this migration (2026-11-02, read-only query, no write):
  --   CHECK (((((
  --     CASE WHEN (rule_id IS NOT NULL) THEN 1 ELSE 0 END +
  --     CASE WHEN (installation_rate_id IS NOT NULL) THEN 1 ELSE 0 END) +
  --     CASE WHEN (credit_source IS NOT NULL) THEN 1 ELSE 0 END) +
  --     CASE WHEN is_bike_allowance THEN 1 ELSE 0 END) = 1))
  if v_def <> 'CHECK (((((
CASE
    WHEN (rule_id IS NOT NULL) THEN 1
    ELSE 0
END +
CASE
    WHEN (installation_rate_id IS NOT NULL) THEN 1
    ELSE 0
END) +
CASE
    WHEN (credit_source IS NOT NULL) THEN 1
    ELSE 0
END) +
CASE
    WHEN is_bike_allowance THEN 1
    ELSE 0
END) = 1))' then
    raise exception 'incentives_earned_one_source constraint definition does not match what this migration expects (got: %) — re-verify against the live function body before proceeding, do not blindly widen', v_def;
  end if;
end;
$$;

alter table public.incentives_earned drop constraint incentives_earned_one_source;
alter table public.incentives_earned add constraint incentives_earned_one_source
  check (
    (
      (case when rule_id is not null then 1 else 0 end
       + case when installation_rate_id is not null then 1 else 0 end)
      + case when credit_source is not null then 1 else 0 end
    )
    + case when is_bike_allowance then 1 else 0 end
    + case when referral_bonus_event_id is not null then 1 else 0 end
    = 1
  );


-- ============================================================================
-- End of package 1. NOT applied to the live database until rehearsed
-- (DRYRUN-OK), independently reviewed (string-literal review + security
-- review), and explicitly APPROVED for apply.
-- ============================================================================
