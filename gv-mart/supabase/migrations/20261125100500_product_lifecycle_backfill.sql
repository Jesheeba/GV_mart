-- Product Lifecycle & Automated Service Reminder System — Drop 1, migration 6/8.
-- One-time backfill of existing installations_logged rows into
-- customer_installed_products. Amendment 1: installation_date defaults from
-- the earliest recorded event for that (customer, product) pair (the visit's
-- created_at, which is the only date this stack has today for an existing
-- installation) and is explicitly marked unconfirmed so the Master UI shows
-- it as correctable, not authoritative.

do $$
declare
  v_row record;
begin
  for v_row in
    select il.customer_id, il.product_id, min(il.created_at)::date as earliest_date,
           (array_agg(il.visit_id order by il.created_at))[1] as earliest_visit_id
    from (
      select st.customer_id, l.product_id, l.created_at, l.visit_id
      from public.installations_logged l
      join public.service_visits v on v.id = l.visit_id
      join public.service_tickets st on st.id = v.ticket_id
    ) il
    group by il.customer_id, il.product_id
    having not exists (
      select 1 from public.customer_installed_products cip
      where cip.customer_id = il.customer_id and cip.product_id = il.product_id
    )
  loop
    perform public.create_installed_product(
      v_row.customer_id, v_row.product_id, v_row.earliest_date, v_row.earliest_visit_id, true
    );
  end loop;
end $$;
