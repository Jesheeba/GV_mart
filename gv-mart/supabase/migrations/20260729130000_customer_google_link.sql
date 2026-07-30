-- Google OAuth customer login: an admin-created customer record has no auth
-- account at all (create_customer_with_details never touches
-- profiles/auth.users — see 20260701091400_customer_rpc.sql, and
-- customers.primary_profile_id starts null). This RPC is the missing link:
-- after a first-time Google sign-in, the client asks the customer for their
-- mobile number and calls this to find the matching customers row (entered
-- by staff) and attach the new auth.users id to it.
--
-- SECURITY DEFINER because the caller has no profile row yet, so
-- current_org_id()/is_staff()/current_customer_id() all resolve to null —
-- none of the normal RLS policies would let a brand-new sign-in read
-- `organizations` or write `customers`/`profiles` on its own.
create or replace function public.link_customer_google_account(p_mobile text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_customer_id uuid;
  v_org_id uuid;
  v_customer_name text;
  v_primary_profile_id uuid;
begin
  if auth.uid() is null then
    raise exception 'link_customer_google_account: no authenticated user';
  end if;

  if p_mobile !~ '^[6-9]\d{9}$' then
    raise exception 'invalid_mobile';
  end if;

  if exists (select 1 from public.profiles where id = auth.uid()) then
    raise exception 'profile_exists';
  end if;

  select id, org_id, name, primary_profile_id
  into v_customer_id, v_org_id, v_customer_name, v_primary_profile_id
  from public.customers
  where mobile = p_mobile
  order by created_at
  limit 1;

  if v_customer_id is null then
    raise exception 'not_found';
  end if;

  if v_primary_profile_id is not null then
    raise exception 'already_linked';
  end if;

  insert into public.profiles (id, org_id, full_name, phone, role, language)
  values (auth.uid(), v_org_id, coalesce(nullif(v_customer_name, ''), 'Customer'), p_mobile, 'customer', 'en');

  update public.customers set primary_profile_id = auth.uid() where id = v_customer_id;

  return v_customer_id;
end;
$$;

grant execute on function public.link_customer_google_account(text) to authenticated;
