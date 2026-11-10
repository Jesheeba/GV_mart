-- Rehearsal wrapper for 20261116100000_close_outstanding_reminders_bulk.sql +
-- supabase/tests/close_outstanding_reminders_bulk.test.sql.
--
-- WRITTEN ONLY -- never executed against any database by the agent that produced this file. The owner runs this
-- by hand, after 11:00 IST (this feature's established gate time -- matches every other apply script under
-- supabase/ops/2026111510*), once satisfied the sha256-pinned text embedded below for BOTH files is byte-for-byte
-- what they reviewed.
--
-- Same six-guarantee structure as every other rehearsal wrapper in this project (ORG CHECK, LOCK, GATE, PIN, RUN,
-- PROVE): this block ends in an unconditional RAISE EXCEPTION, so nothing it does can ever commit, independent of
-- whether the embedded test passes, fails, or the gate/pin refuses outright.
--
-- PROVE scope: close_outstanding_reminders_if_zero_bulk() only ever updates public.customer_outstanding_reminders
-- rows, and only for the calling org -- the fingerprint below covers every REAL (non __TEST_) org's reminder rows,
-- which must be byte-identical before and after (this migration adds a function; the embedded test's own __TEST_
-- rows are rolled back by its closing RAISE before the AFTER fingerprint is taken).
do $rehearsal$
declare
  v_ist_hour                 int;
  v_expected_org_fingerprint text := '6f891cf85011f08c2f22fb4a208d21bd';
  v_actual_org_fingerprint   text;
  v_expected_migration_hash  text := 'c7b19159782b85ee79f9a32bb4e7de50a49b18eb520c18fefb8ca928ac9cd4ba';
  v_expected_test_hash       text := '64ab398a53112d56f7ea87cfbef317c6c1c7e285d46762d7191c5e749949c87c';
  v_actual_migration_hash    text;
  v_actual_test_hash         text;
  v_fp_before                text;
  v_fp_after                 text;
  v_inner_result             text;
  res                        text := '';
  v_embedded_migration        text := $migration$-- Accounts follow-up, reminder management batch, item 2 — auto-close ALL
