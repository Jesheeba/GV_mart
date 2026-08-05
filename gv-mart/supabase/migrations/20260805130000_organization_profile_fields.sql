-- Printable documents (invoices/quotations) need the org's postal address and
-- phone number in the letterhead — organizations previously only carried
-- name + gst_no, so there was nowhere to source these from.
alter table organizations add column address text;
alter table organizations add column phone text;
