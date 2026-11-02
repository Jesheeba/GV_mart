-- Accounts follow-up, Feature B step 6 (client-requested, 2026-11-02): no
-- triggers on invoices/payments. Instead a SECURITY DEFINER sync -- run
-- daily by cron plus a master-only "Refresh" button -- creates or refreshes
-- one open customer_outstanding task per customer (title shows total due +
-- invoice count), applies a master-editable minimum-balance / minimum-age
-- threshold, assigns a master-editable default owner (falling back to the
-- org's master), and closes the task once the balance reaches zero.
-- Idempotent: re-running with nothing changed makes no writes. Never
-- contacts a customer -- purely an internal task/reminder sync, same as
-- the existing customer_outstanding_* conventions.

-- ── settings: threshold + default owner ──────────────────────────────────
alter table public.settings add column if not exists min_outstanding_balance numeric(12,2) not null default 50 check (min_outstanding_balance >= 0);
alter table public.settings add column if not exists min_outstanding_days integer not null default 3 check (min_outstanding_days >= 0);
alter table public.settings add column if not exists default_accounts_owner_id uuid references public.profiles (id) on delete set null;

comment on column public.settings.min_outstanding_balance is
  'Minimum unpaid balance (summed across a customer''s unpaid/partial invoices) before sync_outstanding_tasks opens a follow-up task for that customer. Master-editable, ships at 50.';
comment on column public.settings.min_outstanding_days is
  'Minimum age in days, since the customer''s oldest unpaid invoice, before sync_outstanding_tasks opens a follow-up task. Master-editable, ships at 3.';
comment on column public.settings.default_accounts_owner_id is
  'Who sync_outstanding_tasks assigns new customer-outstanding tasks to. Null (the default) falls back to the org''s active master at sync time; reassignment after creation still works through the normal task UI.';

-- ── tasks: enforce one open customer_outstanding task per customer ────────
-- Matches customer_outstanding_links' "exactly one target" discipline and
-- lead_followups' one-open-per-lead precedent -- same idea, applied here at
-- the customer level since this release groups by customer, not invoice.
create unique index if not exists tasks_customer_outstanding_one_open_idx
  on public.tasks (org_id, ref_id)
  where ref_type = 'customer_outstanding' and status = 'open';

-- ── internal, per-org sync -- NO grants to anon or authenticated. Reachable
-- only from the two trusted entry points below: sync_outstanding_tasks()
-- (the cron target, which loops every real org id itself) and
-- refresh_outstanding_tasks() (the master-only wrapper, which derives
-- org_id from current_org_id(), never from caller input). ─────────────────
create or replace function public._sync_outstanding_tasks_for_org(p_org_id uuid)
returns int
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_owner uuid;
  v_min_balance numeric;
  v_min_days integer;
  v_customer record;
  v_title text;
  v_existing_task_id uuid;
  v_existing_title text;
  v_created_or_updated int := 0;
  v_closed int := 0;
begin
  select coalesce(
           s.default_accounts_owner_id,
           (select p.id from public.profiles p
             where p.org_id = p_org_id and p.role = 'master' and p.is_active
             order by p.created_at asc limit 1)
         ),
         s.min_outstanding_balance,
         s.min_outstanding_days
    into v_owner, v_min_balance, v_min_days
  from public.settings s
  where s.org_id = p_org_id;

  if v_owner is null then
    -- no settings row, or no active master to fall back to -- nothing
    -- safe to assign a task to; skip this org for this run rather than
    -- raising and aborting every other org's sync.
    return 0;
  end if;

  for v_customer in
    select i.customer_id,
           sum(i.total - i.amount_paid) as outstanding,
           count(*) as invoice_count,
           min(i.created_at)::date as oldest_date,
           c.name as customer_name
    from public.invoices i
    join public.customers c on c.id = i.customer_id
    where i.org_id = p_org_id
      and i.payment_status <> 'paid'
      and i.total - i.amount_paid > 0
      and not public.is_test_customer(i.customer_id)
    group by i.customer_id, c.name
  loop
    select t.id, t.title into v_existing_task_id, v_existing_title
    from public.tasks t
    where t.org_id = p_org_id
      and t.ref_type = 'customer_outstanding'
      and t.ref_id = v_customer.customer_id
      and t.status = 'open';

    if v_customer.outstanding >= v_min_balance
       and (current_date - v_customer.oldest_date) >= v_min_days then
      v_title := format('Follow up: %s outstanding (%s invoice%s) — %s',
                         to_char(v_customer.outstanding, 'FM999999999990.00'),
                         v_customer.invoice_count,
                         case when v_customer.invoice_count = 1 then '' else 's' end,
                         v_customer.customer_name);

      if v_existing_task_id is null then
        insert into public.tasks (org_id, assignee_id, assigned_by, title, due_date, source, ref_type, ref_id)
        values (p_org_id, v_owner, v_owner, v_title, current_date, 'system', 'customer_outstanding', v_customer.customer_id);
        v_created_or_updated := v_created_or_updated + 1;
      elsif v_existing_title is distinct from v_title then
        update public.tasks set title = v_title, updated_at = now() where id = v_existing_task_id;
        v_created_or_updated := v_created_or_updated + 1;
      end if;
    end if;
    -- below-threshold-but-not-zero customers with an existing open task are
    -- deliberately left alone here -- only a real zero balance (below)
    -- closes a task, so a partial payment doesn't flip it open/closed
    -- every run.
  end loop;

  -- close every open customer_outstanding task whose customer now has zero
  -- qualifying outstanding (payment landed, credit note, etc).
  update public.tasks t
    set status = 'done', updated_at = now()
  where t.org_id = p_org_id
    and t.ref_type = 'customer_outstanding'
    and t.status = 'open'
    and not exists (
      select 1 from public.invoices i
      where i.org_id = p_org_id and i.customer_id = t.ref_id
        and i.payment_status <> 'paid' and i.total - i.amount_paid > 0
    );
  get diagnostics v_closed = row_count;

  return v_created_or_updated + v_closed;
end;
$function$;

revoke all on function public._sync_outstanding_tasks_for_org(uuid) from public, anon, authenticated;

-- ── cron entry point: every real org, once a day ──────────────────────────
create or replace function public.sync_outstanding_tasks()
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_org record;
begin
  for v_org in select id from public.organizations loop
    perform public._sync_outstanding_tasks_for_org(v_org.id);
  end loop;
end;
$function$;

revoke all on function public.sync_outstanding_tasks() from public, anon, authenticated;

-- ── master-only wrapper for the Refresh button ────────────────────────────
create or replace function public.refresh_outstanding_tasks()
returns int
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_org uuid := public.current_org_id();
begin
  if v_org is null or not coalesce(public.is_master(), false) then
    raise exception 'refresh_outstanding_tasks: master only';
  end if;
  return public._sync_outstanding_tasks_for_org(v_org);
end;
$function$;

revoke all on function public.refresh_outstanding_tasks() from public, anon, authenticated;
grant execute on function public.refresh_outstanding_tasks() to authenticated;

-- ── pg_cron schedule (daily, 06:00 IST = 00:30 UTC) ───────────────────────
-- Same unschedule-then-schedule idempotent shape as
-- 20261007120000_lead_followup_notifications.sql / 20261202100100_geocode_rate_limit.sql.
create extension if not exists pg_cron with schema pg_catalog;

do $$
begin
  if exists (select 1 from cron.job where jobname = 'sync-outstanding-tasks') then
    perform cron.unschedule('sync-outstanding-tasks');
  end if;
  perform cron.schedule('sync-outstanding-tasks', '30 0 * * *', 'select public.sync_outstanding_tasks()');
end
$$;
