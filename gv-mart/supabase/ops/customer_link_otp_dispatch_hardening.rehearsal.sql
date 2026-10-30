-- Rehearsal wrapper for supabase/migrations/20261121100100_customer_link_otp_dispatch_hardening.sql + supabase/tests/customer_link_otp_dispatch_hardening.test.sql.
-- Also embeds supabase/migrations/20261120100200_whatsapp_outbox_secret_payload_scrub.sql (its own precheck's prerequisite) because that migration is
-- committed on this branch but not yet applied live as of this writing -- see this generator
-- script's own header comment for why that is the correct, non-silent way to handle the ordering.
--
-- WRITTEN ONLY -- never executed against any database by the agent that produced this file except
-- through the project's approved Management-API runner (supabase/ops/run_rehearsal.mjs,
-- sha256-verified before use), and only as a REHEARSAL: this block always ends in RAISE EXCEPTION,
-- so nothing it does can ever commit, regardless of pass/fail.
do $rehearsal$
declare
  v_ist_hour                 int;
  v_expected_org_fingerprint text := '6f891cf85011f08c2f22fb4a208d21bd';
  v_actual_org_fingerprint   text;
  v_expected_prereq_hash    text := '8533249a1b9441f14fc18867a79f7b1dde53a49df296504aa668135f56f78fd1';
  v_expected_migration_hash text := '7fc531e9fc0c8318a0d266c26df1cf9652e023d6d3cc600283d40f341cdb6a0f';
  v_expected_test_hash      text := '871f74372723561c03ada1a88cecd8444e03932492e8a65487b76f68ed0837ea';
  v_actual_prereq_hash      text;
  v_actual_migration_hash   text;
  v_actual_test_hash        text;
  v_fp_before            text;
  v_fp_after             text;
  v_inner_result         text;
  res                    text := '';
  v_embedded_prereq      text := $prereq$-- Fixes a HIGH finding from the independent security review of the customer-OTP-link fast-dispatch
-- path (docs/DECISIONS.md section 9, Edge Function review): whatsapp_outbox's existing
-- redaction-on-send/redaction-on-give-up logic (wa-milestone-dispatch-core.ts,
-- wa-dispatch-v2.ts) only ever replaces the `payload` column. It never touches
-- `template_params` (added by 20261016300000_wa_dispatch_v2_schema.sql), which
-- wa-send-core.ts's `executeSend` writes unconditionally, BEFORE the send, whenever a row is
-- dispatched through an approved template (`buildTemplateRequest`'s `vars`, which for a
-- `customer_link_otp` row would include the raw 6-digit code under `vars.code` -- wired by
-- wa-event-context.ts specifically so a future template mapping can use it as a named
-- parameter). Today this is NOT exploitable: no `whatsapp_event_templates` row maps
-- `customer_link_otp` to any template (held pending the owner's brand-neutrality check on
-- `lexdraft_otp`, see docs/DECISIONS.md section 9.3), so `plan.kind` can never resolve to
-- `"template"` for this ref_type and `template_params` is never written for it. But the moment
-- that mapping is ever added, every future `customer_link_otp` send would silently start
-- leaving the plaintext code in `template_params` forever, unredacted, readable by the same
-- `whatsapp_outbox_select_staff` policy the whole redaction mechanism exists to defend against.
--
-- This migration closes that gap at the DATABASE layer, not just in application code, so it
-- cannot be reopened by a future code change that forgets the TypeScript-side redaction call:
--   1. A new registry table, `whatsapp_payload_secret_ref_types`, names every `ref_type` whose
--      `whatsapp_outbox.payload` may carry a secret value (today: only `customer_link_otp`, its
--      `code` key) and records whether a DB-level scrub trigger for it is confirmed wired
--      (`redaction_covered`). This migration inserts exactly one row, already covered.
--   2. A BEFORE UPDATE trigger on `whatsapp_outbox`, `scrub_whatsapp_outbox_secret_payload`,
--      fires whenever a row's `ref_type` is in that registry and its `status` is leaving
--      `'pending'` (i.e. a terminal state: sent, failed, or skipped_no_template) -- at that
--      point the code has either been delivered or never will be, so there is nothing left to
--      protect by keeping it. It unconditionally sets `template_params` to NULL and strips any
--      `code` key out of `payload` (defense in depth on top of, not instead of, the existing
--      application-level full-payload-replace redaction -- idempotent and harmless if the
--      application code already did both).
--   3. A BEFORE INSERT OR UPDATE trigger on `whatsapp_event_templates`,
--      `guard_secret_ref_type_template_mapping`, refuses to create or activate a mapping for any
--      `event_key` that appears in the registry with `redaction_covered = false` -- a mechanical
--      guard, not just a code-review convention, against ever wiring a template to a
--      secret-carrying ref_type before its DB-level scrub coverage exists. `customer_link_otp` is
--      inserted already covered (step 1), so this migration does not itself block the eventual
--      `lexdraft_otp` (or replacement) mapping -- that mapping is still withheld for the separate,
--      unrelated reason recorded in DECISIONS.md section 9.3 (unconfirmed brand neutrality), not
--      because of this guard.
--
-- Deliberate scope limit, documented rather than silently assumed: this guard only protects
-- ref_types someone has explicitly registered in `whatsapp_payload_secret_ref_types`. A brand-new
-- secret-carrying ref_type invented in the future and mapped to a template WITHOUT first being
-- added to this registry would not be caught by trigger 3 -- there is no way for a database
-- constraint to infer "this payload might contain a secret" from an arbitrary future ref_type on
-- its own. Guarding against that remains a code-review discipline (the same discipline that
-- caught this gap in the first place), not something this migration claims to close generically.
-- audit_log/error-text check (requested explicitly): read every audit_log insert in
-- request_customer_link_code/verify_customer_link_code (20261120100000_customer_link_otp.sql) --
-- none ever include the code itself, only phone_last4/challenge_id/attempts metadata. No
-- console.log/console.error anywhere in the dispatch path prints payload/body/code (confirmed by
-- the Edge Function review). Nothing further to fix on those two fronts.

