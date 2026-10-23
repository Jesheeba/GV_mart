-- A service ticket / lead / rental contract snapshots the customer's
-- address_id once, at insert time (book_service_ticket, the AMC/rental
-- auto-booking RPCs, create_lead, etc.). If the customer had no address yet
-- at that moment, the snapshot is NULL forever — nothing ever re-reads it,
-- even after staff later add and confirm the customer's address (with a map
-- pin, lat/lng set). That's the bug: "master changed/set the location,
-- customer_id lines up, but the already-created ticket still shows nothing
-- on the technician side" — the two rows were never linked.
--
-- Fix: whenever an address gets (or already has) a confirmed map pin
-- (lat/lng both set), backfill any of that customer's still-unlinked
-- tickets/leads/active rental contracts to point at it. Only fills NULL
-- links — never overwrites an address_id staff already deliberately chose
-- (e.g. a second/secondary address picked for a specific job), so this is
-- purely additive and safe to run repeatedly.

create or replace function public.backfill_customer_address_links()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.lat is null or new.lng is null then
    return new;
  end if;

  update public.service_tickets
  set address_id = new.id
  where customer_id = new.customer_id
    and address_id is null
    and status not in ('completed', 'cancelled');

  update public.leads
  set address_id = new.id
  where customer_id = new.customer_id
    and address_id is null;

  update public.rental_contracts
  set address_id = new.id
  where customer_id = new.customer_id
    and address_id is null
    and status = 'active';

  return new;
end;
$$;

drop trigger if exists addresses_backfill_null_links on public.addresses;
create trigger addresses_backfill_null_links
  after insert or update of lat, lng on public.addresses
  for each row
  execute function public.backfill_customer_address_links();

-- One-time catch-up for records that are already stuck on an old build:
-- link any customer's still-unlinked open ticket / lead / active rental to
-- their existing primary address, if that address already has a confirmed
-- pin. (Fixes, among others, today's ticket 383a62ef-d64b-4f11-9676-
-- 59a169bae9ee, whose customer's primary address was added after the
-- ticket.)
update public.service_tickets t
set address_id = a.id
from public.addresses a
where t.customer_id = a.customer_id
  and a.is_primary = true
  and a.lat is not null
  and a.lng is not null
  and t.address_id is null
  and t.status not in ('completed', 'cancelled');

update public.leads l
set address_id = a.id
from public.addresses a
where l.customer_id = a.customer_id
  and a.is_primary = true
  and a.lat is not null
  and a.lng is not null
  and l.address_id is null;

update public.rental_contracts r
set address_id = a.id
from public.addresses a
where r.customer_id = a.customer_id
  and a.is_primary = true
  and a.lat is not null
  and a.lng is not null
  and r.address_id is null
  and r.status = 'active';
