-- Product Lifecycle & Automated Service Reminder System — Drop 2, migration 1/3.
-- Sales Daily Follow-ups must be actionable (owner amendment 2): Mark contacted (+note),
-- Snooze (pick a date), Create service request. Logged as an append-only action history,
-- NOT as lead_followups rows (that table's postpone/stuck/outcome invariants are lead-specific
-- and would be corrupted by a non-lead row type — see DECISIONS.md #13).

alter table public.customer_part_schedules
  add column snoozed_until date;
-- Snoozing is a SALES-SIDE deferral of being nagged about it, not a change to the real due
-- date: customer/technician alerts and status computation are completely unaffected by this
-- column — only the Sales Daily Follow-ups surfacing query reads it.

create table public.lifecycle_followup_actions (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  customer_part_schedule_id uuid not null references public.customer_part_schedules (id) on delete cascade,
  action_type text not null check (action_type in ('contacted', 'snoozed', 'service_request_created')),
  note text,
  snoozed_until date,
  service_ticket_id uuid references public.service_tickets (id),
  created_by uuid references public.profiles (id),
  created_at timestamptz not null default now()
);

create index lifecycle_followup_actions_schedule_idx
  on public.lifecycle_followup_actions (customer_part_schedule_id);
create index lifecycle_followup_actions_org_idx on public.lifecycle_followup_actions (org_id);

create trigger audit_lifecycle_followup_actions after insert or update or delete
  on public.lifecycle_followup_actions for each row execute function public.audit_master_change();

alter table public.lifecycle_followup_actions enable row level security;

create policy lifecycle_followup_actions_select_sales on public.lifecycle_followup_actions
  for select using (org_id = public.current_org_id() and public.is_sales_staff());

revoke all on public.lifecycle_followup_actions from public, anon;
grant select, insert on public.lifecycle_followup_actions to authenticated;
