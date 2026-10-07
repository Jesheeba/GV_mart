-- New Lead form: "Enquiry type" replaced by the product type being enquired
-- about (RO / AC / Inverter / Battery), and the inventory picker replaced by a
-- free-text client-instruction note. Both optional; enquiry_type is untouched
-- (automation flows still key off it).
alter table public.leads
  add column if not exists product_category public.brand_category,
  add column if not exists notes text;
