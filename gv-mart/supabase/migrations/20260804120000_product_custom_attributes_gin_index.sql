-- Product Enquiry rebuild (2026-08-04), Phase 6 hardening.
--
-- Filtering the catalog by a custom attribute (products.custom_attributes
-- ->> 'key-id' = 'value') would force a sequential scan without this —
-- added proactively now that the catalog's filter-chip UI exists (Phase 6)
-- and could grow to reference custom attributes later, even though today's
-- chip filters only cover category/brand/price_range (the base columns
-- already in the lean grid select). This index closes the gap without
-- changing the jsonb design itself.
create index if not exists products_custom_attributes_gin_idx on public.products using gin (custom_attributes);
