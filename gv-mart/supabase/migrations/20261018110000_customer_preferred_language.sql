-- Automation Phase 3 / Stage A, part 2 (S2): customers.preferred_language.
--
-- 'en' | 'ta', nullable; empty means English (the engine's order is: preferred_language, the login's profiles.language,
-- the rule's language, 'en'). Backfilled once from the login language where a login exists. The backfill runs with
-- triggers off for that single statement (session_replication_role = replica, transaction-local) so it does not bump
-- customers.updated_at or write an audit row for every customer: it is a mechanical default, not a user edit.

alter table public.customers
  add column preferred_language text check (preferred_language in ('en', 'ta'));

set local session_replication_role = replica;
update public.customers c
   set preferred_language = p.language
  from public.profiles p
 where p.id = c.primary_profile_id
   and p.language in ('en', 'ta')
   and c.preferred_language is null;
set local session_replication_role = origin;

-- ── who may write it ────────────────────────────────────────────────────────────────────────────────────────────────────
-- (1) A customer editing their OWN record: the live guard only allows name and profession, so the customer app's language
--     field would be refused. preferred_language is added to the allowed list; every other column stays refused.
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
    if (to_jsonb(new) - array['name', 'profession', 'preferred_language', 'updated_at'])
       is distinct from (to_jsonb(old) - array['name', 'profession', 'preferred_language', 'updated_at']) then
      raise exception 'customers: you can only edit your name, profession and message language here';
    end if;
  end if;

  return new;
end;
$$;

-- (2) Staff: the customers write policy covers master and sales_admin only, so an operations-only user's direct UPDATE
--     silently affects 0 rows. This definer function is the one door for every staff role that manages customers.
create function public.set_customer_preferred_language(p_customer_id uuid, p_language text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid := public.current_org_id();
begin
  if auth.uid() is null or not (coalesce(public.is_ops_staff(), false) or coalesce(public.is_sales_staff(), false)) then
    raise exception 'set_customer_preferred_language: only master, operations or sales staff can change this';
  end if;
  if p_language is not null and p_language not in ('en', 'ta') then
    raise exception 'set_customer_preferred_language: language must be en or ta';
  end if;
  update public.customers set preferred_language = p_language where id = p_customer_id and org_id = v_org;
  if not found then
    raise exception 'set_customer_preferred_language: customer not found';
  end if;
end;
$$;
revoke all on function public.set_customer_preferred_language(uuid, text) from public, anon;
grant execute on function public.set_customer_preferred_language(uuid, text) to authenticated, service_role;
