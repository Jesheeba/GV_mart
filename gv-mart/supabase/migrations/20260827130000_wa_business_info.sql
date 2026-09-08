-- AI/CRM Answer Layer — "what's your address / phone number / hours"
-- capability. organizations already holds name/address/phone (used today
-- for invoice/quotation letterhead, see OrgProfileCard in SettingsTab.tsx)
-- and address/phone are already nullable + null for this org today — that
-- IS the "empty by default, no placeholder" state the task asked for, no
-- backfill needed. business_hours is the one genuinely new field: there's
-- no existing customer-facing "we're open X-Y" text anywhere (work_start/
-- work_end on settings are staff attendance/SLA inputs, a different concern
-- from what a customer should be told).
alter table public.organizations
  add column business_hours text;

-- ── wa_get_business_info — same shape/security posture as the other 4
-- Answer Layer RPCs (20260827090000): SECURITY DEFINER, not granted to
-- anon/authenticated (also covered automatically by the default-privilege
-- override in 20260827094500). No phone/identity param at all — org-wide
-- static data, same "no identity check" reasoning as wa_get_product_price.
-- Returns the raw columns as-is (including nulls) rather than pre-building
-- a message — the Answer Layer's own model composes the reply and already
-- has the instruction (SYSTEM_PROMPT) to say "don't have that yet" on a
-- null field rather than invent one; this RPC's job is just to report truth.
create or replace function public.wa_get_business_info(p_org_id uuid)
returns jsonb
language sql
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'business_name', name,
    'address', address,
    'phone', phone,
    'business_hours', business_hours
  )
  from public.organizations
  where id = p_org_id;
$$;

-- Intentionally NOT granted to authenticated — service_role only.
