-- Task 7 (Customer Dashboard enhancement spec, 2026-07-30): server-side
-- filtering + pagination for the customer app's Bookings list. The previous
-- listMyTickets() fetched the customer's ENTIRE ticket history unbounded and
-- filtered client-side into just two static Upcoming/Past buckets.
--
-- Two RPCs:
--   1. list_my_tickets_filtered — the main paginated/filtered query. Uses a
--      single `filtered` CTE reused by both the total count and the page
--      slice (rather than duplicating the WHERE clause), and shapes nested
--      product/appointment/technician/amc data via correlated subqueries
--      (not FROM-clause joins) so a ticket can never appear more than once
--      even if it somehow had multiple appointment rows.
--   2. list_my_ticket_technicians — small helper for the "Assigned
--      Technician" filter dropdown: only technicians who have actually
--      served this customer (not the whole org's roster).
--
-- Note: the spec's Product Type filter list (RO/AC/Inverter/Washing
-- Machine/Refrigerator/Others) doesn't match this app's actual product
-- category enum (`brand_category`: ro/ac/inverter/battery, see
-- 20260701090300_catalog_inventory.sql) — the filter uses the real
-- categories so it never silently returns zero rows for a type the org
-- doesn't actually sell.

create or replace function public.list_my_tickets_filtered(
  p_from_date date default null,
  p_to_date date default null,
  p_product_category text default null,
  p_status ticket_status default null,
  p_amc_status amc_status default null,
  p_service_type ticket_type default null,
  p_technician_id uuid default null,
  p_booking_number text default null,
  p_search text default null,
  p_limit integer default 20,
  p_offset integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_customer_id uuid;
  v_total bigint;
  v_items jsonb;
begin
  v_customer_id := public.current_customer_id();
  if v_customer_id is null then
    raise exception 'list_my_tickets_filtered: caller is not a customer';
  end if;

  with filtered as (
    select st.*
    from public.service_tickets st
    where st.customer_id = v_customer_id
      and (p_from_date is null or st.created_at::date >= p_from_date)
      and (p_to_date is null or st.created_at::date <= p_to_date)
      and (p_status is null or st.status = p_status)
      and (p_service_type is null or st.type = p_service_type)
      and (
        p_product_category is null
        or exists (select 1 from public.products p where p.id = st.product_id and p.category::text = p_product_category)
      )
      and (
        p_amc_status is null
        or exists (select 1 from public.amc_contracts ac where ac.id = st.contract_id and ac.status = p_amc_status)
      )
      and (
        p_technician_id is null
        or exists (select 1 from public.appointments ap where ap.ticket_id = st.id and ap.technician_id = p_technician_id)
      )
      and (p_booking_number is null or btrim(p_booking_number) = '' or st.id::text ilike btrim(p_booking_number) || '%')
      and (
        p_search is null or btrim(p_search) = ''
        or st.name_of_complaint ilike '%' || btrim(p_search) || '%'
        or st.nature_of_complaint ilike '%' || btrim(p_search) || '%'
      )
  ),
  paged as (
    select * from filtered order by created_at desc limit p_limit offset p_offset
  )
  select
    (select count(*) from filtered),
    coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'id', pg.id,
            'status', pg.status,
            'type', pg.type,
            'name_of_complaint', pg.name_of_complaint,
            'nature_of_complaint', pg.nature_of_complaint,
            'created_at', pg.created_at,
            'product', (
              select jsonb_build_object('id', p.id, 'name', p.name, 'category', p.category)
              from public.products p where p.id = pg.product_id
            ),
            'appointment', (
              select jsonb_build_object(
                'id', ap.id,
                'scheduled_at', ap.scheduled_at,
                'mode', ap.mode,
                'status', ap.status,
                'technician', (
                  select jsonb_build_object('id', t.id, 'full_name', pr.full_name)
                  from public.technicians t join public.profiles pr on pr.id = t.profile_id
                  where t.id = ap.technician_id
                )
              )
              from public.appointments ap where ap.ticket_id = pg.id
              order by ap.created_at desc limit 1
            ),
            'amc_status', (select ac.status from public.amc_contracts ac where ac.id = pg.contract_id)
          )
          order by pg.created_at desc
        )
        from paged pg
      ),
      '[]'::jsonb
    )
  into v_total, v_items;

  return jsonb_build_object('items', v_items, 'total_count', v_total);
end;
$$;

grant execute on function public.list_my_tickets_filtered(
  date, date, text, ticket_status, amc_status, ticket_type, uuid, text, text, integer, integer
) to authenticated;

create or replace function public.list_my_ticket_technicians()
returns table (technician_id uuid, full_name text)
language sql
security definer
set search_path = public
stable
as $$
  select distinct t.id, pr.full_name
  from public.service_tickets st
  join public.appointments ap on ap.ticket_id = st.id
  join public.technicians t on t.id = ap.technician_id
  join public.profiles pr on pr.id = t.profile_id
  where st.customer_id = public.current_customer_id()
  order by pr.full_name;
$$;

grant execute on function public.list_my_ticket_technicians() to authenticated;
