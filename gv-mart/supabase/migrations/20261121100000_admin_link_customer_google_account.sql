-- Master-only stopgap for linking a customer's Google sign-in while OTP
-- linking (docs/spec-link-customer-login-phone-otp.md) is parked. The old
-- link_customer_google_account(text) RPC trusted whatever mobile number the
-- SIGNED-IN CALLER typed (account-takeover: anyone could type any customer's
-- mobile and claim their record) and stays revoked — see
-- 20261021100000_revoke_link_customer_google_account.sql. This is a
-- different trust model: the MASTER, already looking at one specific
-- customer's detail page, types the Google email that customer told them
-- they signed in with. No customer-facing surface is touched or notified.
--
-- Match-by-email, not match-by-mobile: the Google sign-in is identified by
-- its auth.identities row (provider = 'google'), not auth.users.email —
-- auth.users.email can in principle be set by other means, whereas the
-- identity row is what Supabase recorded at the actual Google OAuth
-- handshake. Email is lower()+trim()'d on both sides to close the
-- whitespace/case tricks called out in the security review.
--
-- Any auth user that already has a profiles row — customer, staff,
-- technician, whoever — is refused. This is deliberate and covers "linking
-- an auth user that belongs to a staff/technician": staff and technicians
-- always have a profiles row, so they can never match here.
create or replace function public.admin_link_customer_google_account(p_customer_id uuid, p_google_email text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_email text := lower(trim(p_google_email));
  v_customer record;
  v_auth_id uuid;
  v_match_count int;
begin
  if auth.uid() is null then
    raise exception 'admin_link_customer_google_account: no authenticated user';
  end if;
  if not public.is_master() then
    raise exception 'admin_link_customer_google_account: master role required';
  end if;
  if v_email = '' or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'invalid_email';
  end if;

  -- Row lock first: serializes two masters acting on the same customer
  -- concurrently (one linking, one unlinking, or two different emails).
  select id, org_id, name, mobile, preferred_language, primary_profile_id, is_test
    into v_customer
    from public.customers
   where id = p_customer_id
     for update;

  if v_customer.id is null or v_customer.org_id is distinct from public.current_org_id() then
    raise exception 'customer_not_found';
  end if;
  if v_customer.is_test then
    raise exception 'test_customer';
  end if;
  if v_customer.primary_profile_id is not null then
    raise exception 'already_linked';
  end if;

  -- Reject on >1 match too: an ambiguous email should never silently pick
  -- "the first one", it should refuse and say so.
  select count(*) into v_match_count
    from auth.identities i
   where i.provider = 'google'
     and lower(trim(i.identity_data->>'email')) = v_email;

  if v_match_count = 0 then
    raise exception 'no_matching_signin';
  end if;
  if v_match_count > 1 then
    raise exception 'ambiguous_signin';
  end if;

  select i.user_id into v_auth_id
    from auth.identities i
   where i.provider = 'google'
     and lower(trim(i.identity_data->>'email')) = v_email;

  if exists (select 1 from public.profiles where id = v_auth_id) then
    raise exception 'signin_already_linked';
  end if;

  begin
    insert into public.profiles (id, org_id, full_name, phone, role, language)
    values (v_auth_id, v_customer.org_id, coalesce(nullif(v_customer.name, ''), 'Customer'), v_customer.mobile, 'customer', coalesce(v_customer.preferred_language, 'en'));
  exception when unique_violation then
    -- lost a race against a concurrent call for a DIFFERENT customer that matched the same sign-in
    raise exception 'signin_already_linked';
  end;

  update public.customers set primary_profile_id = v_auth_id where id = v_customer.id;

  insert into public.audit_log (org_id, actor_id, action, table_name, row_id, before, after)
  values (
    v_customer.org_id, auth.uid(), 'admin_link_google_account', 'customers', v_customer.id,
    jsonb_build_object('primary_profile_id', null),
    jsonb_build_object('primary_profile_id', v_auth_id, 'google_email', v_email)
  );
end;
$$;

revoke all on function public.admin_link_customer_google_account(uuid, text) from public, anon, authenticated;
grant execute on function public.admin_link_customer_google_account(uuid, text) to authenticated;

-- Undo for a mistaken link. Deletes the profiles row entirely (not just
-- clearing customers.primary_profile_id) so the sign-in is fully reset to
-- its pre-link state and can be relinked — correctly, or to a different
-- customer — afterwards. If that profile has since accumulated rows that
-- reference it (anything beyond the bare customer link), the delete is
-- refused with a message rather than silently cascading.
create or replace function public.admin_unlink_customer_google_account(p_customer_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_customer record;
  v_profile_id uuid;
begin
  if auth.uid() is null then
    raise exception 'admin_unlink_customer_google_account: no authenticated user';
  end if;
  if not public.is_master() then
    raise exception 'admin_unlink_customer_google_account: master role required';
  end if;
  if p_reason is null or trim(p_reason) = '' then
    raise exception 'reason_required';
  end if;

  select id, org_id, primary_profile_id
    into v_customer
    from public.customers
   where id = p_customer_id
     for update;

  if v_customer.id is null or v_customer.org_id is distinct from public.current_org_id() then
    raise exception 'customer_not_found';
  end if;
  if v_customer.primary_profile_id is null then
    raise exception 'not_linked';
  end if;

  v_profile_id := v_customer.primary_profile_id;

  update public.customers set primary_profile_id = null where id = v_customer.id;

  begin
    delete from public.profiles where id = v_profile_id;
  exception when foreign_key_violation then
    raise exception 'unlink_blocked_has_records';
  end;

  insert into public.audit_log (org_id, actor_id, action, table_name, row_id, before, after)
  values (
    v_customer.org_id, auth.uid(), 'admin_unlink_google_account', 'customers', v_customer.id,
    jsonb_build_object('primary_profile_id', v_profile_id),
    jsonb_build_object('primary_profile_id', null, 'reason', p_reason)
  );
end;
$$;

revoke all on function public.admin_unlink_customer_google_account(uuid, text) from public, anon, authenticated;
grant execute on function public.admin_unlink_customer_google_account(uuid, text) to authenticated;
