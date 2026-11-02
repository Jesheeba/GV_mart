-- Referral incentives, DB package 2/3 (compute_incentives block + resolver + report/preview RPCs
-- + the active-referrer picker RPC + void detection). Owner corrections (APPROVED message,
-- 2026-11-02, both rounds). Depends on package 1 (20261202100000) for
-- referral_bonus_rates/referral_bonus_events/customers.referred_by_user_id/referred_at/
-- leads.referred_by_user_id/incentives_earned.referral_bonus_event_id/void_referral_event.
--
-- SALE vs SERVICE vs AMC — the final rule (5 lines, per the owner's 2nd-round correction 1),
-- derived by reading the LIVE bodies of create_sale, _sale_create_line_invoice,
-- create_service_invoice, sell_amc_plan and sell_amc_plan_onsite directly (not inferred), and
-- re-proven by actually CALLING create_sale and create_service_invoice with dummy data inside
-- the rolled-back rehearsal (see rehearsal_functional_test_v2.sql):
--   1. "Sale" = an invoices row with sold_by IS NOT NULL and type IN ('product','spare') —
--      sold_by is written ONLY by _sale_create_line_invoice and by create_sale's own inline AMC
--      insert, both reachable ONLY from create_sale.
--   2. "Service" = a service_tickets row with status='completed' and a non-null invoice_id,
--      created by create_service_invoice — that function's own invoice INSERT never lists
--      sold_by, so these invoices are always sold_by IS NULL, naturally disjoint from (1).
--   3. "AMC" = any amc_contracts row for the customer, keyed on created_at, regardless of which
--      of its 3 creators (create_sale's cart add-on, sell_amc_plan, sell_amc_plan_onsite) made
--      it — no invoice/payment check at all, per the owner's 1st-round answer 1.
--   4. These three are mutually exclusive by construction: sold_by splits sale-vs-service
--      cleanly; AMC is detected independently via amc_contracts, never via invoices, so it can
--      never collide with either (even though create_sale's own AMC add-on DOES also write an
--      invoice with sold_by set — that invoice is simply never looked at for "sale" detection,
--      because the customer's AMC event is already captured via amc_contracts directly).
--   5. sell_amc_plan_onsite also sets sold_by on its invoice, but that invoice is irrelevant here
--      for the same reason as point 4 — AMC never reads invoices.

-- ============================================================================
-- 1. customer_has_qualifying_history — shared helper (owner 2nd-round correction 6). Used both
--    by the detection block below (a referral never qualifies against a customer's own earlier
--    event) and by the lead-conversion carry-over (package 3) so a referrer can never be
--    attached after the fact to a customer who already has purchase history.
-- ============================================================================

create or replace function public.customer_has_qualifying_history(p_customer_id uuid)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  select exists (
    select 1 from public.invoices i
    where i.customer_id = p_customer_id and i.payment_status = 'paid'
      and i.sold_by is not null and i.type in ('product', 'spare')
  )
  or exists (
    select 1 from public.service_tickets st
    join public.invoices i2 on i2.id = st.invoice_id
    where st.customer_id = p_customer_id and st.status = 'completed' and i2.payment_status = 'paid'
  )
  or exists (
    select 1 from public.amc_contracts ac where ac.customer_id = p_customer_id
  )
$$;
revoke all on function public.customer_has_qualifying_history(uuid) from public, anon, authenticated;


-- ============================================================================
-- 2. first_qualifying_event_for_customer — shared helper, the same 3-source
--    earliest-wins detection the compute_incentives block uses, factored out
--    so it can be unit-tested and reused without duplicating the UNION ALL.
-- ============================================================================

create or replace function public.first_qualifying_event_for_customer(p_customer_id uuid)
returns table (source text, qualifying_ref_id uuid, qualified_at timestamptz)
language sql
stable
security definer
set search_path to 'public'
as $$
  select x.source, x.qualifying_ref_id, x.qualified_at
  from (
    select 'sale'::text as source, i.id as qualifying_ref_id,
           case when exists (select 1 from public.payments pay where pay.invoice_id = i.id)
                then (select max(pay.paid_at) from public.payments pay where pay.invoice_id = i.id)
                else i.created_at end as qualified_at
    from public.invoices i
    where i.customer_id = p_customer_id
      and i.payment_status = 'paid'
      and i.sold_by is not null
      and i.type in ('product', 'spare')
    union all
    select 'service'::text, st.id,
           greatest(
             (select max(v.timer_end) from public.service_visits v where v.ticket_id = st.id and v.timer_end is not null),
             case when exists (select 1 from public.payments pay where pay.invoice_id = st.invoice_id)
                  then (select max(pay.paid_at) from public.payments pay where pay.invoice_id = st.invoice_id)
                  else i2.created_at end
           )
    from public.service_tickets st
    join public.invoices i2 on i2.id = st.invoice_id
    where st.customer_id = p_customer_id
      and st.status = 'completed'
      and st.invoice_id is not null
      and i2.payment_status = 'paid'
    union all
    select 'amc'::text, ac.id, ac.created_at
    from public.amc_contracts ac
    where ac.customer_id = p_customer_id
  ) x
  order by x.qualified_at asc
  limit 1
$$;
revoke all on function public.first_qualifying_event_for_customer(uuid) from public, anon, authenticated;


-- ============================================================================
-- 3. resolve_referrer_for_customer — owner correction 1's resolution order,
--    now reading customers.referred_at (owner 2nd-round correction 2) instead
--    of the earlier draft's imprecise updated_at stand-in.
-- ============================================================================

create or replace function public.resolve_referrer_for_customer(p_customer_id uuid)
returns table (referred_by_user_id uuid, referrer_technician_id uuid, referred_at timestamptz, origin text)
language sql
stable
security definer
set search_path to 'public'
as $$
  select
    coalesce(c.referred_by_user_id, legacy.profile_id) as referred_by_user_id,
    coalesce(
      (select t.id from public.technicians t where t.profile_id = c.referred_by_user_id),
      legacy.technician_id
    ) as referrer_technician_id,
    coalesce(c.referred_at, legacy.referred_at) as referred_at,
    case when c.referred_by_user_id is not null then 'customer_field' when legacy.profile_id is not null then 'legacy_lead' else null end as origin
  from public.customers c
  left join lateral (
    select l.owner_id as technician_id, t.profile_id, l.created_at as referred_at
    from public.leads l
    join public.technicians t on t.id = l.owner_id
    where l.source = 'referral' and l.owner_id is not null and l.customer_id = p_customer_id
    order by l.created_at asc
    limit 1
  ) legacy on c.referred_by_user_id is null
  where c.id = p_customer_id
$$;

comment on function public.resolve_referrer_for_customer(uuid) is
  'Owner correction 1''s resolution order: customers.referred_by_user_id if set, else the technician
   owning the EARLIEST legacy leads row (source=''referral'', owner_id not null) for this customer.
   First wins across both. referred_at reads customers.referred_at (set once by the guard trigger,
   package 1) for the customer-field path, or the legacy lead''s created_at for the legacy-lead
   path, per owner 2nd-round correction 2.';

revoke all on function public.resolve_referrer_for_customer(uuid) from public, anon, authenticated;


-- ============================================================================
-- 4. list_active_referrers — the combined active technician+staff picker,
--    used by the customer/lead forms (UI stream).
-- ============================================================================

create or replace function public.list_active_referrers(p_org_id uuid)
returns table (id uuid, full_name text, kind text)
language plpgsql
stable
security definer
set search_path to 'public'
as $$
begin
  -- Security review finding 1 (2026-11-02, HIGH, fixed): this function was missing the
  -- org-match check every sibling function in this file has (set_referral_bonus_rate,
  -- compute_incentives, referral_bonus_preview, etc.) — without it, any authenticated caller
  -- could pass a foreign org's id and read that org's active technician/staff names. Matches
  -- the exact guard pattern used everywhere else in this feature.
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'list_active_referrers: org mismatch';
  end if;

  return query
    select p.id, p.full_name, 'technician'::text as kind
    from public.technicians t
    join public.profiles p on p.id = t.profile_id
    where t.org_id = p_org_id and t.is_active and p.is_active
    union all
    select p.id, p.full_name, 'staff'::text as kind
    from public.profiles p
    where p.org_id = p_org_id and p.is_active
      and p.role in ('master', 'operation_admin', 'sales_admin')
      and not exists (select 1 from public.technicians t where t.profile_id = p.id)
    order by 2;
end;
$$;
revoke all on function public.list_active_referrers(uuid) from public, anon;
grant execute on function public.list_active_referrers(uuid) to authenticated;


-- ============================================================================
-- 5. count_referrals_pending_rate — owner 2nd-round correction 3: a
--    qualifying referral with no referral_bonus_rates row in force gets NO
--    event inserted at all; this read-only count is how the report/preview/
--    HR screens surface "N qualifying referrals, no rate set" instead.
-- ============================================================================

create or replace function public.count_referrals_pending_rate(p_org_id uuid, p_period date default null)
returns integer
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  v_period date := date_trunc('month', coalesce(p_period, (now() at time zone 'Asia/Kolkata')::date))::date;
  v_count integer := 0;
  v_cust record;
  v_ev record;
  v_rate numeric(12,2);
begin
  for v_cust in
    select c.id as customer_id, r.referred_by_user_id, r.referred_at
    from public.customers c
    cross join lateral public.resolve_referrer_for_customer(c.id) r
    where c.org_id = p_org_id
      and not c.is_test
      and r.referred_by_user_id is not null
      and not exists (select 1 from public.referral_bonus_events e where e.customer_id = c.id)
  loop
    select * into v_ev from public.first_qualifying_event_for_customer(v_cust.customer_id);
    if v_ev.qualified_at is null then continue; end if;
    if v_ev.qualified_at < v_cust.referred_at then continue; end if;
    if date_trunc('month', v_ev.qualified_at at time zone 'Asia/Kolkata') <> v_period then continue; end if;

    select amount into v_rate
    from public.referral_bonus_rates
    where org_id = p_org_id
      and coalesce(referral_source, v_ev.source) = v_ev.source
      and effective_from <= (v_ev.qualified_at at time zone 'Asia/Kolkata')::date
      and (effective_to is null or effective_to > (v_ev.qualified_at at time zone 'Asia/Kolkata')::date)
    order by (referral_source is not null) desc
    limit 1;

    if v_rate is null then
      v_count := v_count + 1;
    end if;
  end loop;
  return v_count;
end;
$$;
revoke all on function public.count_referrals_pending_rate(uuid, date) from public, anon, authenticated;


-- ============================================================================
-- 6. compute_incentives — ADDITIVE block only. Everything above the marked
--    block is byte-identical to the live function read on 2026-11-02 (see
--    _local_only/reports/referral_incentives/queries/48_compute_incentives_live.sql.out.txt);
--    the independent string-literal review should diff this against that
--    file directly, not trust this comment.
-- ============================================================================

create or replace function public.compute_incentives(p_org_id uuid, p_period date)
returns setof incentives_earned
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_period date := date_trunc('month', p_period)::date;
  v_rule record;
  v_tech record;
  v_rate record;
  v_metric numeric(12, 2);
  v_review_count integer;
  v_amount numeric(12, 2);
  v_existing_id uuid;
  v_review_enabled boolean;
  -- Unit 5 additions, own-bike allowance block only.
  v_bike_tech record;
  v_own_days integer;
  v_days_in_month integer;
  v_base_setting numeric(12, 2);
  v_prorated numeric(12, 2);
  v_extra numeric(12, 2);
  v_excluded boolean;
  -- Referral bonus additions (owner corrections, 2026-11-02, both rounds).
  v_ref_cust record;
  v_ref record;
  v_ref_rate numeric(12, 2);
  v_ref_locked boolean;
  v_ref_locked_count integer := 0;
begin
  if not public.is_master() then
    raise exception 'compute_incentives: master role required';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'compute_incentives: org mismatch';
  end if;

  -- Google's policy forbids rewarding reviews: the 'review' rule type only pays while the master has switched this ON
  -- (default OFF). Existing rules and rows are untouched; the switch only stops new computations.
  select coalesce(s.review_incentives_enabled, false) into v_review_enabled from public.settings s where s.org_id = p_org_id;

  for v_rule in select * from public.incentive_rules where org_id = p_org_id and is_active loop
    for v_tech in select id from public.technicians where org_id = p_org_id and is_active loop
      if exists (
        select 1 from public.incentives_earned
        where org_id = p_org_id and technician_id = v_tech.id and rule_id = v_rule.id and period = v_period
      ) then
        continue;
      end if;

      -- A rule set to ₹0 pays nothing: no zero-amount rows.
      if v_rule.amount <= 0 then
        continue;
      end if;

      if v_rule.type = 'service_income' then
        v_metric := public.technician_attributed_revenue(p_org_id, v_tech.id, v_period);
        if v_metric >= v_rule.threshold and v_rule.threshold > 0 then
          insert into public.incentives_earned (org_id, technician_id, rule_id, amount, period)
          values (p_org_id, v_tech.id, v_rule.id, v_rule.amount, v_period);
        end if;

      elsif v_rule.type = 'sales_income' then
        v_metric := public.technician_attributed_sales(p_org_id, v_tech.id, v_period);
        if v_metric >= v_rule.threshold and v_rule.threshold > 0 then
          insert into public.incentives_earned (org_id, technician_id, rule_id, amount, period)
          values (p_org_id, v_tech.id, v_rule.id, v_rule.amount, v_period);
        end if;

      elsif v_rule.type = 'review' and v_review_enabled then
        select count(*) into v_review_count
        from public.ratings r
        join public.service_visits v on v.id = r.visit_id
        where v.org_id = p_org_id
          and v.technician_id = v_tech.id
          and r.google_review_clicked = true
          and not public._visit_is_test(v.id)
          and r.created_at >= (v_period::timestamp at time zone 'Asia/Kolkata')
          and r.created_at < ((v_period + interval '1 month')::timestamp at time zone 'Asia/Kolkata');

        if v_review_count >= v_rule.threshold and v_rule.threshold > 0 then
          insert into public.incentives_earned (org_id, technician_id, rule_id, amount, period)
          values (p_org_id, v_tech.id, v_rule.id, v_rule.amount, v_period);
        end if;

      elsif v_rule.type = 'finder_credit' then
        v_metric := public.technician_finder_conversions(p_org_id, v_tech.id, v_period);
        if v_metric >= v_rule.threshold and v_rule.threshold > 0 then
          insert into public.incentives_earned (org_id, technician_id, rule_id, amount, period)
          values (p_org_id, v_tech.id, v_rule.id, v_rule.amount, v_period);
        end if;

      elsif v_rule.type = 'installation' then
        v_metric := public.technician_installation_count(p_org_id, v_tech.id, v_period);
        if v_metric >= v_rule.threshold and v_rule.threshold > 0 then
          insert into public.incentives_earned (org_id, technician_id, rule_id, amount, period)
          values (p_org_id, v_tech.id, v_rule.id, v_rule.amount, v_period);
        end if;
      end if;
    end loop;
  end loop;

  -- Per-unit installation rates (additive to the flat-threshold rule above).
  for v_tech in select id from public.technicians where org_id = p_org_id and is_active loop
    for v_rate in
      select m.rate_id, sum(m.qty)::int as qty, ra.flat_amount
      from (
        select il.qty, public.installation_rate_for(p_org_id, il.product_id) as rate_id
        from public.installations_logged il
        where il.org_id = p_org_id
          and il.technician_id = v_tech.id
          -- already paid by an installation-ticket credit (pending or approved): never counted twice
          and not exists (
            select 1 from public.installation_incentive_credits c
            where c.visit_id = il.visit_id and c.product_id = il.product_id and c.status <> 'void'
          )
          and not public._visit_is_test(il.visit_id)
          and il.created_at >= (v_period::timestamp at time zone 'Asia/Kolkata')
          and il.created_at < ((v_period + interval '1 month')::timestamp at time zone 'Asia/Kolkata')
      ) m
      join public.installation_incentive_rates ra on ra.id = m.rate_id
      group by m.rate_id, ra.flat_amount
    loop
      v_amount := v_rate.qty * v_rate.flat_amount;
      if v_amount <= 0 then
        continue;
      end if;
      select id into v_existing_id from public.incentives_earned
        where technician_id = v_tech.id and installation_rate_id = v_rate.rate_id and period = v_period;
      if v_existing_id is null then
        insert into public.incentives_earned (org_id, technician_id, installation_rate_id, amount, period)
        values (p_org_id, v_tech.id, v_rate.rate_id, v_amount, v_period);
      else
        update public.incentives_earned set amount = v_amount where id = v_existing_id and amount is distinct from v_amount;
      end if;
    end loop;
  end loop;

  -- Installation-ticket credits: the master-approved credits completed in the month, one row per technician and month.
  -- Recomputed on every run (like the per-unit rates) so a late approval or a void is reflected.
  for v_tech in select id from public.technicians where org_id = p_org_id and is_active loop
    select coalesce(sum(c.amount), 0) into v_amount
    from public.installation_incentive_credits c
    where c.org_id = p_org_id
      and c.technician_id = v_tech.id
      and c.status = 'approved'
      and c.created_at >= (v_period::timestamp at time zone 'Asia/Kolkata')
      and c.created_at < ((v_period + interval '1 month')::timestamp at time zone 'Asia/Kolkata')
      and not public._ticket_is_test(c.ticket_id);
    select id into v_existing_id from public.incentives_earned
      where technician_id = v_tech.id and credit_source = 'installation_ticket' and period = v_period;
    if v_existing_id is null then
      if v_amount > 0 then
        insert into public.incentives_earned (org_id, technician_id, credit_source, amount, period)
        values (p_org_id, v_tech.id, 'installation_ticket', v_amount, v_period);
      end if;
    else
      update public.incentives_earned set amount = v_amount where id = v_existing_id and amount is distinct from v_amount;
    end if;
  end loop;

  -- ── Unit 5: own-bike allowance (new block) ──────────────────────────────
  -- Pro-rated by days-in-month on an own bike (technician_own_bike_days,
  -- Unit 1); a company-bike technician or one with no vehicle row at all
  -- gets 0 own-days and so pays 0 — "every existing component of the
  -- incentive total is unchanged" holds because this block only ever
  -- INSERTs a new is_bike_allowance row or UPDATEs one it already owns; it
  -- never touches a rule_id/installation_rate_id/credit_source row.
  --
  -- The existing-row lookup happens BEFORE the <= 0 check, deliberately: a
  -- technician can be recomputed for a period more than once (an admin
  -- switches them to a company bike or excludes them, then re-runs
  -- compute_incentives for a month already touched). If a row from an
  -- earlier, larger-amount run already exists and the new amount is <= 0,
  -- it must be zeroed, not silently left stale — "continue"-ing straight
  -- past it (the original shape of this block) would leave the technician
  -- permanently overpaid in incentives_earned until some other code path
  -- happened to delete the row, which none does.
  select own_bike_allowance_base into v_base_setting from public.settings where org_id = p_org_id;
  v_base_setting := coalesce(v_base_setting, 0);
  v_days_in_month := (v_period + interval '1 month')::date - v_period;

  for v_bike_tech in select id, profile_id from public.technicians where org_id = p_org_id and is_active loop
    v_own_days := public.technician_own_bike_days(p_org_id, v_bike_tech.id, v_period);
    v_prorated := round(v_base_setting * v_own_days / v_days_in_month, 2);
    v_excluded := public.monthly_adjustment_excluded(p_org_id, v_bike_tech.profile_id, v_period, 'bike_allowance');
    v_extra := public.monthly_adjustment_top_up(p_org_id, v_bike_tech.profile_id, v_period, 'bike_allowance');
    v_amount := (case when v_excluded then 0 else v_prorated end) + v_extra;

    select id into v_existing_id from public.incentives_earned
      where technician_id = v_bike_tech.id and period = v_period and is_bike_allowance;

    if v_amount <= 0 then
      if v_existing_id is not null then
        update public.incentives_earned set amount = 0 where id = v_existing_id and amount is distinct from 0;
      end if;
      continue;
    end if;

    if v_existing_id is null then
      insert into public.incentives_earned (org_id, technician_id, is_bike_allowance, amount, period)
      values (p_org_id, v_bike_tech.id, true, v_amount, v_period);
    else
      update public.incentives_earned set amount = v_amount where id = v_existing_id and amount is distinct from v_amount;
    end if;
  end loop;

  -- ══════════════════════════════════════════════════════════════════════
  -- ── Referral bonus (owner corrections, APPROVED 2026-11-02, both rounds) ─
  -- Additive block. (a) detect new qualifying events, SKIPPING customers with
  -- no rate in force (owner 2nd-round correction 3 — no placeholder event);
  -- (b) re-validate + void existing unpaid/unlocked events; (c) upsert
  -- incentives_earned per event for technician referrers; (d) never write
  -- for a locked technician+period, count them instead.
  -- ══════════════════════════════════════════════════════════════════════

  for v_ref_cust in
    select c.id as customer_id, r.referred_by_user_id, r.referrer_technician_id, r.referred_at
    from public.customers c
    cross join lateral public.resolve_referrer_for_customer(c.id) r
    where c.org_id = p_org_id
      and not c.is_test
      and r.referred_by_user_id is not null
      and not exists (select 1 from public.referral_bonus_events e where e.customer_id = c.id)
  loop
    select * into v_ref from public.first_qualifying_event_for_customer(v_ref_cust.customer_id);

    if v_ref.qualified_at is null then
      continue; -- no qualifying event at all yet for this customer
    end if;
    if v_ref.qualified_at < v_ref_cust.referred_at then
      continue; -- the customer's first-ever event predates the referral capture: never qualifies, permanently
    end if;
    if date_trunc('month', v_ref.qualified_at at time zone 'Asia/Kolkata') <> v_period then
      continue; -- qualifies, but in a different month than the one being computed right now
    end if;

    select amount into v_ref_rate
    from public.referral_bonus_rates
    where org_id = p_org_id
      and coalesce(referral_source, v_ref.source) = v_ref.source
      and effective_from <= (v_ref.qualified_at at time zone 'Asia/Kolkata')::date
      and (effective_to is null or effective_to > (v_ref.qualified_at at time zone 'Asia/Kolkata')::date)
    order by (referral_source is not null) desc -- a source-specific rate wins over a null/"all" rate
    limit 1;

    if v_ref_rate is null then
      -- Owner 2nd-round correction 3: no rate in force -> no event, no placeholder. Surfaced
      -- instead via count_referrals_pending_rate() in the report/preview/HR screens.
      continue;
    end if;

    insert into public.referral_bonus_events
      (org_id, customer_id, referred_by_user_id, referrer_technician_id, source, qualifying_ref_id, qualified_at, rate_amount)
    values
      (p_org_id, v_ref_cust.customer_id, v_ref_cust.referred_by_user_id, v_ref_cust.referrer_technician_id, v_ref.source, v_ref.qualifying_ref_id, v_ref.qualified_at, v_ref_rate);
  end loop;

  -- (b) Re-validate every non-voided event. AMC has a real cancellation signal; sale/service do
  -- not (see paid_timing_and_void_findings.md section 3) — only the two universal conditions
  -- (referrer inactive, customer is_test) apply to those two sources. Skips any event whose
  -- technician+period salary is already locked (voiding there must go through
  -- void_referral_event, which itself refuses while locked, same as this check).
  for v_ref in
    select e.* from public.referral_bonus_events e
    where e.org_id = p_org_id and e.status <> 'voided'
      and not exists (
        select 1 from public.incentives_earned ie
        join public.salaries s on s.technician_id = ie.technician_id and s.period = ie.period
        where ie.referral_bonus_event_id = e.id and s.locked_at is not null
      )
  loop
    if (
      (v_ref.source = 'amc' and exists (select 1 from public.amc_contracts ac where ac.id = v_ref.qualifying_ref_id and ac.cancelled_at is not null))
      or (v_ref.referrer_technician_id is not null and not exists (select 1 from public.technicians t where t.id = v_ref.referrer_technician_id and t.is_active))
      or public.is_test_customer(v_ref.customer_id)
    ) then
      update public.referral_bonus_events
        set status = 'voided', voided_at = now(), void_reason = 'auto-voided by compute_incentives: amc cancelled, referrer inactive, or customer flagged test'
        where id = v_ref.id;
    end if;
  end loop;

  -- (c)+(d) Upsert incentives_earned for technician-referrer events qualifying in v_period, skipping
  -- (and counting) any whose technician+period salary is already locked. Staff-referrer events
  -- (referrer_technician_id is null) get no incentives_earned row at all — surfaced instead as a
  -- manual "pending payout" line on StaffSalaryTab per owner answer 2; nothing to do here for them.
  for v_ref in
    select e.* from public.referral_bonus_events e
    where e.org_id = p_org_id
      and e.referrer_technician_id is not null
      and date_trunc('month', e.qualified_at at time zone 'Asia/Kolkata') = v_period
  loop
    select exists (
      select 1 from public.salaries s where s.technician_id = v_ref.referrer_technician_id and s.period = v_period and s.locked_at is not null
    ) into v_ref_locked;

    if v_ref_locked then
      v_ref_locked_count := v_ref_locked_count + 1;
      continue;
    end if;

    select id into v_existing_id from public.incentives_earned
      where technician_id = v_ref.referrer_technician_id and referral_bonus_event_id = v_ref.id and period = v_period;

    v_amount := case when v_ref.status = 'voided' then 0 else v_ref.rate_amount end;

    if v_existing_id is null then
      if v_amount > 0 then
        insert into public.incentives_earned (org_id, technician_id, referral_bonus_event_id, amount, period)
        values (p_org_id, v_ref.referrer_technician_id, v_ref.id, v_amount, v_period);
      end if;
    else
      update public.incentives_earned set amount = v_amount where id = v_existing_id and amount is distinct from v_amount;
    end if;
  end loop;

  -- v_ref_locked_count is surfaced via referral_bonus_report/referral_bonus_preview's
  -- "pending_month_locked" summary field (those functions recompute the same count themselves,
  -- read-only, rather than this function returning it — compute_incentives's return shape is
  -- fixed as SETOF incentives_earned and must not change).

  return query
    select * from public.incentives_earned
    where org_id = p_org_id and period = v_period
    order by technician_id;
end;
$function$;


-- ============================================================================
-- 7. referral_bonus_report + referral_bonus_preview — read-only RPCs for
--    HR/Masters and the technician's own Profile page. Summary now includes
--    pending_no_rate (owner 2nd-round correction 3).
-- ============================================================================

create or replace function public._referral_bonus_rows(p_org_id uuid, p_period date, p_technician_id uuid)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
      'referral_bonus_event_id', e.id,
      'referred_by_user_id', e.referred_by_user_id,
      'referrer_name', coalesce(
        (select p.full_name from public.technicians t join public.profiles p on p.id = t.profile_id where t.id = e.referrer_technician_id),
        (select p.full_name from public.profiles p where p.id = e.referred_by_user_id)
      ),
      'referrer_kind', case when e.referrer_technician_id is not null then 'technician' else 'staff' end,
      'customer_id', e.customer_id,
      'customer_name', (select c.name from public.customers c where c.id = e.customer_id),
      'source', e.source,
      'qualifying_ref_id', e.qualifying_ref_id,
      'qualified_at', e.qualified_at,
      'rate_amount', e.rate_amount,
      'status', e.status,
      'month_locked', e.referrer_technician_id is not null and exists (
        select 1 from public.salaries s
        where s.technician_id = e.referrer_technician_id and s.period = date_trunc('month', p_period)::date and s.locked_at is not null
      ),
      'incentives_earned_id', (
        select ie.id from public.incentives_earned ie
        where ie.referral_bonus_event_id = e.id and ie.period = date_trunc('month', p_period)::date
      )
    ) order by e.qualified_at desc), '[]'::jsonb)
  from public.referral_bonus_events e
  where e.org_id = p_org_id
    and date_trunc('month', e.qualified_at at time zone 'Asia/Kolkata') = date_trunc('month', p_period)::date
    and (p_technician_id is null or e.referrer_technician_id = p_technician_id)
