-- One-time DATA backfill for legacy amc_contracts rows whose visit schedule
-- is incomplete or entirely missing, caused by two bugs now fixed
-- prospectively (new contracts only) in:
--   20260715110000_amc_multiyear_scheduling_and_next_service_recalc.sql
--   20260715120000_auto_assign_customer_and_amc_bookings.sql
--
-- Bug 1a: sell_amc_plan / renew_amc_plan only ever looped `1..visits_per_year`
--   instead of `1..(years*visits_per_year)` — a multi-year contract's visits
--   after year 1 were never scheduled.
-- Bug 1b: create_sale's AMC add-on path had NO scheduling loop at all —
--   contracts sold that way got ZERO visits ever, for any year.
-- Both fixes are forward-only. Contracts created before they were deployed
-- still have the incomplete/empty schedule this migration backfills.
--
-- Investigation note: this migration was written WITHOUT a live headcount of
-- affected contracts. The investigation step called for a read-only Node
-- script against the anon key, but RLS on amc_contracts/service_tickets/
-- appointments (20260701091300_rls.sql) gates SELECT on
-- `org_id = current_org_id() and is_staff()`, both of which resolve via
-- auth.uid() — null with no authenticated session, so an anon key with no
-- login returns zero rows on every one of those tables (confirmed by
-- actually running such a script — not a guess). Obtaining a staff session
-- to read around that (e.g. hunting for seed/test credentials) would have
-- gone beyond the anon-key-only access this task authorized, so that path
-- was not taken. Consequently this migration is written to be entirely
-- self-computing: every number it needs (expected vs. actual visit count,
-- linkage, ambiguity) is derived from the live table contents at the moment
-- it actually runs, not from any count gathered in advance.
--
-- Scope, kept deliberately conservative:
--  - INSERT-only. Never updates or deletes any existing service_tickets or
--    appointments row. The only UPDATE in this file touches
--    amc_contracts.next_service_date, and only for a contract this
--    migration itself just added visits to.
--  - Only contracts with status = 'active' and expiry_date > current_date —
--    an expired or cancelled contract doesn't need future visits.
--  - Only backfills visit slots strictly in the future (slot date >
--    current_date). A slot whose date already passed with nothing
--    scheduled for it is unrecoverable — inventing a past "scheduled" visit
--    would be noise, not a useful backfill — so it is silently left
--    unfilled.
--  - Ticket linkage: prefers service_tickets.contract_id (added in
--    20260713090000_amc_contract_id_on_tickets.sql). For a contract with
--    ZERO tickets linked that way (genuinely legacy, predating that
--    column), falls back to inferring linkage via
--    customer_id + product_id + type = 'amc' — but ONLY when that
--    customer+product pairing maps to exactly this one amc_contracts row.
--    If the same customer+product has more than one AMC contract on record
--    (e.g. an expired contract plus its renewal), unlinked legacy tickets
--    can't be confidently attributed to either one, so that contract is
--    skipped entirely rather than guessed at.
--  - Idempotent: compares the number of visits a contract already has
--    against the number it should have (years * visits_per_year) before
--    inserting anything, so re-running this migration does not create
--    duplicate visits.
--  - Each newly-created visit is auto-assigned via the existing
--    public._auto_assign_ticket_internal(p_ticket_id, p_org_id) helper
--    (20260715120000), matching how newly-created AMC visits behave now.
--  - next_service_date is recomputed, but only for contracts this migration
--    actually added visits to — same "earliest remaining scheduled/
--    in_progress appointment" logic create_service_invoice's fix uses.
do $$
declare
  v_contract record;
  v_interval_months integer;
  v_total_visits integer;
  v_address_id uuid;
  v_is_inferred boolean;
  v_actual_total integer;
  v_visit_date date;
  v_ticket_id uuid;
  v_next_service_date date;
  v_visits_inserted integer;
