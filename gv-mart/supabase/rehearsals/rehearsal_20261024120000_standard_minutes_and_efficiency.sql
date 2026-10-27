-- REHEARSAL (NOT RUN; for the owner's approval of this exact text): standard minutes + efficiency (P5, review round 2): migration 20261024120000 + its tests
-- This run changes no real data: every statement below runs inside one rolled-back transaction and the embedded
-- test file itself ends in an unconditional RAISE, so nothing is ever committed, on the real org or anywhere else.
-- One request, one DO block. It: (1) refuses to run before 18:00 IST (the clock is read from clock_timestamp()),
-- (2) recomputes the sha256 of every embedded file and refuses on any mismatch with the pinned value, (3) recomputes
-- a RELATIVE fingerprint of the real organisation (its id + name, picking the earliest non-__TEST-named row — not an
-- exact snapshot of the whole table, so it survives new test orgs being added later) and refuses on any mismatch,
-- confirming this rehearsal is pointed at the real project and that EVERY function this migration redefines
-- (report_ops_resolution, report_kpi_tiles) still equals the one embedded below, freshly re-proved at rehearsal time rather than a pinned
-- value,
-- (4) executes the migration text(s) and then the test file in order, (5) always ends in an unconditional RAISE
-- EXCEPTION, so nothing is ever committed.
-- No top-level begin / commit / savepoint / rollback. No schema_migrations row is written. Never concatenated with
-- test code outside this wrapper. Expected error text starts with RESULTS (or TIMING); anything else is a failure
-- and also rolls back.
-- Pinned (sha256 of the LF blob at the commit this wrapper was generated from):
--   8f72f88c3d71707319bdf17c5f89a72d25661068611bb9089c1b768977e5672e  gv-mart/supabase/migrations/20261024120000_standard_minutes_and_efficiency.sql
--   34c7853753a552ada639ee5025dcde90a491174ac47affec41cde62aec9c81e0  gv-mart/supabase/tests/standard_minutes_and_efficiency.test.sql
-- Pinned (relative fingerprint of the real organisation; read-only, confirmed against the live project):
--   6f891cf85011f08c2f22fb4a208d21bd  md5(organizations.id || '|' || organizations.name) of the earliest non-__TEST row
-- Pinned (sha256 of the ORIGINAL function-defining text embedded below, read from the migration that last
-- defined each; nothing else about these pins is trusted — the comparison itself is recomputed live):
--   646f78b8495c15b060156e6dd7d176d4dd7ba170a57c8d828060eded0b2c4d18  (embedded original of public.report_ops_resolution(date,date))
--   ad0dd4eba0f679ebb9d54aab32c9367a905bdb69df70914e704d2cca673686eb  (embedded original of public.report_kpi_tiles(date,date))

do $rehearsal$
declare
  v_ist time := (clock_timestamp() at time zone 'Asia/Kolkata')::time;
  v_text text;
  v_hash text;
  v_check text;
  v_orig_text text;
  v_orig_hash text;
  v_check_def text;
  v_live_def text;
begin
  if v_ist < time '18:00' then
    raise exception 'REHEARSAL_REFUSED: the clock reads % IST, before 18:00 IST', to_char(v_ist, 'HH24:MI:SS');
  end if;

  select md5(o.id::text || '|' || o.name) into v_check
    from public.organizations o
   where o.name not like '\_\_TEST%'
   order by o.created_at asc
   limit 1;
  if v_check is distinct from '6f891cf85011f08c2f22fb4a208d21bd' then
    raise exception 'REHEARSAL_REFUSED: organisation fingerprint mismatch (expected the real GV Mart org, got %)', coalesce(v_check, 'null');
  end if;

  -- Live-definition precheck (1/2): report_ops_resolution is an EXISTING function this migration redefines.
  -- Re-create the ORIGINAL (embedded below VERBATIM, from the migration that last defined it) inside a sub-block
  -- that is rolled back, compare its pg_get_functiondef to the function as it is ACTUALLY live right now (both computed
  -- fresh here, not a value fetched ahead of time and hard-coded) and refuse on any difference. This proves the
  -- live function equals the repo file, not merely that it matched when this wrapper was written.
  v_orig_text := $orig0$create or replace function public.report_ops_resolution(p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_org uuid := public._report_org();
  v_from timestamptz;
  v_to timestamptz;
  v_result jsonb;
begin
  if p_from is null or p_to is null then
    raise exception 'report_ops_resolution: p_from and p_to are required';
  end if;
  v_from := public._report_ist_start(p_from);
  v_to := public._report_ist_start(p_to + 1);

  select jsonb_build_object(
    'resolved_within_24h', count(*) filter (where t.updated_at - t.created_at <= interval '24 hours'),
    'total_completed', count(*),
    'percent', case when count(*) > 0 then round(count(*) filter (where t.updated_at - t.created_at <= interval '24 hours') * 100.0 / count(*), 1) end
  ) into v_result
  from public.service_tickets t
  where t.org_id = v_org and not public.is_test_customer(t.customer_id) and t.status = 'completed' and t.created_at >= v_from and t.created_at < v_to;
  return v_result;
end;
$function$;
$orig0$;
  v_orig_hash := encode(sha256(convert_to(v_orig_text, 'UTF8')), 'hex');
  if v_orig_hash <> '646f78b8495c15b060156e6dd7d176d4dd7ba170a57c8d828060eded0b2c4d18' then
    raise exception 'REHEARSAL_REFUSED: hash mismatch for the embedded original of report_ops_resolution: %', v_orig_hash;
  end if;
  v_live_def := pg_get_functiondef('public.report_ops_resolution(date,date)'::regprocedure);
  begin
    execute v_orig_text;
    v_check_def := pg_get_functiondef('public.report_ops_resolution(date,date)'::regprocedure);
    raise exception 'GV_PRECHECK_PROBE';
  exception when others then
    if sqlerrm <> 'GV_PRECHECK_PROBE' then raise; end if;
  end;
  if v_check_def is distinct from v_live_def then
    raise exception 'REHEARSAL_REFUSED: the live definition of report_ops_resolution no longer matches the original migration text — refusing to redefine it';
  end if;

  -- Live-definition precheck (2/2): report_kpi_tiles is an EXISTING function this migration redefines.
  -- Re-create the ORIGINAL (embedded below VERBATIM, from the migration that last defined it) inside a sub-block
  -- that is rolled back, compare its pg_get_functiondef to the function as it is ACTUALLY live right now (both computed
  -- fresh here, not a value fetched ahead of time and hard-coded) and refuse on any difference. This proves the
  -- live function equals the repo file, not merely that it matched when this wrapper was written.
  v_orig_text := $orig1$CREATE OR REPLACE FUNCTION public.report_kpi_tiles(p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_org uuid := public._report_org();                    -- raises unless an active master / operation_admin / sales_admin
  v_role text := public.current_role()::text;
  v_master boolean := (v_role = 'master');
  v_ops boolean := (v_role in ('master', 'operation_admin'));
  v_from timestamptz;
  v_to timestamptz;
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_sales jsonb;
  v_service jsonb;
  v_money jsonb;
  v_funnel jsonb;
  v_ops_res jsonb;
  v_fb jsonb;
  v_cust jsonb;
  v_inv_total numeric;
  v_inv_gst numeric;
  v_coll_total numeric;
  v_coll_net numeric;
  v_exp_total numeric;
  v_won integer;
  v_leads integer;
begin
  if p_from is null or p_to is null then
    raise exception 'report_kpi_tiles: p_from and p_to are required';
  end if;
  if p_to < p_from then
    raise exception 'report_kpi_tiles: p_to must not be before p_from';
  end if;
  v_from := public._report_ist_start(p_from);
  v_to := public._report_ist_start(p_to + 1);

  -- ── sales group ────────────────────────────────────────────────────────────────────────────────────────────────────
  if v_role in ('master', 'operation_admin', 'sales_admin') then
    with b as (
      select * from public._report_invoice_base(v_org, v_from, v_to)
    ),
    lines as (
      -- line revenue of the window's counter-sale (class sales) invoices, by item type
      select ii.item_type::text as item_type,
             sum(ii.qty * ii.price - ii.discount) as revenue,
             sum(ii.qty) as qty
      from public.invoice_items ii
      join b on b.invoice_id = ii.invoice_id and b.class = 'sales'
      where ii.org_id = v_org
      group by ii.item_type
    ),
    cls as (
      select class, count(*) as cnt, sum(total) as total from b group by class
    )
    select jsonb_build_object(
      'invoiced', jsonb_build_object(
        'count', (select count(*) from b),
        'total', (select coalesce(sum(total), 0) from b),
        'gst', (select coalesce(sum(gst), 0) from b),
        'net', (select coalesce(sum(total) - sum(gst), 0) from b)),
      'collected', jsonb_build_object(
        'total', (select coalesce(sum(amount_paid), 0) from b),
        'net', (select coalesce(sum(amount_paid) - round(sum(case when total > 0 then amount_paid * gst / total else 0 end), 2), 0) from b)),
      -- tile 3, live: every unpaid or part-paid invoice of a non-test customer, whatever its date
      'outstanding', (
        select jsonb_build_object(
          'amount', coalesce(sum(i.total - i.amount_paid), 0),
          'invoice_count', count(*),
          'oldest_invoice_date', min((i.created_at at time zone 'Asia/Kolkata')::date))
        from public.invoices i
        where i.org_id = v_org and i.payment_status <> 'paid' and i.total - i.amount_paid > 0
          and not public.is_test_customer(i.customer_id)),
      -- tile 7. product + spare + gst_and_adjustments = the whole "sales" class; the five streams add up to invoiced.total
      'streams', jsonb_build_object(
        'product', (select coalesce(sum(revenue), 0) from lines where item_type = 'product'),
        'spare_counter', (select coalesce(sum(revenue), 0) from lines where item_type = 'spare'),
        'gst_and_adjustments', (select coalesce((select total from cls where class = 'sales'), 0) - coalesce(sum(revenue), 0) from lines),
        'service', coalesce((select total from cls where class = 'service'), 0),
        'amc', coalesce((select total from cls where class = 'amc'), 0),
        'rental', coalesce((select total from cls where class = 'rental'), 0),
        'note', 'Spares used on a service visit count as Service, not as Spare.'),
      -- tile 8
      'units_sold', (select coalesce(sum(qty), 0) from lines where item_type = 'product'),
      'avg_sale_value', (select case when coalesce((select cnt from cls where class = 'sales'), 0) > 0
                                     then round((select total from cls where class = 'sales') / (select cnt from cls where class = 'sales'), 2) else 0 end)
    ) into v_sales;

    -- tiles 9, 10 (composed)
    v_funnel := public.get_lead_funnel(v_from, v_to - interval '1 microsecond');
    v_leads := coalesce((v_funnel->>'total')::integer, 0);
    v_won := coalesce((v_funnel #>> '{by_status,won}')::integer, 0);
    -- tile 16 (composed)
    v_cust := public.report_customer_totals(p_from, p_to);

    v_sales := v_sales || jsonb_build_object(
      'leads', jsonb_build_object(
        'new', v_leads,
        'won', v_won,
        'lost', coalesce((v_funnel #>> '{by_status,lost}')::integer, 0),
        'won_percent', case when v_leads > 0 then round(v_won * 100.0 / v_leads, 1) end),
      'repeat_buyers', jsonb_build_object(
        'buying_customers', v_cust->'buying_customers',
        'repeat_buyers', v_cust->'repeat_buyers',
        'new_buyers', v_cust->'new_buyers',
        'repeat_rate_percent', v_cust->'repeat_rate_percent'));
  end if;

  -- ── service group ──────────────────────────────────────────────────────────────────────────────────────────────────
  if v_ops then
    v_ops_res := public.report_ops_resolution(p_from, p_to);
    v_fb := public.report_feedback(p_from, p_to);
    select jsonb_build_object(
      -- tile 12, live
      'open_tickets', (
        select jsonb_build_object(
          'count', count(*),
          'urgent', count(*) filter (where t.priority in ('very_urgent', 'urgent')),
          'past_sla', count(*) filter (where t.sla_due_at is not null and t.sla_due_at < now()))
        from public.service_tickets t
        where t.org_id = v_org and t.status in ('open', 'assigned', 'in_progress')
          and not public.is_test_customer(t.customer_id)
          and not public._ticket_is_future_amc_visit(t.id)),
      -- tile 13
      'resolved_within_24h', jsonb_build_object(
        'resolved', v_ops_res->'resolved_within_24h',
        'completed', v_ops_res->'total_completed',
        'percent', v_ops_res->'percent'),
      -- tile 14
      'rating', jsonb_build_object(
        'average', v_fb->'average_rating',
        'count', (select coalesce(sum((s->>'count')::integer), 0) from jsonb_array_elements(v_fb->'stars_distribution') s),
        'below_4_5', jsonb_array_length(coalesce(v_fb->'low_rating_entries', '[]'::jsonb))),
      -- tile 15, live counts + the window's AMC revenue
      'amc', jsonb_build_object(
        'active', (select count(*) from public.amc_contracts c
                    where c.org_id = v_org and c.cancelled_at is null and not public.is_test_customer(c.customer_id)
                      and c.start_date <= v_today and c.expiry_date >= v_today),
        'renewal_window', (select count(*) from public.amc_contracts c
                    where c.org_id = v_org and c.cancelled_at is null and not public.is_test_customer(c.customer_id)
                      and c.status = 'due_soon' and c.expiry_date >= v_today),
        'revenue', (select coalesce(sum(b.total), 0) from public._report_invoice_base(v_org, v_from, v_to) b where b.class = 'amc'))
    ) into v_service;
  end if;

  -- ── money-out group (master only) ─────────────────────────────────────────────────────────────────────────────────
  if v_master then
    select coalesce(sum(b.total), 0), coalesce(sum(b.gst), 0), coalesce(sum(b.amount_paid), 0),
           coalesce(sum(b.amount_paid) - round(sum(case when b.total > 0 then b.amount_paid * b.gst / b.total else 0 end), 2), 0)
      into v_inv_total, v_inv_gst, v_coll_total, v_coll_net
    from public._report_invoice_base(v_org, v_from, v_to) b;

    select coalesce(sum(amount), 0) into v_exp_total
    from public.expenses where org_id = v_org and date >= p_from and date <= p_to;

    with it as (
      select qty, price, discount, cost
      from public.invoice_items
      where org_id = v_org and created_at >= v_from and created_at < v_to
        and not public._invoice_is_test(invoice_id)
    ),
    gl as (
      select cost
      from public.gift_logs
      where org_id = v_org and created_at >= v_from and created_at < v_to
        and (invoice_id is null or not public._invoice_is_test(invoice_id))
    ),
    m as (
      select (select coalesce(sum(qty * price - discount), 0) from it where cost is not null) as revenue,
             (select coalesce(sum(qty * cost), 0) from it where cost is not null) as cost,
             (select coalesce(sum(cost), 0) from gl where cost is not null) as gifts,
             (select count(*) from it where cost is null) + (select count(*) from gl where cost is null) as missing
    )
    select jsonb_build_object(
      -- tile 4
      'spend', jsonb_build_object(
        'total', v_exp_total,
        'by_category', coalesce((
          select jsonb_agg(jsonb_build_object('category', e.category, 'amount', e.amount) order by e.amount desc, e.category)
          from (select category, sum(amount) as amount from public.expenses
                where org_id = v_org and date >= p_from and date <= p_to group by category) e), '[]'::jsonb),
        'operating_excl_purchase', (select coalesce(sum(amount), 0) from public.expenses
                                     where org_id = v_org and date >= p_from and date <= p_to and category <> 'purchase')),
      -- tile 5: cash basis (Q1)
      'cash_profit', jsonb_build_object('collected_net', v_coll_net, 'spend', v_exp_total, 'profit', v_coll_net - v_exp_total),
      -- tile 6
      'item_margin', jsonb_build_object(
        'revenue', m.revenue, 'cost', m.cost, 'gifts_cost', m.gifts,
        'profit', m.revenue - m.cost - m.gifts,
        'margin_percent', case when m.revenue > 0 then round((m.revenue - m.cost - m.gifts) / m.revenue * 100, 1) end,
        'missing_cost_count', m.missing,
        'cost_missing', m.missing > 0)
    ) into v_money
    from m;
  end if;

  return jsonb_build_object(
    'window', jsonb_build_object('from', p_from, 'to', p_to, 'today_ist', v_today),
    'role', v_role,
    'sales', v_sales,          -- null for a caller who may not see it
    'service', v_service,
    'money_out', v_money);
end;
$function$;
$orig1$;
  v_orig_hash := encode(sha256(convert_to(v_orig_text, 'UTF8')), 'hex');
  if v_orig_hash <> 'ad0dd4eba0f679ebb9d54aab32c9367a905bdb69df70914e704d2cca673686eb' then
    raise exception 'REHEARSAL_REFUSED: hash mismatch for the embedded original of report_kpi_tiles: %', v_orig_hash;
  end if;
  v_live_def := pg_get_functiondef('public.report_kpi_tiles(date,date)'::regprocedure);
  begin
    execute v_orig_text;
    v_check_def := pg_get_functiondef('public.report_kpi_tiles(date,date)'::regprocedure);
    raise exception 'GV_PRECHECK_PROBE';
  exception when others then
    if sqlerrm <> 'GV_PRECHECK_PROBE' then raise; end if;
  end;
  if v_check_def is distinct from v_live_def then
    raise exception 'REHEARSAL_REFUSED: the live definition of report_kpi_tiles no longer matches the original migration text — refusing to redefine it';
  end if;

  v_text := $rh0$-- P5: a standard-minutes master per service (complaint) type; an actual-vs-standard efficiency figure on the
-- technician performance report; the overrun buffer and the ops-resolution SLA move from hard-coded constants to
-- settings. INFORMATIONAL ONLY: nothing here is read by compute_incentives, technician_kpi_summary's "flagged"
-- logic, or any review column — see the standing instruction this package was built under.
--
-- Version label (comment only; does not change report_performance_efficiency's return payload):
--   (a) Migration version: this is the 3rd on-disk revision of this file (content byte-identical across the
--       two renames — Nov-dated -> 20261024110000 -> 20261024120000, commits 996ee08, 2770919 — only the
--       filename/pins/cross-references changed); the SQL itself last changed functionally in 37fb04e
--       (sla_hours threaded through) and 6898e35 (test-only fix).
--   (b) Live functions this migration redefines, and how the match is proven: report_ops_resolution (last live
--       body: 20261016110000_test_customer_flag.sql) and report_kpi_tiles (last live body:
--       20261022100000_amc_visits_unassigned_until_due.sql). Neither is pinned here as a static md5 of "the live
--       definition" — the rehearsal wrapper (rehearsals/rehearsal_20261024120000_standard_minutes_and_efficiency.sql)
--       embeds each ORIGINAL function's full text verbatim and, at rehearsal run time, recreates it under a
--       sub-block and compares its pg_get_functiondef output against the function AS IT IS ACTUALLY LIVE right
--       then, refusing on any mismatch. A pinned md5 of "the live definition" computed now would go stale the
--       moment the live function changed and nothing would catch that; the wrapper's live, recomputed comparison
--       is the actual safety property wanted here. What IS pinned (sha256, in the wrapper's own header) is the
--       embedded ORIGINAL text itself, so the wrapper can't silently drift from what this file says it embeds.
--       report_performance_efficiency is NOT in this list: it is a brand-new RPC with no live predecessor to
--       diff against or prove a match for.
--   (c) Diff baseline: this file (and its rollback/test/wrapper) were last reviewed by the owner at commit
--       b355850 (chore(reports): P5 reconciliation). Everything from b355850 to this revision is summarized in
--       the P5 handoff: the SLA-hours threading fix (37fb04e) and its tests (5d2fe2b, 42718d4), a test-only
--       PL/pgSQL variable-shadow fix (6898e35), two pure migration renumberings with no SQL content change
--       (996ee08 also restored report_kpi_tiles — not just report_ops_resolution — in the rollback, which the
--       first sla_hours round had missed; 2770919), and the wrapper rewrite to the live-comparison shape
--       described in (b) (cc5cf3a). Current tip: cc5cf3a.
--
-- 1. complaint_types.standard_minutes: nullable, master-edited in Masters > Complaint Types (ComplaintTypesTab.tsx,
--    which already master-gates writes via complaint_types_write_master — no RLS change). Per-ITEM standard times
--    (products.standard_time_minutes, spares.standard_time_minutes, 20260725100000) and the four per-TICKET-TYPE
--    defaults (settings.default_duration_*, 20260721090000) already existed; this is the finer-grained master the
--    audit found missing — per complaint type, not just per paid/warranty/amc/installation.
--
-- 2. settings.job_overrun_buffer_minutes (was the OVERRUN_BUFFER_MINUTES=5 constant in src/lib/job-overrun.ts) and
--    settings.ops_resolution_sla_hours (was the hard-coded `interval '24 hours'` inside report_ops_resolution).
--    report_ops_resolution's SAME signature and return shape otherwise; only its body now reads settings instead
--    of a literal. Default 24 preserves today's behaviour exactly until master changes it in Settings.
--
--    Review fix: report_ops_resolution kept its key literally named 'resolved_within_24h' while the window
--    behind it became configurable — an honest label needs the actual hours, not a baked-in "24". Rather than
--    rename that key (which every current reader keys off by name) the function now ALSO returns 'sla_hours' in
--    the same payload, additively, so every caller can derive its own label from the real value instead of
--    assuming 24. report_kpi_tiles is its one other SQL caller and is redefined here too, forwarding that same
--    'sla_hours' field into its own tile-13 sub-object, additively, so the KPI tile strip can show the real
--    figure as well. report_kpi_tiles' live body is the one in 20261022100000_amc_visits_unassigned_until_due.sql
--    (that migration's own "KPI: far-away AMC visits are not counted in open_tickets (live body, one added
--    condition)" redefines the whole function), NOT the earlier 20261017110000 copy it superseded — the starting
--    point here is the later, live one.
--
-- 3. report_performance_efficiency(p_from, p_to): a NEW, separate RPC — report_performance itself is NOT edited.
--    For each technician's timed visits in range (same population as report_performance's own `jobsDone`/
--    `avgCompletionMinutes`: org-scoped, not public._visit_is_test(sv.id), timer_start in range — matched against
--    report_performance's LATEST body in 20261016110000_test_customer_flag.sql, not the earlier
--    20261009120000 copy, which predates the test-customer exclusion), sums actual minutes (timer_end -
--    timer_start) against a resolved "standard" minutes figure (the ticket's complaint_types.standard_minutes if
--    set, else the ticket type's settings.default_duration_* default) and returns a percentage. A visit whose
--    standard cannot be resolved at all is excluded from BOTH sums, not counted as 0 — it would otherwise
--    silently drag the percentage down for a technician who did nothing wrong.

alter table public.complaint_types
  add column standard_minutes integer check (standard_minutes is null or standard_minutes > 0);

alter table public.settings
  add column job_overrun_buffer_minutes integer not null default 5 check (job_overrun_buffer_minutes >= 0),
  add column ops_resolution_sla_hours integer not null default 24 check (ops_resolution_sla_hours > 0);

comment on column public.settings.job_overrun_buffer_minutes is
  'Minutes of grace after a job''s allowed duration before the overrun alert fires (lib/job-overrun.ts). Was a hard-coded constant.';
comment on column public.settings.ops_resolution_sla_hours is
  'Hours within which a completed ticket counts as "resolved on time" for the ops-resolution KPI. Was a hard-coded 24h.';

-- Same signature and return shape as the existing definition; only the literal `interval '24 hours'` becomes a
-- per-org setting. report_kpi_tiles and the amc-visits migration call this by name with no argument change needed.
create or replace function public.report_ops_resolution(p_from date, p_to date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_org uuid := public._report_org();
  v_from timestamptz;
  v_to timestamptz;
  v_sla_hours integer;
  v_result jsonb;
begin
  if p_from is null or p_to is null then
    raise exception 'report_ops_resolution: p_from and p_to are required';
  end if;
  v_from := public._report_ist_start(p_from);
  v_to := public._report_ist_start(p_to + 1);
  select coalesce(s.ops_resolution_sla_hours, 24) into v_sla_hours from public.settings s where s.org_id = v_org;
  v_sla_hours := coalesce(v_sla_hours, 24);

  select jsonb_build_object(
    'resolved_within_24h', count(*) filter (where t.updated_at - t.created_at <= (v_sla_hours || ' hours')::interval),
    'total_completed', count(*),
    'percent', case when count(*) > 0 then round(count(*) filter (where t.updated_at - t.created_at <= (v_sla_hours || ' hours')::interval) * 100.0 / count(*), 1) end,
    'sla_hours', v_sla_hours
  ) into v_result
  from public.service_tickets t
  where t.org_id = v_org and not public.is_test_customer(t.customer_id) and t.status = 'completed' and t.created_at >= v_from and t.created_at < v_to;
  return v_result;
end;
$$;

create or replace function public.report_performance_efficiency(p_from date, p_to date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_org uuid := public._report_org();
  v_from timestamptz;
  v_to timestamptz;
  v_result jsonb;
begin
  if p_from is null or p_to is null then
    raise exception 'report_performance_efficiency: p_from and p_to are required';
  end if;
  v_from := public._report_ist_start(p_from);
  v_to := public._report_ist_start(p_to + 1);

  with vis as (
    select sv.technician_id,
           greatest(0, round(extract(epoch from (sv.timer_end - sv.timer_start)) / 60)) as actual_minutes,
           coalesce(
             ct.standard_minutes,
             case st.type
               when 'paid' then s.default_duration_paid_minutes
               when 'warranty' then s.default_duration_warranty_minutes
               when 'amc' then s.default_duration_amc_minutes
               when 'installation' then s.default_duration_installation_minutes
             end
           ) as standard_minutes
    from public.service_visits sv
    join public.service_tickets st on st.id = sv.ticket_id
    join public.settings s on s.org_id = v_org
    left join public.complaint_types ct on ct.id = st.complaint_type_id
    where sv.org_id = v_org and not public._visit_is_test(sv.id) and sv.timer_start >= v_from and sv.timer_start < v_to
      and sv.timer_start is not null and sv.timer_end is not null
  ),
  agg as (
    select technician_id, sum(standard_minutes) as std_sum, sum(actual_minutes) as act_sum, count(*) as n
    from vis
    where standard_minutes is not null
    group by technician_id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', a.technician_id,
      'efficiency_percent', case when a.act_sum > 0 then round(a.std_sum * 100.0 / a.act_sum, 1) end,
      'efficiency_sample_count', a.n
    )), '[]'::jsonb)
  into v_result
  from agg a;
  return v_result;
end;
$$;
revoke all on function public.report_performance_efficiency(date, date) from public, anon;
grant execute on function public.report_performance_efficiency(date, date) to authenticated;

-- report_kpi_tiles (review fix): its live body, unchanged except tile 13 now also carries 'sla_hours' through from
-- report_ops_resolution's own newly-added field, additively — every other line is byte-identical to the live function.
CREATE OR REPLACE FUNCTION public.report_kpi_tiles(p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_org uuid := public._report_org();                    -- raises unless an active master / operation_admin / sales_admin
  v_role text := public.current_role()::text;
  v_master boolean := (v_role = 'master');
  v_ops boolean := (v_role in ('master', 'operation_admin'));
  v_from timestamptz;
  v_to timestamptz;
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_sales jsonb;
  v_service jsonb;
  v_money jsonb;
  v_funnel jsonb;
  v_ops_res jsonb;
  v_fb jsonb;
  v_cust jsonb;
  v_inv_total numeric;
  v_inv_gst numeric;
  v_coll_total numeric;
  v_coll_net numeric;
  v_exp_total numeric;
  v_won integer;
  v_leads integer;
begin
  if p_from is null or p_to is null then
    raise exception 'report_kpi_tiles: p_from and p_to are required';
  end if;
  if p_to < p_from then
    raise exception 'report_kpi_tiles: p_to must not be before p_from';
  end if;
  v_from := public._report_ist_start(p_from);
  v_to := public._report_ist_start(p_to + 1);

  -- ── sales group ────────────────────────────────────────────────────────────────────────────────────────────────────
  if v_role in ('master', 'operation_admin', 'sales_admin') then
    with b as (
      select * from public._report_invoice_base(v_org, v_from, v_to)
    ),
    lines as (
      -- line revenue of the window's counter-sale (class sales) invoices, by item type
      select ii.item_type::text as item_type,
             sum(ii.qty * ii.price - ii.discount) as revenue,
             sum(ii.qty) as qty
      from public.invoice_items ii
      join b on b.invoice_id = ii.invoice_id and b.class = 'sales'
      where ii.org_id = v_org
      group by ii.item_type
    ),
    cls as (
      select class, count(*) as cnt, sum(total) as total from b group by class
    )
    select jsonb_build_object(
      'invoiced', jsonb_build_object(
        'count', (select count(*) from b),
        'total', (select coalesce(sum(total), 0) from b),
        'gst', (select coalesce(sum(gst), 0) from b),
        'net', (select coalesce(sum(total) - sum(gst), 0) from b)),
      'collected', jsonb_build_object(
        'total', (select coalesce(sum(amount_paid), 0) from b),
        'net', (select coalesce(sum(amount_paid) - round(sum(case when total > 0 then amount_paid * gst / total else 0 end), 2), 0) from b)),
      -- tile 3, live: every unpaid or part-paid invoice of a non-test customer, whatever its date
      'outstanding', (
        select jsonb_build_object(
          'amount', coalesce(sum(i.total - i.amount_paid), 0),
          'invoice_count', count(*),
          'oldest_invoice_date', min((i.created_at at time zone 'Asia/Kolkata')::date))
        from public.invoices i
        where i.org_id = v_org and i.payment_status <> 'paid' and i.total - i.amount_paid > 0
          and not public.is_test_customer(i.customer_id)),
      -- tile 7. product + spare + gst_and_adjustments = the whole "sales" class; the five streams add up to invoiced.total
      'streams', jsonb_build_object(
        'product', (select coalesce(sum(revenue), 0) from lines where item_type = 'product'),
        'spare_counter', (select coalesce(sum(revenue), 0) from lines where item_type = 'spare'),
        'gst_and_adjustments', (select coalesce((select total from cls where class = 'sales'), 0) - coalesce(sum(revenue), 0) from lines),
        'service', coalesce((select total from cls where class = 'service'), 0),
        'amc', coalesce((select total from cls where class = 'amc'), 0),
        'rental', coalesce((select total from cls where class = 'rental'), 0),
        'note', 'Spares used on a service visit count as Service, not as Spare.'),
      -- tile 8
      'units_sold', (select coalesce(sum(qty), 0) from lines where item_type = 'product'),
      'avg_sale_value', (select case when coalesce((select cnt from cls where class = 'sales'), 0) > 0
                                     then round((select total from cls where class = 'sales') / (select cnt from cls where class = 'sales'), 2) else 0 end)
    ) into v_sales;

    -- tiles 9, 10 (composed)
    v_funnel := public.get_lead_funnel(v_from, v_to - interval '1 microsecond');
    v_leads := coalesce((v_funnel->>'total')::integer, 0);
    v_won := coalesce((v_funnel #>> '{by_status,won}')::integer, 0);
    -- tile 16 (composed)
    v_cust := public.report_customer_totals(p_from, p_to);

    v_sales := v_sales || jsonb_build_object(
      'leads', jsonb_build_object(
        'new', v_leads,
        'won', v_won,
        'lost', coalesce((v_funnel #>> '{by_status,lost}')::integer, 0),
        'won_percent', case when v_leads > 0 then round(v_won * 100.0 / v_leads, 1) end),
      'repeat_buyers', jsonb_build_object(
        'buying_customers', v_cust->'buying_customers',
        'repeat_buyers', v_cust->'repeat_buyers',
        'new_buyers', v_cust->'new_buyers',
        'repeat_rate_percent', v_cust->'repeat_rate_percent'));
  end if;

  -- ── service group ──────────────────────────────────────────────────────────────────────────────────────────────────
  if v_ops then
    v_ops_res := public.report_ops_resolution(p_from, p_to);
    v_fb := public.report_feedback(p_from, p_to);
    select jsonb_build_object(
      -- tile 12, live
      'open_tickets', (
        select jsonb_build_object(
          'count', count(*),
          'urgent', count(*) filter (where t.priority in ('very_urgent', 'urgent')),
          'past_sla', count(*) filter (where t.sla_due_at is not null and t.sla_due_at < now()))
        from public.service_tickets t
        where t.org_id = v_org and t.status in ('open', 'assigned', 'in_progress')
          and not public.is_test_customer(t.customer_id)
          and not public._ticket_is_future_amc_visit(t.id)),
      -- tile 13 (review fix: 'sla_hours' now carried through additively, so the tile strip can say the real figure)
      'resolved_within_24h', jsonb_build_object(
        'resolved', v_ops_res->'resolved_within_24h',
        'completed', v_ops_res->'total_completed',
        'percent', v_ops_res->'percent',
        'sla_hours', v_ops_res->'sla_hours'),
      -- tile 14
      'rating', jsonb_build_object(
        'average', v_fb->'average_rating',
        'count', (select coalesce(sum((s->>'count')::integer), 0) from jsonb_array_elements(v_fb->'stars_distribution') s),
        'below_4_5', jsonb_array_length(coalesce(v_fb->'low_rating_entries', '[]'::jsonb))),
      -- tile 15, live counts + the window's AMC revenue
      'amc', jsonb_build_object(
        'active', (select count(*) from public.amc_contracts c
                    where c.org_id = v_org and c.cancelled_at is null and not public.is_test_customer(c.customer_id)
                      and c.start_date <= v_today and c.expiry_date >= v_today),
        'renewal_window', (select count(*) from public.amc_contracts c
                    where c.org_id = v_org and c.cancelled_at is null and not public.is_test_customer(c.customer_id)
                      and c.status = 'due_soon' and c.expiry_date >= v_today),
        'revenue', (select coalesce(sum(b.total), 0) from public._report_invoice_base(v_org, v_from, v_to) b where b.class = 'amc'))
    ) into v_service;
  end if;

  -- ── money-out group (master only) ─────────────────────────────────────────────────────────────────────────────────
  if v_master then
    select coalesce(sum(b.total), 0), coalesce(sum(b.gst), 0), coalesce(sum(b.amount_paid), 0),
           coalesce(sum(b.amount_paid) - round(sum(case when b.total > 0 then b.amount_paid * b.gst / b.total else 0 end), 2), 0)
      into v_inv_total, v_inv_gst, v_coll_total, v_coll_net
    from public._report_invoice_base(v_org, v_from, v_to) b;

    select coalesce(sum(amount), 0) into v_exp_total
    from public.expenses where org_id = v_org and date >= p_from and date <= p_to;

    with it as (
      select qty, price, discount, cost
      from public.invoice_items
      where org_id = v_org and created_at >= v_from and created_at < v_to
        and not public._invoice_is_test(invoice_id)
    ),
    gl as (
      select cost
      from public.gift_logs
      where org_id = v_org and created_at >= v_from and created_at < v_to
        and (invoice_id is null or not public._invoice_is_test(invoice_id))
    ),
    m as (
      select (select coalesce(sum(qty * price - discount), 0) from it where cost is not null) as revenue,
             (select coalesce(sum(qty * cost), 0) from it where cost is not null) as cost,
             (select coalesce(sum(cost), 0) from gl where cost is not null) as gifts,
             (select count(*) from it where cost is null) + (select count(*) from gl where cost is null) as missing
    )
    select jsonb_build_object(
      -- tile 4
      'spend', jsonb_build_object(
        'total', v_exp_total,
        'by_category', coalesce((
          select jsonb_agg(jsonb_build_object('category', e.category, 'amount', e.amount) order by e.amount desc, e.category)
          from (select category, sum(amount) as amount from public.expenses
                where org_id = v_org and date >= p_from and date <= p_to group by category) e), '[]'::jsonb),
        'operating_excl_purchase', (select coalesce(sum(amount), 0) from public.expenses
                                     where org_id = v_org and date >= p_from and date <= p_to and category <> 'purchase')),
      -- tile 5: cash basis (Q1)
      'cash_profit', jsonb_build_object('collected_net', v_coll_net, 'spend', v_exp_total, 'profit', v_coll_net - v_exp_total),
      -- tile 6
      'item_margin', jsonb_build_object(
        'revenue', m.revenue, 'cost', m.cost, 'gifts_cost', m.gifts,
        'profit', m.revenue - m.cost - m.gifts,
        'margin_percent', case when m.revenue > 0 then round((m.revenue - m.cost - m.gifts) / m.revenue * 100, 1) end,
        'missing_cost_count', m.missing,
        'cost_missing', m.missing > 0)
    ) into v_money
    from m;
  end if;

  return jsonb_build_object(
    'window', jsonb_build_object('from', p_from, 'to', p_to, 'today_ist', v_today),
    'role', v_role,
    'sales', v_sales,          -- null for a caller who may not see it
    'service', v_service,
    'money_out', v_money);
end;
$function$;
$rh0$;
  v_hash := encode(sha256(convert_to(v_text, 'UTF8')), 'hex');
  if v_hash <> '8f72f88c3d71707319bdf17c5f89a72d25661068611bb9089c1b768977e5672e' then
    raise exception 'REHEARSAL_REFUSED: hash mismatch for 20261024120000_standard_minutes_and_efficiency.sql: %', v_hash;
  end if;
  execute v_text;

  v_text := $rh1$-- Rolled-back DB tests for 20261024120000_standard_minutes_and_efficiency (P5).
-- NOT RUN (written for review). Run only through the rehearsal wrapper: it applies the migration and then this file in ONE
-- request; this file ends in an unconditional RAISE, so nothing is committed. Throwaway __TEST_ organisation only.
create temp table res (n serial, line text);
grant all on res to public;
grant usage on sequence res_n_seq to public;
-- 20261024100000 (applied live) runs `alter default privileges for role postgres revoke execute on functions from public`, globally. That also
-- removes PUBLIC execute from the helper functions below, which live in pg_temp and are called after `set local role authenticated`. This default
-- makes every function created here executable again, including helpers added later. (pg_temp is not a name ALTER DEFAULT PRIVILEGES accepts, so
-- the session's real temporary schema is looked up. The setting is rolled back with the wrapper, and disappears with the session otherwise.)
do $g$ begin execute format('alter default privileges in schema %s grant execute on functions to public', pg_my_temp_schema()::regnamespace); end $g$;
create function pg_temp.chk(p_name text, p_ok boolean, p_info text default '') returns void language plpgsql as $f$
begin insert into pg_temp.res(line) values (case when coalesce(p_ok,false) then 'PASS  ' else 'FAIL  ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end); end $f$;
create function pg_temp.mkuser(p_role text, p_org uuid, p_tech boolean default false) returns uuid language plpgsql as $f$
declare v uuid := gen_random_uuid();
begin
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
  values (v, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '__t_' || p_role || '_' || v || '@test.invalid', 'x', now(), now(), now(), '{}', '{}');
  insert into public.profiles (id, org_id, full_name, role, is_active) values (v, p_org, '__TEST_ ' || p_role, p_role::public.user_role, true)
    on conflict (id) do update set role = excluded.role, is_active = true, org_id = excluded.org_id;
  if p_tech then insert into public.technicians (org_id, profile_id, is_active) values (p_org, v, true); end if;
  return v;
end $f$;
create function pg_temp.act(p_uid uuid, p_sql text) returns text language plpgsql as $f$
declare n int;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    execute p_sql;
    get diagnostics n = row_count;
    execute 'reset role';
    return 'ok:' || n;
  exception when others then
    execute 'reset role';
    return 'err:' || sqlerrm;
  end;
end $f$;
create function pg_temp.call_as(p_uid uuid, p_fn text, p_from date, p_to date) returns jsonb language plpgsql as $f$
declare v_result jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  execute format('select public.%I($1, $2)', p_fn) into v_result using p_from, p_to;
  execute 'reset role';
  return v_result;
exception when others then
  execute 'reset role';
  return jsonb_build_object('__error', sqlerrm);
end $f$;

do $t$
declare
  v_org uuid; m uuid; t1 uuid; t2 uuid;
  v_brand uuid; v_model uuid; v_product uuid; v_cust uuid; v_cust_test uuid;
  v_ct_fast uuid; v_tk1 uuid; v_tk2 uuid; v_tk3 uuid; v_tk_test uuid; v_tech1 uuid; v_tech2 uuid;
  v_vis1 uuid; v_vis2 uuid; v_vis3 uuid; v_vis_test uuid;
  x text; r jsonb; v_from date := current_date - 1; v_to date := current_date + 1;
  v_now timestamptz := now();
begin
  insert into public.organizations(name) values ('__TEST_p5') returning id into v_org;
  insert into public.settings(org_id) values (v_org) on conflict do nothing;
  m := pg_temp.mkuser('master', v_org);
  t1 := pg_temp.mkuser('technician', v_org, true); t2 := pg_temp.mkuser('technician', v_org, true);
  select id into v_tech1 from public.technicians where profile_id = t1;
  select id into v_tech2 from public.technicians where profile_id = t2;

  -- C: columns
  perform pg_temp.chk('C1 complaint_types.standard_minutes exists (nullable int, > 0 check)',
    (select data_type from information_schema.columns where table_schema = 'public' and table_name = 'complaint_types' and column_name = 'standard_minutes') = 'integer');
  perform pg_temp.chk('C2 settings has job_overrun_buffer_minutes (default 5) and ops_resolution_sla_hours (default 24)',
    (select column_default from information_schema.columns where table_schema = 'public' and table_name = 'settings' and column_name = 'job_overrun_buffer_minutes') = '5'
    and (select column_default from information_schema.columns where table_schema = 'public' and table_name = 'settings' and column_name = 'ops_resolution_sla_hours') = '24');
  perform pg_temp.chk('C3 existing settings rows got the default (no backfill needed to reach it)',
    (select ops_resolution_sla_hours = 24 and job_overrun_buffer_minutes = 5 from public.settings where org_id = v_org));

  -- MASTER: complaint type standard minutes, master-write only
  insert into public.complaint_types(org_id, product_category, label) values (v_org, 'ro', '__TEST_fast_fix') returning id into v_ct_fast;
  x := pg_temp.act(m, format('update public.complaint_types set standard_minutes = 20 where id = %L', v_ct_fast));
  perform pg_temp.chk('M1 master sets a complaint type''s standard minutes', x = 'ok:1', x);
  x := pg_temp.act(t1, format('update public.complaint_types set standard_minutes = 999 where id = %L', v_ct_fast));
  perform pg_temp.chk('M2 a technician cannot (complaint_types_write_master, unchanged)', x = 'ok:0' or x like 'err:%', x);
  x := pg_temp.act(m, format('insert into public.complaint_types(org_id, product_category, label, standard_minutes) values (%L, ''ro'', ''__TEST_bad'', -5)', v_org));
  perform pg_temp.chk('M3 a non-positive standard_minutes is refused', x like 'err:%', x);

  -- fixtures for the efficiency RPC
  insert into public.customers(org_id, name, mobile) values (v_org, '__TEST_cust', '9000000010') returning id into v_cust;
  insert into public.customers(org_id, name, mobile, is_test) values (v_org, '__TEST_cust_test', '9000000011', true) returning id into v_cust_test;
  insert into public.brands(org_id, name, category) values (v_org, '__TEST_brand', 'ro') returning id into v_brand;
  insert into public.models(org_id, brand_id, name) values (v_org, v_brand, '__TEST_model') returning id into v_model;

  -- ticket 1: complaint type with standard_minutes=20, technician t1 takes 30 actual minutes -> below standard
  insert into public.service_tickets(org_id, customer_id, type, complaint_type_id, name_of_complaint) values (v_org, v_cust, 'paid', v_ct_fast, '__TEST_t1') returning id into v_tk1;
  insert into public.service_visits(org_id, ticket_id, technician_id, timer_start, timer_end)
    values (v_org, v_tk1, v_tech1, v_now, v_now + interval '30 minutes') returning id into v_vis1;

  -- ticket 2: no complaint_type_id, type='amc' -> falls back to settings.default_duration_amc_minutes (30);
  -- technician t1, actual 45 minutes
  insert into public.service_tickets(org_id, customer_id, type, name_of_complaint) values (v_org, v_cust, 'amc', '__TEST_t2') returning id into v_tk2;
  insert into public.service_visits(org_id, ticket_id, technician_id, timer_start, timer_end)
    values (v_org, v_tk2, v_tech1, v_now, v_now + interval '45 minutes') returning id into v_vis2;

  -- ticket 3: a complaint type with NO standard_minutes set, no fallback applicable other than its own type default;
  -- give it type 'paid' (default 45) so it still resolves — this one is just a second, independent sample for t2.
  insert into public.service_tickets(org_id, customer_id, type, name_of_complaint) values (v_org, v_cust, 'paid', '__TEST_t3') returning id into v_tk3;
  insert into public.service_visits(org_id, ticket_id, technician_id, timer_start, timer_end)
    values (v_org, v_tk3, v_tech2, v_now, v_now + interval '90 minutes') returning id into v_vis3;

  -- a test-customer's visit must be excluded entirely (same population as report_performance)
  insert into public.service_tickets(org_id, customer_id, type, complaint_type_id, name_of_complaint) values (v_org, v_cust_test, 'paid', v_ct_fast, '__TEST_test_customer') returning id into v_tk_test;
  insert into public.service_visits(org_id, ticket_id, technician_id, timer_start, timer_end)
    values (v_org, v_tk_test, v_tech1, v_now, v_now + interval '5 minutes') returning id into v_vis_test;

  r := pg_temp.call_as(m, 'report_performance_efficiency', v_from, v_to);
  perform pg_temp.chk('E1 the RPC returns without error for master', not (r ? '__error'), r::text);

  -- t1: standard 20 (vis1) + 30 (vis2, amc default) = 50; actual 30 + 45 = 75 -> 50*100/75 = 66.7
  perform pg_temp.chk('E2 t1''s efficiency is (20+30)/(30+45) = 66.7% over 2 samples, the test-customer visit excluded',
    (select (e->>'efficiency_percent')::numeric = 66.7 and (e->>'efficiency_sample_count')::int = 2
       from jsonb_array_elements(r) e where e->>'id' = v_tech1::text),
    r::text);
  -- t2: standard 45 (vis3, paid default) ; actual 90 -> 50.0
  perform pg_temp.chk('E3 t2''s efficiency is 45/90 = 50.0% over 1 sample',
    (select (e->>'efficiency_percent')::numeric = 50.0 and (e->>'efficiency_sample_count')::int = 1
       from jsonb_array_elements(r) e where e->>'id' = v_tech2::text),
    r::text);
  perform pg_temp.chk('E4 the test customer''s visit contributed to neither technician''s sample count',
    not exists (select 1 from jsonb_array_elements(r) e where (e->>'efficiency_sample_count')::int > 2));

  x := pg_temp.act(t1, format('select public.report_performance_efficiency(%L, %L)', v_from, v_to));
  perform pg_temp.chk('E5 a technician cannot call it (is_staff()-gated via _report_org, same as every other report RPC)',
    x like '%not permitted%' or x like 'err:%', x);
  perform pg_temp.chk('E6 the function is not callable by anon or PUBLIC',
    not has_function_privilege('anon', 'public.report_performance_efficiency(date,date)', 'execute')
    and not exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                     where p.pronamespace = 'public'::regnamespace and p.proname = 'report_performance_efficiency' and a.grantee = 0));

  -- SLA setting actually changes report_ops_resolution's behaviour (same signature, same shape, no caller change)
  update public.settings set ops_resolution_sla_hours = 1 where org_id = v_org;
  update public.service_tickets set status = 'completed', created_at = now() - interval '2 hours', updated_at = now() where id = v_tk1;
  r := pg_temp.call_as(m, 'report_ops_resolution', v_from, v_to);
  perform pg_temp.chk('S1 with a 1-hour SLA, a ticket completed 2 hours after creation is NOT within SLA',
    (r->>'resolved_within_24h')::int = 0, r::text);
  update public.settings set ops_resolution_sla_hours = 24 where org_id = v_org;
  r := pg_temp.call_as(m, 'report_ops_resolution', v_from, v_to);
  perform pg_temp.chk('S2 reverting to the 24h default, the same ticket IS within SLA again',
    (r->>'resolved_within_24h')::int = 1, r::text);

  -- S3/S4 (review fix): the RPC's key is still literally named 'resolved_within_24h' even though the window is
  -- configurable, so it now ALSO carries the real value as 'sla_hours' — an honest label can be built from that,
  -- without guessing 24. Prove the carried value actually reflects a non-default setting, not just the default.
  update public.settings set ops_resolution_sla_hours = 6 where org_id = v_org;
  r := pg_temp.call_as(m, 'report_ops_resolution', v_from, v_to);
  perform pg_temp.chk('S3 report_ops_resolution carries the real sla_hours (6, not the 24 default) in its payload',
    (r->>'sla_hours')::int = 6, r::text);

  r := pg_temp.call_as(m, 'report_kpi_tiles', v_from, v_to);
  perform pg_temp.chk('S4 report_kpi_tiles forwards the SAME sla_hours into its own tile-13 sub-object (additive; every other field of that object is untouched)',
    (r #>> '{service,resolved_within_24h,sla_hours}')::int = 6
    and (r #>> '{service,resolved_within_24h,percent}') is not null,
    r::text);
  update public.settings set ops_resolution_sla_hours = 24 where org_id = v_org;

  raise exception 'RESULTS%', E'\n' || (select string_agg(r2.line, E'\n' order by r2.n) from pg_temp.res r2);
end $t$;
$rh1$;
  v_hash := encode(sha256(convert_to(v_text, 'UTF8')), 'hex');
  if v_hash <> '34c7853753a552ada639ee5025dcde90a491174ac47affec41cde62aec9c81e0' then
    raise exception 'REHEARSAL_REFUSED: hash mismatch for standard_minutes_and_efficiency.test.sql: %', v_hash;
  end if;
  execute v_text;

  raise exception 'REHEARSAL_DID_NOT_RAISE: the test file should have raised RESULTS';
end
$rehearsal$;