$$;
revoke all on function public._referral_bonus_rows(uuid, date, uuid) from public, anon, authenticated;

create or replace function public.referral_bonus_report(p_period date, p_technician_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  v_org uuid := public.current_org_id();
  v_tech uuid := public.current_technician_id();
  v_staff boolean := public.is_staff();
  v_filter uuid;
  v_rows jsonb;
begin
  if v_org is null or not (v_staff or v_tech is not null) then
    raise exception 'referral_bonus_report: not allowed';
  end if;
  -- Same visibility rule as referral_overview: a technician always sees only their own rows,
  -- regardless of what p_technician_id they pass (owner correction 8).
  v_filter := case when v_staff then p_technician_id else v_tech end;

  v_rows := public._referral_bonus_rows(v_org, p_period, v_filter);

  return jsonb_build_object(
    'summary', jsonb_build_object(
      'total_events', jsonb_array_length(v_rows),
      'pending', (select count(*) from jsonb_array_elements(v_rows) x where x->>'status' = 'pending'),
      'approved', (select count(*) from jsonb_array_elements(v_rows) x where x->>'status' = 'approved'),
      'paid', (select count(*) from jsonb_array_elements(v_rows) x where x->>'status' = 'paid'),
      'voided', (select count(*) from jsonb_array_elements(v_rows) x where x->>'status' = 'voided'),
      'pending_month_locked', (select count(*) from jsonb_array_elements(v_rows) x where (x->>'month_locked')::boolean and x->>'incentives_earned_id' is null),
      'pending_no_rate', case when v_staff then public.count_referrals_pending_rate(v_org, p_period) else null end
    ),
    'rows', v_rows
  );
end;
$$;
revoke all on function public.referral_bonus_report(date, uuid) from public, anon;
grant execute on function public.referral_bonus_report(date, uuid) to authenticated;

create or replace function public.referral_bonus_preview(p_org_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
begin
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'referral_bonus_preview: org mismatch';
  end if;
  -- Read-only "this month so far" — identical visibility rule to referral_bonus_report, just
  -- always scoped to the open month and (for a technician) always self.
  return public.referral_bonus_report(date_trunc('month', v_today)::date, null);
end;
$$;
revoke all on function public.referral_bonus_preview(uuid) from public, anon;
grant execute on function public.referral_bonus_preview(uuid) to authenticated;
