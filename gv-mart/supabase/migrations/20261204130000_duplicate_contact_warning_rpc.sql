-- Staff-side duplicate-contact warning RPC (urgent item, 2026-11-02 investigation).
--
-- Context: owner reported "when creating a customer with an existing number, I
-- see an error popup YET one entry still gets created." Root-cause investigation
-- (code read + live, read-only queries, no writes) found:
--   * create_customer_with_details has NO dedupe check, by design -- a manual
--     "Create Customer" is always a new row (confirmed in both the live function
--     body via pg_get_functiondef and the unapplied 20261204120000 migration --
--     no pg_sleep/savepoints/subtransactions either, so Postgres atomicity holds;
--     a single call either fully commits or fully rolls back, it never leaves a
--     partial insert behind).
--   * The existing inline duplicate hint (useMobileDuplicateCheck /
--     customers.form.duplicateWarning, shown per-member in CustomerFormPage) is
--     informational only -- it never re-runs at Save time and never blocks Save.
--   * Live evidence (read-only, 2026-10-17 onward, is_test excluded): 6 real
--     (org_id, mobile) duplicate pairs with gaps of ~5 minutes to ~24 hours --
--     i.e. ordinary, separate single-submit creates, NOT a sub-second
--     double-click race. That matches this mechanism exactly: staff sees (or
--     misses) the quiet inline hint, proceeds anyway, and the RPC -- which has
--     no enforcement -- happily creates another row for the same number.
--   * Separately (not fixed here -- flagged for the owner): CustomerFormPage's
--     Save button has no guardReentry (src/lib/async-guard.ts) wiring, unlike
--     AccountsPage's "+ Create" buttons, so a fast double-click could ALSO
--     create two rows via two concurrent RPC calls. No live evidence of that
--     specific pattern was found (no sub-2-second-gap pairs), so it is reported
--     as a latent gap, not the confirmed cause. Note too that even once the
--     unapplied 20261204120000 advisory-lock migration lands, it would not
--     close this gap -- that lock only serializes a manual create against the
--     two lead-conversion paths' check-then-act, not a manual create against a
--     second concurrent manual create of itself (the function still inserts
--     unconditionally after taking the lock).
--
-- This migration is the long-term mitigation for the confirmed mechanism above:
-- a read-only RPC the staff-side Create Customer / Create Lead forms can call
-- live (debounced, on blur/change of the mobile field) to show a non-blocking
-- "existing record(s) found" banner with enough context (name, mobile, email,
-- created_at, ticket/invoice counts) for staff to make an informed call, plus
-- an explicit "Create anyway" confirmation step once a match is shown -- same
-- "never pre-emptive, only once a real conflict is flagged" shape as
-- assign_ticket_technician's p_force override (TicketDetailPage.tsx).
--
-- This RPC does NOT enforce anything server-side (by design, matching the
-- existing "manual create is always new" convention) and does NOT merge/filter
-- the already-known 2026-10-16 bulk-import placeholder-mobile duplicates --
-- that is a separate, not-yet-decided cleanup problem. It only answers "does
-- this org already have a customer or lead with this mobile/email right now."
--
-- Security model: SECURITY INVOKER, not DEFINER. The three tables it reads
-- (customers, leads, service_tickets/invoices via subselects) already have
-- RLS policies granting SELECT to is_staff() within current_org_id()
-- (customers_select_staff / leads_select_staff / service_tickets_select_staff /
-- invoices_select_staff, all from 20260701091300_rls.sql) -- so INVOKER rides
-- those existing policies instead of bypassing them, which is strictly safer
-- than DEFINER for a function that does nothing a staff member couldn't
-- already do with four individual SELECTs. The explicit is_staff()/org guard
-- below is defense-in-depth (a clear exception instead of a silent empty
-- result for a non-staff caller), not the only thing standing between this
-- function and someone else's org.
--
-- NOT APPLIED. Needs the standard pipeline: rehearsal (as the real
-- authenticated staff role, not service_role), DRYRUN-OK, a fresh security
-- review, an anon-exposure diff, and the owner's typed APPROVED.

create or replace function public.find_duplicate_contacts(
  p_mobile text default null,
  p_email text default null
)
returns table (
  source text,
  id uuid,
  name text,
  mobile text,
  email text,
  created_at timestamptz,
  ticket_count bigint,
  invoice_count bigint
)
language plpgsql
stable
security invoker
set search_path to 'public'
as $function$
declare
  v_org_id uuid := public.current_org_id();
  -- _mobile_key (20261016110000_test_customer_flag.sql, already live) -- last
  -- 10 digits only. Deliberately NOT the unapplied 2A migration's
  -- normalize_mobile (country-code/trunk-prefix aware): that function does not
  -- exist live yet, and this RPC must work independently of whether/when that
  -- other migration is ever approved.
  v_mobile_key text := public._mobile_key(p_mobile);
  v_email text := lower(btrim(coalesce(p_email, '')));
begin
  if not public.is_staff() then
    raise exception 'find_duplicate_contacts: caller is not staff';
  end if;

  if v_org_id is null then
    raise exception 'find_duplicate_contacts: no organisation for the current session';
  end if;

  -- Nothing to match on -- return no rows rather than scanning the org.
  if v_mobile_key is null and v_email = '' then
    return;
  end if;

  return query
  select * from (
    select
      'customer'::text as source,
      c.id,
      c.name,
      c.mobile,
      c.email,
      c.created_at,
      (select count(*) from public.service_tickets t where t.customer_id = c.id)::bigint as ticket_count,
      (select count(*) from public.invoices i where i.customer_id = c.id)::bigint as invoice_count
    from public.customers c
    where c.org_id = v_org_id
      and not c.is_test
      and (
        (v_mobile_key is not null and public._mobile_key(c.mobile) = v_mobile_key)
        or (v_email <> '' and lower(c.email) = v_email)
      )
    union all
    -- Leads have no email column -- mobile-only match. Always zero
    -- ticket/invoice counts (a lead isn't a customer yet).
    select
      'lead'::text,
      l.id,
      l.name,
      l.mobile,
      null::text,
      l.created_at,
      0::bigint,
      0::bigint
    from public.leads l
    where l.org_id = v_org_id
      and not l.is_test
      and v_mobile_key is not null
      and public._mobile_key(l.mobile) = v_mobile_key
  ) matches
  order by created_at desc
  limit 10;
end;
$function$;

-- EXECUTE revoked explicitly from public/anon below -- this project
-- auto-grants it on new functions by default (see the 20260827
-- default_privileges_anon_execute_leak fix); always revoke explicitly rather
-- than relying on no default grant.
revoke all on function public.find_duplicate_contacts(text, text) from public, anon;
grant execute on function public.find_duplicate_contacts(text, text) to authenticated, service_role;
