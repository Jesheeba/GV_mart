-- updated_at trigger, applied to every table that has the column (all of
-- them) — one function, applied mechanically rather than hand-listing 50+
-- CREATE TRIGGER statements.
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

do $$
declare
  t text;
begin
  for t in
    select table_name from information_schema.columns
    where table_schema = 'public' and column_name = 'updated_at'
  loop
    execute format(
      'create trigger set_updated_at before update on public.%I for each row execute function public.set_updated_at()',
      t
    );
  end loop;
end $$;

-- BuildSpec §5: "customer_members ... max 5 enforced in app + check" — a
-- plain CHECK constraint cannot see sibling rows, so this is a trigger.
create or replace function public.enforce_customer_members_limit()
returns trigger
language plpgsql
as $$
declare
  member_count integer;
begin
  select count(*) into member_count
  from public.customer_members
  where customer_id = new.customer_id;

  if member_count >= 5 then
    raise exception 'customer_members: a customer may have at most 5 members (customer_id=%)', new.customer_id;
  end if;

  return new;
end;
$$;

create trigger customer_members_limit_check
  before insert on public.customer_members
  for each row execute function public.enforce_customer_members_limit();

-- RLS helper functions. SECURITY DEFINER so they bypass RLS internally —
-- otherwise a policy on `profiles` that calls current_org_id() (which
-- itself selects from profiles) would recurse.
create or replace function public.current_org_id()
returns uuid
language sql stable security definer set search_path = public
as $$ select org_id from public.profiles where id = auth.uid() $$;

create or replace function public.current_role()
returns user_role
language sql stable security definer set search_path = public
as $$ select role from public.profiles where id = auth.uid() $$;

create or replace function public.is_master()
returns boolean
language sql stable security definer set search_path = public
as $$ select public.current_role() = 'master' $$;

-- master / operation_admin / sales_admin (Section 3: "staff roles")
create or replace function public.is_staff()
returns boolean
language sql stable security definer set search_path = public
as $$ select public.current_role() in ('master', 'operation_admin', 'sales_admin') $$;

create or replace function public.is_ops_staff()
returns boolean
language sql stable security definer set search_path = public
as $$ select public.current_role() in ('master', 'operation_admin') $$;

create or replace function public.is_sales_staff()
returns boolean
language sql stable security definer set search_path = public
as $$ select public.current_role() in ('master', 'sales_admin') $$;

create or replace function public.current_technician_id()
returns uuid
language sql stable security definer set search_path = public
as $$ select id from public.technicians where profile_id = auth.uid() $$;

create or replace function public.current_customer_id()
returns uuid
language sql stable security definer set search_path = public
as $$ select id from public.customers where primary_profile_id = auth.uid() $$;
