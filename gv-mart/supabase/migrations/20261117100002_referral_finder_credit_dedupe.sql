-- Incentive audit, Finding H-02 (High) — finder_credit incentive has no dedupe
-- against repeated referral leads for the same customer+technician.
--
-- Two changes, at two different layers, per the task's decision ("a referral bonus
-- may be earned at most once per (customer, technician, referral type) however many
-- sales screens capture it"):
--
-- 1. THE METRIC ITSELF (the real fix — this is what the ₹ incentive math reads):
--    technician_finder_conversions() counted `count(distinct v.ticket_id)` — i.e. a
--    distinct TICKET, not a distinct CUSTOMER. Five call sites (create_sale,
--    sell_amc_plan, sell_amc_plan_onsite, renew_amc_plan, create_complaint_ticket —
--    20260804150000_referral_capture_functions.sql) can each independently mint a
--    new `leads` row with the same (customer_id, owner_id) pair, and every one of
--    those leads can go on to produce its own completed ticket, so the SAME
--    customer being referred (or re-attributed) by the SAME technician through two
--    different flows was counted twice. Changed to `count(distinct st.customer_id)`
--    — one credit per customer this technician has a completed referral-sourced
--    ticket for, this period, however many tickets/leads trace back to that
--    customer. `referral_type` only has one value in this codebase today
--    (`'finder_credit'` — see below), so distinct customer_id already IS distinct
--    (owner_id, customer_id, referral_type) within this function (owner_id is fixed
--    to p_technician_id by the join/where clause).
--
-- 2. THE CAPTURE LAYER (defense in depth, "enforce in the database (guard or unique
--    key)"): a `referral_type` column + partial unique index on
--    `leads (customer_id, owner_id, referral_type)` so a second referral lead for
--    the same pair can never physically exist as a separate row, closing the gap
--    even for a future screen that reads `leads` directly instead of going through
--    technician_finder_conversions(). `referral_type` is a plain text column with a
--    single value today ('finder_credit' — the one and only referral bonus this
--    codebase computes); it exists as a column rather than a hard-coded literal in
--    the index purely so a future SECOND referral-bonus type (if one is ever added)
--    can get its own independent one-per-customer-per-technician slot without a
--    schema change — see DECISIONS.md.
--
--    "Make the capture points tolerate the duplicate silently" is implemented as a
--    BEFORE INSERT trigger on `leads`, not by editing the 4 functions that actually
--    use this optional-attribution `source='referral'` pattern today (create_sale,
--    sell_amc_plan, renew_amc_plan, _create_complaint_ticket_internal —
--    sell_amc_plan_onsite's CURRENT body, 20261016100000, no longer takes an
--    optional referring-technician id at all; it always attributes to the acting
--    technician under `source='field'`, a different, mandatory-not-optional
--    mechanism this migration leaves untouched — see DECISIONS.md). Each of those 4
--    bodies has been through many historical CREATE OR REPLACE revisions across
--    many migration files and runs hundreds of lines of unrelated scheduling/
--    billing logic; reproducing all 4 verbatim just to add an ON CONFLICT clause to
--    one of dozens of inserts each performs would be a far larger, far riskier diff
--    than this task's "nothing else" scope justifies, for no improvement over the
--    trigger below — AND a hard unique index these functions don't expect would
--    make a legitimate SECOND sale to the same customer by the same technician
--    (a real, non-duplicate event — e.g. an AMC renewed a year later) throw an
--    unhandled `unique_violation` and abort the whole sale, a regression strictly
--    worse than today. The trigger avoids all of that:
--      - only engages when NEW.source = 'referral' and NEW.owner_id is not null
--        (every existing non-referral lead-insert path, and sell_amc_plan_onsite's
--        unrelated `source='field'` path, are both untouched);
--      - takes a per-(customer_id, owner_id, referral_type) transaction-scoped
--        advisory lock BEFORE checking for an existing row, so two truly
--        simultaneous referral captures for the same pair serialise on the lock
--        instead of racing past a plain EXISTS check (released automatically at
--        COMMIT/ROLLBACK — pg_advisory_xact_lock never leaks across transactions);
--      - if a matching lead already exists, clears `NEW.owner_id` to null instead of
--        skipping the insert — the row is still created (so every downstream
--        `returning id into v_lead_id` / `lead_activities.lead_id` / ticket.lead_id
--        in the 4 calling functions gets a real, valid lead id and none of them
--        ever sees a NOT NULL violation; `lead_activities.lead_id uuid not null` —
--        20260701090900_leads_automation.sql — would otherwise abort the entire
--        sale/ticket/AMC/complaint if the row were skipped instead), it is simply
--        no longer attributed to that technician. That is EXACTLY how every one of
--        these 4 functions already treats an unknown/invalid
--        p_referred_by_technician_id ("an unknown/foreign technician id is silently
--        ignored rather than raising" — 20260804150000's own header comment) — this
--        reuses that exact established philosophy rather than inventing a new one,
--        and it is also why nulling owner_id (rather than skipping) can never itself
--        hit the unique index below: a row with owner_id null never matches that
--        index's `where ... owner_id is not null` predicate.
--
-- Report (owner_questions.md / task instruction: "report any existing rows that
-- would violate it — the audit says there are none"): verified live, read-only,
-- immediately before writing this migration —
-- _local_only/reports/payroll_fixes/backup_before_counts.sql.out.txt shows
-- `leads_referral_dupes` = 0 rows (zero (customer_id, owner_id) pairs with more
-- than one `source='referral'` lead) as of 2026-10-29, so the unique index below
-- is created against a clean table with nothing to pre-clean. The rehearsal (on
-- throwaway __TEST_ data) re-proves this is still true as part of a full apply
-- dry run.

alter table public.leads
  add column if not exists referral_type text not null default 'finder_credit';

create unique index if not exists leads_referral_once_idx
  on public.leads (customer_id, owner_id, referral_type)
  where source = 'referral' and owner_id is not null;

create or replace function public._dedupe_referral_leads()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_existing uuid;
begin
  if new.source = 'referral' and new.owner_id is not null then
    -- Transaction-scoped advisory lock keyed by the same triple the unique index
    -- covers — serialises two simultaneous captures for the same pair so the
    -- EXISTS check below can never race. Released automatically at the end of
    -- this transaction.
    perform pg_advisory_xact_lock(hashtextextended(new.customer_id::text || '|' || new.owner_id::text || '|' || new.referral_type, 0));

    select id into v_existing
    from public.leads
    where customer_id = new.customer_id
      and owner_id = new.owner_id
      and referral_type = new.referral_type
      and source = 'referral'
    limit 1;

    if v_existing is not null then
      -- Silently tolerate the duplicate: strip the (repeat) attribution rather than
      -- skipping the row, so the insert still succeeds and every downstream NOT
      -- NULL reference to the new lead's id stays valid (see header).
      new.owner_id := null;
    end if;
  end if;
  return new;
end;
$$;
revoke all on function public._dedupe_referral_leads() from public, anon, authenticated;

drop trigger if exists aaa_dedupe_referral_leads on public.leads;
create trigger aaa_dedupe_referral_leads
  before insert on public.leads
  for each row execute function public._dedupe_referral_leads();

-- technician_finder_conversions: the real metric fix (see header, point 1).
create or replace function public.technician_finder_conversions(p_org_id uuid, p_technician_id uuid, p_period date)
returns integer
language sql
stable security definer
set search_path to 'public'
as $$
  select count(distinct st.customer_id)::integer
  from public.service_visits v
  join public.service_tickets st on st.id = v.ticket_id
  join public.leads l on l.id = st.lead_id
  where v.org_id = p_org_id
    and st.org_id = p_org_id
    and st.lead_id is not null
    and l.owner_id = p_technician_id
    and st.status = 'completed'
    and not public.is_test_customer(st.customer_id)
    and v.timer_end is not null
    and v.timer_end >= (date_trunc('month', p_period)::date::timestamp at time zone 'Asia/Kolkata')
    and v.timer_end < ((date_trunc('month', p_period)::date + interval '1 month')::timestamp at time zone 'Asia/Kolkata');
$$;
-- No EXECUTE grant at all, to anon OR authenticated — matches
-- 20260923150000_lock_down_anon_exposed_internal_rpcs.sql's explicit security
-- posture for this function (internal-only, called exclusively from other
-- SECURITY DEFINER functions such as compute_salary/compute_incentives, never
-- directly from the frontend). CREATE OR REPLACE does not reset existing grants,
-- but this REVOKE is kept explicit so this file is correct and self-contained on
-- its own, independent of migration run order.
revoke execute on function public.technician_finder_conversions(uuid, uuid, date) from anon;
revoke execute on function public.technician_finder_conversions(uuid, uuid, date) from authenticated;
