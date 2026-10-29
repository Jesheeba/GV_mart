-- Product Lifecycle & Automated Service Reminder System — Drop 1, migration 5/8.
-- `settings` is one typed-column-per-org row here (not jsonb), per
-- 20260701091100_system.sql's own header comment — so reminder stage
-- offsets are plain admin-editable columns, same convention as
-- amc_book_window_days.

alter table public.settings
  add column lifecycle_reminder_days_before integer[] not null default '{14,7}',
  add column lifecycle_overdue_days integer[] not null default '{3,7}';

-- ── generate_lifecycle_reminders ────────────────────────────────────────
-- Daily pg_cron job body (in-DB only — no outbound HTTP/WhatsApp in scope,
-- so pg_cron is used directly, same as lead-followup-notifications and
-- amc-assign-due-visits, rather than the GitHub-Actions path reserved for
-- anything that sends outbound messages).
create or replace function public.generate_lifecycle_reminders(p_now timestamptz default now())
returns integer
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_org record;
  v_today date;
  v_row record;
  v_days_before integer[];
  v_overdue_days integer[];
  v_days_out integer;
  v_stage text;
  v_created integer := 0;
begin
  for v_org in select id from public.organizations loop
    v_today := (p_now at time zone 'Asia/Kolkata')::date;

    select lifecycle_reminder_days_before, lifecycle_overdue_days
      into v_days_before, v_overdue_days
      from public.settings where org_id = v_org.id;

    -- Recompute status on every active schedule for this org first.
    update public.customer_part_schedules cps
    set status = case
      when cps.last_replaced_date is not null and cps.next_due_date > v_today
           and cps.next_due_date - v_today > coalesce(v_days_before[1], 14) then 'pending'
      when cps.next_due_date < v_today then 'overdue'
      when cps.next_due_date = v_today then 'due'
      when cps.next_due_date - v_today <= coalesce(v_days_before[1], 14) then 'due_soon'
      else 'pending'
    end
    where cps.org_id = v_org.id and cps.status <> 'replaced_na';

    -- Part-replacement reminders: customer + technician-visible (via
    -- notification to the org's ops/master/sales roles) + dedup on
    -- (schedule_id, due_date, stage).
    for v_row in
      select cps.*, cip.customer_id, cip.is_backfilled, p.full_name as product_name
      from public.customer_part_schedules cps
      join public.customer_installed_products cip on cip.id = cps.installed_product_id
      join public.products p on p.id = cip.product_id
      where cps.org_id = v_org.id
        and cps.status <> 'replaced_na'
        and not public.is_test_customer(cip.customer_id)
    loop
      v_days_out := v_row.next_due_date - v_today;

      if v_row.is_backfilled then
        -- Flood prevention (DECISIONS.md #1): a backfilled installed
        -- product that has never had any reminder at all gets exactly ONE
        -- consolidated notice, regardless of how overdue it already is.
        if v_days_out <= 0 and not exists (
          select 1 from public.lifecycle_reminder_events e
          where e.customer_part_schedule_id = v_row.id
        ) then
          insert into public.lifecycle_reminder_events (org_id, customer_part_schedule_id, due_date, stage)
          values (v_org.id, v_row.id, v_row.next_due_date, 'backfill_consolidated')
          on conflict do nothing;
          if found then
            insert into public.notifications (org_id, user_id, type, title, body, ref_id)
            select v_org.id, c.primary_profile_id, 'lifecycle_part_due',
                   'Service part may be due',
                   v_row.product_name || ': ' || v_row.label || ' may be due for replacement — please confirm at next visit.',
                   v_row.installed_product_id
            from public.customers c where c.id = v_row.customer_id and c.primary_profile_id is not null;
            v_created := v_created + 1;
          end if;
        end if;
        continue;
      end if;

      v_stage := case
        when v_days_out = coalesce(v_days_before[1], 14) then 't_minus_14'
        when v_days_out = coalesce(v_days_before[2], 7) then 't_minus_7'
        when v_days_out = 0 then 'due'
        when v_days_out = -coalesce(v_overdue_days[1], 3) then 'overdue_3'
        when v_days_out = -coalesce(v_overdue_days[2], 7) then 'overdue_7'
        else null
      end;
      if v_stage is null then
        continue;
      end if;

      insert into public.lifecycle_reminder_events (org_id, customer_part_schedule_id, due_date, stage)
      values (v_org.id, v_row.id, v_row.next_due_date, v_stage)
      on conflict do nothing;
      if found then
        insert into public.notifications (org_id, user_id, type, title, body, ref_id)
        select v_org.id, c.primary_profile_id, 'lifecycle_part_due',
               case when v_stage like 'overdue%' then 'Service part overdue' else 'Service part due soon' end,
               v_row.product_name || ': ' || v_row.label ||
               case when v_days_out > 0 then ' due in ' || v_days_out || ' day(s).'
                    when v_days_out = 0 then ' due today.'
                    else ' overdue by ' || abs(v_days_out) || ' day(s).' end,
               v_row.installed_product_id
        from public.customers c where c.id = v_row.customer_id and c.primary_profile_id is not null;

        insert into public.notifications (org_id, role, type, title, body, ref_id)
        values (v_org.id, 'operation_admin', 'lifecycle_part_due',
                case when v_stage like 'overdue%' then 'Service part overdue' else 'Service part due soon' end,
                v_row.product_name || ': ' || v_row.label || ' for one customer', v_row.installed_product_id);

        v_created := v_created + 1;
      end if;
    end loop;

    -- Lifetime-expiry reminders, same dedupe shape, separate ledger.
    for v_row in
      select cip.*, p.full_name as product_name
      from public.customer_installed_products cip
      join public.products p on p.id = cip.product_id
      where cip.org_id = v_org.id
        and cip.status = 'active'
        and cip.lifetime_expiry_date is not null
        and not public.is_test_customer(cip.customer_id)
    loop
      v_days_out := v_row.lifetime_expiry_date - v_today;
      v_stage := case
        when v_days_out = coalesce(v_days_before[1], 14) then 't_minus_14'
        when v_days_out = coalesce(v_days_before[2], 7) then 't_minus_7'
        when v_days_out = 0 then 'due'
        when v_days_out = -coalesce(v_overdue_days[1], 3) then 'overdue_3'
        when v_days_out = -coalesce(v_overdue_days[2], 7) then 'overdue_7'
        else null
      end;
      if v_stage is null then
        continue;
      end if;

      insert into public.lifecycle_expiry_reminder_events (org_id, installed_product_id, due_date, stage)
      values (v_org.id, v_row.id, v_row.lifetime_expiry_date, v_stage)
      on conflict do nothing;
      if found then
        insert into public.notifications (org_id, role, type, title, body, ref_id)
        values (v_org.id, 'master', 'lifecycle_product_expiry',
                'Product lifetime expiring', v_row.product_name || ' nearing end of lifetime.', v_row.id);
        v_created := v_created + 1;
      end if;
    end loop;
  end loop;

  return v_created;
end;
$$;

revoke all on function public.generate_lifecycle_reminders(timestamptz) from public, anon;
grant execute on function public.generate_lifecycle_reminders(timestamptz) to service_role;

-- Heartbeat wrapper, same shape as amc_assign_cron_tick (20261022100000).
create or replace function public.lifecycle_reminders_cron_tick(p_job_key text default 'generate_lifecycle_reminders')
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  begin
    perform public.generate_lifecycle_reminders();
  exception when others then
    insert into public.cron_job_heartbeats (job_key, last_run_at, last_status, last_error)
    values (p_job_key, clock_timestamp(), 'error', left(sqlerrm, 500))
    on conflict (job_key) do update
      set last_run_at = excluded.last_run_at, last_status = 'error', last_error = excluded.last_error;
    return;
  end;
  insert into public.cron_job_heartbeats (job_key, last_run_at, last_status, last_error, last_stale_alert_at)
  values (p_job_key, clock_timestamp(), 'ok', null, null)
  on conflict (job_key) do update
    set last_run_at = excluded.last_run_at, last_status = 'ok', last_error = null, last_stale_alert_at = null;
end;
$$;
revoke all on function public.lifecycle_reminders_cron_tick(text) from public, anon, authenticated;
grant execute on function public.lifecycle_reminders_cron_tick(text) to service_role;

insert into public.cron_job_heartbeats (job_key) values ('generate_lifecycle_reminders')
on conflict do nothing;

select cron.unschedule(jobid) from cron.job where jobname = 'lifecycle-generate-reminders';
select cron.schedule(
  'lifecycle-generate-reminders',
  '30 1 * * *',  -- 07:00 IST daily, after amc-assign-due-visits (06:30 IST)
  $$select public.lifecycle_reminders_cron_tick()$$
);
