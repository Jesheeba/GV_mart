-- Auto-onboarding on first Google sign-in (customer app). Replaces the dead-end "contact the
-- shop" notice for the common case: a brand-new Google sign-in with no profiles row yet.
--
-- Trust model, same spirit as admin_link_customer_google_account (20261121100000) but fully
-- server-driven: the function takes NO identity parameters at all. Every fact it acts on --
-- the caller's own Google email, whether it's Google-verified, whether the caller already has a
-- profile -- is read server-side from auth.uid() / auth.users / auth.identities. There is
-- nothing for a malicious caller to pass in that could make this function act on anyone else's
-- record: the ONLY input is auth.uid() itself, which the caller cannot forge (it comes from
-- their own verified JWT, the same as every other `auth.uid()`-based function in this project).
--
-- Email source: auth.identities, provider = 'google', not auth.users.email -- identical
-- reasoning to admin_link_customer_google_account's own comment (that function's lookup goes the
-- other direction -- master-typed email to identity -- this one goes identity to email, but it's
-- the same "the identity row is what Google actually verified" principle). Additionally requires
-- auth.users.email_confirmed_at is not null for THIS caller -- Google sign-ins are normally
-- already confirmed by the time the session exists, but this is checked explicitly rather than
-- assumed.
--
-- Match rule (never guesses):
--   0 matches                                  -> create a new 'customer_app'-sourced customer,
--                                                  not flagged.
--   exactly 1 match, that customer unlinked     -> link (same effect as
--                                                  admin_link_customer_google_account: create the
--                                                  profiles row, set primary_profile_id).
--   exactly 1 match, already linked to a         -> DO NOT link (would silently take over someone
--     DIFFERENT auth user                          else's account). Create a new customer instead,
--                                                  flagged needs_review.
--   more than 1 match                           -> ambiguous. Create a new customer instead,
--                                                  flagged needs_review. Never pick one.
-- "Match" is always is_test = false and lower(trim(email)) exact-equality -- test customers are
-- never matched, by construction (the WHERE clause excludes them, not a post-hoc check).
--
-- Idempotent: a caller who already has ANY profiles row short-circuits immediately -- a
-- 'customer' role profile returns its already-linked customers row unchanged (no new INSERT, no
-- new audit_log row, this is a pure read on retry); any other role raises 'staff_account' and
-- touches nothing. This is also what makes a second concurrent call for the same caller safe on
-- its own merits, on top of the advisory lock below: whichever of two racing calls loses the
-- lock wait sees the first call's already-committed profiles row and takes the idempotent path.
create or replace function public.customer_auto_onboard()
returns public.customers
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_existing public.customers;
  v_email text;
  v_name text;
  v_default_org uuid;
  v_match_count int;
  v_matched public.customers;
  v_new public.customers;
  v_reason text;
begin
  if v_uid is null then
    raise exception 'customer_auto_onboard: no authenticated user';
  end if;

  -- Serializes two concurrent calls for the SAME caller (double-click, a retry racing the
  -- first attempt) -- belt-and-suspenders on top of the idempotent short-circuit above and
  -- profiles' own primary key (id = auth.uid()), which would otherwise turn a genuine race
  -- into a unique_violation instead of a clean second "already onboarded" return.
  perform pg_advisory_xact_lock(hashtext(v_uid::text));

  if exists (select 1 from public.profiles where id = v_uid) then
    if exists (select 1 from public.profiles where id = v_uid and role is distinct from 'customer') then
      raise exception 'staff_account';
    end if;
    select c.* into v_existing from public.customers c where c.primary_profile_id = v_uid;
    if v_existing.id is not null then
      return v_existing;
    end if;
    -- a customer-role profile with no linked customer row should never happen through any path
    -- this project has today (every customer-role profile is created either by
    -- admin_link_customer_google_account, this function, or OTP linking -- all three set
    -- primary_profile_id in the same transaction as the profiles insert) -- refuse rather than
    -- guess if it somehow does.
    raise exception 'customer_auto_onboard: profile exists with no linked customer';
  end if;

  select lower(trim(i.identity_data->>'email')) into v_email
    from auth.identities i
   where i.user_id = v_uid and i.provider = 'google'
   order by i.created_at asc
   limit 1;

  if v_email is null or v_email = '' then
    raise exception 'customer_auto_onboard: no Google sign-in found for this user';
  end if;

  if not exists (select 1 from auth.users u where u.id = v_uid and u.email_confirmed_at is not null) then
    raise exception 'customer_auto_onboard: email not confirmed';
  end if;

  -- Supabase's Google provider has populated this under slightly different keys across
  -- versions (full_name, name) -- try both, falling back to the identities row (which is
  -- always present here, already fetched above) before giving up to a generic label.
  select coalesce(
    nullif(btrim(u.raw_user_meta_data->>'full_name'), ''),
    nullif(btrim(u.raw_user_meta_data->>'name'), ''),
    nullif(btrim(i.identity_data->>'full_name'), ''),
    nullif(btrim(i.identity_data->>'name'), '')
  ) into v_name
  from auth.users u
  left join auth.identities i on i.user_id = u.id and i.provider = 'google'
  where u.id = v_uid
  order by i.created_at asc
  limit 1;

  -- The one real (non-__TEST_) organisation -- same convention this project's own
  -- rehearsal/apply scripts already pin on (oldest real org by created_at). A brand-new Google
  -- sign-in has no org context of its own to draw from (no profile yet), so this is the only
  -- place that context can come from.
  select o.id into v_default_org
    from public.organizations o
   where o.name not like '\_\_TEST\_%' escape '\'
   order by o.created_at asc
   limit 1;

  if v_default_org is null then
    raise exception 'customer_auto_onboard: no organisation to onboard into';
  end if;

  -- SECURITY REVIEW (2026-11-30) -- accepted single-org limitation, documented not fixed: this
  -- match (and v_matched below) is NOT scoped to v_default_org or any org at all -- it searches
  -- every organisation. Harmless today because v_default_org IS the only real organisation
  -- (same premise this whole function's org-selection already depends on), but if a second
  -- real organisation is ever created, a sign-in intended for org B could match and link to a
  -- customer that actually belongs to org A, with no client-supplied org to validate against
  -- (this function has no parameters at all, so there is nothing to scope the match TO until
  -- after it already ran). Revisit before this project is ever multi-org: either scope both
  -- queries to v_default_org, or add a loud guard that refuses outright if more than one real
  -- organisation exists.
  select count(*) into v_match_count
    from public.customers c
   where c.is_test = false
     and c.email is not null
     and lower(trim(c.email)) = v_email;

  if v_match_count = 1 then
    -- FOR UPDATE: closes the race between two DIFFERENT callers whose emails both match this
    -- same unlinked customer at the same time (admin_link_customer_google_account locks its
    -- matched row the same way, for the same reason) -- without it, both could read
    -- primary_profile_id IS NULL before either writes, and both would try to link.
    select c.* into v_matched
      from public.customers c
     where c.is_test = false
       and c.email is not null
       and lower(trim(c.email)) = v_email
     limit 1
     for update;

    if v_matched.primary_profile_id is null then
      -- Link: same data effects as admin_link_customer_google_account's own link path.
      insert into public.profiles (id, org_id, full_name, phone, role, language)
      values (v_uid, v_matched.org_id, coalesce(nullif(v_matched.name, ''), 'Customer'), v_matched.mobile, 'customer', coalesce(v_matched.preferred_language, 'en'));

      update public.customers set primary_profile_id = v_uid where id = v_matched.id;

      insert into public.audit_log (org_id, actor_id, action, table_name, row_id, before, after)
      values (
        v_matched.org_id, null, 'auto_link_email', 'customers', v_matched.id,
        jsonb_build_object('primary_profile_id', null),
        jsonb_build_object('primary_profile_id', v_uid, 'google_email', v_email)
      );

      select c.* into v_existing from public.customers c where c.id = v_matched.id;
      return v_existing;
    end if;

    -- Exactly one match, but it's already linked to a DIFFERENT auth user -- never take over an
    -- existing login. Falls through to the create-new-flagged path below.
    v_reason := 'email matched an existing customer already linked to a different sign-in';
  elsif v_match_count > 1 then
    -- Ambiguous -- more than one existing customer shares this email. Never pick one.
    v_reason := 'email matched more than one existing customer';
  end if;
  -- v_match_count = 0 falls through with v_reason still null (not flagged).

  -- profiles row MUST be inserted first -- customers.primary_profile_id is a foreign key to it,
  -- so referencing v_uid in the customers insert before this would violate that constraint.
  insert into public.profiles (id, org_id, full_name, phone, role, language)
  values (v_uid, v_default_org, coalesce(v_name, 'Customer'), null, 'customer', 'en');

  insert into public.customers (org_id, name, mobile, email, source, is_test, needs_review, needs_review_reason, primary_profile_id)
  values (
    v_default_org, coalesce(v_name, 'Customer'), null, v_email, 'customer_app', false,
    v_reason is not null, v_reason, v_uid
  )
  returning * into v_new;

  insert into public.audit_log (org_id, actor_id, action, table_name, row_id, before, after)
  values (
    v_default_org, null, 'auto_create', 'customers', v_new.id,
    null,
    jsonb_build_object('email', v_email, 'needs_review', v_new.needs_review, 'needs_review_reason', v_reason)
  );

  return v_new;
end;
$$;

revoke all on function public.customer_auto_onboard() from public, anon, authenticated;
grant execute on function public.customer_auto_onboard() to authenticated;
