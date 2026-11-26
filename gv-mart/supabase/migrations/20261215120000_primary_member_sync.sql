-- Customer data-sync fixes (build-docs/features/customer-data-sync.md, sweep 2026-11-26).
--
-- 1. The primary member IS the customer. customers.name/mobile/email/profession are a copy of the primary
--    customer_members row, but only set_primary_member kept the copy current. Editing the primary member left the
--    header, list, call button and technician view on the old name/mobile. Two email boxes saved to two places
--    (Google sign-in reads customers.email). A profession set in the customer app was reverted by the next admin
--    member edit. Now one trigger pair keeps both rows in step on EVERY write path. Each side copies only the
--    columns that actually changed in that statement, so an unrelated edit can never blank the other side.
--    A customer editing their own family row may only move name/profession onto the customer row, the same fields
--    guard_customer_self_update lets them edit there directly. Mobile/email (used for sign-in matching) stay
--    staff-only.
-- 2. The customer app writes an address as one text box (full_address + area). When the customer changes that text,
--    the street-level parts an admin saved earlier are stale. Clear them, so the admin form shows the customer's
--    text instead of rebuilding full_address from the old parts.
-- 3. One-off: fill blank member emails from the account email, and blank professions either way. This never
--    overwrites a value. customers.email is deliberately NOT filled from a member email: that would newly enable
--    Google sign-in matching for the customer.

-- 1. primary member -> customer ----------------------------------------------------------------------------------------
create or replace function public._sync_primary_member_to_customer()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_customer_self boolean := auth.uid() is not null
    and public.current_customer_id() is not distinct from new.customer_id
    and not coalesce(public.is_staff(), false);
begin
  if not new.is_primary or new.moved_out_at is not null then
    return new;
  end if;

  update public.customers c
  set
    name = case when new.name is distinct from old.name then new.name else c.name end,
    profession = case when new.profession is distinct from old.profession then new.profession else c.profession end,
    mobile = case when not v_customer_self and new.mobile is distinct from old.mobile then new.mobile else c.mobile end,
    email = case when not v_customer_self and new.email is distinct from old.email then lower(nullif(btrim(new.email), '')) else c.email end
  where c.id = new.customer_id
    and (
      (new.name is distinct from old.name and c.name is distinct from new.name)
      or (new.profession is distinct from old.profession and c.profession is distinct from new.profession)
      or (not v_customer_self and new.mobile is distinct from old.mobile and c.mobile is distinct from new.mobile)
      or (not v_customer_self and new.email is distinct from old.email and c.email is distinct from lower(nullif(btrim(new.email), '')))
    );
  return new;
end;
$$;
revoke all on function public._sync_primary_member_to_customer() from public, anon, authenticated;

drop trigger if exists zz_sync_primary_member_to_customer on public.customer_members;
create trigger zz_sync_primary_member_to_customer
  after update of name, mobile, email, profession on public.customer_members
  for each row execute function public._sync_primary_member_to_customer();

-- 1b. customer -> primary member ---------------------------------------------------------------------------------------
-- The loop ends after one round trip: each side only writes when the value really differs.
create or replace function public._sync_customer_to_primary_member()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.customer_members m
  set
    name = case when new.name is distinct from old.name then new.name else m.name end,
    profession = case when new.profession is distinct from old.profession then new.profession else m.profession end,
    mobile = case when new.mobile is distinct from old.mobile and new.mobile is not null then new.mobile else m.mobile end,
    email = case when new.email is distinct from old.email then new.email else m.email end
  where m.customer_id = new.id
    and m.is_primary
    and m.moved_out_at is null
    and (
      (new.name is distinct from old.name and m.name is distinct from new.name)
      or (new.profession is distinct from old.profession and m.profession is distinct from new.profession)
      or (new.mobile is distinct from old.mobile and new.mobile is not null and m.mobile is distinct from new.mobile)
      or (new.email is distinct from old.email and m.email is distinct from new.email)
    );
  return new;
end;
$$;
revoke all on function public._sync_customer_to_primary_member() from public, anon, authenticated;

drop trigger if exists zz_sync_customer_to_primary_member on public.customers;
create trigger zz_sync_customer_to_primary_member
  after update of name, mobile, email, profession on public.customers
  for each row execute function public._sync_customer_to_primary_member();

-- 2. customer-app address text edit clears the stale street-level parts ------------------------------------------------
create or replace function public._clear_stale_address_parts()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  if auth.uid() is not null
     and public.current_customer_id() is not distinct from new.customer_id
     and not coalesce(public.is_staff(), false)
     and new.full_address is distinct from old.full_address
     -- the customer didn't send the parts themselves in this same statement
     and new.door_no is not distinct from old.door_no
     and new.plot_no is not distinct from old.plot_no
     and new.building_name is not distinct from old.building_name
     and new.street_cross is not distinct from old.street_cross
     and new.sub_area is not distinct from old.sub_area
     and new.landmark is not distinct from old.landmark
  then
    new.door_no := null;
    new.plot_no := null;
    new.building_name := null;
    new.street_cross := null;
    new.sub_area := null;
    new.landmark := null;
  end if;
  return new;
end;
$$;
revoke all on function public._clear_stale_address_parts() from public, anon, authenticated;

drop trigger if exists clear_stale_address_parts on public.addresses;
create trigger clear_stale_address_parts
  before update of full_address on public.addresses
  for each row execute function public._clear_stale_address_parts();

-- 3. one-off: fill blanks only (see header) ------------------------------------------------------------------------------------------
update public.customer_members m
set email = c.email
from public.customers c
where m.customer_id = c.id and m.is_primary and m.moved_out_at is null
  and nullif(btrim(m.email), '') is null and c.email is not null;

update public.customers c
set profession = m.profession
from public.customer_members m
where m.customer_id = c.id and m.is_primary and m.moved_out_at is null
  and nullif(btrim(c.profession), '') is null and nullif(btrim(m.profession), '') is not null;

update public.customer_members m
set profession = c.profession
from public.customers c
where m.customer_id = c.id and m.is_primary and m.moved_out_at is null
  and nullif(btrim(m.profession), '') is null and nullif(btrim(c.profession), '') is not null;

notify pgrst, 'reload schema';
