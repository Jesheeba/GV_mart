-- Master-only merge tool: attaches an auto-created ('app') or needs_review customer's Google
-- sign-in to an existing, already-known customer record -- the counterpart to
-- admin_link_customer_google_account for the one case that tool refuses: the auth user already
-- has a profile (every auto-created customer does, by design -- customer_auto_onboard always
-- links the new sign-in to whatever it creates). This is the correct tool for "a returning
-- customer signed in with Google before staff had a chance to find their existing record" --
-- not a general-purpose customer-merge (it refuses outright unless the auto-created side is
-- completely empty, see below), and never auto-applied -- a master always chooses the target.
--
-- customers.archived_at / archived_by: NEW. The emptied auto-created record is archived, not
-- hard-deleted -- its audit_log history (auto_create, and now this merge) stays attached to a
-- real row, same reasoning admin_unlink_customer_google_account's own header gives for deleting
-- profiles but never customers. Archived customers are excluded from the admin customer list and
-- search by default (frontend, same migration's sibling PR) but the row itself, and its
-- audit_log trail, is never removed.
alter table public.customers add column archived_at timestamptz;
alter table public.customers add column archived_by uuid references public.profiles (id) on delete set null;

-- Reuses customer_delete_impact's exact counts (20261005140000_delete_customer.sql) for the
-- "completely empty" check -- tickets (visits), amc_contracts/warranties/rental_contracts
-- (lifecycle), quotations and invoices (orders/payments). Deliberately does NOT check
-- addresses/customer_members -- those aren't lifecycle data and the spec doesn't ask for it; an
-- auto-created customer who has typed in their own address before a master gets to it should
-- still be mergeable (the address itself doesn't move -- it stays with the archived record,
-- same as any other data on a customer that already has invoices would with an outright delete).
create or replace function public.admin_merge_auto_customer(p_from_customer_id uuid, p_to_customer_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_from public.customers;
  v_to public.customers;
  v_auth_id uuid;
  v_tickets int; v_amc int; v_warranties int; v_rentals int; v_quotations int; v_invoices int;
begin
  if auth.uid() is null then
    raise exception 'admin_merge_auto_customer: no authenticated user';
  end if;
  if not public.is_master() then
    raise exception 'admin_merge_auto_customer: master role required';
  end if;
  if p_reason is null or trim(p_reason) = '' then
    raise exception 'reason_required';
  end if;
  if p_from_customer_id = p_to_customer_id then
    raise exception 'same_customer';
  end if;

  -- Lock in a fixed order (by id) regardless of which argument is which, so two concurrent
  -- merges touching the same pair of rows in opposite order can never deadlock.
  if p_from_customer_id < p_to_customer_id then
    select * into v_from from public.customers where id = p_from_customer_id for update;
    select * into v_to from public.customers where id = p_to_customer_id for update;
  else
    select * into v_to from public.customers where id = p_to_customer_id for update;
    select * into v_from from public.customers where id = p_from_customer_id for update;
  end if;

  if v_from.id is null or v_from.org_id is distinct from public.current_org_id() then
    raise exception 'from_customer_not_found';
  end if;
  if v_to.id is null or v_to.org_id is distinct from public.current_org_id() then
    raise exception 'to_customer_not_found';
  end if;

  if v_from.source is distinct from 'customer_app' then
    raise exception 'from_customer_not_auto_created';
  end if;
  if v_from.archived_at is not null then
    raise exception 'from_customer_already_archived';
  end if;
  if v_from.primary_profile_id is null then
    raise exception 'from_customer_not_linked';
  end if;

  if v_to.is_test then
    raise exception 'to_customer_is_test';
  end if;
  if v_to.archived_at is not null then
    raise exception 'to_customer_archived';
  end if;
  if v_to.primary_profile_id is not null then
    raise exception 'to_customer_already_linked';
  end if;

  select count(*) into v_tickets from public.service_tickets where customer_id = v_from.id;
  select count(*) into v_amc from public.amc_contracts where customer_id = v_from.id;
  select count(*) into v_warranties from public.warranties where customer_id = v_from.id;
  select count(*) into v_rentals from public.rental_contracts where customer_id = v_from.id;
  select count(*) into v_quotations from public.quotations where customer_id = v_from.id;
  select count(*) into v_invoices from public.invoices where customer_id = v_from.id;
  if v_tickets > 0 or v_amc > 0 or v_warranties > 0 or v_rentals > 0 or v_quotations > 0 or v_invoices > 0 then
    raise exception 'from_customer_has_records';
  end if;

  v_auth_id := v_from.primary_profile_id;

  -- Move the link: FROM must be cleared FIRST -- customers.primary_profile_id is UNIQUE, so
  -- setting TO's primary_profile_id while FROM still holds the same value would violate that
  -- constraint (caught by this migration's own rehearsal, not by inspection: two rows briefly
  -- sharing one primary_profile_id value, even within a single transaction, is checked
  -- immediately since the constraint isn't DEFERRABLE).
  update public.customers set primary_profile_id = null, archived_at = now(), archived_by = auth.uid() where id = v_from.id;
  update public.customers set primary_profile_id = v_auth_id, email = coalesce(v_to.email, v_from.email) where id = v_to.id;

  -- The profile's own display fields were set from the auto-created (FROM) customer at
  -- creation time -- now that it represents TO, bring them into line, same effect
  -- admin_link_customer_google_account's own link path already has for a fresh link.
  update public.profiles
    set org_id = v_to.org_id, full_name = coalesce(nullif(v_to.name, ''), 'Customer'), phone = v_to.mobile, language = coalesce(v_to.preferred_language, 'en')
    where id = v_auth_id;

  insert into public.audit_log (org_id, actor_id, action, table_name, row_id, before, after)
  values (
    v_to.org_id, auth.uid(), 'admin_merge_auto_customer', 'customers', v_to.id,
    jsonb_build_object('primary_profile_id', null),
    jsonb_build_object('primary_profile_id', v_auth_id, 'merged_from_customer_id', v_from.id, 'reason', p_reason)
  );
  insert into public.audit_log (org_id, actor_id, action, table_name, row_id, before, after)
  values (
    v_from.org_id, auth.uid(), 'admin_merge_auto_customer_archived', 'customers', v_from.id,
    jsonb_build_object('primary_profile_id', v_auth_id, 'archived_at', null),
    jsonb_build_object('primary_profile_id', null, 'archived_at', now(), 'merged_into_customer_id', v_to.id, 'reason', p_reason)
  );
end;
$$;

revoke all on function public.admin_merge_auto_customer(uuid, uuid, text) from public, anon, authenticated;
grant execute on function public.admin_merge_auto_customer(uuid, uuid, text) to authenticated;
