-- Incentive audit, Finding H-01 (High) — "Log to Accounts" has no DB-side function,
-- no link back to the salary row, and no duplicate guard.
--
-- Covers BOTH posting paths that write expenses.category='salary':
--   - Technician payroll: SalaryTab's "Log to Accounts" button, posting a `salaries`
--     row (computed by compute_salary()).
--   - Non-technician staff salary: StaffSalaryTab's "Log Salary" button, a manually
--     typed amount with NO underlying `salaries` row at all (audit: "the staff path
--     has zero protection" — it didn't even have the client-side `alreadyLogged`
--     check the technician path had).
--
-- Design: additive, nullable `expenses.salary_id` traces a technician-path row back
-- to the exact `salaries` row it came from (the audit's own suggested fix — populate
-- the unused `ref_id`-style link, done here as a dedicated typed column instead of
-- reusing the untyped `ref_id`, which already means different things for other
-- categories). Idempotency is enforced by TWO partial unique indexes, not app logic,
-- so two simultaneous clicks (or a retry after a timeout) can never both succeed:
--   1. expenses_salary_once_idx — one expense per `salaries` row, ever (technician path).
--   2. expenses_staff_salary_month_once_idx — one NON-voided manual staff-salary
--      expense per (staff_id, month) when there is no `salaries` row to key off
--      (non-technician path). `voided_at is null` in the partial predicate is what
--      lets a master re-log a corrected amount after Finding H-03's reopen/void flow
--      (20261117100001) voids the previous one — re-logging is a deliberate NEW
--      action, not the double-post this finding closes.
--
-- Both posting paths now go through ONE SECURITY DEFINER RPC,
-- `log_salary_to_accounts`, instead of the bare `supabase.from("expenses").insert()`
-- the audit found (src/services/reports.ts createExpense, called directly from
-- SalaryTab.tsx/StaffSalaryTab.tsx) — master-only, same as the existing UI gate, but
-- now enforced in the database rather than only in the React components. A second
-- attempt (including a true concurrent double-click, caught via the unique index
-- rather than a race-prone "check then insert") is a clean, non-raising no-op that
-- returns the date it was already logged on.
--
-- `voided_at`/`voided_by`/`void_reason` are added here (not in 20261117100001) because
-- the unique index above already needs them in its predicate; H-03's reopen flow is
-- the thing that SETS them.

alter table public.expenses
  add column if not exists salary_id uuid references public.salaries (id) on delete set null,
  add column if not exists voided_at timestamptz,
  add column if not exists voided_by uuid references public.profiles (id) on delete set null,
  add column if not exists void_reason text;

-- `locked_at`/`logged_expense_id` belong conceptually to Finding H-03's lock/reopen
-- flow (20261117100001), but log_salary_to_accounts below needs to set/read them in
-- the SAME transaction as the insert it guards, so both columns are added here,
-- additive and nullable, where the table they extend is first touched; 20261117100001
-- adds the enforcement (compute_salary refusal) and the reopen RPC that clears them.
alter table public.salaries
  add column if not exists locked_at timestamptz,
  add column if not exists logged_expense_id uuid references public.expenses (id) on delete set null;

create index if not exists expenses_salary_id_idx on public.expenses (salary_id) where salary_id is not null;

-- One NON-VOIDED posted expense per salaries row, ever. Independent-review fix
-- (2026-10-29, caught before apply): an earlier draft of this predicate omitted
-- `voided_at is null`, which — combined with reopen_salary_posting()
-- (20261117100001) voiding the old expense and clearing salaries.locked_at/
-- logged_expense_id, but NOT touching the old expense row's own salary_id/category
-- — would have made the stale, now-voided expense row still match this index,
-- so a fresh log_salary_to_accounts() call for the same salary_id would hit the
-- unique_violation handler and incorrectly report the corrected salary as
-- "already logged" (pointing at the voided row), permanently blocking the entire
-- reopen-and-relog flow this migration's own header describes. `voided_at is null`
-- below matches the staff-month index's predicate for the same reason: a voided
-- row must never count toward "already posted" for either path.
create unique index if not exists expenses_salary_once_idx
  on public.expenses (salary_id)
  where category = 'salary' and salary_id is not null and voided_at is null;

-- Non-technician staff path has no salaries row to key off; the natural key is
-- staff + calendar month. Excludes voided rows so a corrected re-log after a
-- master's reopen/void (H-03) is never blocked by the very row it replaced.
-- date_trunc('month', date::timestamp) rather than bare date_trunc('month', date):
-- the plain-date overload of date_trunc that Postgres otherwise resolves to is only
-- STABLE (not IMMUTABLE — it is implemented by promoting to timestamptz, which is
-- timezone-dependent), and an index expression requires IMMUTABLE. Forcing the
-- ::timestamp (not timestamptz) cast first picks the genuinely IMMUTABLE overload;
-- a `date` value has no time-of-day or timezone component to begin with, so this
-- changes no behaviour, only which overload gets resolved.
create unique index if not exists expenses_staff_salary_month_once_idx
  on public.expenses (staff_id, date_trunc('month', date::timestamp))
  where category = 'salary' and salary_id is null and staff_id is not null and voided_at is null;

