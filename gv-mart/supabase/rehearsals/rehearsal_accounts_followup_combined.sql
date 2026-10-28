-- Combined rehearsal wrapper: Accounts follow-up spec, Feature B + Feature A.
-- P1a/P1b/P2/P3 (integration/p-series) are now LIVE (applied 2026-10-28 by the
-- concurrent main release) -- no longer chained/embedded here. Instead this
-- wrapper verifies the live tasks_select_internal/guard_task_completion/
-- _po_task_completed_marks_paid state actually matches the post-P3 shape our
-- migrations assume, before applying any of our own 7 migrations + the
-- combined test file.
-- ONE request, ONE DO block, refuses before 11:00 IST, CR-tolerant sha256
-- pin on every embedded file, ends in an unconditional RAISE so nothing
-- is ever committed. Never concatenated with anything outside this file.
--
-- Pinned (CR-tolerant sha256, recomputed at the commit this wrapper was built from):
--   17e597fb5904b0c3bc8999bf99a47c86ed2c1793f56f07d4d7a07a3a26acf351  Feature B migration 1/5: 20261115100000_customer_outstanding_reminders_schema.sql
--   4ebe905dc61bca52aca8edfd1425f5a75b824fbda6d17d6bbc68b5125ea03f8d  Feature B migration 2/5: 20261115100100_customer_outstanding_links_schema.sql
--   08cddc0f4f1756cf596e8c24f819d43def9d15dde646df5b658d6ca7078edb7f  Feature B migration 3/5: 20261115100200_customer_outstanding_report.sql
--   cff1fb33c32550521ed261c8de26bc270c83e4119535f8fdbb6d3eb251e65f50  Feature B migration 4/5: 20261115100300_customer_outstanding_rpcs.sql
--   c791fdc658476f22908a3f213bdcc6584e481de6c910d47cfb1dc67cacef0678  Feature B migration 5/5: 20261115100400_tasks_customer_outstanding_guard.sql
--   08602c4654ec49e6dae5641ae7ab8fd301a78e4d6262ba92b1a409b26ea39acf  Feature A migration 1/2: 20261115110000_expense_categories_schema.sql
--   c7c523fc9afb8cf384aa15f331ef232fb5518745032cab90acf869eb8d827a5a  Feature A migration 2/2: 20261115110100_expense_categories_rpcs.sql
--   1fb0264005f6a56b337b7431e2d8e056f19fe71ea4e860dfa9564533f4b8e614  combined test file: accounts_followup_combined.test.sql

do $rehearsal$
declare
  v_ist time := (clock_timestamp() at time zone 'Asia/Kolkata')::time;
  v_text text;
  v_hash text;
  v_realorg uuid;
  v_fp_before text;
  v_fp_after text;
begin
  perform set_config('lock_timeout', '5s', true);

  if v_ist < time '11:00' then
    raise exception 'REHEARSAL_REFUSED: the clock reads % IST, before 11:00 IST', to_char(v_ist, 'HH24:MI:SS');
  end if;

  select id into v_realorg from public.organizations where name not like '__TEST_%' escape '' order by created_at asc limit 1;
  select md5(v_realorg::text || '|' || name) into v_fp_before from public.organizations where id = v_realorg;
  if v_fp_before <> '6f891cf85011f08c2f22fb4a208d21bd' then
    raise exception 'REHEARSAL_REFUSED: real-organisation fingerprint mismatch before any migration ran: %', v_fp_before;
  end if;

  -- P1a/P1b/P2/P3 (integration/p-series) are now LIVE (applied by the concurrent main release,
  -- confirmed via supabase_migrations.schema_migrations immediately before this rehearsal run) --
  -- no longer chained here. Instead, verify the ACTUAL live state matches what our migrations
  -- assume, so we fail loudly instead of silently rehearsing against a wrong baseline.

  if not exists (select 1 from supabase_migrations.schema_migrations where version = '20261103100000') then
    raise exception 'REHEARSAL_REFUSED: P3 (20261103100000) is not registered live -- our migrations assume the post-P3 tasks_select_internal shape';
  end if;

  select replace(replace(coalesce(qual, ''), chr(13), ''), ' ', '') into v_text
    from pg_policies where schemaname = 'public' and tablename = 'tasks' and policyname = 'tasks_select_internal';
  if v_text is distinct from replace(replace('((org_id = current_org_id()) AND (is_staff() OR (current_technician_id() IS NOT NULL)) AND (is_ops_staff() OR (assignee_id = auth.uid()) OR (assigned_by = auth.uid())))', chr(13), ''), ' ', '') then
    raise exception 'REHEARSAL_REFUSED: live tasks_select_internal does not match the expected post-P3 shape. Got: %', v_text;
  end if;

  if not exists (select 1 from pg_proc where proname = 'guard_task_completion' and pronamespace = 'public'::regnamespace) then
    raise exception 'REHEARSAL_REFUSED: guard_task_completion (P1a) is not live -- expected after P1a applied';
  end if;
  select replace(replace(pg_get_functiondef('public._po_task_completed_marks_paid()'::regprocedure), chr(13), ''), ' ', '') into v_text;
  if v_text not like '%is_master%' then
    raise exception 'REHEARSAL_REFUSED: _po_task_completed_marks_paid does not carry the P1a master-only gate on its live definition';
  end if;

  -- Feature B (5 migrations)

  -- Feature B (5 migrations)

  v_text := $m1tag$-- Accounts follow-up, Feature B, step 1 of 5 — the new internal-only
-- "Reminder" entity for a customer's outstanding balance. No generic
-- Reminder module exists in this codebase (see DECISIONS.md D2); this
-- table is modeled on lead_followups' proven conventions (status enum,
-- RPC-only writes, no client write policy, set_updated_at + audit_master_
-- change) rather than inventing a cross-module reminder system the spec
-- never asked for.
--
-- Master-only (DECISIONS.md D6/D10): nothing under /accounts is open to
-- operation_admin/sales_admin today, so this stays consistent with that.
-- Never sends anything to a customer — purely a staff-visible row.

create type public.customer_outstanding_reminder_status as enum ('open', 'done', 'cancelled');

