-- DRYRUN-OK copy of the GO APPLY script for migration 20261121100100_customer_link_otp_dispatch_hardening.sql
-- (phase 3, HIGH fix: closes the "never dispatched before expiry" gap in whatsapp_outbox's
-- plaintext-OTP-code retention -- see the migration file's own header comment for the full
-- reasoning, including why the pg_net-hardening half of this phase's task was found infeasible
-- for the migration role and is NOT part of this script), branch feat/customer-otp-link.
--
-- WRITTEN ONLY -- never executed against any database by the agent that produced this file
-- except as a DRYRUN (see below) through the sha256-verified supabase/ops/run_rehearsal.mjs.
--
-- Re-running this script after a successful apply is always a safe no-op refusal (step 3:
-- already-registered check), never a double-apply.


-- 1. Status table -- autocommitted on its own, independent of the DO block's outcome.
drop table if exists pg_temp.dispatch_hardening_apply_status;
create temp table dispatch_hardening_apply_status (
  migration_version text,
  version_registered boolean,
  scrub_function_exists boolean,
  cron_job_scheduled boolean,
  scrub_function_not_anon_executable boolean,
  registry_row_covered boolean,
  org_fingerprint_before text,
  org_fingerprint_after text,
  applied_at timestamptz
);

-- 2. The apply itself -- one DO block, atomic as a whole.
do $apply$
declare
  v_ist_hour                 int;
  v_expected_org_fingerprint text := '6f891cf85011f08c2f22fb4a208d21bd';
  v_org_fingerprint_before   text;
  v_org_fingerprint_after    text;
  v_expected_migration_hash  text := '7fc531e9fc0c8318a0d266c26df1cf9652e023d6d3cc600283d40f341cdb6a0f';
  v_actual_migration_hash    text;
  v_migration_version        text := '20261121100100';
  v_already_registered       boolean;
  v_embedded_migration       text := $migration$-- 20261121100100_customer_link_otp_dispatch_hardening.sql
