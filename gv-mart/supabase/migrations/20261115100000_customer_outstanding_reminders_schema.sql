-- Accounts follow-up, Feature B, step 1 of 5 — the new internal-only
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
