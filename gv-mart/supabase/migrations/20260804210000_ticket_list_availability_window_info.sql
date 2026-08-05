-- Companion to 20260804200000_restore_customer_unavailability_booking.sql:
-- the bookings LIST page needs to show the geometry-booked from/to window
-- for bookings with no slot_id, same as the detail page already gets via
-- its `appointments(*)` select. Redefines list_my_tickets_filtered
-- (20260731180000_ticket_list_slot_info.sql) with available_from/
-- available_to/is_narrow_window added to the appointment sub-object.
-- Signature unchanged; everything else verbatim from the live version.
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
                'follow_up_flagged_at', ap.follow_up_flagged_at,
                'slot_name', slot.name,
                'slot_start_time', slot.start_time,
                'slot_end_time', slot.end_time,
                'available_from', ap.available_from,
                'available_to', ap.available_to,
                'is_narrow_window', ap.is_narrow_window,
                'technician', (
                  select jsonb_build_object('id', t.id, 'full_name', pr.full_name)
                  from public.technicians t join public.profiles pr on pr.id = t.profile_id
                  where t.id = ap.technician_id
                )
              )
              from public.appointments ap
              left join public.appointment_slots slot on slot.id = ap.slot_id
              where ap.ticket_id = pg.id
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
