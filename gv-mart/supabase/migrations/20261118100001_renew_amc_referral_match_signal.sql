-- Connection-map follow-up finding F-05 (Low, carried over as F-03 in that
-- report) — referral capture must come from a validated list, or, if free-
-- typed, a non-matching entry must show a clear warning instead of silently
-- dropping the credit, at all 5 capture points.
--
-- Audited all 5 (create_sale, sell_amc_plan, sell_amc_plan_onsite,
-- renew_amc_plan, create_complaint_ticket/_create_complaint_ticket_internal):
--   - create_sale (NewSalePage.tsx), sell_amc_plan (SellAmcPanel.tsx),
--     create_complaint_ticket (NewComplaintPage.tsx) already take a
--     `p_referred_by_technician_id uuid` and their ONLY frontend caller already
--     uses a real `<select>` bound to the technicians list (confirmed by
--     reading each .tsx file) — already "a validated list," nothing to fix.
--   - sell_amc_plan_onsite's current body (20261016100000) no longer takes an
--     optional referring-technician at all; it always attributes to the
--     caller (a technician, by the function's own access check) — not an
--     instance of this pattern, nothing to fix.
--   - renew_amc_plan is the ONE genuine gap: it takes a free-typed
--     `p_referred_by_technician_name text` from the CUSTOMER app
--     (AmcBookingPanel.tsx — a customer only knows a name, not an id, so a
--     dropdown isn't an option here), resolves it server-side, and — per its
--     own prior code comment, "Silently ignored... if the name doesn't match
--     exactly one active technician" (src/services/customerApp.ts) — gave
--     zero signal on a miss. Fixed here: the function now reports whether a
--     given name actually matched, and the frontend (this task's follow-up
--     TypeScript change) shows a clear warning on a miss instead of silently
--     succeeding with no indication.
--
-- Bonus fix found while rehearsing the above (same lines, this same
-- migration): the pre-existing `select count(*), min(t.id) into ...` raised
-- "function min(uuid) does not exist" on this Postgres version -- there is no
-- min/max aggregate for uuid -- meaning ANY renewal where a customer typed
-- ANY referring-technician name (matching or not) crashed the ENTIRE
-- renew_amc_plan call, not just the referral attribution. Replaced with a
-- plain count + a separate lookup only when the count is exactly 1 -- see
-- DECISIONS.md.
--
-- `referral_matched` in the returned jsonb: `null` when no name was given at
-- all (nothing to warn about — most renewals have no referrer); `true` when a
-- name was given and matched exactly one active technician (credit applied,
-- same as before); `false` when a name was given but did NOT match (sale
-- still succeeds, exactly as before — "never block the sale" — but the
-- caller now knows to warn the customer, instead of a silent drop).

create or replace function public.renew_amc_plan(p_org_id uuid, p_product_id uuid, p_plan_id uuid, p_payment_reference text, p_years integer default null::integer, p_referred_by_technician_name text default null::text, p_address_id uuid default null::uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_customer_id uuid;
  v_plan amc_plans;
  v_years integer;
  v_existing amc_contracts;
  v_settings settings;
  v_start_date date;
  v_expiry date;
  v_interval_months integer;
  v_total_visits integer;
  v_visit_date date;
  v_ticket_id uuid;
  v_contract_id uuid;
  v_address_id uuid;
  v_ticket_ids uuid[] := '{}';
  v_tech_id uuid;
  v_tech_match_count integer;
  v_customer_name text;
  v_lead_id uuid; -- FINDER CREDIT: resolved technician referral, if any
  v_referral_matched boolean; -- F-05: null = no name given; true/false = matched or not
begin
  v_customer_id := public.current_customer_id();
  if v_customer_id is null then
    raise exception 'renew_amc_plan: caller is not a customer';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'renew_amc_plan: org mismatch';
  end if;
  if p_payment_reference is null or btrim(p_payment_reference) = '' then
    raise exception 'renew_amc_plan: a payment reference is required';
  end if;
  if not exists (select 1 from public.products where id = p_product_id and org_id = p_org_id and category = 'ro') then
    raise exception 'renew_amc_plan: AMC plans are only sold on RO products';
  end if;

  select * into v_plan from public.amc_plans where id = p_plan_id and org_id = p_org_id;
  if v_plan.id is null then
    raise exception 'renew_amc_plan: plan % not found', p_plan_id;
  end if;

  v_years := coalesce(p_years, v_plan.years);
  if v_years <= 0 then
    raise exception 'renew_amc_plan: years must be greater than zero';
  end if;

  select * into v_settings from public.settings where org_id = p_org_id;

  select * into v_existing from public.amc_contracts
  where org_id = p_org_id and customer_id = v_customer_id and product_id = p_product_id
  order by expiry_date desc limit 1;

  if v_existing.id is not null
     and v_existing.expiry_date - v_settings.amc_book_window_days > (now() at time zone 'Asia/Kolkata')::date then
    raise exception 'renew_amc_plan: renewal is only available from % (admin-set window)', v_existing.expiry_date - v_settings.amc_book_window_days;
  end if;

  if p_referred_by_technician_name is not null and btrim(p_referred_by_technician_name) <> '' then
    -- Pre-existing live bug, found and fixed while adding the referral_matched
    -- signal below (same lines, same migration): the old `min(t.id)` aggregate
    -- raises "function min(uuid) does not exist" on this Postgres version --
    -- uuid has no min/max aggregate defined. This meant ANY renewal where a
    -- customer typed ANY referring-technician name (match or no match) crashed
    -- the entire renew_amc_plan call with an unhandled error, not just the
    -- referral attribution -- confirmed live in this migration's own rehearsal
    -- (first run failed with exactly that error on real test data). Replaced
    -- with a plain count, then a separate id lookup only when the count is
    -- exactly 1 -- same matching semantics, no aggregate-on-uuid involved.
    select count(*) into v_tech_match_count
    from public.technicians t
    join public.profiles pr on pr.id = t.profile_id
    where t.org_id = p_org_id
      and t.is_active = true
      and pr.is_active = true
      and lower(btrim(pr.full_name)) = lower(btrim(p_referred_by_technician_name));

    if v_tech_match_count = 1 then
      select t.id into v_tech_id
      from public.technicians t
      join public.profiles pr on pr.id = t.profile_id
      where t.org_id = p_org_id
        and t.is_active = true
        and pr.is_active = true
        and lower(btrim(pr.full_name)) = lower(btrim(p_referred_by_technician_name))
      limit 1;
      v_referral_matched := true;
    else
      v_tech_id := null;
      v_referral_matched := false;
    end if;
  end if;

  if v_tech_id is not null then
    select name into v_customer_name from public.customers where id = v_customer_id;
    insert into public.leads (org_id, customer_id, name, source, status, owner_id)
    values (p_org_id, v_customer_id, coalesce(v_customer_name, 'AMC customer'), 'referral', 'won', v_tech_id)
    returning id into v_lead_id;

    insert into public.lead_activities (org_id, lead_id, type, note)
    values (p_org_id, v_lead_id, 'converted', format('AMC self-service purchase, referred by %s', p_referred_by_technician_name));
  end if;

  v_start_date := greatest((now() at time zone 'Asia/Kolkata')::date, coalesce(v_existing.expiry_date, (now() at time zone 'Asia/Kolkata')::date));
  v_expiry := v_start_date + (v_years || ' years')::interval;
  v_interval_months := greatest(1, round(12.0 / v_plan.visits_per_year)::integer);
  v_total_visits := v_years * v_plan.visits_per_year;

  insert into public.amc_contracts (org_id, customer_id, product_id, plan_id, start_date, expiry_date, status, next_service_date)
  values (p_org_id, v_customer_id, p_product_id, p_plan_id, v_start_date, v_expiry, 'active', v_start_date + make_interval(months => v_interval_months))
  returning id into v_contract_id;

  if p_address_id is not null and exists (select 1 from public.addresses where id = p_address_id and customer_id = v_customer_id) then
    v_address_id := p_address_id;
  else
    select a.id into v_address_id from public.addresses a where a.customer_id = v_customer_id and a.is_primary = true limit 1;
  end if;

  v_visit_date := v_start_date;
  for i in 1..v_total_visits loop
    v_visit_date := v_start_date + make_interval(months => public._visit_month_offset(v_plan.visits_per_year, i));
    exit when v_visit_date > v_expiry;
    v_visit_date := public._visit_working_day(p_org_id, v_visit_date);

    insert into public.service_tickets (
      org_id, customer_id, address_id, product_id, name_of_complaint, nature_of_complaint,
      type, priority, status, channel, contract_id, lead_id
    ) values (
      p_org_id, v_customer_id, v_address_id, p_product_id,
      format('AMC scheduled service %s of %s', i, v_total_visits), v_plan.name,
      'amc', 'normal', 'open', 'customer_app', v_contract_id, v_lead_id -- FINDER CREDIT
    )
    returning id into v_ticket_id;
    v_ticket_ids := array_append(v_ticket_ids, v_ticket_id);

    insert into public.appointments (org_id, ticket_id, mode, scheduled_at, available_from, available_to, status)
    values (p_org_id, v_ticket_id, 'datetime', public._visit_start_ts(p_org_id, v_visit_date), public._visit_window_from(p_org_id), public._visit_window_to(p_org_id), 'scheduled');

    perform public._auto_assign_ticket_internal(v_ticket_id, p_org_id, p_skip_rating_logic => true);
  end loop;

  insert into public.notifications (org_id, role, type, title, body, ref_id)
  values (
    p_org_id, 'operation_admin', 'amc_renewed', 'AMC renewed via customer app',
    format('%s plan (%s years) â€” payment ref %s', v_plan.name, v_years, p_payment_reference), v_contract_id
  );

  return jsonb_build_object('contract_id', v_contract_id, 'ticket_ids', to_jsonb(v_ticket_ids), 'expiry_date', v_expiry, 'referral_matched', v_referral_matched);
end;
$function$;

-- Matches this function's own established grant pattern exactly (every prior
-- CREATE OR REPLACE across its signature's history re-grants the same way,
-- with no accompanying REVOKE statement — confirmed by grepping every
-- migration that touches this function).
grant execute on function public.renew_amc_plan(uuid, uuid, uuid, text, integer, text, uuid) to authenticated;
