-- Cleanup for auto-onboard-seed.sql. Run by hand via run_rehearsal.mjs once the 3 Playwright
-- scripts are done with it.
--
-- IMPORTANT: customer_auto_onboard() always onboards into "the one real (non-__TEST_)
-- organisation" (it has no org context of its own to draw from -- see the function's own
-- comment) -- NOT into this seed's throwaway __TEST_auto_onboard_pw org. Running scenario A
-- (brand-new user) or C (ambiguous) for real creates a REAL row in the REAL org: a new
-- customer with email onboard-new.test@gvmart.invalid or onboard-ambiguous.test@gvmart.invalid
-- respectively, plus a profiles row for whichever seeded auth user triggered it. This cleanup
-- removes those by email, wherever they landed, in addition to the throwaway org itself.
do $cleanup$
declare
  v_org uuid;
begin
  -- Whatever customer_auto_onboard created in the real org for the new-user and ambiguous
  -- scenarios (scenario B's existing customer in the __TEST_ org is handled below, untouched
  -- here since it was never auto-*created*, only linked).
  delete from public.audit_log where row_id in (
    select id from public.customers where email in ('onboard-new.test@gvmart.invalid', 'onboard-ambiguous.test@gvmart.invalid')
  );
  delete from public.customers where email in ('onboard-new.test@gvmart.invalid', 'onboard-ambiguous.test@gvmart.invalid');

  select id into v_org from public.organizations where name = '__TEST_auto_onboard_pw';
  if v_org is not null then
    delete from public.audit_log where org_id = v_org;
    delete from public.customers where org_id = v_org;
    delete from public.organizations where id = v_org;
  end if;

  -- Deleting the profiles above (via the customers delete's own cascade is NOT how this works --
  -- profiles aren't deleted by a customers delete; they're deleted here explicitly, by whichever
  -- auth user ended up primary_profile_id'd) is handled by the auth.users delete below (profiles.id
  -- references auth.users(id) on delete cascade).
  delete from auth.users where email in (
    'onboard-new.test@gvmart.invalid',
    'onboard-existing.test@gvmart.invalid',
    'onboard-ambiguous.test@gvmart.invalid'
  );
  -- auth.identities rows cascade from auth.users on delete (GoTrue's own FK) -- nothing else to remove.
end
$cleanup$;
