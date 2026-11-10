-- Urgent item 4 (2026-11-02) — proves create_complaint_ticket keeps the master's picked date
-- when auto-assignment can't immediately find a free technician, instead of silently bumping
-- the appointment to the next day. The runner concatenates
-- 20261201100100_fix_complaint_appointment_silent_next_day_bump.sql in front of this block in
-- ONE transaction; the block ends in RAISE so nothing is committed. Throwaway __TEST_ org/customer.
--
-- NOT EXECUTED by this session (no DB access/authorization for this task — read-only code
-- investigation only). Run this the same way the other supabase/tests/*.test.sql files are run,
-- against the migration above, once that migration is approved and applied in a test/staging DB.
do $t$
declare
  res text := ''; v_org uuid; v_master uuid := gen_random_uuid(); v_cust uuid; v_addr uuid; v_brand uuid; v_model uuid; v_prod uuid;
  v_picked_date date := (now() at time zone 'Asia/Kolkata')::date + 3; -- a date with NO technician at all -> auto-assign will always report noneAvailable
  r1 jsonb; r2 jsonb; v_appt_date date; v_bumped boolean;
begin
  insert into organizations(name) values ('__TEST_item4_org') returning id into v_org;
  insert into settings(org_id) select v_org where not exists (select 1 from settings where org_id = v_org);
  update settings set work_start = '09:00', work_end = '18:00', narrow_window_threshold_minutes = 60 where org_id = v_org;

  insert into auth.users(id, email) values (v_master, '__test_'||v_master||'@example.invalid');
  insert into profiles(id, org_id, full_name, role) values (v_master, v_org, '__TEST_master', 'master');
  insert into customers(org_id, name, mobile) values (v_org, '__TEST_customer', '9700000099') returning id into v_cust;
  insert into addresses(org_id, customer_id) values (v_org, v_cust) returning id into v_addr;
  insert into brands(org_id, name, category) values (v_org, '__TEST_brand', 'ro') returning id into v_brand;
  insert into models(org_id, brand_id, name) values (v_org, v_brand, '__TEST_model') returning id into v_model;
  insert into products(org_id, brand_id, model_id, name, category, price) values (v_org, v_brand, v_model, '__TEST_product', 'ro', 1000) returning id into v_prod;

  perform set_config('request.jwt.claims', json_build_object('sub', v_master, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';

  -- A: deliberately ZERO technicians exist in this org, so auto-assign can never succeed —
  -- this is the exact condition that used to silently bump the appointment to v_picked_date + 1.
  begin
    r1 := create_complaint_ticket(
      v_org, v_cust, v_addr, v_prod, v_brand, v_model, '__TEST_issue A', 'n', 'normal', 'call', 'datetime',
      true, -- p_auto_assign
      v_picked_date, null, null, null, null, '[]'::jsonb
    );
    select (a.scheduled_at at time zone 'Asia/Kolkata')::date, a.next_day_priority into v_appt_date, v_bumped
    from appointments a where a.id = (r1->>'appointment_id')::uuid;

    res := res || E'\n' || case
      when v_appt_date = v_picked_date and coalesce(v_bumped, false) = false
        then 'ok   A appointment kept the master''s picked date ('||v_picked_date||') even though no technician was free'
      else 'FAIL A got scheduled_at date='||v_appt_date||' next_day_priority='||v_bumped||' (picked '||v_picked_date||') result='||r1::text
    end;
  exception when others then res := res || E'\n' || 'FAIL A '||sqlerrm; end;

  -- B: unavailable windows that fully block BOTH the picked day and the next day -> THIS is the
  -- one legitimate case the bump exists for; it should still bump, with next_day_priority = true.
  begin
    r2 := create_complaint_ticket(
      v_org, v_cust, v_addr, v_prod, v_brand, v_model, '__TEST_issue B', 'n', 'normal', 'call', 'datetime',
      false, -- p_auto_assign off, isolate the geometry bump from the assignment path
      v_picked_date, null, null, null, null, jsonb_build_array(jsonb_build_object('start', '00:00', 'end', '23:59'))
    );
    select a.next_day_priority, (a.scheduled_at at time zone 'Asia/Kolkata')::date into v_bumped, v_appt_date
    from appointments a where a.id = (r2->>'appointment_id')::uuid;

    res := res || E'\n' || case
      when coalesce(v_bumped, false) = true and v_appt_date = v_picked_date + 1
        then 'ok   B a genuinely fully-blocked day still bumps to the next day, as designed'
      else 'FAIL B next_day_priority='||v_bumped||' scheduled date='||v_appt_date
    end;
  exception when others then res := res || E'\n' || 'FAIL B '||sqlerrm; end;

  execute 'reset role';
  raise exception E'RESULTS:%', res;
end
$t$;
