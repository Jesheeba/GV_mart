-- Rollback for the full customer_auto_onboard migration chain:
--   20261130100000_customer_auto_onboard_schema.sql
--   20261130100001_customer_auto_onboard_rpc.sql
--   20261130100002_unlink_blocks_auto_relink.sql
--   20261130100003_merge_auto_customer.sql
-- Run in this order (reverse of apply) -- tested together, in this exact order, inside the
-- rolled-back rehearsal wrapper (20261130100000_customer_auto_onboard.rehearsal.sql), which
-- applies all 4 migrations, runs the test matrix, THEN runs this rollback, THEN verifies the
-- pre-migration state is restored -- all before its own final RAISE undoes everything.

-- 1. Drop the merge tool first (newest, nothing else depends on it).
drop function if exists public.admin_merge_auto_customer(uuid, uuid, text);

-- 2. Restore admin_link_customer_google_account / admin_unlink_customer_google_account to their
--    ORIGINAL 20261121100000 bodies (byte-for-byte, reproduced here) -- undoes 20261130100002's
--    one-line change to each (the auto_link_blocked_at/by set/clear). Both functions are
--    already live independent of this branch, so this restores them rather than dropping them.
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

-- 3. Drop the auto-onboard RPC itself.
drop function if exists public.customer_auto_onboard();

-- 4. Drop every column this chain added. WARNING on the two NOT-NULL-affecting lines below --
--    see the same warning in context: restoring mobile's NOT NULL fails loudly (not silently)
--    if any row has gone NULL since this applied; check first:
--      select count(*) from public.customers where mobile is null;
--    If that's > 0, either backfill a value for those rows or leave mobile nullable.
alter table public.customers drop constraint if exists customers_email_format;
alter table public.customers drop column if exists email;
alter table public.customers drop column if exists needs_review;
alter table public.customers drop column if exists needs_review_reason;
alter table public.customers drop column if exists auto_link_blocked_at;
alter table public.customers drop column if exists auto_link_blocked_by;
alter table public.customers drop column if exists archived_at;
alter table public.customers drop column if exists archived_by;

-- Only run this line after confirming (see WARNING above) that no row has mobile is null:
-- alter table public.customers alter column mobile set not null;