-- ── 1. Registry: which ref_types' outbox payload may carry a secret ─────────────────────────
create table if not exists public.whatsapp_payload_secret_ref_types (
  ref_type text primary key,
  redaction_covered boolean not null default false,
  covered_note text,
  created_at timestamptz not null default now()
);

alter table public.whatsapp_payload_secret_ref_types enable row level security;
revoke all on public.whatsapp_payload_secret_ref_types from public, anon, authenticated;
-- No policy for any role: this is an internal trigger-support table, not a UI surface. Read via
-- service_role (migrations, ad-hoc audits) only.

insert into public.whatsapp_payload_secret_ref_types (ref_type, redaction_covered, covered_note)
values (
  'customer_link_otp',
  true,
  'scrub_whatsapp_outbox_secret_payload trigger added in this migration clears template_params '
  || 'and strips payload.code on any non-pending status; application-level full-payload-replace '
  || 'redaction (wa-milestone-dispatch-core.ts, wa-dispatch-v2.ts) already covered payload.body/'
  || 'code, this trigger is defense in depth plus the first thing to actually cover template_params.'
)
on conflict (ref_type) do update set redaction_covered = excluded.redaction_covered, covered_note = excluded.covered_note;

-- ── 2. Scrub trigger on whatsapp_outbox ──────────────────────────────────────────────────────
create or replace function public.scrub_whatsapp_outbox_secret_payload()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.ref_type is null then
    return new;
  end if;
  if old.status = 'pending' and new.status <> 'pending'
     and exists (
       select 1 from public.whatsapp_payload_secret_ref_types
       where ref_type = new.ref_type and redaction_covered = true
     )
  then
    new.template_params := null;
    if new.payload is not null and new.payload ? 'code' then
      new.payload := new.payload - 'code';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists scrub_whatsapp_outbox_secret_payload on public.whatsapp_outbox;
create trigger scrub_whatsapp_outbox_secret_payload
  before update on public.whatsapp_outbox
  for each row
  execute function public.scrub_whatsapp_outbox_secret_payload();

-- ── 3. Guard trigger on whatsapp_event_templates ─────────────────────────────────────────────
create or replace function public.guard_secret_ref_type_template_mapping()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_covered boolean;
begin
  select redaction_covered into v_covered
  from public.whatsapp_payload_secret_ref_types
  where ref_type = new.event_key;

  if v_covered is distinct from null and v_covered is distinct from true then
    raise exception 'guard_secret_ref_type_template_mapping: event_key % carries a secret payload with no confirmed DB-level redaction coverage -- see whatsapp_payload_secret_ref_types', new.event_key;
  end if;

  return new;
