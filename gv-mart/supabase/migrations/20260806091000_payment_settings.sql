-- QR Payment + Gated Completion Code — admin-configured UPI payment
-- destination. One typed row per org, same deliberate deviation from a
-- generic key/value table as `settings` itself (20260701091100_system.sql):
-- "the single source of truth", not two places to look.
create table public.payment_settings (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null unique references public.organizations (id) on delete cascade,
  merchant_name text not null default '',
  -- UPI VPA format (handle@bank), e.g. "gvmart@okhdfcbank". Mirrored
  -- client-side (lib/upi.ts's UPI_ID_REGEX) so the admin form fails fast —
  -- this CHECK is the server-side backstop, never trusting the client alone.
  -- Empty string is allowed so a freshly-inserted, not-yet-configured row
  -- can exist without failing this constraint; payment_enabled (below)
  -- staying false is what actually keeps an unconfigured row from being
  -- usable.
  -- {2,64} not {2,256}: Postgres's bundled regex engine caps interval
  -- repetition counts at 255 (RE_DUP_MAX) — see the fix migration
  -- 20260806095000 for the "invalid repetition count(s)" bug this avoids.
  upi_id text not null default '' check (upi_id = '' or upi_id ~ '^[\w.-]{2,64}@[a-zA-Z]{2,64}$'),
  phone_number text,
  -- Defaults false: a freshly-created row (before the admin has ever saved
  -- real values) must never silently offer UPI collection with a blank/
  -- garbage upi_id. Toggled independently afterwards.
  payment_enabled boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger set_updated_at
  before update on public.payment_settings
  for each row execute function public.set_updated_at();

alter table public.payment_settings enable row level security;

-- Staff and technicians read their own org's row in full — no more
-- sensitive to them than any other operational config already visible via
-- settings_select_org. Technicians need this to know whether to even offer
-- "UPI" as a selectable payment method on the on-site Payment step.
create policy payment_settings_select_staff on public.payment_settings
  for select using (org_id = public.current_org_id());

-- Customers have no `profiles` row (current_org_id() resolves via profiles
-- and would return null for them), so scope instead through their own
-- ticket — same join shape as service_visit_otps_select_customer
-- (20260725110000_otp_completion_confirmation.sql).
create policy payment_settings_select_customer on public.payment_settings
  for select using (
    exists (
      select 1 from public.service_tickets t
      where t.org_id = payment_settings.org_id and t.customer_id = public.current_customer_id()
    )
  );

-- Master only — this is financial/payment-destination config.
create policy payment_settings_write_master on public.payment_settings
  for all using (org_id = public.current_org_id() and public.is_master())
  with check (org_id = public.current_org_id() and public.is_master());

create trigger audit_payment_settings after insert or update or delete on public.payment_settings
  for each row execute function public.audit_master_change();

-- Realtime: the customer's payment screen regenerates its QR live the
-- moment an admin changes the UPI id/merchant name/enable toggle, without a
-- page refresh — same idempotent-publication pattern as every other
-- realtime table added in this codebase (e.g.
-- 20260805140000_service_tickets_realtime.sql).
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'payment_settings'
  ) then
    alter publication supabase_realtime add table payment_settings;
  end if;
end $$;
