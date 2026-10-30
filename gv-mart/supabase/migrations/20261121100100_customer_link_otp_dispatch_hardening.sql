-- 20261121100100_customer_link_otp_dispatch_hardening.sql
--
-- Phase 3 (template-wiring prep) of the customer-OTP-link feature, docs/DECISIONS.md section 10.
--
-- (a) HIGH -- the 6-digit code must never be retained in whatsapp_outbox's stored params/payload,
--     on EVERY path a row can leave this table's protection, not just the two the app code already
--     covers (confirmed send, and a cron/fast-dispatch pass that happens to visit an
--     already-expired-but-still-pending row -- wa-milestone-dispatch-core.ts's
--     customerLinkOtpStillSendable, phase 2). The gap this migration closes: a row that is simply
--     NEVER visited by any dispatch pass before its challenge expires (fast-dispatch secret not
--     yet provisioned, Edge Function down, cron not firing -- all real, documented possibilities in
--     this project's own history) stays `status = 'pending'` forever, so neither the existing
--     application-level redaction (triggers off `status` leaving `'pending'`) nor the DB-level
--     scrub trigger added in 20261120100200_whatsapp_outbox_secret_payload_scrub.sql (same
--     `status`-transition trigger condition) ever fires. A time-based sweep is the only mechanism
--     that can close this: `scrub_expired_customer_link_otp_outbox()`, run every minute by pg_cron
--     (this project's existing pattern -- 20261007120000_lead_followup_notifications.sql,
--     20261022100000_amc_visits_unassigned_until_due.sql), finds any `customer_link_otp` outbox row
--     still `pending` whose challenge has expired/been used/been superseded and clears its secret
--     material directly (belt-and-suspenders with the status-transition trigger: this sweep ALSO
--     flips the row to `'failed'`/`'otp_expired_or_used_db_sweep'` so the existing trigger fires
--     too, and clears payload/template_params itself in the same statement in case the trigger is
--     ever changed later). A 1-minute sweep against a 10-minute expiry bounds the worst-case
--     plaintext exposure window for a row nothing else ever touches to under a minute past expiry,
--     matching the cron granularity already used elsewhere in this project.
--
--     This also makes the `redaction_covered = true` claim already recorded for `customer_link_otp`
--     in `whatsapp_payload_secret_ref_types` (20261120100200) honest for the FIRST time across every
--     code path, not just send/give-up-on-visit: the covered_note is refreshed below to describe
--     all three mechanisms together. `guard_secret_ref_type_template_mapping` (same migration)
--     already refuses any future `whatsapp_event_templates` mapping while `redaction_covered` is
--     false for a registered ref_type -- this migration does not change that guard, it makes the
--     thing the guard is vouching for actually true.
--
-- (b) pg_net hardening -- ATTEMPTED, FOUND INFEASIBLE FOR THIS PROJECT'S MIGRATION ROLE, NOT
--     SILENTLY SKIPPED. The task asked to revoke default PUBLIC/anon/authenticated EXECUTE on
--     `net.*` (pg_net) functions. Read-only live probe (2026-10-30) confirmed the exposure is real:
--     every `net.*` function is owned by `supabase_admin` with `proacl` null (the Postgres
--     function default -- PUBLIC, and therefore anon/authenticated as PUBLIC members, holds
--     EXECUTE). PostgREST never exposes the `net` schema, so this is not reachable from the
--     anon/authenticated API key today, but it is the same shape of exposure this project has been
--     bitten by once before (DECISIONS.md "default-privileges anon EXECUTE leak"), so closing it
--     was worth attempting as defense in depth.
--
--     It was then attempted for real, as a REHEARSAL (rolled back, never committed) rather than
--     assumed: `revoke execute on function net.http_post(...) from public, anon, authenticated`,
--     run as `postgres` (the role every migration on this project runs as -- confirmed
--     `rolsuper = false`, confirmed NOT a member of `supabase_admin`, confirmed not the owner of
--     any `net.*` function). The statement ran WITHOUT ERROR -- but a before/after comparison of
--     `net.http_post`'s own `proacl` and of `has_function_privilege('public', ..., 'execute')`
--     proved the REVOKE silently did nothing: PostgreSQL only lets a REVOKE actually remove a
--     grant that the revoking role itself made (or holds admin/ownership authority over); the
--     implicit PUBLIC-default grant on a function owned by a DIFFERENT role (`supabase_admin`) was
--     made by that owner, not by `postgres`, so `postgres` revoking it is accepted syntactically
--     but has zero effect -- `proacl` went from `null` to an explicit `{=X/supabase_admin,
--     supabase_admin=X/supabase_admin}` (PUBLIC's `=X` entry carried over unchanged) and
--     `has_function_privilege('public', 'net.http_post(...)', 'execute')` stayed `true` before and
--     after. A second probe confirmed there is no workaround available to this role either:
--     `postgres` is not a member of `supabase_admin` (`pg_has_role` false) and
--     `alter default privileges for role supabase_admin in schema net ...` errors
--     "permission denied to change default privileges".
--
--     CONCLUSION: closing PUBLIC/anon/authenticated's default EXECUTE on `net.*` functions
--     requires authority this project's migration role does not have on this project (it would
--     need to run as `supabase_admin` or an actual superuser -- not available to migrations, the
--     Management API connection, or this agent). This migration therefore does NOT attempt to
--     mutate any `net.*` grant -- doing so while reporting success would be a false security
--     claim. The already-existing, already-effective mitigation is unchanged and is the real
--     control here: every caller of `net.http_post` in this codebase
--     (`wa_otp_fast_dispatch_invoke`) is itself a narrowly-scoped SECURITY DEFINER wrapper, OWNED
--     BY `postgres` (so `postgres` CAN and does lock IT down -- revoked from
--     public/anon/authenticated, confirmed by that migration's own existing grant statement),
--     callable only from one other SECURITY DEFINER function in this codebase, never from a grant-
--     mediated external path. `net.*` itself staying PUBLIC-executable by default is unreachable
--     from anywhere outside this project's own Postgres connection (PostgREST never exposes the
--     `net` schema -- confirmed in DECISIONS.md section 2's own prior reasoning), so the residual
--     risk is unchanged from before this migration, not newly accepted by it. Recorded here, and in
--     docs/DECISIONS.md, as a finding for the owner: if closing this at the `net` schema level
--     itself is wanted, it requires a Supabase support request (their own `supabase_admin`-level
--     access), not something buildable from inside this repository.
--
-- (c) HIGH, found by this phase's own independent adversarial review -- see the DO block below for
--     the full finding: is_customer_link_otp_enabled() was never granted EXECUTE to `service_role`,
--     which silently defeated part of this phase's own dispatch-time re-check (wa-milestone-
--     dispatch-core.ts) in real deployment. Fixed here with an additive GRANT.
--
-- Nothing in this migration EDITS the two already-applied migrations
-- (20261120100000_customer_link_otp.sql, 20261120100100_customer_link_otp_fast_dispatch.sql) or the
-- already-committed 20261120100200_whatsapp_outbox_secret_payload_scrub.sql -- additive only.

do $mig$
declare
  v_scrubbed int;
begin
  ----------------------------------------------------------------------------
  -- (a) time-based expiry sweep for customer_link_otp outbox rows -----------
  ----------------------------------------------------------------------------
  if to_regclass('public.customer_link_otp_challenges') is null
     or to_regclass('public.whatsapp_outbox') is null then
    raise exception 'customer_link_otp_dispatch_hardening: prerequisite tables missing -- base migration not applied';
  end if;

  if to_regclass('public.whatsapp_payload_secret_ref_types') is null then
    raise exception 'customer_link_otp_dispatch_hardening: whatsapp_payload_secret_ref_types missing -- 20261120100200 not applied first';
  end if;

  create or replace function public.scrub_expired_customer_link_otp_outbox()
  returns integer
  language plpgsql
  security definer
  set search_path = public, pg_temp
  as $fn$
  declare
    v_count integer;
  begin
    with stale as (
      select o.id
      from public.whatsapp_outbox o
      join public.customer_link_otp_challenges c on c.outbox_id = o.id
      where o.ref_type = 'customer_link_otp'
        and o.status = 'pending'
        and (c.used_at is not null or c.superseded_at is not null or c.expires_at <= clock_timestamp())
      for update of o skip locked
    )
    update public.whatsapp_outbox o
    set status = 'failed',
        error = 'otp_expired_or_used_db_sweep',
        template_params = null,
        payload = case
          when o.payload is not null and o.payload ? 'code'
            then (o.payload - 'code') || jsonb_build_object('body', '[redacted after otp expired/used]')
          else jsonb_build_object('body', '[redacted after otp expired/used]')
        end
    from stale
    where o.id = stale.id;
    get diagnostics v_count = row_count;
    return v_count;
  end;
  $fn$;

  revoke all on function public.scrub_expired_customer_link_otp_outbox() from public, anon, authenticated;
  -- Runs only via pg_cron (as the role that scheduled it, postgres) -- never called from application
  -- code or an Edge Function, so no authenticated/service_role grant is needed either.

  -- Unschedule-then-reschedule makes this migration idempotent on re-run (cron.schedule errors on a
  -- duplicate job name otherwise), same convention as the lead-followup/AMC cron jobs above.
  perform cron.unschedule(jobid) from cron.job where jobname = 'customer-link-otp-expiry-scrub';
  perform cron.schedule('customer-link-otp-expiry-scrub', '* * * * *', 'select public.scrub_expired_customer_link_otp_outbox()');

  -- Refresh the registry note so it accurately describes all coverage paths together (the row
  -- itself, and redaction_covered=true, are unchanged -- this migration does not alter the mapping
  -- guard's verdict, it makes the verdict true for the first time across every path).
  update public.whatsapp_payload_secret_ref_types
  set covered_note = 'Three independent mechanisms now cover customer_link_otp: '
    || '(1) wa-milestone-dispatch-core.ts redacts payload.body to a placeholder on confirmed send '
    || '(v2 path) or on give-up-on-visit (otp_expired_or_used, both dispatch paths); '
    || '(2) scrub_whatsapp_outbox_secret_payload (20261120100200) clears template_params and strips '
    || 'payload.code on any status transition away from pending, DB-level, independent of app code; '
    || '(3) scrub_expired_customer_link_otp_outbox (this migration), a 1-minute pg_cron sweep, '
    || 'closes the remaining gap -- a row dispatch never visits at all before its challenge expires '
    || '-- by finding it directly via customer_link_otp_challenges and flipping/clearing it itself.'
  where ref_type = 'customer_link_otp';

  if not found then
    raise exception 'customer_link_otp_dispatch_hardening: whatsapp_payload_secret_ref_types has no customer_link_otp row -- 20261120100200 not applied first';
  end if;

  ----------------------------------------------------------------------------
  -- (c) HIGH fix, found by this phase's own independent adversarial review (not self-discovered):
  -- is_customer_link_otp_enabled() (20261120100100_customer_link_otp_fast_dispatch.sql) was
  -- granted EXECUTE to `authenticated` only -- never to `service_role`. The new dispatch-time
  -- re-check added this phase to wa-milestone-dispatch-core.ts calls this RPC using the Edge
  -- Function's service-role admin client (the same client every other call in that file uses),
  -- so in real deployment that RPC call would hit "permission denied for function" on every
  -- single customer_link_otp dispatch -- silently swallowed by the re-check's own
  -- fail-open-on-error branch into a log line and an unconditional send, meaning the entire
  -- dispatch-time re-check this phase set out to build would have been a permanent no-op in
  -- production, never actually re-checking anything. Confirmed via to_regprocedure/grant probe
  -- before fixing, not assumed. This does not touch the already-applied 20261120100100 migration
  -- file -- the grant is additive, applied here instead.
  ----------------------------------------------------------------------------
  if to_regprocedure('public.is_customer_link_otp_enabled()') is null then
    raise exception 'customer_link_otp_dispatch_hardening: is_customer_link_otp_enabled() missing -- 20261120100100 not applied first';
  end if;
  grant execute on function public.is_customer_link_otp_enabled() to service_role;

  ----------------------------------------------------------------------------
  -- Assertions -- fail the whole migration unless the end state is exactly as intended.
  ----------------------------------------------------------------------------
  if to_regprocedure('public.scrub_expired_customer_link_otp_outbox()') is null then
    raise exception 'assertion failed: scrub_expired_customer_link_otp_outbox was not created';
  end if;

  if has_function_privilege('anon', 'public.scrub_expired_customer_link_otp_outbox()', 'execute')
     or has_function_privilege('authenticated', 'public.scrub_expired_customer_link_otp_outbox()', 'execute') then
    raise exception 'assertion failed: scrub_expired_customer_link_otp_outbox is anon/authenticated-executable';
  end if;

  if not exists (select 1 from cron.job where jobname = 'customer-link-otp-expiry-scrub') then
    raise exception 'assertion failed: customer-link-otp-expiry-scrub cron job was not scheduled';
  end if;

  if not exists (select 1 from public.whatsapp_payload_secret_ref_types where ref_type = 'customer_link_otp' and redaction_covered = true) then
    raise exception 'assertion failed: customer_link_otp registry row missing or not marked covered';
  end if;

  if not has_function_privilege('service_role', 'public.is_customer_link_otp_enabled()', 'execute') then
    raise exception 'assertion failed: service_role still cannot execute is_customer_link_otp_enabled()';
  end if;
end
$mig$;