-- open customer-outstanding reminders whose customer's balance has reached
-- zero, computed on read (owner's condition: no trigger, no background job)
-- whenever the Customer Outstanding list or the new Reminders view loads,
-- not only when one customer's own "Follow up" dialog opens.
--
-- This is the same logic close_outstanding_reminders_if_zero (20261115100300)
-- already runs for a single customer, generalised into a loop over every
-- customer in this org that currently has an open reminder. No money table
-- is touched or written to -- only customer_outstanding_reminders rows are
-- updated, exactly as the existing per-customer version does.

create or replace function public.close_outstanding_reminders_if_zero_bulk()
returns int
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_org uuid := public.current_org_id();
  v_total_closed int := 0;
  v_customer record;
  v_outstanding numeric;
  v_closed int;
begin
  if v_org is null or not coalesce(public.is_master(), false) then
    raise exception 'close_outstanding_reminders_if_zero_bulk: master only';
  end if;

  for v_customer in
    select distinct customer_id
    from public.customer_outstanding_reminders
    where org_id = v_org and status = 'open'
  loop
    select coalesce(sum(i.total - i.amount_paid), 0) into v_outstanding
    from public.invoices i
    where i.org_id = v_org
      and i.customer_id = v_customer.customer_id
      and i.payment_status <> 'paid'
      and i.total - i.amount_paid > 0;

    if v_outstanding <= 0 then
      with closed as (
        update public.customer_outstanding_reminders
          set status = 'done', source = 'system', closed_by = null, closed_at = now(),
              close_reason = 'outstanding reached zero'
          where org_id = v_org and customer_id = v_customer.customer_id and status = 'open'
          returning 1
      )
      select count(*) into v_closed from closed;
      v_total_closed := v_total_closed + v_closed;
    end if;
  end loop;

  return v_total_closed;
end;
$function$;
revoke all on function public.close_outstanding_reminders_if_zero_bulk() from public, anon;
grant execute on function public.close_outstanding_reminders_if_zero_bulk() to authenticated;
$migration$;
  v_embedded_test              text := $testbody$-- DB test for 20261116100000_close_outstanding_reminders_bulk.sql.
-- NOT RUN standalone (written for review) -- run only through the approved
-- rehearsal wrapper. Throwaway __TEST_ organisation only.

create temp table res (n serial, line text);
grant all on res to public;
grant usage on sequence res_n_seq to public;
do $g$ begin execute format('alter default privileges in schema %s grant execute on functions to public', pg_my_temp_schema()::regnamespace); end $g$;
create function pg_temp.chk(p_name text, p_ok boolean, p_info text default '') returns void language plpgsql as $f$
begin insert into pg_temp.res(line) values (case when coalesce(p_ok,false) then 'PASS  ' else 'FAIL  ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end); end $f$;
create function pg_temp.mkuser(p_role text, p_org uuid, p_name text default null) returns uuid language plpgsql as $f$
declare v uuid := gen_random_uuid();
begin
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
  values (v, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '__t_' || p_role || '_' || v || '@test.invalid', 'x', now(), now(), now(), '{}', '{}');
  insert into public.profiles (id, org_id, full_name, role, is_active) values (v, p_org, coalesce(p_name, '__TEST_ ' || p_role), p_role::public.user_role, true)
    on conflict (id) do update set role = excluded.role, is_active = true, org_id = excluded.org_id, full_name = excluded.full_name;
  return v;
end $f$;
create function pg_temp.as_user(p_uid uuid) returns void language plpgsql as $f$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true); execute 'set local role authenticated'; end $f$;
create function pg_temp.as_anon() returns void language plpgsql as $f$
begin perform set_config('request.jwt.claims', '', true); execute 'set local role anon'; end $f$;
create function pg_temp.as_pg() returns void language plpgsql as $f$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $f$;

do $t$
declare
  v_org uuid;
  v_master uuid; v_tp uuid;
  v_cust_paid uuid; v_cust_still_owes uuid; v_cust_other_org uuid;
  v_inv1 uuid; v_inv2 uuid;
  v_rem1 public.customer_outstanding_reminders;
  v_rem2 public.customer_outstanding_reminders;
  v_closed int;
begin
  insert into organizations (name) values ('__TEST_closebulk') returning id into v_org;
  insert into settings (org_id) values (v_org) on conflict (org_id) do nothing;
  v_master := pg_temp.mkuser('master', v_org, '__TEST_ Mira Master');
  v_tp := pg_temp.mkuser('technician', v_org, '__TEST_ Tara Tech');
  insert into technicians (org_id, profile_id, is_active) values (v_org, v_tp, true);

  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ Fully Paid Now', '9400000221') returning id into v_cust_paid;
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ Still Owes', '9400000222') returning id into v_cust_still_owes;

  -- This customer's invoice is now fully paid -- its open reminder must auto-close on the bulk sweep.
  insert into invoices (org_id, customer_id, type, subtotal, gst, total, amount_paid, payment_status)
    values (v_org, v_cust_paid, 'product', 1000, 0, 1000, 1000, 'paid') returning id into v_inv1;
  -- This customer still owes money -- its open reminder must NOT close.
  insert into invoices (org_id, customer_id, type, subtotal, gst, total, amount_paid, payment_status)
    values (v_org, v_cust_still_owes, 'product', 1000, 0, 1000, 200, 'partial') returning id into v_inv2;

  perform pg_temp.as_user(v_master);
  select * into v_rem1 from public.create_customer_outstanding_reminder(v_cust_paid, now() + interval '1 day', 'test', v_inv1, 1000);
  select * into v_rem2 from public.create_customer_outstanding_reminder(v_cust_still_owes, now() + interval '1 day', 'test', v_inv2, 800);

  -- 1. The bulk sweep closes the fully-paid customer's reminder and leaves the other open.
  select public.close_outstanding_reminders_if_zero_bulk() into v_closed;
  perform pg_temp.chk('bulk sweep closes exactly 1 reminder (the fully-paid customer)', v_closed = 1, v_closed::text);
  perform pg_temp.chk('the fully-paid customer''s reminder is now done, source=system, with a close_reason',
    (select status = 'done' and source = 'system' and close_reason = 'outstanding reached zero' from public.customer_outstanding_reminders where id = v_rem1.id));
  perform pg_temp.chk('the still-owing customer''s reminder is untouched (still open)',
    (select status = 'open' from public.customer_outstanding_reminders where id = v_rem2.id));

  -- 2. Running it again is a safe no-op (nothing left open for the paid customer).
  select public.close_outstanding_reminders_if_zero_bulk() into v_closed;
  perform pg_temp.chk('re-running the sweep closes 0 (already closed, idempotent)', v_closed = 0, v_closed::text);

  -- 3. Role gating: technician and anon are both refused.
  perform pg_temp.as_user(v_tp);
  begin
    perform public.close_outstanding_reminders_if_zero_bulk();
    perform pg_temp.chk('technician is refused (expected an exception, got none)', false);
  exception when others then
    perform pg_temp.chk('technician is refused with the master-only error', sqlerrm = 'close_outstanding_reminders_if_zero_bulk: master only', sqlerrm);
  end;

  perform pg_temp.as_anon();
  begin
    perform public.close_outstanding_reminders_if_zero_bulk();
    perform pg_temp.chk('anon is refused (expected an exception, got none)', false);
  exception when others then
    perform pg_temp.chk('anon is refused (permission denied or master-only)', true, sqlerrm);
  end;

  perform pg_temp.as_pg();

  -- cleanup within the same throwaway org -- not strictly required (whole org is rolled back
  -- by the rehearsal wrapper's final RAISE) but keeps this file honest if ever run alone.
  delete from public.customer_outstanding_links where customer_id in (v_cust_paid, v_cust_still_owes);
  delete from public.customer_outstanding_reminders where customer_id in (v_cust_paid, v_cust_still_owes);

  -- Unconditional final raise (this project's hard rule: a test that can return without raising
  -- can be concatenated in front of an unapproved migration and committed live by accident -- see
  -- the 2026-10-13 "migration + test concat accident" postmortem). Never a plain RAISE NOTICE.
  raise exception E'RESULTS:%', (select string_agg(line, E'\n' order by n) from pg_temp.res);
end;
$t$;
$testbody$;
begin
  -- 0. ORG CHECK
  select md5(o.id::text || '|' || o.name) into v_actual_org_fingerprint
  from public.organizations o
  where o.name not like '\_\_TEST%' escape '\'
  order by o.created_at asc
  limit 1;

  if v_actual_org_fingerprint is distinct from v_expected_org_fingerprint then
    raise exception 'REHEARSAL_REFUSED: organisation fingerprint mismatch';
  end if;

  -- 1. LOCK
  perform set_config('lock_timeout', '5s', true);

  v_ist_hour := extract(hour from (now() at time zone 'Asia/Kolkata'))::int;

  -- 2. GATE -- 11:00 IST
  if v_ist_hour < 11 then
    raise exception 'REHEARSAL_REFUSED: this rehearsal only runs after 11:00 IST (current IST hour=%)', v_ist_hour;
  end if;

  -- 3. PIN
  v_actual_migration_hash := encode(sha256(convert_to(replace(v_embedded_migration, E'\r', ''), 'UTF8')), 'hex');
  v_actual_test_hash := encode(sha256(convert_to(replace(v_embedded_test, E'\r', ''), 'UTF8')), 'hex');

  if v_actual_migration_hash is distinct from v_expected_migration_hash then
    raise exception 'REHEARSAL_REFUSED: embedded MIGRATION text does not match its pinned sha256 (expected %, got %)',
      v_expected_migration_hash, v_actual_migration_hash;
  end if;

  if v_actual_test_hash is distinct from v_expected_test_hash then
    raise exception 'REHEARSAL_REFUSED: embedded TEST text does not match its pinned sha256 (expected %, got %)',
      v_expected_test_hash, v_actual_test_hash;
  end if;

  res := res || E'\nok   ORG CHECK passed, GATE passed: IST hour=' || v_ist_hour || E', both embedded-text sha256 hashes verified';

  -- Real-organisation fingerprint BEFORE -- every real (non __TEST_) customer_outstanding_reminders row.
  select encode(sha256(convert_to(coalesce(string_agg(x, ',' order by x), ''), 'UTF8')), 'hex') into v_fp_before
  from (
    select r.id::text || ':' || r.status::text || ':' || coalesce(r.closed_at::text, '-') as x
    from public.customer_outstanding_reminders r
    join public.organizations o on o.id = r.org_id
    where o.name not like '\_\_TEST%' escape '\'
  ) real_rows;
  res := res || E'\nINFO real-row fingerprint BEFORE = ' || v_fp_before;

  -- 4. RUN
  execute replace(v_embedded_migration, E'\r', '');
  res := res || E'\nok   migration applied inside this still-open transaction';

  begin
    execute replace(v_embedded_test, E'\r', '');
    v_inner_result := 'FAIL embedded test returned without raising -- it must always end in RAISE EXCEPTION E''RESULTS:%''';
  exception when others then
    v_inner_result := sqlerrm;
  end;
  res := res || E'\n--- embedded test output ---\n' || coalesce(v_inner_result, '(no result captured)') || E'\n--- end embedded test output ---';

  -- 5. PROVE
  select encode(sha256(convert_to(coalesce(string_agg(x, ',' order by x), ''), 'UTF8')), 'hex') into v_fp_after
  from (
    select r.id::text || ':' || r.status::text || ':' || coalesce(r.closed_at::text, '-') as x
    from public.customer_outstanding_reminders r
    join public.organizations o on o.id = r.org_id
    where o.name not like '\_\_TEST%' escape '\'
  ) real_rows;
  res := res || E'\nINFO real-row fingerprint AFTER  = ' || v_fp_after;
  res := res || E'\n' || case when v_fp_after = v_fp_before
                          then 'ok   real-organisation fingerprint unchanged -- this rehearsal mutated no real data'
                          else 'FAIL real-organisation fingerprint CHANGED -- investigate before trusting anything above' end;

  raise exception E'RESULTS:%', res;
end
$rehearsal$;