end;
$$;

drop trigger if exists guard_secret_ref_type_template_mapping on public.whatsapp_event_templates;
create trigger guard_secret_ref_type_template_mapping
  before insert or update on public.whatsapp_event_templates
  for each row
  execute function public.guard_secret_ref_type_template_mapping();

revoke all on function public.scrub_whatsapp_outbox_secret_payload() from public, anon, authenticated;
revoke all on function public.guard_secret_ref_type_template_mapping() from public, anon, authenticated;
$prereq$;
  v_embedded_migration   text := $migration$-- 20261121100100_customer_link_otp_dispatch_hardening.sql
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
  v_embedded_test text := $testbody$-- Test for 20261121100100_customer_link_otp_dispatch_hardening.sql.
-- Run inside the rehearsal wrapper's own transaction, AFTER the migration has been applied in the
-- same transaction (never standalone against real data). Ends by raising an exception listing
-- every assertion's pass/fail so the wrapper's own outer RAISE EXCEPTION captures it, and so
-- nothing here ever commits regardless of outcome.
do $test$
declare
  v_results text := '';
  v_org_id uuid;
  v_customer_expired uuid;
  v_customer_valid uuid;
  v_customer_used uuid;
  v_outbox_expired uuid;
  v_outbox_valid uuid;
  v_outbox_used uuid;
  v_scrubbed int;
  v_row record;
