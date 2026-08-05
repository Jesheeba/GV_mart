-- QR Payment + Gated Completion Code — the customer's payment screen needs
-- invoices.payment_status to flip to 'paid' live (no refresh) the moment
-- the technician taps "Payment received". Same idempotent-publication
-- pattern as 20260805140000_service_tickets_realtime.sql.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'invoices'
  ) then
    alter publication supabase_realtime add table invoices;
  end if;
end $$;
