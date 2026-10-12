-- Rollback for 20261018110000_customer_preferred_language.sql. Run AFTER the rollback of 20261018120000 (the engine reads
-- the column). Dropping the column loses the language choices. The self-update guard goes back to name + profession only.
begin;
drop function if exists public.set_customer_preferred_language(uuid, text);
create or replace function public.guard_customer_self_update()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  if current_user not in ('authenticated', 'anon') then
    return new;
  end if;

  -- only restrict the customer acting on their OWN row; staff writes
  -- (customers_write_sales) are untouched
  if old.id = public.current_customer_id() then
    if (to_jsonb(new) - array['name', 'profession', 'updated_at'])
       is distinct from (to_jsonb(old) - array['name', 'profession', 'updated_at']) then
      raise exception 'customers: you can only edit your name and profession here';
    end if;
  end if;

  return new;
end;
$$;
alter table public.customers drop column if exists preferred_language;
commit;
