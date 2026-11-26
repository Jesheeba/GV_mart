-- Rolled-back DB tests for 20261216100000_customer_water_household_v2 + 20261216110000_water_solution_followup
-- + 20261216120000_primary_member_sync.
-- Runs AFTER customer_water_household_v2.fixtures.sql and both migrations, in one transaction ending in RAISE: read
-- RESULTS in the error. Test names map to the acceptance criteria / edge cases in
-- build-docs/features/customer-water-household.md (WH-*) and water-solution-followup.md (FU-*).
do $t$
declare
  v_org uuid := pg_temp.fx('org');
  v_master uuid := pg_temp.fx('master'); v_master_late uuid := pg_temp.fx('master_late');
  v_sales uuid := pg_temp.fx('sales'); v_sales2 uuid := pg_temp.fx('sales2'); v_op uuid := pg_temp.fx('opadmin');
  v_tech uuid := pg_temp.fx('tech'); v_custp uuid := pg_temp.fx('custp'); v_other_master uuid := pg_temp.fx('other_master');
  v_fu uuid := pg_temp.fx('c_fu');
  r record; b boolean; txt text; st text; n bigint;
  v_task uuid; v_task2 uuid; v_lead uuid; v_lead_other uuid;
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
begin
  -- ══ WH: schema ══════════════════════════════════════════════════════════════════════════════════════════════
  perform pg_temp.chk('WH-drop: addresses water columns are gone',
    not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'addresses' and column_name in ('water_source', 'water_tds', 'water_ph', 'health_condition')));
  perform pg_temp.chk('WH-drop: customer_health_profile table is gone', to_regclass('public.customer_health_profile') is null);
  perform pg_temp.chk('WH-drop: household_health_level type is gone', not exists (select 1 from pg_type where typname = 'household_health_level'));
  perform pg_temp.chk('WH-drop: get_customer_health_condition is gone', not exists (select 1 from pg_proc where proname = 'get_customer_health_condition'));
  perform pg_temp.chk('WH-drop: stamp_customer_health_profile is gone', not exists (select 1 from pg_proc where proname = 'stamp_customer_health_profile'));
  perform pg_temp.chk('WH-drop: settings.show_health_condition_to_technicians is gone',
    not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'settings' and column_name = 'show_health_condition_to_technicians'));

  -- ══ WH: backfill ════════════════════════════════════════════════════════════════════════════════════════════
  select * into r from customers where id = pg_temp.fx('c_corp');
  perform pg_temp.chk('WH-backfill: "  Corporation " maps to corporation, TDS/pH copied', r.water_source = 'corporation' and r.water_source_other is null and r.water_tds_ppm = 300 and r.water_ph = 7.2,
    format('%s/%s/%s', r.water_source, r.water_tds_ppm, r.water_ph));
  perform pg_temp.chk('WH-backfill: address health text carried into problems faced', r.household_problems = array['Kidney stones']);
  select * into r from customers where id = pg_temp.fx('c_bore');
  perform pg_temp.chk('WH-backfill: "Bore well" maps to borewater', r.water_source = 'borewater' and r.water_source_other is null);
  select * into r from customers where id = pg_temp.fx('c_lake');
  perform pg_temp.chk('WH-backfill: unknown text maps to other + its text', r.water_source = 'other' and r.water_source_other = 'Lake water');
  perform pg_temp.chk('WH-backfill: blank health text gives an empty problems list', r.household_problems = '{}'::text[]);
  select * into r from customers where id = pg_temp.fx('c_keep');
  perform pg_temp.chk('WH-backfill: existing customer values are never overwritten', r.water_source = 'corporation' and r.water_source_other is null and r.water_tds_ppm = 100,
    format('%s/%s', r.water_source, r.water_tds_ppm));
  perform pg_temp.chk('WH-backfill: empty customer fields still filled from the address (pH)', r.water_ph = 6.5);
  select * into r from customers where id = pg_temp.fx('c_range');
  perform pg_temp.chk('WH-backfill: out-of-range TDS/pH skipped, not fatal', r.water_tds_ppm is null and r.water_ph is null);
  select * into r from customers where id = pg_temp.fx('c_primary');
  perform pg_temp.chk('WH-backfill: the primary address is the one used', r.water_tds_ppm = 50, coalesce(r.water_tds_ppm::text, 'null'));

  -- real organisations: only water/problem columns may differ, and only on customers that had address water data
  select count(*) into n
  from real_before b0 join public.customers c on c.id = b0.id
  where (to_jsonb(c) - array['water_source', 'water_source_other', 'water_tds_ppm', 'water_ph', 'water_hardness_ppm', 'household_problems', 'water_recommended_solution', 'updated_at'])
        is distinct from (b0.j - array['water_source', 'water_source_other', 'water_tds_ppm', 'water_ph', 'updated_at']);
  -- name WHICH columns moved, and whether each was blank before (the only intended non-water change is
  -- 20261216120000's blank-profession fill)
  select string_agg(distinct k.key || case when nullif(btrim(b0.j ->> k.key), '') is null then '(was blank)' else '(had value)' end, ', ')
  into txt
  from real_before b0 join public.customers c on c.id = b0.id
  cross join lateral jsonb_each(to_jsonb(c)) k
  where k.key not in ('water_source', 'water_source_other', 'water_tds_ppm', 'water_ph', 'water_hardness_ppm', 'household_problems', 'water_recommended_solution', 'updated_at')
    and k.value is distinct from (b0.j -> k.key);
  perform pg_temp.chk('WH-backfill: real customers: only blank professions were filled, nothing else changed',
    n = 0 or txt = 'profession(was blank)', format('%s rows; %s', n, coalesce(txt, 'none')));
  select count(*) into n from real_before b0 join public.customers c on c.id = b0.id
  where (to_jsonb(c) ->> 'water_source') is distinct from (b0.j ->> 'water_source')
     or (to_jsonb(c) ->> 'water_tds_ppm') is distinct from (b0.j ->> 'water_tds_ppm')
     or (to_jsonb(c) ->> 'water_ph') is distinct from (b0.j ->> 'water_ph')
     or cardinality(c.household_problems) > 0;
  perform pg_temp.chk('WH-backfill: at most 2 real customers gained water values (2 live addresses had data)', n <= 2, n::text);
  perform pg_temp.chk('WH-backfill: real customer count unchanged',
    (select count(*) from public.customers c where c.org_id not in (v_org, pg_temp.fx('org2'))) = (select count(*) from real_before));

  -- ══ WH: new columns + checks ═════════════════════════════════════════════════════════════════════════════════
  perform pg_temp.as_user(v_sales);
  update customers set water_hardness_ppm = 350, household_problems = array['Hair fall', 'White stains on taps'] where id = v_fu;
  perform pg_temp.chk('WH-save: sales_admin saves hardness + problems',
    (select water_hardness_ppm = 350 and household_problems = array['Hair fall', 'White stains on taps'] from customers where id = v_fu));
  begin update customers set water_hardness_ppm = -1 where id = v_fu; st := 'ok'; exception when others then st := sqlstate; end;
  perform pg_temp.chk('WH-check: negative hardness refused', st = '23514', st);
  begin update customers set household_problems = array['a','b','c','d','e','f','g','h','i','j','k'] where id = v_fu; st := 'ok'; exception when others then st := sqlstate; end;
  perform pg_temp.chk('WH-check: 11 problems refused (cap 10)', st = '23514', st);
  begin update customers set household_problems = array['a','b','c','d','e','f','g','h','i','j'] where id = v_fu; st := 'ok'; exception when others then st := sqlstate; end;
  perform pg_temp.chk('WH-check: exactly 10 problems accepted', st = 'ok', st);
  begin update customers set household_problems = array['ok', ''] where id = v_fu; st := 'ok'; exception when others then st := sqlstate; end;
  perform pg_temp.chk('WH-check: blank problem refused', st = '23514', st);
  begin update customers set household_problems = array['ok', null] where id = v_fu; st := 'ok'; exception when others then st := sqlstate; end;
  perform pg_temp.chk('WH-check: null problem refused', st = '23514', st);
  begin update customers set household_problems = null where id = v_fu; st := 'ok'; exception when others then st := sqlstate; end;
  perform pg_temp.chk('WH-check: null list refused (empty list instead)', st = '23502', st);
  update customers set household_problems = array['Hair fall', 'White stains on taps'] where id = v_fu;
  perform pg_temp.as_pg();

  -- guard: operation_admin may edit the new water columns but nothing else; the customer may not edit them
  perform pg_temp.as_user(v_op);
  begin update customers set water_hardness_ppm = 360, water_recommended_solution = 'Softener' where id = v_fu; st := 'ok'; exception when others then st := sqlstate || ' ' || sqlerrm; end;
  perform pg_temp.chk('WH-guard: operation_admin may edit hardness + solution', st = 'ok', st);
  begin update customers set name = '__TEST_ renamed' where id = v_fu; st := 'ok'; exception when others then st := 'refused'; end;
  perform pg_temp.chk('WH-guard: operation_admin still may not edit other columns', st = 'refused', st);
  perform pg_temp.as_pg();
  perform pg_temp.as_user(v_custp);
  begin update customers set household_problems = array['self-edit'] where id = v_fu; get diagnostics n = row_count; st := 'rows=' || n; exception when others then st := 'refused'; end;
  perform pg_temp.chk('WH-guard: the customer cannot edit problems faced', st in ('refused', 'rows=0'), st);
  perform pg_temp.chk('WH-read: the customer can read their own hardness/problems/solution',
    (select water_hardness_ppm = 360 and cardinality(household_problems) = 2 and water_recommended_solution = 'Softener' from customers where id = v_fu));
  perform pg_temp.as_pg();
  perform pg_temp.as_user(v_sales);
  begin update customers set water_recommended_solution = repeat('x', 501) where id = v_fu; st := 'ok'; exception when others then st := sqlstate; end;
  perform pg_temp.chk('FU-check: solution over 500 characters refused', st = '23514', st);
  begin update customers set water_recommended_solution = '   ' where id = v_fu; st := 'ok'; exception when others then st := sqlstate; end;
  perform pg_temp.chk('FU-check: blank solution refused (client sends null)', st = '23514', st);
  perform pg_temp.as_pg();

  -- ══ FU: set / move / clear ═══════════════════════════════════════════════════════════════════════════════════
  perform pg_temp.as_user(v_sales);
  v_task := public.set_customer_water_followup(v_fu, v_today + 3);
  perform pg_temp.as_pg();
  select * into r from tasks where id = v_task;
  perform pg_temp.chk('FU-1: one open task, due on the chosen date', r.status = 'open' and r.due_date = v_today + 3 and r.ref_type = 'customer_water_followup' and r.ref_id = v_fu and r.source = 'system');
  perform pg_temp.chk('FU-1: assigned to the OLDEST active master, assigned_by = the caller', r.assignee_id = v_master and r.assigned_by = v_sales,
    format('assignee=%s', r.assignee_id));
  perform pg_temp.chk('FU-1: title names the customer', r.title = 'Water follow-up: __TEST_ wv2 followup', r.title);
  perform pg_temp.chk('FU-1: description carries problems, hardness and solution',
    r.description like '%Problems faced: Hair fall, White stains on taps%' and r.description like '%Total hardness: 360%' and r.description like '%Recommended solution: Softener%', r.description);
  perform pg_temp.chk('FU-1: the master got a task_assigned notification',
    exists (select 1 from notifications where user_id = v_master and type = 'task_assigned' and ref_id = v_task));

  perform pg_temp.as_user(v_sales);
  select count(*) into n from public.get_customer_water_followup(v_fu) g where g.task_id = v_task and g.due_date = v_today + 3;
  perform pg_temp.chk('FU-read: sales_admin reads the open follow-up through the RPC', n = 1);
  v_task2 := public.set_customer_water_followup(v_fu, v_today + 5);
  perform pg_temp.chk('FU-2: changing the date moves the SAME task', v_task2 = v_task);
  perform pg_temp.as_pg();
  perform pg_temp.chk('FU-2: task due moved + due_moved logged',
    (select due_date from tasks where id = v_task) = v_today + 5
    and exists (select 1 from task_logs where task_id = v_task and kind = 'due_moved' and to_value = (v_today + 5)::text));
  perform pg_temp.chk('FU-2: still exactly one open follow-up task',
    (select count(*) from tasks where ref_type = 'customer_water_followup' and ref_id = v_fu and status = 'open') = 1);

  perform pg_temp.as_user(v_sales);
  perform public.set_customer_water_followup(v_fu, v_today + 5);
  perform pg_temp.chk('FU-2: re-saving the same date is a no-op success', (select due_date from tasks where id = v_task) = v_today + 5);
  begin perform public.set_customer_water_followup(v_fu, v_today - 1); st := 'ok'; exception when others then st := sqlstate; end;
  perform pg_temp.chk('FU-edge: a past date is refused', st = '22023', st);
  perform pg_temp.chk('FU-edge: today is allowed (boundary)', public.set_customer_water_followup(v_fu, v_today) = v_task);
  perform public.set_customer_water_followup(v_fu, v_today + 5);
  perform pg_temp.as_pg();

  -- an overdue task re-saved with its own (past) date must not fail
  update tasks set due_date = v_today - 2 where id = v_task;
  perform pg_temp.as_user(v_sales);
  begin perform public.set_customer_water_followup(v_fu, v_today - 2); st := 'ok'; exception when others then st := sqlstate; end;
  perform pg_temp.chk('FU-edge: re-saving an already-overdue date succeeds', st = 'ok', st);
  perform public.set_customer_water_followup(v_fu, v_today + 5);
  perform pg_temp.as_pg();

  -- who may call it
  perform pg_temp.as_user(v_tech);
  begin perform public.set_customer_water_followup(v_fu, v_today + 9); st := 'ok'; exception when others then st := sqlstate; end;
  perform pg_temp.chk('FU-sec: a technician may not set a follow-up', st = '42501', st);
  select count(*) into n from public.get_customer_water_followup(v_fu);
  perform pg_temp.chk('FU-sec: a technician reads nothing through the RPC', n = 0);
  perform pg_temp.as_pg();
  perform pg_temp.as_user(v_custp);
  begin perform public.set_customer_water_followup(v_fu, v_today + 9); st := 'ok'; exception when others then st := sqlstate; end;
  perform pg_temp.chk('FU-sec: the customer may not set a follow-up', st = '42501', st);
  perform pg_temp.as_pg();
  perform pg_temp.as_user(v_other_master);
  begin perform public.set_customer_water_followup(v_fu, v_today + 9); st := 'ok'; exception when others then st := sqlstate; end;
  perform pg_temp.chk('FU-sec: another organisation''s master cannot touch this customer', st = 'P0002', st);
  select count(*) into n from public.get_customer_water_followup(v_fu);
  perform pg_temp.chk('FU-sec: another organisation reads nothing', n = 0);
  perform pg_temp.as_pg();
  begin perform public.set_customer_water_followup(v_fu, v_today + 9); st := 'ok'; exception when others then st := sqlstate; end;
  perform pg_temp.chk('FU-sec: no signed-in user is refused', st = '42501', st);
  perform pg_temp.chk('FU-sec: anon has no EXECUTE on the follow-up RPCs',
    not has_function_privilege('anon', 'public.set_customer_water_followup(uuid, date)', 'execute')
    and not has_function_privilege('anon', 'public.postpone_water_followup(uuid, date, text)', 'execute')
    and not has_function_privilege('anon', 'public.close_water_followup_as_lead(uuid, uuid)', 'execute')
    and not has_function_privilege('anon', 'public.get_customer_water_followup(uuid)', 'execute')
    and not has_function_privilege('authenticated', 'public.notify_due_water_followups()', 'execute'));

  -- concurrency backstop: a second open task for the same customer is impossible
  begin
    insert into tasks (org_id, assignee_id, title, source, ref_type, ref_id, status) values (v_org, v_master, 'dup', 'system', 'customer_water_followup', v_fu, 'open');
    st := 'ok';
  exception when others then st := sqlstate; end;
  perform pg_temp.chk('FU-edge: unique index blocks a second open follow-up task', st = '23505', st);

  -- ══ FU: postpone ══════════════════════════════════════════════════════════════════════════════════════════
  perform pg_temp.as_user(v_master);
  begin perform public.postpone_water_followup(v_task, v_today + 8, '  '); st := 'ok'; exception when others then st := sqlstate; end;
  perform pg_temp.chk('FU-5: postpone without a reason is refused', st = '22023', st);
  begin perform public.postpone_water_followup(v_task, v_today + 4, 'Customer travelling'); st := 'ok'; exception when others then st := sqlstate; end;
  perform pg_temp.chk('FU-5: postpone to an EARLIER date is refused', st = '22023', st);
  begin perform public.postpone_water_followup(v_task, v_today + 5, 'Customer travelling'); st := 'ok'; exception when others then st := sqlstate; end;
  perform pg_temp.chk('FU-5: postpone to the SAME date is refused', st = '22023', st);
  begin perform public.postpone_water_followup(v_task, v_today + 8, repeat('r', 501)); st := 'ok'; exception when others then st := sqlstate; end;
  perform pg_temp.chk('FU-5: reason over 500 characters refused', st = '22023', st);
  perform public.postpone_water_followup(v_task, v_today + 8, ' Customer travelling ');
  perform pg_temp.as_pg();
  perform pg_temp.chk('FU-2: postpone moves the due date', (select due_date from tasks where id = v_task) = v_today + 8);
  perform pg_temp.chk('FU-2: postpone reason logged as a note with the new date',
    exists (select 1 from task_logs where task_id = v_task and kind = 'note' and note = 'Postponed: Customer travelling' and next_planned_date = v_today + 8));
  perform pg_temp.as_user(v_sales);
  select count(*) into n from public.get_customer_water_followup(v_fu) g where g.due_date = v_today + 8;
  perform pg_temp.chk('FU-2: the customer side sees the postponed date', n = 1);
  perform pg_temp.as_pg();
  perform pg_temp.as_user(v_sales2);
  begin perform public.postpone_water_followup(v_task, v_today + 9, 'not mine'); st := 'ok'; exception when others then st := sqlstate; end;
  perform pg_temp.chk('FU-sec: a sales_admin who neither created nor owns the task cannot postpone it', st = '42501', st);
  perform pg_temp.as_pg();
  perform pg_temp.as_user(v_sales);
  begin perform public.postpone_water_followup(v_task, v_today + 9, 'creator may'); st := 'ok'; exception when others then st := sqlstate; end;
  perform pg_temp.chk('FU-sec: the sales_admin who set it may postpone it', st = 'ok', st);
  perform pg_temp.as_pg();

  -- ══ FU: daily reminder ══════════════════════════════════════════════════════════════════════════════════════
  update tasks set due_date = v_today where id = v_task;
  n := public.notify_due_water_followups();
  perform pg_temp.chk('FU-remind: one reminder for a task due today', n >= 1 and exists (select 1 from notifications where type = 'water_followup_due' and ref_id = v_task and user_id = v_master));
  perform public.notify_due_water_followups();
  perform pg_temp.chk('FU-remind: running again the same day does not repeat it',
    (select count(*) from notifications where type = 'water_followup_due' and ref_id = v_task) = 1);
  update tasks set due_date = v_today + 9 where id = v_task;
  perform pg_temp.chk('FU-remind: the cron job is scheduled at 03:30 UTC (09:00 IST)',
    exists (select 1 from cron.job where jobname = 'water-followup-due' and schedule = '30 3 * * *'));

  -- ══ FU: convert to lead ═════════════════════════════════════════════════════════════════════════════════════
  insert into leads (org_id, customer_id, name, mobile, source, status) values (v_org, pg_temp.fx('c_other'), '__TEST_ wrong lead', '9000000408', 'field', 'new') returning id into v_lead_other;
  insert into leads (org_id, customer_id, name, mobile, source, status) values (v_org, v_fu, '__TEST_ wv2 lead', '9000000407', 'field', 'new') returning id into v_lead;
  perform pg_temp.as_user(v_master);
  begin perform public.close_water_followup_as_lead(v_task, v_lead_other); st := 'ok'; exception when others then st := sqlstate; end;
  perform pg_temp.chk('FU-4: a lead for a different customer is refused', st = '22023', st);
  perform public.close_water_followup_as_lead(v_task, v_lead);
  perform pg_temp.as_pg();
  perform pg_temp.chk('FU-4: converting closes the task and logs the lead',
    (select status from tasks where id = v_task) = 'done'
    and exists (select 1 from task_logs where task_id = v_task and note = 'Converted to lead ' || v_lead::text));
  perform pg_temp.as_user(v_master);
  begin perform public.close_water_followup_as_lead(v_task, v_lead); st := 'ok'; exception when others then st := sqlstate; end;
  perform pg_temp.chk('FU-edge: converting again to the same lead is a no-op', st = 'ok', st);
  begin perform public.close_water_followup_as_lead(v_task, v_lead_other); st := 'ok'; exception when others then st := sqlstate; end;
  perform pg_temp.chk('FU-edge: a closed task cannot be converted to another lead', st = '22023', st);
  begin perform public.postpone_water_followup(v_task, v_today + 20, 'too late'); st := 'ok'; exception when others then st := sqlstate; end;
  perform pg_temp.chk('FU-edge: a closed task cannot be postponed', st = '22023', st);
  perform pg_temp.as_pg();

  perform pg_temp.as_user(v_sales);
  select count(*) into n from public.get_customer_water_followup(v_fu);
  perform pg_temp.chk('FU-edge: after conversion the customer shows no open follow-up', n = 0);
  v_task2 := public.set_customer_water_followup(v_fu, v_today + 30);
  perform pg_temp.chk('FU-edge: a new date after closing creates a FRESH task', v_task2 is not null and v_task2 <> v_task);
  -- FU-3: clearing the date closes the open task
  perform pg_temp.chk('FU-3: clearing returns null', public.set_customer_water_followup(v_fu, null) is null);
  perform pg_temp.as_pg();
  perform pg_temp.chk('FU-3: clearing the date closes the task with a note',
    (select status from tasks where id = v_task2) = 'done'
    and exists (select 1 from task_logs where task_id = v_task2 and note = 'Follow-up date cleared on the customer profile'));
  perform pg_temp.as_user(v_sales);
  perform pg_temp.chk('FU-3: clearing again with nothing open is a no-op', public.set_customer_water_followup(v_fu, null) is null);
  perform pg_temp.as_pg();

  -- no active master: the task falls back to the caller instead of being orphaned
  update profiles set is_active = false where id in (v_master, v_master_late);
  perform pg_temp.as_user(v_sales);
  v_task2 := public.set_customer_water_followup(pg_temp.fx('c_other'), v_today + 2);
  perform pg_temp.as_pg();
  perform pg_temp.chk('FU-edge: with no active master the caller gets the task', (select assignee_id from tasks where id = v_task2) = v_sales);
  update profiles set is_active = true where id in (v_master, v_master_late);

  -- empty profile: description is null rather than an empty string
  perform pg_temp.as_user(v_sales);
  v_task2 := public.set_customer_water_followup(pg_temp.fx('c_bore'), v_today + 2);
  perform pg_temp.as_pg();
  select description into txt from tasks where id = v_task2;
  perform pg_temp.chk('FU-edge: a profile with no problems/solution gives a null description', txt is null, coalesce(txt, 'null'));

  -- ══ SYNC: primary member <-> customer row (20261216120000) ══════════════════════════════════════════════
  perform pg_temp.chk('SYNC-backfill: blank member email filled from the account email',
    (select email from customer_members where id = pg_temp.fx('m_sync')) = 'sync.a@test.invalid');
  perform pg_temp.chk('SYNC-backfill: blank customer profession filled from the primary member',
    (select profession from customers where id = pg_temp.fx('c_sync')) = 'Teacher');
  perform pg_temp.chk('SYNC-backfill: account email is NOT filled from a member email (sign-in matching stays opt-in)',
    (select email from customers where id = pg_temp.fx('c_sync2')) is null);

  perform pg_temp.as_user(v_sales);
  update customer_members set name = '__TEST_ sync A renamed', mobile = '9000000499', email = 'New.Mail@Test.Invalid' where id = pg_temp.fx('m_sync');
  perform pg_temp.as_pg();
  select * into r from customers where id = pg_temp.fx('c_sync');
  perform pg_temp.chk('SYNC-1: staff editing the primary member updates the customer name + mobile',
    r.name = '__TEST_ sync A renamed' and r.mobile = '9000000499', format('%s / %s', r.name, r.mobile));
  perform pg_temp.chk('SYNC-4: ... and the account email (normalised to lower case)', r.email = 'new.mail@test.invalid', coalesce(r.email, 'null'));

  perform pg_temp.as_user(v_sales);
  update customer_members set name = '__TEST_ kid renamed' where id = pg_temp.fx('m_sync_kid');
  perform pg_temp.as_pg();
  perform pg_temp.chk('SYNC-edge: a non-primary member edit never touches the customer row',
    (select name from customers where id = pg_temp.fx('c_sync')) = '__TEST_ sync A renamed');

  -- customer row -> primary member, only the changed column
  perform pg_temp.as_user(v_sales);
  update customers set profession = 'Engineer' where id = pg_temp.fx('c_sync2');
  perform pg_temp.as_pg();
  select * into r from customer_members where id = pg_temp.fx('m_sync2');
  perform pg_temp.chk('SYNC-6: a profession edited on the customer row reaches the primary member', r.profession = 'Engineer', coalesce(r.profession, 'null'));
  perform pg_temp.chk('SYNC-edge: an unrelated customer edit never blanks the member''s email (account email is null)', r.email = 'member.b@test.invalid', coalesce(r.email, 'null'));

  -- the customer editing their own family row: name/profession move, mobile/email do not
  perform pg_temp.as_user(pg_temp.fx('custp2'));
  update customer_members set name = '__TEST_ self renamed', mobile = '9000000498' where id = pg_temp.fx('m_self');
  perform pg_temp.as_pg();
  select * into r from customers where id = pg_temp.fx('c_self');
  perform pg_temp.chk('SYNC-sec: the customer''s own member edit moves the name onto the account', r.name = '__TEST_ self renamed', r.name);
  perform pg_temp.chk('SYNC-sec: ... but never the account mobile (sign-in matching)', r.mobile = '9000000413', r.mobile);
  perform pg_temp.as_user(pg_temp.fx('custp2'));
  update customers set profession = 'Doctor' where id = pg_temp.fx('c_self');
  perform pg_temp.as_pg();
  perform pg_temp.chk('SYNC-6: a profession set in the customer app reaches the primary member',
    (select profession from customer_members where id = pg_temp.fx('m_self')) = 'Doctor');

  -- ══ ADDR: customer-app address text edit clears stale street-level parts ════════════════════════════════
  perform pg_temp.as_user(pg_temp.fx('custp2'));
  update addresses set lat = 13.08, lng = 80.27 where id = pg_temp.fx('a_self');
  perform pg_temp.as_pg();
  perform pg_temp.chk('ADDR-edge: a pin-only customer edit keeps the admin''s street-level parts',
    (select door_no = '12A' and street_cross = '2nd Cross' from addresses where id = pg_temp.fx('a_self')));
  perform pg_temp.as_user(pg_temp.fx('custp2'));
  update addresses set full_address = '45, New Street, Anna Nagar', area = 'Anna Nagar' where id = pg_temp.fx('a_self');
  perform pg_temp.as_pg();
  select * into r from addresses where id = pg_temp.fx('a_self');
  perform pg_temp.chk('ADDR-2: the customer changing the address text clears the stale parts and keeps their text',
    r.door_no is null and r.street_cross is null and r.full_address = '45, New Street, Anna Nagar' and r.area = 'Anna Nagar');
  perform pg_temp.as_user(v_sales);
  update addresses set door_no = '7', full_address = '7, Anna Nagar' where id = pg_temp.fx('a_self');
  update addresses set full_address = '7, Main Road, Anna Nagar' where id = pg_temp.fx('a_self');
  perform pg_temp.as_pg();
  perform pg_temp.chk('ADDR-edge: a staff edit of the address text never clears the parts',
    (select door_no from addresses where id = pg_temp.fx('a_self')) = '7');

  select string_agg(r2.line, E'\n' order by r2.n) into txt from pg_temp.res r2;
  raise exception E'RESULTS (% pass / % fail)\n%',
    (select count(*) from pg_temp.res where line like 'PASS%'), (select count(*) from pg_temp.res where line like 'FAIL%'), txt;
end $t$;