begin
  -- Per-org running totals, drained into one summary notification per org
  -- after the main loop (never one notification per contract).
  create temporary table tmp_amc_backfill_summary (
    org_id uuid primary key,
    contracts_backfilled integer not null default 0,
    visits_backfilled integer not null default 0
  ) on commit drop;

  for v_contract in
    select
      c.id, c.org_id, c.customer_id, c.product_id, c.start_date, c.expiry_date,
      c.status, c.next_service_date,
      p.years as plan_years, p.visits_per_year as plan_visits_per_year, p.name as plan_name
    from public.amc_contracts c
    join public.amc_plans p on p.id = c.plan_id
    where c.status = 'active' and c.expiry_date > current_date
    order by c.id
  loop
    v_interval_months := greatest(1, 12 / v_contract.plan_visits_per_year);
    v_total_visits := v_contract.plan_years * v_contract.plan_visits_per_year;

    -- ── Determine linkage mode and the contract's current actual visit
    -- count. Direct linkage (service_tickets.contract_id) always wins when
    -- any exists; only fall back to inference when it's the only option. ──
    if exists (
      select 1 from public.service_tickets st
      where st.contract_id = v_contract.id and st.type = 'amc'
    ) then
      v_is_inferred := false;
      select count(distinct st.id) into v_actual_total
      from public.service_tickets st
      where st.contract_id = v_contract.id and st.type = 'amc';
    else
      -- Zero direct-linked tickets: genuinely legacy. Only safe to infer via
      -- customer_id + product_id when that pairing maps to exactly this one
      -- contract — a renewal creates a second amc_contracts row on the same
      -- product, which would make inference ambiguous for both.
      if (
        select count(*) from public.amc_contracts c2
        where c2.customer_id = v_contract.customer_id and c2.product_id = v_contract.product_id
      ) > 1 then
        -- Ambiguous — cannot confidently tell which contract any unlinked
        -- legacy tickets for this customer+product belong to. Excluded from
        -- the backfill rather than guessed at.
        continue;
      end if;

      v_is_inferred := true;
      select count(distinct st.id) into v_actual_total
      from public.service_tickets st
      where st.contract_id is null
        and st.customer_id = v_contract.customer_id
        and st.product_id = v_contract.product_id
        and st.type = 'amc';
    end if;

    v_actual_total := coalesce(v_actual_total, 0);

    -- Idempotency guard: nothing missing (or already fully backfilled by a
    -- prior run of this migration) — skip without touching anything.
    if v_actual_total >= v_total_visits then
      continue;
    end if;

    select a.id into v_address_id
    from public.addresses a
    where a.customer_id = v_contract.customer_id and a.is_primary = true
    limit 1;

    v_visits_inserted := 0;

    -- Resume the SAME slot sequence sell_amc_plan uses
    -- (start_date + interval_months * i). Both known bug shapes (1a/1b)
    -- always scheduled a contiguous prefix of this exact sequence starting
    -- at i = 1, so resuming at v_actual_total + 1 lines up with the true
    -- next unfilled slot without needing per-date matching.
    for i in (v_actual_total + 1)..v_total_visits loop
      v_visit_date := v_contract.start_date + make_interval(months => v_interval_months * i);
      exit when v_visit_date > v_contract.expiry_date;

      if v_visit_date > current_date then
        insert into public.service_tickets (
          org_id, customer_id, address_id, product_id, name_of_complaint, nature_of_complaint,
          type, priority, status, channel, contract_id
        ) values (
          v_contract.org_id, v_contract.customer_id, v_address_id, v_contract.product_id,
          format('AMC scheduled service %s of %s', i, v_total_visits), v_contract.plan_name,
          'amc', 'normal', 'open', 'call', v_contract.id
        )
        returning id into v_ticket_id;

        insert into public.appointments (org_id, ticket_id, mode, scheduled_at, status)
        values (v_contract.org_id, v_ticket_id, 'datetime', v_visit_date::timestamptz + time '09:00', 'scheduled');

        perform public._auto_assign_ticket_internal(v_ticket_id, v_contract.org_id);

        v_visits_inserted := v_visits_inserted + 1;
      end if;
      -- Slots at/before current_date with nothing scheduled are
      -- intentionally left unfilled (see file header) — loop just moves on.
    end loop;

    if v_visits_inserted > 0 then
      -- Recompute next_service_date the same way create_service_invoice's
      -- fix does: earliest remaining scheduled/in_progress appointment
      -- among this contract's own AMC visits (NULL once none remain).
      -- For an inferred-linkage contract this also has to include the
      -- still-null-contract_id legacy tickets (never retroactively
      -- stamped — this migration is insert-only), otherwise an
      -- older unlinked-but-still-future visit could be ignored and
      -- next_service_date would understate the true next visit date.
      if v_is_inferred then
        select min(a.scheduled_at::date) into v_next_service_date
        from public.service_tickets st
        join public.appointments a on a.ticket_id = st.id
        where st.type = 'amc'
          and a.status in ('scheduled', 'in_progress')
          and (
            st.contract_id = v_contract.id
            or (st.contract_id is null and st.customer_id = v_contract.customer_id and st.product_id = v_contract.product_id)
          );
      else
        select min(a.scheduled_at::date) into v_next_service_date
        from public.service_tickets st
        join public.appointments a on a.ticket_id = st.id
        where st.contract_id = v_contract.id
          and st.type = 'amc'
          and a.status in ('scheduled', 'in_progress');
      end if;

      update public.amc_contracts
        set next_service_date = v_next_service_date
        where id = v_contract.id;

      insert into tmp_amc_backfill_summary (org_id, contracts_backfilled, visits_backfilled)
      values (v_contract.org_id, 1, v_visits_inserted)
      on conflict (org_id) do update
        set contracts_backfilled = tmp_amc_backfill_summary.contracts_backfilled + 1,
            visits_backfilled = tmp_amc_backfill_summary.visits_backfilled + excluded.visits_backfilled;
    end if;
  end loop;

  -- One summary notification per org actually touched (not one per
  -- contract), so ops staff see this one-time fix happened.
  insert into public.notifications (org_id, role, type, title, body, ref_id)
  select
    s.org_id, 'operation_admin', 'amc_backfill', 'Legacy AMC visit schedules backfilled',
    format(
      '%s AMC contract%s had missing future visits scheduled — %s visit%s added in total.',
      s.contracts_backfilled, case when s.contracts_backfilled = 1 then '' else 's' end,
      s.visits_backfilled, case when s.visits_backfilled = 1 then '' else 's' end
    ),
    null
  from tmp_amc_backfill_summary s;
end $$;
