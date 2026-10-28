-- Accounts follow-up, Feature B, step 2 of 5 — the customer/invoice/amount
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