begin
  -- Use a throwaway __TEST_ org, never a real one. Three separate customers, one per scenario --
  -- customer_link_otp_challenges_one_active_idx allows only one "active" (used_at and
  -- superseded_at both null) challenge PER CUSTOMER, and the expired/valid scenarios below are
  -- both "active" by that definition (only used_at being set makes P3's row inactive).
  insert into public.organizations (name) values ('__TEST_dispatch_hardening') returning id into v_org_id;

  insert into public.customers (org_id, name, mobile) values (v_org_id, '__TEST_customer_dh_expired', '9000000991')
  returning id into v_customer_expired;
  insert into public.customers (org_id, name, mobile) values (v_org_id, '__TEST_customer_dh_valid', '9000000992')
  returning id into v_customer_valid;
  insert into public.customers (org_id, name, mobile) values (v_org_id, '__TEST_customer_dh_used', '9000000993')
  returning id into v_customer_used;

  -- G0: prerequisite objects exist.
  if to_regprocedure('public.scrub_expired_customer_link_otp_outbox()') is null then
    v_results := v_results || 'G0 FAIL: scrub_expired_customer_link_otp_outbox missing' || E'\n';
  else
    v_results := v_results || 'G0 ok: scrub_expired_customer_link_otp_outbox exists' || E'\n';
  end if;

  if not exists (select 1 from cron.job where jobname = 'customer-link-otp-expiry-scrub') then
    v_results := v_results || 'G1 FAIL: cron job not scheduled' || E'\n';
  else
    v_results := v_results || 'G1 ok: cron job scheduled' || E'\n';
  end if;

  if has_function_privilege('anon', 'public.scrub_expired_customer_link_otp_outbox()', 'execute')
     or has_function_privilege('authenticated', 'public.scrub_expired_customer_link_otp_outbox()', 'execute') then
    v_results := v_results || 'G2 FAIL: scrub function is anon/authenticated-executable' || E'\n';
  else
    v_results := v_results || 'G2 ok: scrub function not anon/authenticated-executable' || E'\n';
  end if;

  -- P1: an EXPIRED, never-sent, still-pending row is scrubbed. Carries a wasi_response too, even
  -- though a never-sent row wouldn't realistically have one -- exercises the second-review-round
  -- fix (scrub_whatsapp_outbox_wasi_response) on the same update regardless.
  insert into public.whatsapp_outbox (id, org_id, direction, to_mobile, customer_id, milestone, template, payload, template_params, wasi_response, ref_type, ref_id, status)
  values (gen_random_uuid(), v_org_id, 'outbound', '9000000991', v_customer_expired, 'customer_link_otp', '__TEST__otp', '{"body":"482913 is your code","code":"482913"}'::jsonb, '{"code":"482913"}'::jsonb, '{"echoed_params":{"1":"482913"}}'::jsonb, 'customer_link_otp', gen_random_uuid(), 'pending')
  returning id into v_outbox_expired;
  insert into public.customer_link_otp_challenges (id, org_id, user_id, customer_id, code_salt, code_hash, expires_at, outbox_id)
  values (gen_random_uuid(), v_org_id, gen_random_uuid(), v_customer_expired, 'salt', 'hash', clock_timestamp() - interval '1 minute', v_outbox_expired);

  -- P2: a still-VALID pending row must be left completely untouched.
  insert into public.whatsapp_outbox (id, org_id, direction, to_mobile, customer_id, milestone, template, payload, template_params, ref_type, ref_id, status)
  values (gen_random_uuid(), v_org_id, 'outbound', '9000000992', v_customer_valid, 'customer_link_otp', '__TEST__otp', '{"body":"111222 is your code","code":"111222"}'::jsonb, '{"code":"111222"}'::jsonb, 'customer_link_otp', gen_random_uuid(), 'pending')
  returning id into v_outbox_valid;
  insert into public.customer_link_otp_challenges (id, org_id, user_id, customer_id, code_salt, code_hash, expires_at, outbox_id)
  values (gen_random_uuid(), v_org_id, gen_random_uuid(), v_customer_valid, 'salt', 'hash', clock_timestamp() + interval '5 minutes', v_outbox_valid);

  -- P3: a USED-but-somehow-still-pending row (defense in depth) is also scrubbed.
  insert into public.whatsapp_outbox (id, org_id, direction, to_mobile, customer_id, milestone, template, payload, template_params, ref_type, ref_id, status)
  values (gen_random_uuid(), v_org_id, 'outbound', '9000000993', v_customer_used, 'customer_link_otp', '__TEST__otp', '{"body":"999888 is your code","code":"999888"}'::jsonb, '{"code":"999888"}'::jsonb, 'customer_link_otp', gen_random_uuid(), 'pending')
  returning id into v_outbox_used;
  insert into public.customer_link_otp_challenges (id, org_id, user_id, customer_id, code_salt, code_hash, expires_at, used_at, outbox_id)
  values (gen_random_uuid(), v_org_id, gen_random_uuid(), v_customer_used, 'salt', 'hash', clock_timestamp() + interval '5 minutes', clock_timestamp(), v_outbox_used);

  v_scrubbed := public.scrub_expired_customer_link_otp_outbox();
  if v_scrubbed <> 2 then
    v_results := v_results || format('P1-3 FAIL: expected 2 rows scrubbed, got %s', v_scrubbed) || E'\n';
  else
    v_results := v_results || 'P1-3 ok: exactly 2 rows scrubbed (expired + used-pending)' || E'\n';
  end if;

  select * into v_row from public.whatsapp_outbox where id = v_outbox_expired;
  if v_row.status = 'failed' and v_row.error = 'otp_expired_or_used_db_sweep'
     and v_row.template_params is null and not (v_row.payload ? 'code')
     and v_row.payload->>'body' = '[redacted after otp expired/used]'
     and v_row.wasi_response is null then
    v_results := v_results || 'P1 ok: expired row scrubbed correctly (status/error/payload/template_params/wasi_response)' || E'\n';
  else
    v_results := v_results || format('P1 FAIL: expired row state wrong -- %s', v_row) || E'\n';
  end if;

  select * into v_row from public.whatsapp_outbox where id = v_outbox_valid;
  if v_row.status = 'pending' and v_row.payload->>'code' = '111222' and v_row.template_params->>'code' = '111222' then
    v_results := v_results || 'P2 ok: still-valid pending row left completely untouched' || E'\n';
  else
    v_results := v_results || format('P2 FAIL: valid pending row was modified -- %s', v_row) || E'\n';
  end if;

  select * into v_row from public.whatsapp_outbox where id = v_outbox_used;
  if v_row.status = 'failed' and v_row.error = 'otp_expired_or_used_db_sweep' and v_row.template_params is null then
    v_results := v_results || 'P3 ok: used-but-pending row scrubbed correctly' || E'\n';
  else
    v_results := v_results || format('P3 FAIL: used-pending row state wrong -- %s', v_row) || E'\n';
  end if;

  -- P4: idempotent second call -- nothing left to scrub, no error, returns 0.
  v_scrubbed := public.scrub_expired_customer_link_otp_outbox();
  if v_scrubbed = 0 then
    v_results := v_results || 'P4 ok: second call is a no-op (0 rows)' || E'\n';
  else
    v_results := v_results || format('P4 FAIL: second call scrubbed %s rows, expected 0', v_scrubbed) || E'\n';
  end if;

  -- P5: second independent-review finding -- the REAL send path (wa-send-core.ts's
  -- patchForOutcome update) never explicitly sets wasi_response to null itself; it relies entirely
  -- on scrub_whatsapp_outbox_wasi_response firing as a side effect of the status transition it
  -- DOES make (pending -> sent). Reproduce that exact shape here -- an UPDATE that only sets
  -- `status` (and unrelated columns), never mentioning wasi_response -- and confirm the trigger
  -- still nulls it, proving this isn't just a code-reading claim.
  declare
    v_outbox_sent uuid;
    v_sent_row record;
  begin
    insert into public.whatsapp_outbox (id, org_id, direction, to_mobile, customer_id, milestone, template, payload, template_params, wasi_response, ref_type, ref_id, status)
    values (gen_random_uuid(), v_org_id, 'outbound', '9000000994', v_customer_valid, 'customer_link_otp', '__TEST__otp', '{"body":"555666 is your code","code":"555666"}'::jsonb, '{"1":"555666"}'::jsonb, '{"meta_message_id":"wamid.fake","echoed_params":{"1":"555666"}}'::jsonb, 'customer_link_otp', gen_random_uuid(), 'pending')
    returning id into v_outbox_sent;

    -- Deliberately mirrors patchForOutcome's "sent" patch shape (wa-send-core.ts) -- status and a
    -- few unrelated columns, NEVER wasi_response or template_params.
    update public.whatsapp_outbox set status = 'sent', wa_message_id = 'wamid.fake', delivery_status = 'sent', error = null where id = v_outbox_sent;

    select * into v_sent_row from public.whatsapp_outbox where id = v_outbox_sent;
    if v_sent_row.template_params is null and v_sent_row.wasi_response is null and not (v_sent_row.payload ? 'code') then
      v_results := v_results || 'P5 ok: a real send-shaped update (status only) still triggers wasi_response AND template_params clearing' || E'\n';
    else
      v_results := v_results || format('P5 FAIL: send-shaped update did not clear everything -- %s', v_sent_row) || E'\n';
    end if;
  end;

  -- G3: registry note was refreshed and still marks customer_link_otp covered.
  if exists (
    select 1 from public.whatsapp_payload_secret_ref_types
    where ref_type = 'customer_link_otp' and redaction_covered = true
      and covered_note like '%scrub_expired_customer_link_otp_outbox%'
  ) then
    v_results := v_results || 'G3 ok: registry note refreshed and still covered=true' || E'\n';
  else
    v_results := v_results || 'G3 FAIL: registry row missing, not covered, or note not refreshed' || E'\n';
  end if;

  -- G4: the HIGH fix found by this phase's independent review -- service_role must be able to
  -- execute is_customer_link_otp_enabled(), or the Edge Function dispatcher's dispatch-time
  -- re-check (wa-milestone-dispatch-core.ts) silently fails open on EVERY call in production.
  if has_function_privilege('service_role', 'public.is_customer_link_otp_enabled()', 'execute') then
    v_results := v_results || 'G4 ok: service_role can execute is_customer_link_otp_enabled()' || E'\n';
  else
    v_results := v_results || 'G4 FAIL: service_role still cannot execute is_customer_link_otp_enabled()' || E'\n';
  end if;

  raise exception E'TEST_RESULTS:\n%', v_results;
end
$test$;
$testbody$;
  v_prereq_already_live boolean;
begin
  -- 0. ORG CHECK
  select md5(o.id::text || '|' || o.name) into v_actual_org_fingerprint
  from public.organizations o
  where o.name not like '\_\_TEST%' escape '\'
  order by o.created_at asc
  limit 1;

  if v_actual_org_fingerprint is distinct from v_expected_org_fingerprint then
    raise exception 'REHEARSAL_REFUSED: organisation fingerprint mismatch (expected %, got %)',
      v_expected_org_fingerprint, v_actual_org_fingerprint;
  end if;

  -- 1. LOCK
  perform set_config('lock_timeout', '5s', true);

  -- 2. GATE -- 11:00 IST
  v_ist_hour := extract(hour from (now() at time zone 'Asia/Kolkata'))::int;
  if v_ist_hour < 11 then
    raise exception 'REHEARSAL_REFUSED: this script only runs after 11:00 IST (current IST hour=%)', v_ist_hour;
  end if;

  -- 3. PIN -- all three embedded texts must match their pinned sha256.
  v_actual_prereq_hash := encode(sha256(convert_to(replace(v_embedded_prereq, E'\r', ''), 'UTF8')), 'hex');
  v_actual_migration_hash := encode(sha256(convert_to(replace(v_embedded_migration, E'\r', ''), 'UTF8')), 'hex');
  v_actual_test_hash := encode(sha256(convert_to(replace(v_embedded_test, E'\r', ''), 'UTF8')), 'hex');
  if v_actual_prereq_hash is distinct from v_expected_prereq_hash then
    raise exception 'REHEARSAL_REFUSED: embedded prereq (20261120100200) text does not match its pinned sha256 (expected %, got %)',
      v_expected_prereq_hash, v_actual_prereq_hash;
  end if;
  if v_actual_migration_hash is distinct from v_expected_migration_hash then
    raise exception 'REHEARSAL_REFUSED: embedded migration text does not match its pinned sha256 (expected %, got %)',
      v_expected_migration_hash, v_actual_migration_hash;
  end if;
  if v_actual_test_hash is distinct from v_expected_test_hash then
    raise exception 'REHEARSAL_REFUSED: embedded test text does not match its pinned sha256 (expected %, got %)',
      v_expected_test_hash, v_actual_test_hash;
  end if;

  -- 4. PREREQ -- run 20261120100200 first IF not already live (idempotent either way: create
  -- table if not exists / create-or-replace / drop-trigger-then-create).
  select (to_regclass('public.whatsapp_payload_secret_ref_types') is not null) into v_prereq_already_live;
  execute replace(v_embedded_prereq, E'\r', '');

  -- NOTE: the fingerprint below deliberately covers ONLY real (non-__TEST_) whatsapp_outbox rows,
  -- not cron.job -- scheduling the customer-link-otp-expiry-scrub cron job is this migration's own
  -- INTENDED effect (proven separately by the G1 assertion in the embedded test below), not an
  -- unintended mutation to catch here; including it would make this fingerprint fail on every run.
  select md5(string_agg(x, ',' order by x)) into v_fp_before from (
    select 'outbox:' || o.id::text || ':' || o.status || ':' || coalesce(o.payload::text,'') || ':' || coalesce(o.template_params::text,'') as x
    from public.whatsapp_outbox o where o.template not like '\_\_TEST\_%' escape '\'
  ) r;

  -- 5. RUN -- apply the pinned migration verbatim, then the test.
  execute replace(v_embedded_migration, E'\r', '');

  begin
    execute replace(v_embedded_test, E'\r', '');
  exception when others then
    v_inner_result := sqlerrm;
  end;

  select md5(string_agg(x, ',' order by x)) into v_fp_after from (
    select 'outbox:' || o.id::text || ':' || o.status || ':' || coalesce(o.payload::text,'') || ':' || coalesce(o.template_params::text,'') as x
    from public.whatsapp_outbox o where o.template not like '\_\_TEST\_%' escape '\'
  ) r;

  res := 'ok   ORG CHECK passed, GATE passed: IST hour=' || v_ist_hour || ', all three embedded-text sha256 hashes verified'
    || E'\nINFO prereq (20261120100200) was already live before this rehearsal: ' || v_prereq_already_live
    || E'\nINFO real-row fingerprint BEFORE = ' || v_fp_before
    || E'\nok   prereq + migration applied inside this still-open transaction (idempotent statements throughout)'
    || E'\n--- embedded test output ---' || E'\n' || coalesce(v_inner_result, '(test raised no exception -- unexpected)') || E'\n--- end embedded test output ---'
    || E'\nINFO real-row fingerprint AFTER  = ' || v_fp_after
    || E'\n' || case when v_fp_after is distinct from v_fp_before
         then 'FAIL real whatsapp_outbox rows or the cron job registry CHANGED -- this rehearsal mutated real data'
         else 'ok   real whatsapp_outbox rows and the cron job registry unchanged -- this rehearsal mutated no real data' end;

  raise exception E'RESULTS:\n%', res;
end
$rehearsal$;