-- log_salary_to_accounts: the only supported way to post a salary expense from now
-- on. Both call sites (SalaryTab, StaffSalaryTab) are switched to call this instead
-- of createExpense() directly — see src/services/hr.ts logSalaryToAccounts().
--
-- p_salary_id null => non-technician manual staff entry (StaffSalaryTab).
-- p_salary_id set  => technician payroll row (SalaryTab); the row must exist, belong
--                     to this org, and its technician's profile must equal p_staff_id
--                     (defense in depth against a client sending a mismatched pair).
--
-- On success for the technician path, the SAME transaction marks the `salaries` row
-- locked (locked_at, logged_expense_id) — Finding H-03, 20261117100001 adds the
-- columns and the compute_salary() refusal that reads them; this function only sets
-- them so the two migrations compose correctly regardless of apply order within the
-- same release (both are being applied together here).
create or replace function public.log_salary_to_accounts(
  p_org_id uuid,
  p_staff_id uuid,
  p_amount numeric,
  p_date date,
  p_note text default null,
  p_salary_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_logged_by uuid := auth.uid();
  v_expense_id uuid;
  v_salary record;
  v_existing_date date;
  v_existing_id uuid;
begin
  if not public.is_master() then
    raise exception 'log_salary_to_accounts: master role required';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'log_salary_to_accounts: org mismatch';
  end if;
  if p_staff_id is null then
    raise exception 'log_salary_to_accounts: p_staff_id is required';
  end if;
  if p_amount is null or p_amount < 0 then
    raise exception 'log_salary_to_accounts: amount must be zero or positive';
  end if;
  if not exists (select 1 from public.profiles where id = p_staff_id and org_id = p_org_id) then
    raise exception 'log_salary_to_accounts: staff % not found in org %', p_staff_id, p_org_id;
  end if;

  if p_salary_id is not null then
    select s.*, t.profile_id into v_salary
    from public.salaries s
    join public.technicians t on t.id = s.technician_id
    where s.id = p_salary_id and s.org_id = p_org_id;

    if v_salary is null then
      raise exception 'log_salary_to_accounts: salary row % not found in org %', p_salary_id, p_org_id;
    end if;
    if v_salary.profile_id is distinct from p_staff_id then
      raise exception 'log_salary_to_accounts: staff % does not match the technician on salary row %', p_staff_id, p_salary_id;
    end if;
    if v_salary.locked_at is not null then
      -- Already logged (or the row is locked without an expense somehow) — report
      -- the existing date rather than attempting a second insert.
      select date into v_existing_date from public.expenses where id = v_salary.logged_expense_id;
      return jsonb_build_object(
        'inserted', false,
        'expense_id', v_salary.logged_expense_id,
        'already_logged_at', v_existing_date,
        'message', format('already logged on %s', coalesce(v_existing_date::text, 'an earlier date'))
      );
    end if;
  end if;

  begin
    insert into public.expenses (org_id, category, amount, date, note, staff_id, salary_id, logged_by)
    values (p_org_id, 'salary', p_amount, coalesce(p_date, current_date), p_note, p_staff_id, p_salary_id, v_logged_by)
    returning id into v_expense_id;
  exception when unique_violation then
    -- Someone else (or this same click, doubled) got there first in the gap between
    -- this transaction starting and now — find what they logged and report it as a
    -- clean no-op instead of surfacing a raw constraint error to the UI.
    if p_salary_id is not null then
      select id, date into v_existing_id, v_existing_date
      from public.expenses where salary_id = p_salary_id and category = 'salary' and voided_at is null;
    else
      select id, date into v_existing_id, v_existing_date
      from public.expenses
      where staff_id = p_staff_id and category = 'salary' and salary_id is null and voided_at is null
        and date_trunc('month', date::timestamp) = date_trunc('month', coalesce(p_date, current_date)::timestamp)
      order by created_at desc limit 1;
    end if;
    return jsonb_build_object(
      'inserted', false,
      'expense_id', v_existing_id,
      'already_logged_at', v_existing_date,
      'message', format('already logged on %s', coalesce(v_existing_date::text, 'an earlier date'))
    );
  end;

  if p_salary_id is not null then
    update public.salaries
      set locked_at = now(), logged_expense_id = v_expense_id
      where id = p_salary_id;
  end if;

  return jsonb_build_object(
    'inserted', true,
    'expense_id', v_expense_id,
    'already_logged_at', null,
    'message', 'logged'
  );
end;
$$;

revoke all on function public.log_salary_to_accounts(uuid, uuid, numeric, date, text, uuid) from public, anon, authenticated;
grant execute on function public.log_salary_to_accounts(uuid, uuid, numeric, date, text, uuid) to authenticated;
