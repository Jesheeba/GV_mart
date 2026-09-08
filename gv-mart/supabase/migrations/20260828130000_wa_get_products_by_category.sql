-- Fix for a real bug found in live testing: the product-availability
-- keyword answer (whatsapp-status-answers.ts) called wa_get_product_price
-- with a bare category code ("ro") as p_search — that RPC tries a NAME
-- substring match FIRST (`p.name ilike '%ro%'`), which matched "Amaron
-- Current 150Ah Battery" purely because "Amaron" contains "ro" as a
-- substring (Ama-RO-n). A customer asking "do you have RO in stock" got a
-- battery in the answer.
--
-- This RPC does ONLY the exact category match — no name substring phase
-- at all, so this class of collision can't happen here regardless of what
-- future products get added. Same query shape as wa_get_product_price's
-- own category-fallback block (20260827090000), just without the
-- name-match phase that caused the bug.
create or replace function public.wa_get_products_by_category(p_org_id uuid, p_category text)
returns jsonb
language sql
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(x order by x.name), '[]'::jsonb)
  from (
    select p.id as product_id, p.name, b.name as brand, p.category
    from public.products p
    left join public.brands b on b.id = p.brand_id
    where p.org_id = p_org_id and p.is_active = true and p.category::text = p_category
    limit 10
  ) x;
$$;

-- Intentionally NOT granted to authenticated — service_role only (also
-- covered automatically by the default-privilege override in
-- 20260827094500_fix_wa_function_grant_lockdown_v2.sql).