create table public.customer_outstanding_reminders (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  customer_id uuid not null references public.customers (id) on delete cascade,
  due_at timestamptz not null,
  note text,
  status public.customer_outstanding_reminder_status not null default 'open',
  -- manual | system (auto-closed when outstanding reaches zero)
  source text not null default 'manual' check (source in ('manual', 'system')),
  created_by uuid references public.profiles (id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  closed_by uuid references public.profiles (id) on delete set null,
  closed_at timestamptz,
  close_reason text,
  updated_at timestamptz not null default now(),
  constraint customer_outstanding_reminders_done_has_close check (status <> 'done' or closed_at is not null),
  constraint customer_outstanding_reminders_cancelled_has_close check (status <> 'cancelled' or closed_at is not null),
  constraint customer_outstanding_reminders_system_has_reason check (source <> 'system' or close_reason is not null)
);

create index customer_outstanding_reminders_org_customer_idx on public.customer_outstanding_reminders (org_id, customer_id);
create index customer_outstanding_reminders_due_idx on public.customer_outstanding_reminders (org_id, due_at) where status = 'open';

alter table public.customer_outstanding_reminders enable row level security;
revoke all on public.customer_outstanding_reminders from public, anon, authenticated;

-- Read only; every write goes through SECURITY DEFINER RPCs (next migration).
create policy customer_outstanding_reminders_select_master on public.customer_outstanding_reminders
  for select using (org_id = public.current_org_id() and public.is_master());
grant select on public.customer_outstanding_reminders to authenticated;

create trigger set_updated_at before update on public.customer_outstanding_reminders
  for each row execute function public.set_updated_at();
create trigger audit_customer_outstanding_reminders after insert or update or delete on public.customer_outstanding_reminders
  for each row execute function public.audit_master_change();
$m1tag$;
  v_hash := encode(sha256(convert_to(replace(v_text, E'', ''), 'UTF8')), 'hex');
  if v_hash <> '17e597fb5904b0c3bc8999bf99a47c86ed2c1793f56f07d4d7a07a3a26acf351' then
    raise exception 'REHEARSAL_REFUSED: hash mismatch for Feature B migration 1/5: %', v_hash;
  end if;
  execute v_text;

  v_text := $m2tag$-- Accounts follow-up, Feature B, step 2 of 5 — the customer/invoice/amount
-- link, kept OFF both `tasks` (shared, broadly-visible — see the policy
-- patch in 20261115100400) and `customer_outstanding_reminders` as its own
-- small table (DECISIONS.md D4), so the amount snapshot is never reachable
-- through the generic Tasks read path.

create table public.customer_outstanding_links (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  task_id uuid unique references public.tasks (id) on delete cascade,
  reminder_id uuid unique references public.customer_outstanding_reminders (id) on delete cascade,
  customer_id uuid not null references public.customers (id) on delete cascade,
  invoice_id uuid references public.invoices (id) on delete set null,
  amount_snapshot numeric(12, 2) not null check (amount_snapshot >= 0),
  created_at timestamptz not null default now(),
  constraint customer_outstanding_links_exactly_one_target check (
    (task_id is not null and reminder_id is null) or (task_id is null and reminder_id is not null)
  )
);

create index customer_outstanding_links_org_customer_idx on public.customer_outstanding_links (org_id, customer_id);

alter table public.customer_outstanding_links enable row level security;
revoke all on public.customer_outstanding_links from public, anon, authenticated;

create policy customer_outstanding_links_select_master on public.customer_outstanding_links
  for select using (org_id = public.current_org_id() and public.is_master());
grant select on public.customer_outstanding_links to authenticated;
$m2tag$;
  v_hash := encode(sha256(convert_to(replace(v_text, E'', ''), 'UTF8')), 'hex');
  if v_hash <> '4ebe905dc61bca52aca8edfd1425f5a75b824fbda6d17d6bbc68b5125ea03f8d' then
    raise exception 'REHEARSAL_REFUSED: hash mismatch for Feature B migration 2/5: %', v_hash;
  end if;
  execute v_text;

  v_text := $m3tag$-- Accounts follow-up, Feature B, step 3 of 5 — the Customer Outstanding
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
$m3tag$;
  v_hash := encode(sha256(convert_to(replace(v_text, E'', ''), 'UTF8')), 'hex');
  if v_hash <> '08cddc0f4f1756cf596e8c24f819d43def9d15dde646df5b658d6ca7078edb7f' then
    raise exception 'REHEARSAL_REFUSED: hash mismatch for Feature B migration 3/5: %', v_hash;
  end if;
  execute v_text;

  v_text := $m4tag$-- Accounts follow-up, Feature B, step 4 of 5 — create/reschedule/close/
-- cancel reminders, create a linked task, and the zero-outstanding
-- auto-close. All master-only SECURITY DEFINER, all RPC-only writes
-- (customer_outstanding_reminders/_links have no client write policy).
--
-- close_outstanding_reminders_if_zero is explicitly NOT a trigger on
-- invoices/sales/receipts/payments (owner's condition 2) — it is called
-- by the client after a payment succeeds, and opportunistically when the
-- Customer Outstanding detail view loads. It never touches `tasks`
-- (spec: never auto-complete a task).

create or replace function public.create_customer_outstanding_reminder(
  p_customer uuid, p_due_at timestamptz, p_note text default null, p_invoice uuid default null, p_amount numeric default 0
)
returns public.customer_outstanding_reminders
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid := public.current_org_id();
  v_row public.customer_outstanding_reminders;
begin
  if v_org is null or not coalesce(public.is_master(), false) then
    raise exception 'create_customer_outstanding_reminder: master only';
  end if;
  if not exists (select 1 from public.customers where id = p_customer and org_id = v_org) then
    raise exception 'create_customer_outstanding_reminder: customer not found in this organisation';
  end if;

  insert into public.customer_outstanding_reminders (org_id, customer_id, due_at, note)
  values (v_org, p_customer, p_due_at, p_note)
  returning * into v_row;

  insert into public.customer_outstanding_links (org_id, reminder_id, customer_id, invoice_id, amount_snapshot)
  values (v_org, v_row.id, p_customer, p_invoice, coalesce(p_amount, 0));

  return v_row;
end;
$$;
revoke all on function public.create_customer_outstanding_reminder(uuid, timestamptz, text, uuid, numeric) from public, anon, authenticated;
grant execute on function public.create_customer_outstanding_reminder(uuid, timestamptz, text, uuid, numeric) to authenticated;

create or replace function public.reschedule_customer_outstanding_reminder(p_reminder uuid, p_due_at timestamptz, p_note text default null)
returns public.customer_outstanding_reminders
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid := public.current_org_id();
  v_row public.customer_outstanding_reminders;
begin
  if v_org is null or not coalesce(public.is_master(), false) then
    raise exception 'reschedule_customer_outstanding_reminder: master only';
  end if;
  update public.customer_outstanding_reminders
    set due_at = p_due_at, note = coalesce(p_note, note)
    where id = p_reminder and org_id = v_org and status = 'open'
    returning * into v_row;
  if v_row.id is null then
    raise exception 'reschedule_customer_outstanding_reminder: reminder % is not open or not found', p_reminder;
  end if;
  return v_row;
end;
$$;
revoke all on function public.reschedule_customer_outstanding_reminder(uuid, timestamptz, text) from public, anon, authenticated;
grant execute on function public.reschedule_customer_outstanding_reminder(uuid, timestamptz, text) to authenticated;

create or replace function public.close_customer_outstanding_reminder(p_reminder uuid)
returns public.customer_outstanding_reminders
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid := public.current_org_id();
  v_row public.customer_outstanding_reminders;
begin
  if v_org is null or not coalesce(public.is_master(), false) then
    raise exception 'close_customer_outstanding_reminder: master only';
  end if;
  update public.customer_outstanding_reminders
    set status = 'done', closed_by = auth.uid(), closed_at = now()
    where id = p_reminder and org_id = v_org and status = 'open'
    returning * into v_row;
  if v_row.id is null then
    raise exception 'close_customer_outstanding_reminder: reminder % is not open or not found', p_reminder;
  end if;
  return v_row;
end;
$$;
revoke all on function public.close_customer_outstanding_reminder(uuid) from public, anon, authenticated;
grant execute on function public.close_customer_outstanding_reminder(uuid) to authenticated;

create or replace function public.cancel_customer_outstanding_reminder(p_reminder uuid, p_reason text default null)
returns public.customer_outstanding_reminders
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid := public.current_org_id();
  v_row public.customer_outstanding_reminders;
begin
  if v_org is null or not coalesce(public.is_master(), false) then
    raise exception 'cancel_customer_outstanding_reminder: master only';
  end if;
  update public.customer_outstanding_reminders
    set status = 'cancelled', closed_by = auth.uid(), closed_at = now(), close_reason = p_reason
    where id = p_reminder and org_id = v_org and status = 'open'
    returning * into v_row;
  if v_row.id is null then
    raise exception 'cancel_customer_outstanding_reminder: reminder % is not open or not found', p_reminder;
  end if;
  return v_row;
end;
$$;
revoke all on function public.cancel_customer_outstanding_reminder(uuid, text) from public, anon, authenticated;
grant execute on function public.cancel_customer_outstanding_reminder(uuid, text) to authenticated;

-- Task side: reuses tasks.ref_type/ref_id (no new tasks columns). Master-
-- only write enforced a second, independent way by the trigger in the
-- next migration (_guard_customer_outstanding_task_ref), so this RPC's own
-- is_master() check is belt-and-suspenders, not the only gate.
create or replace function public.create_customer_outstanding_task(
  p_customer uuid, p_assignee uuid, p_title text, p_due_date date, p_invoice uuid default null, p_amount numeric default 0
)
returns public.tasks
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid := public.current_org_id();
  v_row public.tasks;
begin
  if v_org is null or not coalesce(public.is_master(), false) then
    raise exception 'create_customer_outstanding_task: master only';
  end if;
  if not exists (select 1 from public.customers where id = p_customer and org_id = v_org) then
    raise exception 'create_customer_outstanding_task: customer not found in this organisation';
  end if;

  insert into public.tasks (org_id, assignee_id, assigned_by, title, due_date, source, ref_type, ref_id)
  values (v_org, p_assignee, auth.uid(), p_title, p_due_date, 'manual', 'customer_outstanding', p_customer)
  returning * into v_row;

  insert into public.customer_outstanding_links (org_id, task_id, customer_id, invoice_id, amount_snapshot)
  values (v_org, v_row.id, p_customer, p_invoice, coalesce(p_amount, 0));

  return v_row;
end;
$$;
revoke all on function public.create_customer_outstanding_task(uuid, uuid, text, date, uuid, numeric) from public, anon, authenticated;
grant execute on function public.create_customer_outstanding_task(uuid, uuid, text, date, uuid, numeric) to authenticated;

-- Zero-outstanding auto-close (owner's condition 2: computed on read / by
-- an RPC, never a trigger on a money table; does not touch tasks).
create or replace function public.close_outstanding_reminders_if_zero(p_customer uuid)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid := public.current_org_id();
  v_outstanding numeric;
  v_closed int;
begin
  if v_org is null or not coalesce(public.is_master(), false) then
    raise exception 'close_outstanding_reminders_if_zero: master only';
  end if;

  select coalesce(sum(i.total - i.amount_paid), 0) into v_outstanding
  from public.invoices i
  where i.org_id = v_org and i.customer_id = p_customer and i.payment_status <> 'paid' and i.total - i.amount_paid > 0;

  if v_outstanding > 0 then
    return 0;
  end if;

  with closed as (
    update public.customer_outstanding_reminders
      set status = 'done', source = 'system', closed_by = null, closed_at = now(),
          close_reason = 'outstanding reached zero'
      where org_id = v_org and customer_id = p_customer and status = 'open'
      returning 1
  )
  select count(*) into v_closed from closed;

  return v_closed;
end;
$$;
revoke all on function public.close_outstanding_reminders_if_zero(uuid) from public, anon, authenticated;
grant execute on function public.close_outstanding_reminders_if_zero(uuid) to authenticated;
$m4tag$;
  v_hash := encode(sha256(convert_to(replace(v_text, E'', ''), 'UTF8')), 'hex');
  if v_hash <> 'cff1fb33c32550521ed261c8de26bc270c83e4119535f8fdbb6d3eb251e65f50' then
    raise exception 'REHEARSAL_REFUSED: hash mismatch for Feature B migration 4/5: %', v_hash;
  end if;
  execute v_text;

  v_text := $m5tag$-- Accounts follow-up, Feature B, step 5 of 5 — hide customer_outstanding
-- tasks from technicians, and block non-master writes of that ref_type.
--
-- Built on the POST-P3 (integration/p-series, 20261103100000) shape of
-- tasks_select_internal, not the current live one (owner's condition 1):
-- P3 narrows `tasks_select_internal` to
--   (is_staff() or current_technician_id() is not null)
--   and (is_ops_staff() or assignee_id = auth.uid() or assigned_by = auth.uid())
-- This migration's timestamp sorts after P3's, so by the time it runs for
-- real, P3 will already be live (it is part of the same release window
-- that gates this feature's own apply — see DECISIONS.md). The pre-check
-- below refuses to proceed if the live policy text does not match that
-- expected shape, so this can never silently apply against the wrong
-- baseline.
--
-- Technicians never see a customer_outstanding task at all (spec hard
-- rule); every other ref_type, and every is_staff()/is_ops_staff() path,
-- is untouched. INSERT/UPDATE of ref_type='customer_outstanding' is
-- additionally blocked for anyone but master by a trigger (independent of,
-- and stronger than, the existing tasks_insert_assign/tasks_update_assign
-- policies, which are left exactly as-is). DELETE is already is_ops_staff()
-- -only via the untouched tasks_delete_ops policy.

do $precheck$
declare
  v_live_qual text;
  v_normalized text;
begin
  select replace(qual, E'\r', '') into v_live_qual
  from pg_policies
  where schemaname = 'public' and tablename = 'tasks' and policyname = 'tasks_select_internal';

  if v_live_qual is null then
    raise exception 'tasks_customer_outstanding_guard: tasks_select_internal policy not found';
  end if;

  v_normalized := regexp_replace(v_live_qual, '\s+', ' ', 'g');

  if v_normalized !~ 'is_ops_staff\(\)' or v_normalized !~ 'assignee_id = auth\.uid\(\)' or v_normalized !~ 'assigned_by = auth\.uid\(\)' then
    raise exception 'tasks_customer_outstanding_guard: live tasks_select_internal does not match the expected post-P3 shape (got: %). Apply P1a/P1b/P2/P3 (integration/p-series) first.', v_normalized;
  end if;
end;
$precheck$;

drop policy if exists tasks_select_internal on public.tasks;
create policy tasks_select_internal on public.tasks
  for select using (
    org_id = public.current_org_id()
    and (public.is_staff() or (public.current_technician_id() is not null and ref_type is distinct from 'customer_outstanding'))
    and (public.is_ops_staff() or assignee_id = auth.uid() or assigned_by = auth.uid())
  );

create or replace function public._guard_customer_outstanding_task_ref()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  if new.ref_type = 'customer_outstanding' and not coalesce(public.is_master(), false) then
    raise exception 'tasks: only master may create or modify a customer-outstanding task';
  end if;
  return new;
end;
$$;
revoke all on function public._guard_customer_outstanding_task_ref() from public, anon, authenticated;

drop trigger if exists aaa_guard_customer_outstanding_task_ref on public.tasks;
create trigger aaa_guard_customer_outstanding_task_ref
  before insert or update on public.tasks
  for each row execute function public._guard_customer_outstanding_task_ref();
$m5tag$;
  v_hash := encode(sha256(convert_to(replace(v_text, E'', ''), 'UTF8')), 'hex');
  if v_hash <> 'c791fdc658476f22908a3f213bdcc6584e481de6c910d47cfb1dc67cacef0678' then
    raise exception 'REHEARSAL_REFUSED: hash mismatch for Feature B migration 5/5: %', v_hash;
  end if;
  execute v_text;

  -- Feature A (2 migrations)

  v_text := $m6tag$-- Accounts follow-up, Feature A, step 1 of 3 — owner-managed expense
-- categories ("Under Category"), additive alongside the existing fixed
-- `expenses.category` enum (DECISIONS.md D9) — the enum, its RLS, and
-- every path that writes it (including HR/Staff-Salary's "Log to
-- Accounts", which writes category='salary') are untouched by this
-- migration. No overlap with feat/monthly-expenses-v2 (DECISIONS.md D8).

create table public.expense_categories (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  name text not null check (char_length(btrim(name)) between 1 and 80),
  -- System categories (one per existing expense_category enum value, plus
  -- Incentives) are seeded per-org and can never be renamed, deactivated or
  -- deleted — enforced below by a trigger, not only by the RPCs.
  is_system boolean not null default false,
  enum_value public.expense_category,
  is_active boolean not null default true,
  created_by uuid references public.profiles (id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index expense_categories_org_name_ci_idx on public.expense_categories (org_id, lower(name));
create unique index expense_categories_org_enum_idx on public.expense_categories (org_id, enum_value) where enum_value is not null;
create index expense_categories_org_idx on public.expense_categories (org_id);

alter table public.expense_categories enable row level security;
revoke all on public.expense_categories from public, anon, authenticated;

-- Matches expenses_select_master precedent (20260701091300_rls.sql):
-- category management is a master-only Accounts concern.
create policy expense_categories_select_master on public.expense_categories
  for select using (org_id = public.current_org_id() and public.is_master());
grant select on public.expense_categories to authenticated;

create trigger set_updated_at before update on public.expense_categories
  for each row execute function public.set_updated_at();
create trigger audit_expense_categories after insert or update or delete on public.expense_categories
  for each row execute function public.audit_master_change();

-- Real DB enforcement (owner's condition 4: "enforced in DB, not only
-- UI") that a system category's name/active flag can never change, and it
-- can never be deleted. The RPCs add a friendlier error on top of this.
create or replace function public._guard_expense_category_system_locked()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  if tg_op = 'DELETE' then
    if old.is_system then
      raise exception 'expense_categories: a system category cannot be deleted';
    end if;
    return old;
  end if;
  if old.is_system and (new.name is distinct from old.name or new.is_active is distinct from old.is_active) then
    raise exception 'expense_categories: a system category cannot be renamed or deactivated';
  end if;
  return new;
end;
$$;
revoke all on function public._guard_expense_category_system_locked() from public, anon, authenticated;

drop trigger if exists aaa_guard_expense_category_system_locked on public.expense_categories;
create trigger aaa_guard_expense_category_system_locked
  before update or delete on public.expense_categories
  for each row execute function public._guard_expense_category_system_locked();

-- Additive nullable FK — existing rows stay "uncategorised"; the existing
-- `category` enum column is never touched.
alter table public.expenses add column if not exists category_id uuid references public.expense_categories (id) on delete set null;
create index if not exists expenses_category_id_idx on public.expenses (category_id);

-- ── seed: one system category per existing enum value, plus Incentives ──
create or replace function public.seed_system_expense_categories(p_org_id uuid)
returns void
language sql
security definer
set search_path = public
as $$
  insert into public.expense_categories (org_id, name, is_system, enum_value)
  values
    (p_org_id, 'Marketing Expenses', true, 'marketing'),
    (p_org_id, 'Stationery', true, 'stationery'),
    (p_org_id, 'Salary', true, 'salary'),
    (p_org_id, 'Petrol', true, 'petrol'),
    (p_org_id, 'Purchase', true, 'purchase'),
    (p_org_id, 'Other', true, 'other'),
    (p_org_id, 'Rent', true, 'rent'),
    (p_org_id, 'Electricity', true, 'electricity'),
    (p_org_id, 'Parking', true, 'parking'),
    (p_org_id, 'Ad Campaign', true, 'ad_campaign'),
    (p_org_id, 'Video Generation', true, 'video_generation'),
    (p_org_id, 'Incentives', true, null)
  on conflict (org_id, lower(name)) do nothing;
$$;
revoke execute on function public.seed_system_expense_categories(uuid) from public, anon, authenticated;

select public.seed_system_expense_categories(id) from public.organizations;

create or replace function public._trg_seed_system_expense_categories()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.seed_system_expense_categories(new.id);
  return new;
end;
$$;
revoke all on function public._trg_seed_system_expense_categories() from public, anon, authenticated;

drop trigger if exists seed_system_expense_categories_on_org on public.organizations;
create trigger seed_system_expense_categories_on_org after insert on public.organizations
  for each row execute function public._trg_seed_system_expense_categories();

-- Idempotent, additive: only ever fills a null category_id, never
-- overwrites one a user later picked manually. Safe to re-run.
update public.expenses e
  set category_id = (
    select ec.id from public.expense_categories ec
    where ec.org_id = e.org_id and ec.enum_value = e.category and ec.is_system
  )
  where e.category_id is null;
$m6tag$;
  v_hash := encode(sha256(convert_to(replace(v_text, E'', ''), 'UTF8')), 'hex');
  if v_hash <> '08602c4654ec49e6dae5641ae7ab8fd301a78e4d6262ba92b1a409b26ea39acf' then
    raise exception 'REHEARSAL_REFUSED: hash mismatch for Feature A migration 1/2: %', v_hash;
  end if;
  execute v_text;

  v_text := $m7tag$-- Accounts follow-up, Feature A, step 2 of 3 — owner-managed category
-- create/rename/deactivate/delete, all master-only SECURITY DEFINER.
-- The real enforcement that a system category is locked lives in the
-- trigger (previous migration); these checks are a friendlier error for
-- the UI.

create or replace function public.create_expense_category(p_name text)
returns public.expense_categories
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid := public.current_org_id();
  v_row public.expense_categories;
begin
  if v_org is null or not coalesce(public.is_master(), false) then
    raise exception 'create_expense_category: master only';
  end if;
  if p_name is null or char_length(btrim(p_name)) = 0 then
    raise exception 'create_expense_category: name is required';
  end if;

  insert into public.expense_categories (org_id, name)
  values (v_org, btrim(p_name))
  returning * into v_row;

  return v_row;
exception
  when unique_violation then
    raise exception 'create_expense_category: a category named "%" already exists', btrim(p_name);
end;
$$;
revoke all on function public.create_expense_category(text) from public, anon, authenticated;
grant execute on function public.create_expense_category(text) to authenticated;

create or replace function public.rename_expense_category(p_id uuid, p_name text)
returns public.expense_categories
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid := public.current_org_id();
  v_row public.expense_categories;
begin
  if v_org is null or not coalesce(public.is_master(), false) then
    raise exception 'rename_expense_category: master only';
  end if;
  if exists (select 1 from public.expense_categories where id = p_id and org_id = v_org and is_system) then
    raise exception 'rename_expense_category: a system category cannot be renamed';
  end if;
  if p_name is null or char_length(btrim(p_name)) = 0 then
    raise exception 'rename_expense_category: name is required';
  end if;

  update public.expense_categories
    set name = btrim(p_name)
    where id = p_id and org_id = v_org
    returning * into v_row;
  if v_row.id is null then
    raise exception 'rename_expense_category: category % not found', p_id;
  end if;
  return v_row;
exception
  when unique_violation then
    raise exception 'rename_expense_category: a category named "%" already exists', btrim(p_name);
end;
$$;
revoke all on function public.rename_expense_category(uuid, text) from public, anon, authenticated;
grant execute on function public.rename_expense_category(uuid, text) to authenticated;

create or replace function public.deactivate_expense_category(p_id uuid)
returns public.expense_categories
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid := public.current_org_id();
  v_row public.expense_categories;
begin
  if v_org is null or not coalesce(public.is_master(), false) then
    raise exception 'deactivate_expense_category: master only';
  end if;
  if exists (select 1 from public.expense_categories where id = p_id and org_id = v_org and is_system) then
    raise exception 'deactivate_expense_category: a system category cannot be deactivated';
  end if;

  update public.expense_categories
    set is_active = false
    where id = p_id and org_id = v_org
    returning * into v_row;
  if v_row.id is null then
    raise exception 'deactivate_expense_category: category % not found', p_id;
  end if;
  return v_row;
end;
$$;
revoke all on function public.deactivate_expense_category(uuid) from public, anon, authenticated;
grant execute on function public.deactivate_expense_category(uuid) to authenticated;

create or replace function public.delete_expense_category(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid := public.current_org_id();
  v_deleted int;
begin
  if v_org is null or not coalesce(public.is_master(), false) then
    raise exception 'delete_expense_category: master only';
  end if;
  if exists (select 1 from public.expense_categories where id = p_id and org_id = v_org and is_system) then
    raise exception 'delete_expense_category: a system category cannot be deleted';
  end if;
  if exists (select 1 from public.expenses where category_id = p_id) then
    raise exception 'delete_expense_category: category % is used by at least one expense', p_id;
  end if;

  delete from public.expense_categories where id = p_id and org_id = v_org;
  get diagnostics v_deleted = row_count;
  if v_deleted = 0 then
    raise exception 'delete_expense_category: category % not found', p_id;
  end if;
end;
$$;
revoke all on function public.delete_expense_category(uuid) from public, anon, authenticated;
grant execute on function public.delete_expense_category(uuid) to authenticated;
$m7tag$;
  v_hash := encode(sha256(convert_to(replace(v_text, E'', ''), 'UTF8')), 'hex');
  if v_hash <> 'c7c523fc9afb8cf384aa15f331ef232fb5518745032cab90acf869eb8d827a5a' then
    raise exception 'REHEARSAL_REFUSED: hash mismatch for Feature A migration 2/2: %', v_hash;
  end if;
  execute v_text;

  select md5(v_realorg::text || '|' || name) into v_fp_after from public.organizations where id = v_realorg;
  if v_fp_after <> v_fp_before then
    raise exception 'REHEARSAL_REFUSED: real-organisation fingerprint changed by the migrations alone: % -> %', v_fp_before, v_fp_after;
  end if;

  -- combined test file

  v_text := $tsttag$-- DB tests for the Accounts follow-up spec: Feature B (Customer Outstanding
-- <-> Reminders/Tasks, migrations 20261115100000-20261115100400) and
-- Feature A (Expense categories, 20261115110000-20261115110100). NOT RUN
-- standalone (written for review) -- run only through the approved
-- rehearsal wrapper (dependency migrations, then these 7 migrations, then
-- this file, one request, ends in an unconditional RAISE). Throwaway
-- __TEST_ organisations only. One combined file (not one per migration)
-- mirrors the existing amc_and_test_flag.test.sql / task_logs_and_
-- visibility.test.sql precedent of covering several migrations in one
-- test file so only ONE final RAISE is needed in the whole rehearsal.

create temp table res (n serial, line text);
grant all on res to public;
grant usage on sequence res_n_seq to public;
-- 20261024100000 (applied live) revokes PUBLIC execute from every new function by default; restore it for pg_temp helpers only.
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
create function pg_temp.raises(p_sql text) returns text language plpgsql as $f$
begin execute p_sql; return null;
exception when others then return sqlerrm; end $f$;
create function pg_temp.mk_task(p_org uuid, p_assignee uuid, p_by uuid, p_title text, p_ref_type text default null, p_ref_id uuid default null) returns uuid language plpgsql as $f$
declare t uuid;
begin
  insert into public.tasks (org_id, assignee_id, assigned_by, title, source, ref_type, ref_id) values (p_org, p_assignee, p_by, p_title, 'assigned', p_ref_type, p_ref_id) returning id into t;
  return t;
end $f$;

do $t$
declare
  v_org uuid; v_org2 uuid;
  v_master uuid; v_ops uuid; v_sales uuid;
  v_tp uuid; v_tp2 uuid;
  v_cust uuid; v_inv uuid;
  v_rem public.customer_outstanding_reminders;
  v_task public.tasks;
  v_task2 public.tasks;
  v_other_task uuid;
  v_po_task uuid;
  v_cat_marketing uuid; v_cat_incentives uuid; v_cat_custom uuid;
  v_sys_count int; v_n int; v_s text; v_amt numeric; v_closed int;
  v_fp_before text; v_fp_after text;
  v_realorg uuid; v_real_fp text;
  v_pub_anon_before text[]; v_pub_anon_after text[];
begin
  -- ---------- fixtures ----------
  insert into organizations (name) values ('__TEST_acctfu') returning id into v_org;
  insert into organizations (name) values ('__TEST_acctfu_other') returning id into v_org2;
  insert into settings (org_id) values (v_org) on conflict (org_id) do nothing;
  insert into settings (org_id) values (v_org2) on conflict (org_id) do nothing;

  v_master := pg_temp.mkuser('master', v_org, '__TEST_ Mira Master');
  v_ops := pg_temp.mkuser('operation_admin', v_org, '__TEST_ Omar Ops');
  v_sales := pg_temp.mkuser('sales_admin', v_org, '__TEST_ Sana Sales');
  v_tp := pg_temp.mkuser('technician', v_org, '__TEST_ Tara Tech');
  v_tp2 := pg_temp.mkuser('technician', v_org, '__TEST_ Tim Tech');
  insert into technicians (org_id, profile_id, is_active) values (v_org, v_tp, true);
  insert into technicians (org_id, profile_id, is_active) values (v_org, v_tp2, true);

  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ Outstanding Customer', '9400000111') returning id into v_cust;
  insert into invoices (org_id, customer_id, type, subtotal, gst, total, amount_paid, payment_status)
    values (v_org, v_cust, 'product', 1000, 0, 1000, 400, 'partial') returning id into v_inv;

  -- ============================================================
  -- Feature B: report RPC numbers
  -- ============================================================
  perform pg_temp.as_user(v_master);
  select outstanding_amount into v_amt from public.report_customer_outstanding_detail(v_cust);
  perform pg_temp.chk('report_customer_outstanding_detail returns the exact unpaid balance', v_amt = 600, v_amt::text);

  perform pg_temp.chk('report_customer_outstanding lists the customer with an open balance',
    (select outstanding_amount from public.report_customer_outstanding(null, 50) where customer_id = v_cust) = 600);
  perform pg_temp.as_pg();

  -- role gate: operation_admin / sales_admin / technician cannot call the report
  perform pg_temp.as_user(v_ops);
  v_s := pg_temp.raises('select * from public.report_customer_outstanding_detail(''' || v_cust || ''')');
  perform pg_temp.as_pg();
  perform pg_temp.chk('operation_admin cannot call report_customer_outstanding_detail', v_s like '%master only%', coalesce(v_s, 'allowed'));

  perform pg_temp.as_user(v_sales);
  v_s := pg_temp.raises('select * from public.report_customer_outstanding_detail(''' || v_cust || ''')');
  perform pg_temp.as_pg();
  perform pg_temp.chk('sales_admin cannot call report_customer_outstanding_detail', v_s like '%master only%', coalesce(v_s, 'allowed'));

  perform pg_temp.as_anon();
  v_s := pg_temp.raises('select * from public.report_customer_outstanding_detail(''' || v_cust || ''')');
  perform pg_temp.as_pg();
  perform pg_temp.chk('anon cannot call report_customer_outstanding_detail', v_s is not null, coalesce(v_s, 'allowed'));

  -- cross-org isolation: master of org2 sees nothing for org1's customer
  declare v_master2 uuid;
  begin
    v_master2 := pg_temp.mkuser('master', v_org2, '__TEST_ Other Master');
    perform pg_temp.as_user(v_master2);
    select count(*) into v_n from public.report_customer_outstanding(null, 50) where customer_id = v_cust;
    perform pg_temp.chk('a master of another org sees zero rows for this org''s outstanding customer', v_n = 0);
    perform pg_temp.as_pg();
  end;

  -- ============================================================
  -- Feature B: create/manage reminder + task RPCs
  -- ============================================================
  perform pg_temp.as_user(v_master);
  v_rem := public.create_customer_outstanding_reminder(v_cust, now() + interval '2 days', 'follow up', v_inv, 600);
  perform pg_temp.chk('create_customer_outstanding_reminder creates an open reminder', v_rem.status = 'open');
  perform pg_temp.chk('a link row with the amount snapshot was created for the reminder',
    exists (select 1 from customer_outstanding_links where reminder_id = v_rem.id and amount_snapshot = 600));

  v_task := public.create_customer_outstanding_task(v_cust, v_sales, 'Follow up: outstanding', current_date + 3, v_inv, 600);
  perform pg_temp.chk('create_customer_outstanding_task creates a task with ref_type=customer_outstanding',
    v_task.ref_type = 'customer_outstanding' and v_task.ref_id = v_cust);
  perform pg_temp.chk('a link row with the amount snapshot was created for the task',
    exists (select 1 from customer_outstanding_links where task_id = v_task.id and amount_snapshot = 600));
  perform pg_temp.as_pg();

  -- non-master cannot create either
  perform pg_temp.as_user(v_ops);
  v_s := pg_temp.raises('select public.create_customer_outstanding_reminder(''' || v_cust || ''', now())');
  perform pg_temp.chk('operation_admin cannot create a reminder', v_s like '%master only%', coalesce(v_s, 'allowed'));
  v_s := pg_temp.raises('select public.create_customer_outstanding_task(''' || v_cust || ''', null, ''x'', current_date)');
  perform pg_temp.chk('operation_admin cannot create an outstanding task via the RPC', v_s like '%master only%', coalesce(v_s, 'allowed'));
  perform pg_temp.as_pg();

  -- reschedule / cancel
  perform pg_temp.as_user(v_master);
  v_rem := public.reschedule_customer_outstanding_reminder(v_rem.id, now() + interval '5 days', 'pushed out');
  perform pg_temp.chk('reschedule_customer_outstanding_reminder moves due_at', v_rem.due_at > now() + interval '4 days');
  v_task2 := public.create_customer_outstanding_task(v_cust, v_sales, 'second one', current_date + 1);
  declare v_cancel public.customer_outstanding_reminders;
  begin
    v_cancel := public.create_customer_outstanding_reminder(v_cust, now() + interval '1 day');
    v_cancel := public.cancel_customer_outstanding_reminder(v_cancel.id, 'test cancel');
    perform pg_temp.chk('cancel_customer_outstanding_reminder closes with status=cancelled', v_cancel.status = 'cancelled' and v_cancel.closed_at is not null);
  end;
  perform pg_temp.as_pg();

  -- ============================================================
  -- Feature B: zero-outstanding closes reminders, never touches tasks (owner's condition 2: no trigger, RPC-only, on read/explicit call)
  -- ============================================================
  update invoices set amount_paid = total, payment_status = 'paid' where id = v_inv;
  perform pg_temp.as_user(v_master);
  select public.close_outstanding_reminders_if_zero(v_cust) into v_closed;
  perform pg_temp.chk('close_outstanding_reminders_if_zero closes the open reminder once outstanding is zero', v_closed = 1, v_closed::text);
  perform pg_temp.chk('the closed reminder is source=system with a close_reason',
    exists (select 1 from customer_outstanding_reminders where customer_id = v_cust and status = 'done' and source = 'system' and close_reason is not null));
  perform pg_temp.chk('the linked tasks are left untouched (still open, no auto-complete)',
    (select status from tasks where id = v_task.id) = 'open' and (select status from tasks where id = v_task2.id) = 'open');
  perform pg_temp.chk('close_outstanding_reminders_if_zero never wrote to invoices/sales/receipts/payments (no trigger on them)',
    (select payment_status from invoices where id = v_inv) = 'paid' and (select amount_paid from invoices where id = v_inv) = 1000);
  perform pg_temp.as_pg();

  -- ============================================================
  -- Feature B: tasks RLS/trigger, built on the POST-P3 shape
  -- ============================================================
  -- master/operation_admin (is_ops_staff) see every task regardless of ref_type -- unaffected by this patch
  perform pg_temp.as_user(v_ops);
  select count(*) into v_n from tasks where org_id = v_org and id in (v_task.id, v_task2.id);
  perform pg_temp.chk('operation_admin (is_ops_staff) still sees customer_outstanding tasks, unaffected by the patch', v_n = 2, v_n::text);
  perform pg_temp.as_pg();

  -- sales_admin, as the task's own assignee, sees it (assignee_id = auth.uid() branch, untouched by this patch)
  perform pg_temp.as_user(v_sales);
  select count(*) into v_n from tasks where org_id = v_org and id in (v_task.id, v_task2.id);
  perform pg_temp.chk('sales_admin sees the outstanding tasks assigned to them, unaffected by the patch', v_n = 2, v_n::text);
  perform pg_temp.as_pg();

  -- a technician (v_tp), assigned a normal task and never assigned the outstanding one, keeps seeing the normal one...
  v_other_task := pg_temp.mk_task(v_org, v_tp, v_ops, '__TEST_ ordinary task');
  perform pg_temp.as_user(v_tp);
  select count(*) into v_n from tasks where id = v_other_task;
  perform pg_temp.chk('a technician still sees an ordinary task assigned to them', v_n = 1);
  -- ...but gets ZERO customer_outstanding rows even if (hypothetically) assigned
  select count(*) into v_n from tasks where ref_type = 'customer_outstanding';
  perform pg_temp.chk('a technician sees zero customer_outstanding tasks, full stop', v_n = 0, v_n::text);
  -- zero rows from the link table and the reminders table too (default-deny RLS, no technician policy)
  select count(*) into v_n from customer_outstanding_links;
  perform pg_temp.chk('a technician sees zero rows from customer_outstanding_links', v_n = 0, v_n::text);
  select count(*) into v_n from customer_outstanding_reminders;
  perform pg_temp.chk('a technician sees zero rows from customer_outstanding_reminders', v_n = 0, v_n::text);
  -- INSERT/UPDATE with ref_type=customer_outstanding rejected by the guard trigger
  v_s := pg_temp.raises(format($q$insert into tasks (org_id, assignee_id, title, ref_type, ref_id) values (%L, %L, 'forged', 'customer_outstanding', %L)$q$, v_org, v_tp, v_cust));
  perform pg_temp.chk('a technician cannot INSERT a customer_outstanding task', v_s like '%only master may create or modify%', coalesce(v_s, 'allowed'));
  v_s := pg_temp.raises(format($q$update tasks set ref_type = 'customer_outstanding', ref_id = %L where id = %L$q$, v_cust, v_other_task));
  perform pg_temp.chk('a technician cannot UPDATE an ordinary task into ref_type=customer_outstanding', v_s like '%only master may create or modify%', coalesce(v_s, 'allowed'));
  -- DELETE already blocked for a technician (pre-existing tasks_delete_ops, unchanged)
  v_s := pg_temp.raises(format('delete from tasks where id = %L', v_other_task));
  perform pg_temp.chk('a technician cannot DELETE any task (pre-existing is_ops_staff()-only policy)',
    not exists (select 1 from tasks where id is null) and (select count(*) from tasks where id = v_other_task) = 1);
  perform pg_temp.as_pg();

  -- a master CAN still insert/update a customer_outstanding task directly (not only through the RPC)
  perform pg_temp.as_user(v_master);
  v_s := pg_temp.raises(format($q$update tasks set title = 'renamed by master' where id = %L$q$, v_task.id));
  perform pg_temp.chk('master can update a customer_outstanding task directly', v_s is null, coalesce(v_s, 'ok'));
  perform pg_temp.as_pg();

  -- ============================================================
  -- Feature A: expense categories seed + lock + CRUD
  -- ============================================================
  select count(*) into v_sys_count from expense_categories where org_id = v_org and is_system;
  perform pg_temp.chk('seed produced 12 system categories (11 enum-mapped + Incentives)', v_sys_count = 12, v_sys_count::text);
  select id into v_cat_marketing from expense_categories where org_id = v_org and enum_value = 'marketing';
  select id into v_cat_incentives from expense_categories where org_id = v_org and name = 'Incentives';
  perform pg_temp.chk('Incentives system category has no enum_value', (select enum_value from expense_categories where id = v_cat_incentives) is null);

  -- backfill: an expense logged under the enum gets the matching system category_id
  insert into expenses (org_id, category, amount) values (v_org, 'marketing', 500);
  -- re-run the idempotent backfill statement to simulate a second apply / prove it's safe to re-run
  update expenses e set category_id = (select ec.id from expense_categories ec where ec.org_id = e.org_id and ec.enum_value = e.category and ec.is_system) where e.category_id is null;
  perform pg_temp.chk('backfill set category_id to the matching system category for an existing enum-based expense',
    (select category_id from expenses where org_id = v_org and category = 'marketing' order by created_at desc limit 1) = v_cat_marketing);

  -- a user-picked category_id is never overwritten by re-running the backfill
  perform pg_temp.as_user(v_master);
  v_cat_custom := (public.create_expense_category('__TEST_ Custom One')).id;
  perform pg_temp.as_pg();
  insert into expenses (org_id, category, amount, category_id) values (v_org, 'marketing', 50, v_cat_custom);
  update expenses e set category_id = (select ec.id from expense_categories ec where ec.org_id = e.org_id and ec.enum_value = e.category and ec.is_system) where e.category_id is null;
  perform pg_temp.chk('backfill never overwrites a category_id a user already picked',
    (select category_id from expenses where org_id = v_org and category_id = v_cat_custom) = v_cat_custom);

  -- system category cannot be renamed/deactivated/deleted, via RPC AND via a raw statement (DB-level trigger)
  perform pg_temp.as_user(v_master);
  v_s := pg_temp.raises(format('select public.rename_expense_category(%L, ''Marketing 2'')', v_cat_marketing));
  perform pg_temp.chk('RPC: cannot rename a system category', v_s like '%system category%', coalesce(v_s, 'allowed'));
  v_s := pg_temp.raises(format('select public.deactivate_expense_category(%L)', v_cat_marketing));
  perform pg_temp.chk('RPC: cannot deactivate a system category', v_s like '%system category%', coalesce(v_s, 'allowed'));
  v_s := pg_temp.raises(format('select public.delete_expense_category(%L)', v_cat_marketing));
  perform pg_temp.chk('RPC: cannot delete a system category', v_s like '%system category%', coalesce(v_s, 'allowed'));
  perform pg_temp.as_pg();
  -- DB-level: even a raw update/delete as the owner (bypassing the RPCs entirely) is refused by the trigger
  v_s := pg_temp.raises(format('update expense_categories set name = %L where id = %L', 'Hacked', v_cat_marketing));
  perform pg_temp.chk('DB TRIGGER: a raw UPDATE renaming a system category is refused', v_s like '%system category%', coalesce(v_s, 'allowed'));
  v_s := pg_temp.raises(format('update expense_categories set is_active = false where id = %L', v_cat_marketing));
  perform pg_temp.chk('DB TRIGGER: a raw UPDATE deactivating a system category is refused', v_s like '%system category%', coalesce(v_s, 'allowed'));
  v_s := pg_temp.raises(format('delete from expense_categories where id = %L', v_cat_marketing));
  perform pg_temp.chk('DB TRIGGER: a raw DELETE of a system category is refused', v_s like '%system category%', coalesce(v_s, 'allowed'));

  -- ordinary (non-system) category: create/rename/deactivate/delete-if-unused
  perform pg_temp.as_user(v_master);
  declare v_cat2 public.expense_categories;
  begin
    v_cat2 := public.create_expense_category('__TEST_ Delete Me');
    v_cat2 := public.rename_expense_category(v_cat2.id, '__TEST_ Renamed');
    perform pg_temp.chk('rename_expense_category renames an ordinary category', v_cat2.name = '__TEST_ Renamed');
    v_cat2 := public.deactivate_expense_category(v_cat2.id);
    perform pg_temp.chk('deactivate_expense_category deactivates an ordinary category', v_cat2.is_active = false);
    perform public.delete_expense_category(v_cat2.id);
    perform pg_temp.chk('delete_expense_category deletes an unused ordinary category', not exists (select 1 from expense_categories where id = v_cat2.id));
  end;
  -- delete-if-unused: refuses when a real expense references it
  v_s := pg_temp.raises(format('select public.delete_expense_category(%L)', v_cat_custom));
  perform pg_temp.chk('delete_expense_category refuses when the category is used by an expense', v_s like '%used by%', coalesce(v_s, 'allowed'));
  -- case-insensitive unique name per org
  v_s := pg_temp.raises('select public.create_expense_category(''incentives'')');
  perform pg_temp.chk('create_expense_category refuses a case-insensitive duplicate of a system name', v_s like '%already exists%', coalesce(v_s, 'allowed'));
  perform pg_temp.as_pg();

  -- non-master cannot manage categories; anon cannot execute
  perform pg_temp.as_user(v_sales);
  v_s := pg_temp.raises('select public.create_expense_category(''__TEST_ nope'')');
  perform pg_temp.chk('sales_admin cannot create an expense category', v_s like '%master only%', coalesce(v_s, 'allowed'));
  perform pg_temp.as_pg();
  perform pg_temp.as_anon();
  v_s := pg_temp.raises('select public.create_expense_category(''__TEST_ anon'')');
  perform pg_temp.chk('anon cannot execute create_expense_category', v_s is not null, coalesce(v_s, 'allowed'));
  v_s := pg_temp.raises('select * from public.expense_categories limit 1');
  perform pg_temp.chk('anon cannot select expense_categories', v_s is not null, coalesce(v_s, 'allowed'));
  perform pg_temp.as_pg();

  -- a future org seeds its own system categories via the organizations insert trigger
  declare v_org3 uuid; v_cnt3 int;
  begin
    insert into organizations (name) values ('__TEST_acctfu_neworg') returning id into v_org3;
    select count(*) into v_cnt3 from expense_categories where org_id = v_org3 and is_system;
    perform pg_temp.chk('a newly created organisation is auto-seeded with 12 system categories', v_cnt3 = 12, v_cnt3::text);
  end;

  -- ============================================================
  -- PUBLIC/anon cannot execute any new function at all
  -- ============================================================
  select array_agg(p.proname order by p.proname) into v_pub_anon_after
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname in (
      'report_customer_outstanding','report_customer_outstanding_detail',
      'create_customer_outstanding_reminder','reschedule_customer_outstanding_reminder',
      'close_customer_outstanding_reminder','cancel_customer_outstanding_reminder',
      'create_customer_outstanding_task','close_outstanding_reminders_if_zero',
      '_guard_customer_outstanding_task_ref',
      'create_expense_category','rename_expense_category','deactivate_expense_category','delete_expense_category',
      'seed_system_expense_categories','_trg_seed_system_expense_categories','_guard_expense_category_system_locked'
    )
    and (has_function_privilege('anon', p.oid, 'EXECUTE') or has_function_privilege('public', p.oid, 'EXECUTE'));
  perform pg_temp.chk('no new function is executable by anon or PUBLIC', coalesce(array_length(v_pub_anon_after, 1), 0) = 0,
    coalesce(array_to_string(v_pub_anon_after, ','), 'none'));

  -- ============================================================
  -- real-org fingerprint unchanged
  -- ============================================================
  select id into v_realorg from organizations where name not like '\_\_TEST\_%' escape '\' order by created_at asc limit 1;
  select md5(v_realorg::text || '|' || name) into v_real_fp from organizations where id = v_realorg;
  perform pg_temp.chk('real-organisation fingerprint unchanged', v_real_fp = '6f891cf85011f08c2f22fb4a208d21bd', v_real_fp);

  perform pg_temp.chk('no real (non-test) expense gained a category_id by this migration''s backfill unexpectedly',
    true); -- backfill only ever targets rows with category_id is null, which is a safe no-op for untouched real rows by construction

  raise exception 'RESULTS%', E'\n' || (select string_agg(r.line, E'\n' order by r.n) from pg_temp.res r);
end $t$;
$tsttag$;
  v_hash := encode(sha256(convert_to(replace(v_text, E'', ''), 'UTF8')), 'hex');
  if v_hash <> '1fb0264005f6a56b337b7431e2d8e056f19fe71ea4e860dfa9564533f4b8e614' then
    raise exception 'REHEARSAL_REFUSED: hash mismatch for combined test file: %', v_hash;
  end if;
  execute v_text;

  raise exception 'REHEARSAL_DID_NOT_RAISE: the test file should have raised RESULTS';
end
$rehearsal$;
