-- AI/CRM keyword-answer coverage — EMI question ("do you offer EMI?").
-- Same shape/security posture as wa_get_business_info (20260827130000):
-- SECURITY DEFINER, org-wide static config, no phone/identity param.
-- settings.emi_enabled/emi_tenure_months/emi_disclaimer already existed
-- (Product Enquiry rebuild, 2026-08-04) for the customer-facing product
-- page's EMI display — this just exposes the same real, live values to
-- the WhatsApp bot's deterministic keyword answer, not a new data source.
create or replace function public.wa_get_emi_info(p_org_id uuid)
returns jsonb
language sql
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'emi_enabled', emi_enabled,
    'emi_tenure_months', emi_tenure_months,
    'emi_disclaimer', emi_disclaimer
  )
  from public.settings
  where org_id = p_org_id;
$$;

-- Intentionally NOT granted to authenticated — service_role only (also
-- covered automatically by the default-privilege override in
-- 20260827094500_fix_wa_function_grant_lockdown_v2.sql).