--
-- Phase 3 (template-wiring prep) of the customer-OTP-link feature, docs/DECISIONS.md section 10.
--
-- (a) HIGH -- the 6-digit code must never be retained in whatsapp_outbox's stored params/payload,
--     on EVERY path a row can leave this table's protection. RECONCILED (2026-10-30) with a
--     concurrent session's own migration, 20261120100200_whatsapp_outbox_secret_payload_scrub.sql
--     (committed to this branch, NOT applied live, NOT edited here -- its bytes are respected as
--     immutable, same as an already-applied migration, per this project's standing convention),
--     into ONE coherent design instead of two separate redaction mechanisms stacked on each other:
--
--     PRIMARY mechanism (owned by 20261120100200, unchanged): a BEFORE UPDATE trigger on
--     whatsapp_outbox, `scrub_whatsapp_outbox_secret_payload`, nulls `template_params` and strips
--     `payload`'s `code` key on ANY status transition away from `'pending'`, for any ref_type
--     registered in `whatsapp_payload_secret_ref_types` with `redaction_covered = true` --
--     `customer_link_otp` already is (that migration's own insert). This fires automatically for
--     EVERY caller that performs such an update: the real send path (wa-send-core.ts's
--     patchForOutcome update, status pending->sent), the give-up-on-visit path
--     (wa-milestone-dispatch-core.ts, status pending->failed), and this migration's own sweep
--     below -- none of them need to null `template_params` themselves, confirmed by this
--     migration's own test actually calling the sweep and checking `template_params` afterward,
--     not assumed from reading the trigger's code alone.
--
--     COMPLEMENTARY, not duplicated: the trigger never touches `payload.body` -- the RENDERED
--     SENTENCE containing the plaintext digits in prose ("482913 is your..."), as opposed to the
--     separate `code` JSON key added later for template-param wiring -- so wa-milestone-dispatch-
--     core.ts's own send-time/give-up updates still explicitly overwrite `payload.body` to a
--     placeholder (unchanged by this migration). The ONE real gap neither the trigger nor any app
--     code can close on its own: a row NO dispatch pass ever visits before its challenge expires
--     (fast-dispatch secret not yet provisioned, Edge Function down, cron not firing -- all real,
--     documented possibilities in this project's own history) stays `status = 'pending'` forever --
--     a trigger only fires on an actual UPDATE, and an unvisited row never gets one. This is the
--     ONLY thing `scrub_expired_customer_link_otp_outbox()` (a 1-minute pg_cron sweep, this
--     project's existing pattern -- 20261007120000_lead_followup_notifications.sql,
--     20261022100000_amc_visits_unassigned_until_due.sql) now does: find such a row and perform
--     the UPDATE (status -> 'failed', `payload.body` -> a placeholder) that both produces the
--     status transition the trigger needs to fire (clearing `template_params`/`payload.code`
--     itself, as the primary mechanism) AND redacts `payload.body` itself (since the trigger
--     won't). A 1-minute sweep against a 10-minute expiry bounds the worst-case plaintext exposure
--     window for a row nothing else ever touches to under a minute past expiry.
--
--     This also makes the `redaction_covered = true` claim already recorded for `customer_link_otp`
--     in `whatsapp_payload_secret_ref_types` (20261120100200) honest for the FIRST time across every
--     code path a row can leave `'pending'` through: the covered_note is refreshed below to
--     describe the reconciled design as one system, not three independent claims. The mapping
--     guard on `whatsapp_event_templates` (same migration, unchanged) already refuses any future
--     mapping while `redaction_covered` is false for a registered ref_type -- it already is true,
--     and the `customer_link_otp -> lexdraft_otp` mapping migration (20261121100200, after this
--     one) depends on that fact, not on anything this migration changes about the guard itself.
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
    -- Reconciled with the OTHER migration this redaction now relies on (20261120100200, committed
    -- by a concurrent session, NOT edited here -- its bytes are respected as if already applied,
    -- per this project's immutable-migration convention): ITS before-update trigger
    -- (scrub_whatsapp_outbox_secret_payload) already nulls template_params and strips payload's
    -- 'code' key on ANY status transition away from 'pending' for a ref_type registered with
    -- redaction_covered = true -- which customer_link_otp already is (that same migration's own
    -- insert). This function's ONLY remaining job is therefore to PRODUCE that transition for a
    -- row nothing else ever updates (the gap that trigger structurally cannot close on its own --
    -- a trigger only fires on an actual UPDATE, and an unvisited row never gets one), and to
    -- redact `payload.body` -- the RENDERED SENTENCE containing the plaintext digits in prose
    -- ("482913 is your..."), which that trigger deliberately does not touch (it only strips the
    -- separate `code` JSON key added later for template-param wiring, not the body text) and
    -- which the app-level send-time redaction (wa-milestone-dispatch-core.ts) does for a row it
    -- actually visits. This function explicitly sets `payload` (full replace, which also drops any
    -- `code` key as a side effect of being a new object) but deliberately does NOT set
    -- `template_params` itself -- that is the other migration's trigger's job, verified by this
    -- migration's own test (G3b) actually calling this function and checking template_params is
    -- null afterward, not assumed.
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
        payload = jsonb_build_object('body', '[redacted after otp expired/used]')
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

  ----------------------------------------------------------------------------
  -- (d) HIGH, found by this phase's own SECOND independent adversarial review (not self-
  -- discovered): a column none of the three reconciled mechanisms above ever touch --
  -- `whatsapp_outbox.wasi_response` (20261016300000_wa_dispatch_v2_schema.sql) -- stores Wasi's
  -- full send-response body (`classifyWasiResponse`/`patchForOutcome`, wa-send-core.ts), passed
  -- through `sanitizeForStorage`/`redactWasiText` first, but that redaction only masks 10-15 digit
  -- runs (phone-number-shaped), never a bare 6-digit code. If Wasi's real API ever echoes a
  -- submitted template param back in its response (a common BSP/webhook pattern, and this phase's
  -- own `components` duplication, part (part of the `customer_link_otp_template_mapping`
  -- migration's TypeScript support) sends the code TWICE in the same request, raising the odds of
  -- exactly that), the plaintext code would sit in `wasi_response` forever, readable via
  -- `whatsapp_outbox_select_staff`, uncovered by any existing mechanism. Not proven exploitable
  -- today (Wasi's real echo behavior for this template is unconfirmed, same caveat as every other
  -- wire-format detail in this feature that only the owner's live phone test can settle) but the
  -- exposure MECHANISM is real and concrete, so this migration closes it now rather than waiting
  -- for that test to find it. A second, separate trigger (own function, own name -- additive,
  -- complementary to 20261120100200's trigger, not a duplicate of it) nulls `wasi_response` under
  -- the identical condition (status leaving 'pending' for a registered-and-covered ref_type).
  create or replace function public.scrub_whatsapp_outbox_wasi_response()
  returns trigger
  language plpgsql
  security definer
  set search_path = public, pg_temp
  as $fn2$
  begin
    if new.ref_type is not null
       and old.status = 'pending' and new.status <> 'pending'
       and exists (
         select 1 from public.whatsapp_payload_secret_ref_types
         where ref_type = new.ref_type and redaction_covered = true
       )
    then
      new.wasi_response := null;
    end if;
    return new;
  end;
  $fn2$;

  drop trigger if exists scrub_whatsapp_outbox_wasi_response on public.whatsapp_outbox;
  create trigger scrub_whatsapp_outbox_wasi_response
    before update on public.whatsapp_outbox
    for each row
    execute function public.scrub_whatsapp_outbox_wasi_response();

  revoke all on function public.scrub_whatsapp_outbox_wasi_response() from public, anon, authenticated;

  -- Refresh the registry note so it accurately describes all coverage paths together, as ONE
  -- reconciled design, not duplicated mechanisms (the row itself, and redaction_covered=true, are
  -- unchanged -- this migration does not alter the mapping guard's verdict, it makes the verdict
  -- true for the first time across every path a row can leave 'pending' through).
  update public.whatsapp_payload_secret_ref_types
  set covered_note = 'customer_link_otp coverage, reconciled 2026-10-30: '
    || 'PRIMARY mechanism, any status transition away from pending -- '
    || 'scrub_whatsapp_outbox_secret_payload (20261120100200)''s trigger nulls template_params and '
    || 'strips payload''s code key generically, for every caller that performs such an update '
    || '(the real send path in wa-send-core.ts, the give-up-on-visit path in '
    || 'wa-milestone-dispatch-core.ts, AND this migration''s own sweep below -- none of them need '
    || 'to null template_params themselves any more, verified by this migration''s own test, not '
    || 'assumed). COMPLEMENTARY, not duplicated: wa-milestone-dispatch-core.ts additionally '
    || 'overwrites payload.body to a placeholder on confirmed send or give-up (the trigger never '
    || 'touches the rendered sentence''s prose, only the separate code key); '
    || 'scrub_expired_customer_link_otp_outbox (this migration, 1-minute pg_cron sweep) does the '
    || 'same payload.body overwrite for the ONE case neither the trigger nor the app-level code can '
    || 'reach on their own -- a row no dispatch pass ever visits before its challenge expires, so '
    || 'no UPDATE (and therefore no trigger fire) would otherwise ever happen. ADDITIONALLY (this '
    || 'migration, second independent review finding): scrub_whatsapp_outbox_wasi_response, a '
    || 'SEPARATE trigger under the identical status-transition condition, nulls wasi_response -- '
    || 'the one column none of the above ever touched, which could otherwise keep the code readable '
    || 'forever if Wasi''s real API ever echoes a submitted template param back in its response.'
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

  if to_regprocedure('public.scrub_whatsapp_outbox_wasi_response()') is null then
    raise exception 'assertion failed: scrub_whatsapp_outbox_wasi_response was not created';
  end if;

  if not exists (select 1 from pg_trigger where tgname = 'scrub_whatsapp_outbox_wasi_response' and tgrelid = 'public.whatsapp_outbox'::regclass and not tgisinternal) then
    raise exception 'assertion failed: scrub_whatsapp_outbox_wasi_response trigger is not attached to whatsapp_outbox';
  end if;

  if has_function_privilege('anon', 'public.scrub_whatsapp_outbox_wasi_response()', 'execute')
     or has_function_privilege('authenticated', 'public.scrub_whatsapp_outbox_wasi_response()', 'execute') then
    raise exception 'assertion failed: scrub_whatsapp_outbox_wasi_response is anon/authenticated-executable';
  end if;
end
$mig$;
$migration$;
begin
  -- DRYRUN-OK: literal first statement of the outer DO block's body -- a pure syntax/compile
  -- check of this exact file. The deeper proof comes from the separate rehearsal wrapper.
  raise exception 'DRYRUN_OK: this exact apply script compiles cleanly -- stopped at the first statement by design, nothing below this line ran, nothing committed';

  -- 0. ORG CHECK
  select md5(o.id::text || '|' || o.name) into v_org_fingerprint_before
  from public.organizations o
  where o.name not like '\_\_TEST%' escape '\'
  order by o.created_at asc
  limit 1;

  if v_org_fingerprint_before is distinct from v_expected_org_fingerprint then
    raise exception 'APPLY_REFUSED: organisation fingerprint mismatch (expected %, got %)',
      v_expected_org_fingerprint, v_org_fingerprint_before;
  end if;

  -- 1. LOCK: scoped to this transaction only.
  perform set_config('lock_timeout', '5s', true);

  -- 2. GATE -- 11:00 IST.
  v_ist_hour := extract(hour from (now() at time zone 'Asia/Kolkata'))::int;
  if v_ist_hour < 11 then
    raise exception 'APPLY_REFUSED: this script only runs after 11:00 IST (current IST hour=%)', v_ist_hour;
  end if;

  -- 3. ALREADY-REGISTERED CHECK
  select exists(
    select 1 from supabase_migrations.schema_migrations where version = v_migration_version
  ) into v_already_registered;

  if v_already_registered then
    raise exception 'APPLY_REFUSED: migration % is already registered -- stop, nothing applied', v_migration_version;
  end if;

  -- 4. PREREQUISITE CHECK -- this script does NOT apply 20261120100200 itself; it must already be live.
  if to_regclass('public.whatsapp_payload_secret_ref_types') is null then
    raise exception 'APPLY_REFUSED: prerequisite migration 20261120100200_whatsapp_outbox_secret_payload_scrub.sql is not applied live yet';
  end if;
  if to_regclass('public.customer_link_otp_challenges') is null or to_regclass('public.whatsapp_outbox') is null then
    raise exception 'APPLY_REFUSED: customer_link_otp_challenges / whatsapp_outbox do not both exist';
  end if;
  if to_regprocedure('public.scrub_expired_customer_link_otp_outbox()') is not null then
    raise exception 'APPLY_REFUSED: public.scrub_expired_customer_link_otp_outbox() already exists before this migration ran';
  end if;

  -- 5. PIN -- CR-tolerant sha256 of the embedded migration text must equal the pinned LF hash.
  v_actual_migration_hash := encode(sha256(convert_to(replace(v_embedded_migration, E'\r', ''), 'UTF8')), 'hex');
  if v_actual_migration_hash is distinct from v_expected_migration_hash then
    raise exception 'APPLY_REFUSED: embedded migration text does not match its pinned sha256 (expected %, got %)',
      v_expected_migration_hash, v_actual_migration_hash;
  end if;

  -- 6. RUN -- apply the pinned migration text verbatim (CR-tolerant).
  execute replace(v_embedded_migration, E'\r', '');

  -- 7. REGISTER
  insert into supabase_migrations.schema_migrations (version, name, statements)
  values (v_migration_version, 'customer_link_otp_dispatch_hardening', array[replace(v_embedded_migration, E'\r', '')]);

  -- 8. POST-APPLY CHECKS
  if to_regprocedure('public.scrub_expired_customer_link_otp_outbox()') is null then
    raise exception 'APPLY_REFUSED: post-apply check failed -- scrub_expired_customer_link_otp_outbox does not exist';
  end if;
  if not exists (select 1 from cron.job where jobname = 'customer-link-otp-expiry-scrub') then
    raise exception 'APPLY_REFUSED: post-apply check failed -- cron job was not scheduled';
  end if;
  if has_function_privilege('anon', 'public.scrub_expired_customer_link_otp_outbox()', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.scrub_expired_customer_link_otp_outbox()', 'EXECUTE') then
    raise exception 'APPLY_REFUSED: post-apply check failed -- scrub function is anon/authenticated-executable';
  end if;
  if not exists (select 1 from public.whatsapp_payload_secret_ref_types where ref_type = 'customer_link_otp' and redaction_covered = true) then
    raise exception 'APPLY_REFUSED: post-apply check failed -- customer_link_otp registry row missing or not covered';
  end if;

  -- 9. real-organisation fingerprint unchanged.
  select md5(o.id::text || '|' || o.name) into v_org_fingerprint_after
  from public.organizations o
  where o.name not like '\_\_TEST%' escape '\'
  order by o.created_at asc
  limit 1;

  if v_org_fingerprint_after is distinct from v_org_fingerprint_before then
    raise exception 'APPLY_REFUSED: post-apply check failed -- real-organisation fingerprint changed (before %, after %)',
      v_org_fingerprint_before, v_org_fingerprint_after;
  end if;

  -- 10. Every step above passed -- record the one status row.
  insert into pg_temp.dispatch_hardening_apply_status (migration_version, version_registered, scrub_function_exists, cron_job_scheduled, scrub_function_not_anon_executable, registry_row_covered, org_fingerprint_before, org_fingerprint_after, applied_at)
  values (
    v_migration_version,
    true,
    true,
    true,
    true,
    true,
    v_org_fingerprint_before,
    v_org_fingerprint_after,
    now()
  );
end
$apply$;

-- 3. The actual thing to look at: one row on success, zero rows if the DO block raised and rolled back.
select * from pg_temp.dispatch_hardening_apply_status;
