-- Accounts follow-up, Feature B, step 3 of 5 — the Customer Outstanding
-- read model. No such page/view existed anywhere before this (DECISIONS.md
-- D1); both functions reuse the EXACT predicate report_kpi_tiles' live
-- 'outstanding' tile already uses (sum(total - amount_paid) where
-- payment_status <> 'paid' and total - amount_paid > 0, excluding
-- is_test_customer), just grouped by customer instead of summed org-wide,
-- so the two numbers reconcile by construction. Both functions are
-- READ-ONLY on money (owner's condition 3) — neither writes anything.
-- Master-only (DECISIONS.md D6/D10).

create index invoices_org_customer_outstanding_idx
  on public.invoices (org_id, customer_id) where payment_status <> 'paid';

create or replace function public.report_customer_outstanding(p_cursor uuid default null, p_limit int default 50)
returns table (
  customer_id uuid,
  customer_name text,
  outstanding_amount numeric,
  oldest_invoice_date date,
  open_reminder_count int,
  next_reminder_at timestamptz,
  open_task_count int,
  task_assignee_name text,
  task_status text
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_org uuid := public.current_org_id();
begin
  if v_org is null or not coalesce(public.is_master(), false) then
    raise exception 'report_customer_outstanding: master only';
  end if;

  return query
  with outstanding as (
    select
      i.customer_id as cid,
      sum(i.total - i.amount_paid) as outstanding_amount,
      min((i.created_at at time zone 'Asia/Kolkata')::date) as oldest_invoice_date
    from public.invoices i
    where i.org_id = v_org
      and i.payment_status <> 'paid'
      and i.total - i.amount_paid > 0
      and not public.is_test_customer(i.customer_id)
    group by i.customer_id
  ),
  reminders as (
    select r.customer_id as cid, count(*)::int as open_count, min(r.due_at) as next_due_at
    from public.customer_outstanding_reminders r
    where r.org_id = v_org and r.status = 'open'
    group by r.customer_id
  ),
  tasks_agg as (
    select
      l.customer_id as cid,
      count(*)::int as open_count,
      -- single representative row (assignee/status of the most-recently-created open task) for the list tile
      (array_agg(p.full_name order by t.created_at desc))[1] as assignee_name,
      (array_agg(t.status::text order by t.created_at desc))[1] as status
    from public.customer_outstanding_links l
    join public.tasks t on t.id = l.task_id
    left join public.profiles p on p.id = t.assignee_id
    where l.org_id = v_org and t.status = 'open'
    group by l.customer_id
  )
  select
    o.cid,
    c.name,
    o.outstanding_amount,
    o.oldest_invoice_date,
    coalesce(rem.open_count, 0),
    rem.next_due_at,
    coalesce(ta.open_count, 0),
    ta.assignee_name,
    ta.status
  from outstanding o
  join public.customers c on c.id = o.cid
  left join reminders rem on rem.cid = o.cid
  left join tasks_agg ta on ta.cid = o.cid
  where p_cursor is null or o.cid > p_cursor
  order by o.cid
  limit greatest(1, least(p_limit, 200));
end;
$$;
revoke all on function public.report_customer_outstanding(uuid, int) from public, anon, authenticated;
grant execute on function public.report_customer_outstanding(uuid, int) to authenticated;

create or replace function public.report_customer_outstanding_detail(p_customer uuid)
returns table (
  customer_id uuid,
  customer_name text,
  outstanding_amount numeric,
  oldest_invoice_date date,
  open_reminder_count int,
  next_reminder_at timestamptz,
  open_task_count int
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_org uuid := public.current_org_id();
begin
  if v_org is null or not coalesce(public.is_master(), false) then
    raise exception 'report_customer_outstanding_detail: master only';
  end if;

  return query
  select
    c.id,
    c.name,
    coalesce((
      select sum(i.total - i.amount_paid) from public.invoices i
      where i.org_id = v_org and i.customer_id = p_customer and i.payment_status <> 'paid' and i.total - i.amount_paid > 0
    ), 0),
    (select min((i.created_at at time zone 'Asia/Kolkata')::date) from public.invoices i
      where i.org_id = v_org and i.customer_id = p_customer and i.payment_status <> 'paid' and i.total - i.amount_paid > 0),
    (select count(*)::int from public.customer_outstanding_reminders r
      where r.org_id = v_org and r.customer_id = p_customer and r.status = 'open'),
    (select min(r.due_at) from public.customer_outstanding_reminders r
      where r.org_id = v_org and r.customer_id = p_customer and r.status = 'open'),
    (select count(*)::int from public.customer_outstanding_links l
      join public.tasks t on t.id = l.task_id
      where l.org_id = v_org and l.customer_id = p_customer and t.status = 'open')
  from public.customers c
  where c.id = p_customer and c.org_id = v_org;
end;
$$;
revoke all on function public.report_customer_outstanding_detail(uuid) from public, anon, authenticated;
grant execute on function public.report_customer_outstanding_detail(uuid) to authenticated;
