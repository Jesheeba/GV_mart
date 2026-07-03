-- Fix: Phase 6's sell_amc_plan (20260702110100_service_amc_functions.sql)
-- logs a plan's included gift via `insert into gift_logs (..., invoice_id, ...)
-- values (..., null, ...)` for AMC sales made outside the New Sale flow
-- (ADM-12's standalone "Sell AMC" button has no invoice at all). gift_logs.
-- invoice_id was `not null` since Phase 1 (20260701090500_sales.sql), which
-- would reject that insert. A gift can legitimately be logged without an
-- invoice, so the column becomes nullable rather than forcing every AMC sale
-- through the invoiced New Sale flow.
alter table gift_logs alter column invoice_id drop not null;
