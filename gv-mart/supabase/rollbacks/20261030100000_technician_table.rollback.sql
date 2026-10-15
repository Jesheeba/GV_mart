-- Rollback for 20261030100000_technician_table.sql.
-- REFUSES while any holiday row exists or any invoice carries a referral stamp: that data would be lost. Export first
--   select * from org_holidays;  select id, referred_by_technician_id from invoices where referred_by_technician_id is not null;
-- then delete / null them deliberately.
begin;
do $g$
begin
  if exists (select 1 from public.org_holidays) then
    raise exception 'rollback refused: org_holidays has rows (export them, then delete them deliberately)';
  end if;
  if exists (select 1 from public.invoices where referred_by_technician_id is not null) then
    raise exception 'rollback refused: invoices.referred_by_technician_id has values (export, then set to null deliberately)';
  end if;
end $g$;

drop function if exists public.report_technician_table(date, date);
drop trigger if exists invoices_stamp_referral on public.invoices;
drop function if exists public._trg_invoice_stamp_referral();
drop index if exists public.invoices_referred_by_idx;
alter table public.invoices drop column if exists referred_by_technician_id;
drop table if exists public.org_holidays;

notify pgrst, 'reload schema';
commit;
