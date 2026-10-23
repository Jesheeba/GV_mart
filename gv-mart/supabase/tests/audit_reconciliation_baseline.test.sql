-- Rolled-back check for 20261024100800_audit_reconciliation_baseline.sql
-- (append-only baseline, mandatory reason) and the dead-man's-switch leg
-- added in 20261024100900_audit_reconciliation_cron.sql. Run through the
-- Management API; always ends in a RAISE so nothing persists. Read the
-- RESULTS in the error.
do $t$
declare
  res text := '';
  v_org uuid; v_master uuid; v_t1 uuid; v_t1p uuid;
  v_moved boolean;
  v_baseline_diff bigint;
  v_moved_count int;
  v_row_count int;
  v_baseline_rows_before int;
  v_baseline_rows_after int;
  v_last_status text;
  v_has_run boolean;
  v_affected int;
begin
  insert into organizations (name) values ('__TEST_recon_baseline') returning id into v_org;
  insert into settings (org_id) values (v_org);
  insert into auth.users (id, aud, role, email) values (gen_random_uuid(), 'authenticated', 'authenticated', 'rb-master@test.invalid')
    returning id into v_master;
  insert into profiles (id, org_id, full_name, role) values (v_master, v_org, '__TEST_ master', 'master');
  v_t1 := gen_random_uuid();
  insert into auth.users (id, aud, role, email) values (v_t1, 'authenticated', 'authenticated', 'rb-t1@test.invalid');
  insert into profiles (id, org_id, full_name, role) values (v_t1, v_org, '__TEST_ tech1', 'technician');
  insert into technicians (org_id, profile_id) values (v_org, v_t1) returning id into v_t1p;

  perform set_config('request.jwt.claims', json_build_object('sub', v_master, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';

  -- Reason is mandatory: null and blank are both rejected.
  begin
    perform capture_audit_reconciliation_baseline(null);
    res := res || E'\n' || 'capture with null reason: SUCCEEDED (bad)';
  exception when others then
    res := res || E'\n' || 'capture with null reason: rejected ('||sqlerrm||')';
  end;
  begin
    perform capture_audit_reconciliation_baseline('   ');
    res := res || E'\n' || 'capture with blank reason: SUCCEEDED (bad)';
  exception when others then
    res := res || E'\n' || 'capture with blank reason: rejected ('||sqlerrm||')';
  end;

  -- A table with no baseline row at all (true before any capture has
  -- ever run) reports moved=true by construction.
  select moved_since_baseline into v_moved from audit_reconciliation_report() where table_name = 'warranties';
  res := res || E'\n' || format('warranties before any capture ever ran reports moved (expect true): %s', v_moved);

  select count(*) into v_baseline_rows_before from audit_reconciliation_baseline;
  select count(*) into v_row_count from capture_audit_reconciliation_baseline('first capture, test harness');
  res := res || E'\n' || format('first capture returns a row per audited table (expect >0): %s', v_row_count);

  select count(*) into v_moved_count from audit_reconciliation_report() where moved_since_baseline;
  res := res || E'\n' || format('moved_since_baseline count immediately after capture (expect 0): %s', v_moved_count);

  -- Move 'brands' away from its just-captured baseline.
  insert into brands (org_id, name, category) values (v_org, '__TEST_brand', 'ro');
  select moved_since_baseline into v_moved from audit_reconciliation_report() where table_name = 'brands';
  res := res || E'\n' || format('brands moved_since_baseline after a properly-audited insert (expect false, since diff did not change): %s', v_moved);

  -- Append-only: capturing again ADDS rows, never updates/deletes the first capture.
  perform capture_audit_reconciliation_baseline('second capture, test harness');
  select count(*) into v_baseline_rows_after from audit_reconciliation_baseline;
  res := res || E'\n' || format('baseline row count strictly grows across two captures (before=%s, after two captures=%s, expect after >= before + 2*tables): %s',
    v_baseline_rows_before, v_baseline_rows_after, v_baseline_rows_after > v_baseline_rows_before);

  -- No update or delete policy exists at all on this table. Checking
  -- rows actually affected, not just absence of an exception: a
  -- statement with no matching policy raises no error but silently
  -- touches zero rows, which looks identical to "rejected" if you only
  -- watch for an exception.
  update audit_reconciliation_baseline set reason = 'tampered' where table_name = 'brands';
  get diagnostics v_affected = row_count;
  res := res || E'\n' || format('UPDATE on a baseline row affected %s rows (expect 0)', v_affected);
  delete from audit_reconciliation_baseline where table_name = 'brands';
  get diagnostics v_affected = row_count;
  res := res || E'\n' || format('DELETE on a baseline row affected %s rows (expect 0)', v_affected);

  -- The report uses the MOST RECENT row per table, not the first.
  select baseline_difference into v_baseline_diff from audit_reconciliation_report() where table_name = 'brands';
  res := res || E'\n' || format('report reads the latest baseline row (brands baseline_difference, expect 0): %s', v_baseline_diff);

  -- Dead-man's switch: the first heartbeat was inserted by the migration
  -- itself at apply time, so it should not look stale yet, and the
  -- in-app leg (riding audit_reconciliation_report, just called above
  -- several times) should not have raised anything.
  select count(*) into v_moved_count from notifications where type = 'cron_job_stale' and org_id = v_org;
  res := res || E'\n' || format('no false cron_job_stale alert for this fresh org (expect 0): %s', v_moved_count);

  -- Force a stale heartbeat and confirm the dead-man's switch fires exactly
  -- once per cooldown. cron_job_heartbeats has no write policy for master
  -- (writes are service-role/cron-only by that table's own design), so
  -- staling it has to happen as the table owner, same as the real cron
  -- functions do it — not as the impersonated master role.
  execute 'reset role';
  update cron_job_heartbeats set last_run_at = now() - interval '30 hours', last_stale_alert_at = null where job_key = 'audit_reconciliation_daily';
  perform set_config('request.jwt.claims', json_build_object('sub', v_master, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  perform audit_reconciliation_report(); -- rides the in-app leg
  select count(*) into v_moved_count from notifications where type = 'cron_job_stale';
  res := res || E'\n' || format('cron_job_stale alert fires once heartbeat is stale (expect >=1): %s', v_moved_count);
  perform audit_reconciliation_report(); -- second call within cooldown must not double-alert
  select count(*) into v_row_count from notifications where type = 'cron_job_stale';
  res := res || E'\n' || format('second call within cooldown does not add another alert (expect same count, %s): %s', v_moved_count, v_row_count);

  -- followup_counts() also rides the audit dead-man's-switch now
  -- (same anchor the lead one already uses). Stale the lead heartbeat
  -- too and confirm one poll raises both, a second poll raises neither.
  execute 'reset role';
  update cron_job_heartbeats set last_run_at = now() - interval '30 hours', last_stale_alert_at = null
    where job_key in ('audit_reconciliation_daily', 'lead_followup_notifications');
  perform set_config('request.jwt.claims', json_build_object('sub', v_master, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select count(*) into v_row_count from notifications where type = 'cron_job_stale';
  perform followup_counts();
  select count(*) into v_moved_count from notifications where type = 'cron_job_stale';
  res := res || E'\n' || format('followup_counts() poll with both heartbeats stale raises 2 new alerts (before=%s, after=%s): %s', v_row_count, v_moved_count, v_moved_count - v_row_count);
  perform followup_counts(); -- second poll, same cooldown window, must add nothing
  select count(*) into v_row_count from notifications where type = 'cron_job_stale';
  res := res || E'\n' || format('second followup_counts() poll within cooldown adds nothing (expect %s): %s', v_moved_count, v_row_count);

  -- The cron tick itself is revoked from authenticated/anon/public
  -- entirely (pg_cron invokes it outside any RLS-bound role, same as
  -- lead_followup_cron_tick) — exercise it the same way here.
  execute 'reset role';
  perform audit_reconciliation_cron_tick();
  perform set_config('request.jwt.claims', json_build_object('sub', v_master, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select last_status, last_run_at is not null into v_last_status, v_has_run from cron_job_heartbeats where job_key = 'audit_reconciliation_daily';
  res := res || E'\n' || format('audit_reconciliation_cron_tick heartbeat after a healthy run: status=%s has_run=%s', v_last_status, v_has_run);

  -- Non-master cannot capture, read the report, or run the cron functions directly.
  execute 'reset role';
  perform set_config('request.jwt.claims', json_build_object('sub', v_t1, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    perform capture_audit_reconciliation_baseline('attempt');
    res := res || E'\n' || 'capture as technician: SUCCEEDED (bad)';
  exception when others then
    res := res || E'\n' || 'capture as technician: rejected ('||sqlerrm||')';
  end;
  begin
    perform audit_reconciliation_report();
    res := res || E'\n' || 'report as technician: SUCCEEDED (bad)';
  exception when others then
    res := res || E'\n' || 'report as technician: rejected ('||sqlerrm||')';
  end;
  begin
    perform audit_reconciliation_cron_tick();
    res := res || E'\n' || 'cron tick as technician: SUCCEEDED (bad, should be revoked from authenticated entirely)';
  exception when others then
    res := res || E'\n' || 'cron tick as technician: rejected ('||sqlerrm||')';
  end;

  execute 'reset role';
  raise exception E'RESULTS%', res;
end $t$;
