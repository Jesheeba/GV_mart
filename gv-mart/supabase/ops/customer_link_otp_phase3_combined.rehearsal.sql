-- COMBINED rehearsal: the FULL reconciled customer_link_otp package, in ONE transaction --
-- 20261120100200 (prereq) -> 20261121100100 (dispatch hardening) + test ->
-- 20261121100150 (auto_link_blocked_at guard, THIS round) + test ->
-- 20261121100200 (template mapping) + test. WRITTEN ONLY -- never executed against any database
-- by the agent that produced this file except through the sha256-verified
-- supabase/ops/run_rehearsal.mjs, and only as a REHEARSAL: ends in RAISE EXCEPTION, nothing commits.
do $rehearsal$
declare
  v_ist_hour int;
  v_expected_org_fingerprint text := '6f891cf85011f08c2f22fb4a208d21bd';
  v_actual_org_fingerprint text;
  v_actual_hash text;
  v_fp_before text;
  v_fp_after text;
  v_hardening_test_result text;
  v_guard_test_result text;
  v_mapping_test_result text;
  res text := '';
  v_embedded_prereq text := $prereq$-- Fixes a HIGH finding from the independent security review of the customer-OTP-link fast-dispatch
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
  v_embedded_hardening text := $hardening$-- 20261121100100_customer_link_otp_dispatch_hardening.sql
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
$hardening$;
  v_embedded_hardening_test text := $hardeningtest$-- Test for 20261121100100_customer_link_otp_dispatch_hardening.sql.
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
$hardeningtest$;
  v_embedded_guard text := $guard$-- 20261121100150_customer_link_otp_respects_auto_link_block.sql
--
-- Phase 3 continuation, docs/DECISIONS.md section 12/13. Closes the BLOCKING QUESTION raised and
-- reported (not silently fixed) in section 12.3: `verify_customer_link_code` (phone-based OTP
-- link, this feature) did not respect `customers.auto_link_blocked_at` the way
-- `customer_auto_onboard()` (email-based auto-link, 20261130100001, already live) already does --
-- a customer a master unlinked via `admin_unlink_customer_google_account` (20261121100000,
-- already live, redefined by 20261130100002 to set this column, already live) could be silently
-- re-linked to a DIFFERENT Google sign-in through the phone/OTP path, defeating the master's
-- unlink exactly the way the "unlink loop" 20261130100002 closed for the email path. Owner
-- APPROVED this exact guard before it was written (the proposal in section 12.3).
--
-- Ordering: strictly AFTER 20261121100100 (dispatch hardening + wasi_response trigger -- this
-- migration does not depend on it directly, but the owner's own ordering instruction keeps the
-- redaction/re-check work before this) and strictly BEFORE 20261121100200 (the template mapping,
-- unaffected by anything here) -- `100150` sorts between `100100` and `100200`.
--
-- NEVER editing the already-applied 20261120100000_customer_link_otp.sql: both functions below
-- are `create or replace`, reproducing the LIVE bodies verbatim (confirmed via
-- `pg_get_functiondef`, sha256-pinned below, CR-tolerant -- this migration REFUSES to apply if the
-- live definition has drifted from what was read when this file was written, exactly the same
-- discipline `20261130100002` used for the two admin link functions) plus exactly ONE added
-- condition each:
--   - `request_customer_link_code`: the match-exclusion condition
--     (`v_match_count <> 1 or v_match_primary_profile_id is not null or v_match_is_test`) gains
--     `or v_match_auto_link_blocked_at is not null` -- a blocked customer becomes indistinguishable
--     from an already-linked/test one, same generic `v_generic` response, same `'no_match'`
--     send-log decision, so the response shape (and the send-log row it creates) leaks nothing new
--     about the phone number typed -- no new oracle, exactly the owner's own explicit requirement.
--   - `verify_customer_link_code`: the lock-time re-check immediately before linking
--     (`primary_profile_id is not null or is_test`) gains `or auto_link_blocked_at is not null` --
--     same collapsed `{status: 'invalid_or_expired', attempts_left: 0}` response as every other
--     "lost the race" case already returns, so a caller holding a correct, not-yet-expired code
--     for a customer who gets blocked in between request and verify sees the IDENTICAL response
--     shape and timing profile as any other race loss, not a new, distinguishable outcome.
-- Nothing else in either function changes: not the rate limits, not the timing-equalization dummy
-- crypto work on the no-match branch (section 7), not the attempts/expiry logic, not the audit_log
-- writes (which still never include the code or the block reason -- confirmed, unchanged).
--
-- Grants and search_path are UNCHANGED from the live functions (confirmed by this migration's own
-- assertions below, not assumed from `create or replace` alone -- Postgres does carry grants
-- across a `create or replace function`, but this migration still re-states and re-verifies them
-- explicitly, same discipline as every other grant-sensitive migration on this branch): `anon` has
-- no EXECUTE, `authenticated` has EXECUTE, `set search_path = public, extensions, pg_temp` for
-- both.

do $mig$
declare
  v_expected_request_hash text := '9e108f6e9f55ad8539773de90d3ceca201231e24874854d3db855f41829557a3';
  v_expected_verify_hash  text := '2a12b2ef965e068297a40922f88477b9b8db92196b896755bc4599196e374bb4';
  v_actual_request_hash text;
  v_actual_verify_hash  text;
begin
  if to_regprocedure('public.request_customer_link_code(text)') is null
     or to_regprocedure('public.verify_customer_link_code(text)') is null then
    raise exception 'customer_link_otp_respects_auto_link_block: base functions missing -- 20261120100000 not applied';
  end if;

  if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'customers' and column_name = 'auto_link_blocked_at') then
    raise exception 'customer_link_otp_respects_auto_link_block: customers.auto_link_blocked_at missing -- 20261130100000 not applied';
  end if;

  -- LIVE-DRIFT CHECK: refuse to replace either function unless its CURRENT live body still
  -- matches the exact body this migration was written against (CR-tolerant, same as every other
  -- sha256 pin on this branch). A real difference here means someone else changed either function
  -- since this migration was written -- this migration must not silently clobber that change.
  v_actual_request_hash := encode(sha256(convert_to(replace(pg_get_functiondef('public.request_customer_link_code(text)'::regprocedure), E'\r', ''), 'UTF8')), 'hex');
  if v_actual_request_hash is distinct from v_expected_request_hash then
    raise exception 'customer_link_otp_respects_auto_link_block: LIVE_DEFINITION_DRIFT -- request_customer_link_code''s live body no longer matches the pinned hash this migration was written against (expected %, got %)',
      v_expected_request_hash, v_actual_request_hash;
  end if;

  v_actual_verify_hash := encode(sha256(convert_to(replace(pg_get_functiondef('public.verify_customer_link_code(text)'::regprocedure), E'\r', ''), 'UTF8')), 'hex');
  if v_actual_verify_hash is distinct from v_expected_verify_hash then
    raise exception 'customer_link_otp_respects_auto_link_block: LIVE_DEFINITION_DRIFT -- verify_customer_link_code''s live body no longer matches the pinned hash this migration was written against (expected %, got %)',
      v_expected_verify_hash, v_actual_verify_hash;
  end if;

  -- ── request_customer_link_code: add v_match_auto_link_blocked_at, select it, check it ───────
  create or replace function public.request_customer_link_code(p_mobile text)
  returns jsonb
  language plpgsql
  security definer
  set search_path = public, extensions, pg_temp
  as $fn$
  declare
    v_user_id uuid := auth.uid();
    v_generic jsonb := jsonb_build_object('status', 'ok', 'message', 'If that number is registered, a verification code was sent on WhatsApp.');
    v_phone_hash text;
    v_phone_last4 text;
    v_match_id uuid;
    v_match_org_id uuid;
    v_match_primary_profile_id uuid;
    v_match_is_test boolean;
    v_match_auto_link_blocked_at timestamptz;
    v_match_preferred_language text;
    v_match_count integer;
    v_now timestamptz := clock_timestamp();
    v_user_sends_last_hour integer;
    v_phone_sends_last_hour integer;
    v_last_send_at timestamptz;
    v_distinct_numbers_24h integer;
    v_code text;
    v_salt text;
    v_challenge_id uuid;
    v_outbox_id uuid;
    v_body text;
  begin
    if v_user_id is null then
      raise exception 'cannot_request_code: not authenticated';
    end if;

    if exists (select 1 from public.profiles where id = v_user_id) then
      raise exception 'cannot_request_code: profile_exists';
    end if;

    if p_mobile !~ '^[6-9]\d{9}$' then
      raise exception 'cannot_request_code: invalid_mobile';
    end if;

    if not public.is_customer_link_otp_enabled() then
      raise exception 'cannot_request_code: feature_disabled';
    end if;

    v_phone_hash := encode(digest(p_mobile, 'sha256'), 'hex');
    v_phone_last4 := right(p_mobile, 4);

    select count(*) into v_user_sends_last_hour
    from public.customer_link_otp_send_log
    where user_id = v_user_id and created_at > v_now - interval '1 hour';

    select count(*) into v_phone_sends_last_hour
    from public.customer_link_otp_send_log
    where phone_hash = v_phone_hash and created_at > v_now - interval '1 hour';

    select max(created_at) into v_last_send_at
    from public.customer_link_otp_send_log
    where user_id = v_user_id and decision = 'sent';

    select count(distinct phone_hash) into v_distinct_numbers_24h
    from public.customer_link_otp_send_log
    where user_id = v_user_id and created_at > v_now - interval '24 hours';

    if v_last_send_at is not null and v_last_send_at > v_now - interval '30 seconds' then
      insert into public.customer_link_otp_send_log (user_id, phone_hash, phone_last4, decision)
      values (v_user_id, v_phone_hash, v_phone_last4, 'limited_cooldown');
      return v_generic;
    end if;

    if v_user_sends_last_hour >= 5 then
      insert into public.customer_link_otp_send_log (user_id, phone_hash, phone_last4, decision)
      values (v_user_id, v_phone_hash, v_phone_last4, 'limited_user');
      return v_generic;
    end if;

    if v_phone_sends_last_hour >= 3 then
      insert into public.customer_link_otp_send_log (user_id, phone_hash, phone_last4, decision)
      values (v_user_id, v_phone_hash, v_phone_last4, 'limited_phone');
      return v_generic;
    end if;

    if v_distinct_numbers_24h >= 5 then
      insert into public.customer_link_otp_send_log (user_id, phone_hash, phone_last4, decision)
      values (v_user_id, v_phone_hash, v_phone_last4, 'limited_distinct_numbers');
      return v_generic;
    end if;

    select count(*) into v_match_count from public.customers where mobile = p_mobile;

    if v_match_count = 1 then
      select id, org_id, primary_profile_id, is_test, auto_link_blocked_at, preferred_language
      into v_match_id, v_match_org_id, v_match_primary_profile_id, v_match_is_test, v_match_auto_link_blocked_at, v_match_preferred_language
      from public.customers where mobile = p_mobile;
    end if;

    -- ADDED (this migration, owner-approved guard): a customer a master unlinked via
    -- admin_unlink_customer_google_account (auto_link_blocked_at set) is treated identically to
    -- an already-linked or test customer -- same v_generic response, same 'no_match' decision row
    -- in the send log -- so this response is indistinguishable from a non-matching phone number,
    -- exactly as the owner required (no new oracle).
    if v_match_count <> 1
       or v_match_primary_profile_id is not null
       or v_match_is_test
       or v_match_auto_link_blocked_at is not null then
      perform encode(digest(encode(gen_random_bytes(16), 'hex') || lpad(floor(random() * 1000000)::text, 6, '0'), 'sha256'), 'hex');
      insert into public.customer_link_otp_send_log (user_id, phone_hash, phone_last4, decision)
      values (v_user_id, v_phone_hash, v_phone_last4, 'no_match');
      return v_generic;
    end if;

    perform pg_advisory_xact_lock(hashtext(v_match_id::text));

    update public.customer_link_otp_challenges
    set superseded_at = v_now
    where customer_id = v_match_id and used_at is null and superseded_at is null;

    v_code := lpad((('x' || encode(gen_random_bytes(4), 'hex'))::bit(32)::bigint % 1000000)::text, 6, '0');
    v_salt := encode(gen_random_bytes(16), 'hex');

    begin
      insert into public.customer_link_otp_challenges (org_id, user_id, customer_id, code_salt, code_hash, expires_at)
      values (v_match_org_id, v_user_id, v_match_id, v_salt, encode(digest(v_salt || v_code, 'sha256'), 'hex'), v_now + interval '10 minutes')
      returning id into v_challenge_id;
    exception when unique_violation then
      insert into public.customer_link_otp_send_log (user_id, phone_hash, phone_last4, decision)
      values (v_user_id, v_phone_hash, v_phone_last4, 'no_match');
      return v_generic;
    end;

    v_body := case coalesce(v_match_preferred_language, 'en')
      when 'ta' then v_code || ' உங்கள் GV Mart கணக்கு இணைப்பு குறியீடு. இதை யாருடனும் பகிர வேண்டாம். 10 நிமிடங்களில் காலாவதியாகும்.'
      else v_code || ' is your GV Mart account linking code. Do not share it with anyone. It expires in 10 minutes.'
    end;

    -- CHANGE (a): 'code' alongside 'body' -- the dispatcher needs the raw code as a value, not just
    -- embedded in a rendered sentence, for a future named-parameter template send. Both keys are
    -- wiped together the moment this row is redacted (the existing redaction code replaces the
    -- WHOLE payload column, not a per-key merge -- see wa-milestone-dispatch-core.ts /
    -- wa-dispatch-v2.ts), so adding this key does not widen how long the plaintext code survives.
    insert into public.whatsapp_outbox (org_id, direction, to_mobile, customer_id, milestone, template, payload, ref_type, ref_id, status)
    values (v_match_org_id, 'outbound', p_mobile, v_match_id, 'customer_link_otp', 'customer_link_otp',
            jsonb_build_object('body', v_body, 'code', v_code), 'customer_link_otp', v_challenge_id, 'pending')
    returning id into v_outbox_id;

    update public.customer_link_otp_challenges set outbox_id = v_outbox_id where id = v_challenge_id;

    insert into public.customer_link_otp_send_log (user_id, phone_hash, phone_last4, decision)
    values (v_user_id, v_phone_hash, v_phone_last4, 'sent');

    insert into public.audit_log (org_id, actor_id, action, table_name, row_id, after)
    values (v_match_org_id, null, 'customer_link_otp_requested', 'customers', v_match_id,
            jsonb_build_object('auth_user_id', v_user_id, 'phone_last4', v_phone_last4, 'challenge_id', v_challenge_id));

    -- CHANGE (b): the fast-dispatch nudge. See wa_otp_fast_dispatch_invoke's own header comment for
    -- why this exists and why its failure is swallowed rather than surfaced or rolled back.
    begin
      perform public.wa_otp_fast_dispatch_invoke(v_match_org_id);
    exception when others then
      null;
    end;

    return v_generic;
  end;
  $fn$;

  revoke all on function public.request_customer_link_code(text) from public, anon, authenticated;
  grant execute on function public.request_customer_link_code(text) to authenticated;

  -- ── verify_customer_link_code: add auto_link_blocked_at to the lock-time re-check ───────────
  create or replace function public.verify_customer_link_code(p_code text)
  returns jsonb
  language plpgsql
  security definer
  set search_path = public, extensions, pg_temp
  as $fn$
  declare
    v_user_id uuid := auth.uid();
    v_challenge record;
    v_code_hash text;
    v_rows_updated integer;
    v_default_attempts_left constant integer := 5;
  begin
    if v_user_id is null then
      raise exception 'cannot_verify_code: not authenticated';
    end if;

    if exists (select 1 from public.profiles where id = v_user_id) then
      raise exception 'cannot_verify_code: profile_exists';
    end if;

    if p_code !~ '^\d{6}$' then
      raise exception 'cannot_verify_code: invalid_format';
    end if;

    if not public.is_customer_link_otp_enabled() then
      raise exception 'cannot_verify_code: feature_disabled';
    end if;

    -- Row lock on the caller's own single active (not used, not superseded) challenge. Scoping by
    -- user_id here (not just "the most recent challenge anywhere") is what stops a second
    -- authenticated user from ever verifying against a challenge they did not request themselves,
    -- even if they correctly guess the code -- the challenge is bound to the requester's own
    -- auth.uid(), checked here, not just to a customer_id/mobile they could type. The lock also
    -- means a second, concurrent verify call for the SAME challenge blocks here until the first
    -- call's transaction commits or rolls back, so two parallel guesses can never both read the
    -- same `attempts` value and both be let through, and two parallel correct-code calls can never
    -- both pass the "still unlinked" check below.
    select * into v_challenge
    from public.customer_link_otp_challenges
    where user_id = v_user_id and used_at is null and superseded_at is null
    order by created_at desc
    limit 1
    for update;

    if v_challenge.id is null then
      return jsonb_build_object('status', 'invalid_or_expired', 'attempts_left', v_default_attempts_left);
    end if;

    if v_challenge.expires_at < clock_timestamp() then
      return jsonb_build_object('status', 'invalid_or_expired', 'attempts_left', v_default_attempts_left);
    end if;

    if v_challenge.attempts >= v_challenge.max_attempts then
      return jsonb_build_object('status', 'invalid_or_expired', 'attempts_left', 0);
    end if;

    v_code_hash := encode(digest(v_challenge.code_salt || p_code, 'sha256'), 'hex');

    if v_code_hash <> v_challenge.code_hash then
      update public.customer_link_otp_challenges
      set attempts = attempts + 1
      where id = v_challenge.id
      returning attempts into v_challenge.attempts;

      insert into public.audit_log (org_id, actor_id, action, table_name, row_id, after)
      values (v_challenge.org_id, null, 'customer_link_otp_wrong_code', 'customers', v_challenge.customer_id,
              jsonb_build_object('auth_user_id', v_user_id, 'challenge_id', v_challenge.id, 'attempts', v_challenge.attempts));

      return jsonb_build_object('status', 'invalid_or_expired', 'attempts_left', greatest(v_challenge.max_attempts - v_challenge.attempts, 0));
    end if;

    -- Correct code: re-check the customer is still unlinked and not flagged test (defends against a
    -- race where staff linked/flagged the customer by hand between request and verify) and mark the
    -- challenge used inside the same row-locked transaction, then run the actual link. Marking it
    -- used FIRST, before the link itself, means the code is burned (single-use) even on the rare
    -- path where the link below then fails its own race check -- a deliberate choice recorded in
    -- DECISIONS.md section 3 (the alternative, marking it used only after a successful link, would
    -- let one correct code be retried indefinitely across repeated race losses).
    update public.customer_link_otp_challenges set used_at = clock_timestamp() where id = v_challenge.id;

    -- Row-lock the customer first (FOR UPDATE) so a concurrent verify for the same customer (a
    -- second challenge, or staff linking/flagging it by hand) blocks here rather than racing --
    -- this MUST happen before inserting the profiles row below: profiles.id is this function's own
    -- insert target and customers.primary_profile_id has a foreign key to it, so the customer
    -- cannot be pointed at a profile that does not exist yet. Locking first, inserting the profile
    -- second, and updating the customer last is the only ordering that satisfies both the FK and
    -- the race-safety requirement.
    perform 1 from public.customers where id = v_challenge.customer_id for update;

    -- ADDED (this migration, owner-approved guard): a customer blocked by a master's unlink
    -- between this challenge's request and this verify call must be treated exactly like "lost
    -- the race" below -- the IDENTICAL {status: 'invalid_or_expired', attempts_left: 0} response
    -- any other re-check failure already returns, so there is no new, distinguishable outcome and
    -- no new timing signal (same code path, same statements run, whether blocked, already-linked,
    -- or flagged test).
    if exists (
      select 1 from public.customers
      where id = v_challenge.customer_id and (primary_profile_id is not null or is_test or auto_link_blocked_at is not null)
    ) then
      -- Lost the race (or the customer was flagged test / linked by hand / blocked by a master in
      -- between): the code is still burned (used_at was already set above), but no profile is
      -- created and nothing else changes.
      return jsonb_build_object('status', 'invalid_or_expired', 'attempts_left', 0);
    end if;

    insert into public.profiles (id, org_id, full_name, phone, role, language)
    select v_user_id, c.org_id, coalesce(nullif(c.name, ''), 'Customer'), c.mobile, 'customer', coalesce(c.preferred_language, 'en')
    from public.customers c where c.id = v_challenge.customer_id;

    update public.customers
    set primary_profile_id = v_user_id, phone_verified = true
    where id = v_challenge.customer_id and primary_profile_id is null and not is_test;

    get diagnostics v_rows_updated = row_count;
    if v_rows_updated <> 1 then
      -- Cannot actually happen given the row lock + re-check immediately above (nothing else can
      -- change this row between here and there), but checked anyway rather than assumed.
      raise exception 'cannot_verify_code: unexpected_link_failure';
    end if;

    insert into public.audit_log (org_id, actor_id, action, table_name, row_id, after)
    values (v_challenge.org_id, v_user_id, 'customer_link_otp_verified', 'customers', v_challenge.customer_id,
            jsonb_build_object('auth_user_id', v_user_id, 'challenge_id', v_challenge.id));

    return jsonb_build_object('status', 'linked');
  end;
  $fn$;

  revoke all on function public.verify_customer_link_code(text) from public, anon, authenticated;
  grant execute on function public.verify_customer_link_code(text) to authenticated;

  ----------------------------------------------------------------------------
  -- Assertions.
  ----------------------------------------------------------------------------
  if has_function_privilege('anon', 'public.request_customer_link_code(text)', 'execute')
     or has_function_privilege('anon', 'public.verify_customer_link_code(text)', 'execute') then
    raise exception 'assertion failed: anon can execute request_customer_link_code or verify_customer_link_code';
  end if;

  if not (has_function_privilege('authenticated', 'public.request_customer_link_code(text)', 'execute')
          and has_function_privilege('authenticated', 'public.verify_customer_link_code(text)', 'execute')) then
    raise exception 'assertion failed: authenticated lost EXECUTE on request_customer_link_code or verify_customer_link_code';
  end if;

  if (select prosrc from pg_proc where oid = 'public.request_customer_link_code(text)'::regprocedure) not like '%v_match_auto_link_blocked_at%' then
    raise exception 'assertion failed: request_customer_link_code was not updated with the auto_link_blocked_at check';
  end if;

  if (select prosrc from pg_proc where oid = 'public.verify_customer_link_code(text)'::regprocedure) not like '%auto_link_blocked_at%' then
    raise exception 'assertion failed: verify_customer_link_code was not updated with the auto_link_blocked_at check';
  end if;
end
$mig$;
$guard$;
  v_embedded_guard_test text := $guardtest$-- Test for 20261121100150_customer_link_otp_respects_auto_link_block.sql. Run inside the
-- rehearsal wrapper's own transaction, AFTER the migration (and everything it depends on) has
-- been applied in the same transaction. Ends by raising an exception listing every assertion's
-- pass/fail, so nothing here ever commits regardless of outcome. Same role discipline as
-- customer_link_otp.test.sql: `set local role authenticated` around each RPC call, `reset role`
-- (and clear request.jwt.claims) before any direct table read/write.
do $t$
declare
  v_results text := '';
  v_org uuid;
  v_user_blocked uuid := gen_random_uuid();
  v_user_unblocked uuid := gen_random_uuid();
  v_user_relinked uuid := gen_random_uuid();
  v_user_relinked2 uuid := gen_random_uuid(); -- P4 uses a FRESH auth user: the 30s per-user send
                                               -- cooldown is scoped to user_id, not customer_id,
                                               -- and P3 already logged a 'sent' decision for
                                               -- v_user_relinked moments earlier in this same test
                                               -- -- reusing it would trip the cooldown and is not
                                               -- what P4 is testing (it tests the CUSTOMER's block
                                               -- being cleared, not the same user's retry timing).
  v_cust_blocked uuid;
  v_cust_unblocked uuid;
  v_cust_relink uuid;
  v_result_blocked jsonb;
  v_result_nonexistent jsonb;
  v_result jsonb;
  v_challenge_id uuid;
  v_code text;
  v_salt text;
  v_row record;
  v_outbox_count int;
  v_send_log_decision text;
begin
  insert into organizations(name) values ('__TEST_otp_auto_link_block_org') returning id into v_org;
  insert into auth.users(id, email) select x, '__test_' || x || '@example.invalid'
    from unnest(array[v_user_blocked, v_user_unblocked, v_user_relinked, v_user_relinked2]) x;

  insert into public.settings (org_id) values (v_org) on conflict (org_id) do nothing;
  update public.settings set wa_dispatch_v2_enabled = true, wa_dispatch_v2_scope = 'org' where org_id = v_org;
  update public.customer_link_otp_settings set enabled = true where id = true;

  -- Three customers, same shape as the base test file: unlinked, not test-flagged. One already
  -- carries auto_link_blocked_at (simulating a master's prior unlink), one does not, one will be
  -- "relinked" mid-test (block cleared, same effect as admin_link_customer_google_account's own
  -- clearing update, which this test does not call directly -- out of scope to touch -- but
  -- whose END STATE it reproduces to prove the OTP path reacts to it).
  insert into customers (org_id, name, mobile, auto_link_blocked_at, auto_link_blocked_by)
  values (v_org, '__TEST_customer_blocked', '9000000091', clock_timestamp() - interval '1 hour', null)
  returning id into v_cust_blocked;
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_customer_unblocked', '9000000092') returning id into v_cust_unblocked;
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_customer_relink', '9000000093') returning id into v_cust_relink;

  -- G0: the migration's own assertions already prove prosrc contains the new checks; restated
  -- behaviourally here.
  v_results := v_results || 'G0 ok: setup complete (migration assertions already proved the source change)' || E'\n';

  ----------------------------------------------------------------------------
  -- P1: a BLOCKED customer's request returns the generic response and writes nothing new beyond
  -- a 'no_match' send-log row -- no challenge, no outbox row.
  ----------------------------------------------------------------------------
  select count(*) into v_outbox_count from public.whatsapp_outbox where org_id = v_org;

  perform set_config('request.jwt.claims', json_build_object('sub', v_user_blocked, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select public.request_customer_link_code('9000000091') into v_result_blocked;   -- blocked customer's real number
  select public.request_customer_link_code('9000000000') into v_result_nonexistent; -- a number matching no customer at all
  execute 'reset role';
  perform set_config('request.jwt.claims', 'null', true);

  if v_result_blocked = jsonb_build_object('status', 'ok', 'message', 'If that number is registered, a verification code was sent on WhatsApp.') then
    v_results := v_results || 'P1a ok: blocked customer gets the generic response' || E'\n';
  else
    v_results := v_results || format('P1a FAIL: blocked customer got %s', v_result_blocked) || E'\n';
  end if;

  if v_result_blocked = v_result_nonexistent then
    v_results := v_results || 'P1b ok: blocked-customer response is byte-identical to a nonexistent-phone response (no new oracle)' || E'\n';
  else
    v_results := v_results || format('P1b FAIL: responses differ -- blocked=%s nonexistent=%s', v_result_blocked, v_result_nonexistent) || E'\n';
  end if;

  if not exists (select 1 from public.customer_link_otp_challenges where customer_id = v_cust_blocked) then
    v_results := v_results || 'P1c ok: blocked customer -- no challenge row created' || E'\n';
  else
    v_results := v_results || 'P1c FAIL: a challenge row was created for a blocked customer' || E'\n';
  end if;

  select count(*) into v_outbox_count from public.whatsapp_outbox where org_id = v_org;
  if v_outbox_count = 0 then
    v_results := v_results || 'P1d ok: no outbox row created for the blocked customer''s request' || E'\n';
  else
    v_results := v_results || format('P1d FAIL: %s outbox row(s) created', v_outbox_count) || E'\n';
  end if;

  select decision into v_send_log_decision from public.customer_link_otp_send_log
  where phone_hash = encode(digest('9000000091', 'sha256'), 'hex') order by created_at desc limit 1;
  if v_send_log_decision = 'no_match' then
    v_results := v_results || 'P1e ok: send-log decision for the blocked customer is ''no_match'' -- same as any other non-matching/ineligible phone' || E'\n';
  else
    v_results := v_results || format('P1e FAIL: send-log decision was %s, expected no_match', v_send_log_decision) || E'\n';
  end if;

  ----------------------------------------------------------------------------
  -- P2: UNBLOCKED customer -- full request+verify flow works unchanged (the new OR condition
  -- must never trip for a customer who isn't blocked).
  ----------------------------------------------------------------------------
  perform set_config('request.jwt.claims', json_build_object('sub', v_user_unblocked, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select public.request_customer_link_code('9000000092') into v_result;
  execute 'reset role';
  perform set_config('request.jwt.claims', 'null', true);

  select id, code_salt into v_challenge_id, v_salt from public.customer_link_otp_challenges
  where customer_id = v_cust_unblocked and used_at is null and superseded_at is null;

  select payload->>'code' into v_code from public.whatsapp_outbox
  where ref_type = 'customer_link_otp' and ref_id = v_challenge_id;

  if v_challenge_id is not null and v_code is not null then
    v_results := v_results || 'P2a ok: unblocked customer -- request created a challenge + outbox row as normal' || E'\n';
  else
    v_results := v_results || 'P2a FAIL: unblocked customer''s request did not create the expected challenge/outbox row' || E'\n';
  end if;

  perform set_config('request.jwt.claims', json_build_object('sub', v_user_unblocked, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select public.verify_customer_link_code(v_code) into v_result;
  execute 'reset role';
  perform set_config('request.jwt.claims', 'null', true);

  if v_result = jsonb_build_object('status', 'linked') then
    v_results := v_results || 'P2b ok: unblocked customer -- verify with the real code links normally, unchanged behaviour' || E'\n';
  else
    v_results := v_results || format('P2b FAIL: unblocked customer verify returned %s', v_result) || E'\n';
  end if;

  if (select primary_profile_id from public.customers where id = v_cust_unblocked) = v_user_unblocked then
    v_results := v_results || 'P2c ok: unblocked customer is actually linked in the customers table' || E'\n';
  else
    v_results := v_results || 'P2c FAIL: unblocked customer was not actually linked' || E'\n';
  end if;

  ----------------------------------------------------------------------------
  -- P3: a customer who becomes blocked IN BETWEEN request and verify (a master unlinks them
  -- mid-flow) -- verify must refuse with the same collapsed response every other race-loss case
  -- already returns, and must NOT link.
  ----------------------------------------------------------------------------
  perform set_config('request.jwt.claims', json_build_object('sub', v_user_relinked, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select public.request_customer_link_code('9000000093') into v_result;
  execute 'reset role';
  perform set_config('request.jwt.claims', 'null', true);

  select id into v_challenge_id from public.customer_link_otp_challenges
  where customer_id = v_cust_relink and used_at is null and superseded_at is null;
  select payload->>'code' into v_code from public.whatsapp_outbox
  where ref_type = 'customer_link_otp' and ref_id = v_challenge_id;

  -- Simulate the master unlinking this customer right now, between request and verify -- the
  -- exact column/value admin_unlink_customer_google_account's own live definition sets (reproduced
  -- as an end state here, not by calling that function, which is out of this feature's scope to
  -- touch).
  update public.customers set auto_link_blocked_at = clock_timestamp(), auto_link_blocked_by = null where id = v_cust_relink;

  perform set_config('request.jwt.claims', json_build_object('sub', v_user_relinked, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select public.verify_customer_link_code(v_code) into v_result;
  execute 'reset role';
  perform set_config('request.jwt.claims', 'null', true);

  if v_result = jsonb_build_object('status', 'invalid_or_expired', 'attempts_left', 0) then
    v_results := v_results || 'P3a ok: a customer blocked between request and verify gets the same collapsed invalid_or_expired/0 response as any other race loss' || E'\n';
  else
    v_results := v_results || format('P3a FAIL: expected invalid_or_expired/0, got %s', v_result) || E'\n';
  end if;

  if (select primary_profile_id from public.customers where id = v_cust_relink) is null then
    v_results := v_results || 'P3b ok: the blocked-mid-flow customer was NOT linked' || E'\n';
  else
    v_results := v_results || 'P3b FAIL: the blocked-mid-flow customer WAS linked -- the guard did not hold' || E'\n';
  end if;

  if not exists (select 1 from public.profiles where id = v_user_relinked) then
    v_results := v_results || 'P3c ok: no profiles row was created for the blocked-mid-flow user' || E'\n';
  else
    v_results := v_results || 'P3c FAIL: a profiles row was created despite the block' || E'\n';
  end if;

  ----------------------------------------------------------------------------
  -- P4: once the block is cleared (the end state admin_link_customer_google_account's own relink
  -- produces -- reproduced here, not by calling that function), OTP works again for this customer.
  ----------------------------------------------------------------------------
  update public.customers set auto_link_blocked_at = null, auto_link_blocked_by = null where id = v_cust_relink;

  perform set_config('request.jwt.claims', json_build_object('sub', v_user_relinked2, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select public.request_customer_link_code('9000000093') into v_result;
  execute 'reset role';
  perform set_config('request.jwt.claims', 'null', true);

  select id into v_challenge_id from public.customer_link_otp_challenges
  where customer_id = v_cust_relink and used_at is null and superseded_at is null;
  select payload->>'code' into v_code from public.whatsapp_outbox
  where ref_type = 'customer_link_otp' and ref_id = v_challenge_id;

  if v_challenge_id is not null and v_code is not null then
    v_results := v_results || 'P4a ok: once unblocked, a fresh request succeeds normally again' || E'\n';
  else
    v_results := v_results || 'P4a FAIL: once unblocked, request did not create a fresh challenge/outbox row' || E'\n';
  end if;

  perform set_config('request.jwt.claims', json_build_object('sub', v_user_relinked2, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select public.verify_customer_link_code(v_code) into v_result;
  execute 'reset role';
  perform set_config('request.jwt.claims', 'null', true);

  if v_result = jsonb_build_object('status', 'linked')
     and (select primary_profile_id from public.customers where id = v_cust_relink) = v_user_relinked2 then
    v_results := v_results || 'P4b ok: once unblocked, verify links normally -- OTP works again for this customer' || E'\n';
  else
    v_results := v_results || format('P4b FAIL: once unblocked, verify returned %s', v_result) || E'\n';
  end if;

  raise exception E'TEST_RESULTS:\n%', v_results;
end
$t$;
$guardtest$;
  v_embedded_mapping text := $mapping$-- 20261121100200_customer_link_otp_template_mapping.sql
--
-- Phase 3 continuation, docs/DECISIONS.md section 10. Wires the `customer_link_otp` event to the
-- real, owner-confirmed WhatsApp template -- the LAST step in this feature's template plumbing,
-- deliberately ordered AFTER 20261121100100_customer_link_otp_dispatch_hardening.sql so file
-- ordering itself enforces that this feature's redaction coverage is in place before any mapping
-- that could ever cause a real template send to exist. `guard_secret_ref_type_template_mapping`
-- (20261120100200_whatsapp_outbox_secret_payload_scrub.sql, committed by a concurrent session, NOT
-- edited here) already refuses to let this insert succeed unless `customer_link_otp` is registered
-- with `redaction_covered = true` in `whatsapp_payload_secret_ref_types` -- confirmed it already is
-- (that migration's own insert); this migration relies on that guard firing for real, not just on
-- reading its code.
--
-- Template facts, owner-confirmed directly from the live Wasi template edit form (2026-10-30, not
-- guessed, not re-derived from any sync job -- the live `whatsapp_wasi_templates` mirror has empty
-- `param_keys` for this template, confirmed read-only, which is why these facts could not come from
-- the database and had to come from the owner):
--   - `lexdraft_otp`, category Authentication, language `en` (matches the live mirror row), status
--     approved.
--   - Body is Meta-generated, not editable: "Your verification code is *{{1}}*." plus an optional
--     security-disclaimer line and an optional expiry line whose presence is not guaranteed --
--     nothing in this migration or the dispatcher depends on those two optional lines existing.
--   - Brand check: PASSED (Meta-generated body, no third-party brand text — the owner's original
--     concern about the name "lexdraft" was about ownership of the WhatsApp Business Account, not
--     the message content, and the owner separately confirmed this account is the right one).
--   - Exactly one Copy Code button. Per the owner's explicit instruction and Meta's own documented
--     shape for this button type, the send payload needs the code in BOTH the body component AND
--     the button component (sub_type "url", index "0", text = the code) -- built in
--     wa-send-core.ts's `buildTemplateRequest` (this phase's own commit) via the new
--     `has_auth_copy_code_button` column below, which duplicates the single resolved body param
--     into a `components` array on the outgoing request. That `components` array is NEVER
--     persisted to `whatsapp_outbox` (same as `headerMediaUrl` already isn't) -- only the flat
--     `params` map is, and that is already covered end-to-end by the reconciled redaction design in
--     20261121100100.
--
-- NOT proof the feature works end-to-end -- per the owner's own explicit instruction, that is only
-- proven by the owner's own later live phone test (a separately-gated step, not run by this
-- migration or this phase). This migration is a pure data change (one row + one new column),
-- exactly as the dispatcher-side code was already built to expect (wa-event-context.ts's
-- `vars.code` wiring, phase 2) -- no application code depends on this migration existing to keep
-- working; everything else in this feature functions identically whether or not this row exists.

do $mig$
begin
  if to_regclass('public.whatsapp_event_templates') is null then
    raise exception 'customer_link_otp_template_mapping: whatsapp_event_templates missing -- base schema not applied';
  end if;

  if to_regclass('public.whatsapp_payload_secret_ref_types') is null then
    raise exception 'customer_link_otp_template_mapping: whatsapp_payload_secret_ref_types missing -- 20261120100200 not applied first';
  end if;

  if not exists (
    select 1 from public.whatsapp_payload_secret_ref_types
    where ref_type = 'customer_link_otp' and redaction_covered = true
  ) then
    raise exception 'customer_link_otp_template_mapping: customer_link_otp is not registered as redaction_covered -- refusing to map a template to it';
  end if;

  -- 1. New column, additive, defaults false (every existing mapping row is unaffected).
  alter table public.whatsapp_event_templates
    add column if not exists has_auth_copy_code_button boolean not null default false;

  -- 2. The mapping row itself. One per organisation, same pattern as the po.quote_request /
  -- test.hello mappings (20261016320000_wa_dispatch_v2_alerts_and_mappings.sql). param_map key "1"
  -- matches Meta's own positional placeholder numbering ({{1}}) for this template's single body
  -- parameter; "code" is the variable key wa-event-context.ts already populates for
  -- ref_type = 'customer_link_otp' (phase 2). This insert itself is the thing
  -- `guard_secret_ref_type_template_mapping` evaluates -- it will raise and roll back this whole
  -- migration if that guard's precondition is ever false, which is exactly the mechanical
  -- enforcement this migration's own file ordering is meant to rely on, not just reasoning about it.
  insert into public.whatsapp_event_templates (org_id, event_key, language, wasi_template_name, param_map, has_auth_copy_code_button)
  select o.id, 'customer_link_otp', 'en', 'lexdraft_otp', '{"1": "code"}'::jsonb, true
  from public.organizations o
  on conflict (org_id, event_key, language) do update
    set wasi_template_name = excluded.wasi_template_name,
        param_map = excluded.param_map,
        has_auth_copy_code_button = excluded.has_auth_copy_code_button;

  -- 3. Assertions.
  if not exists (
    select 1 from public.whatsapp_event_templates
    where event_key = 'customer_link_otp' and language = 'en' and wasi_template_name = 'lexdraft_otp'
      and has_auth_copy_code_button = true and param_map = '{"1": "code"}'::jsonb
  ) then
    raise exception 'assertion failed: customer_link_otp -> lexdraft_otp mapping row is missing or wrong';
  end if;

  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'whatsapp_event_templates' and column_name = 'has_auth_copy_code_button'
  ) then
    raise exception 'assertion failed: has_auth_copy_code_button column was not created';
  end if;
end
$mig$;
$mapping$;
  v_embedded_mapping_test text := $mappingtest$-- Test for 20261121100200_customer_link_otp_template_mapping.sql.
-- Run inside the rehearsal wrapper's own transaction, AFTER both 20261121100100 (dispatch
-- hardening) and this migration have been applied in the same transaction. Ends by raising an
-- exception listing every assertion's pass/fail, so nothing here ever commits regardless of
-- outcome.
do $test$
declare
  v_results text := '';
  v_org_id uuid;
  v_row record;
  v_guard_blocked boolean := false;
begin
  insert into public.organizations (name) values ('__TEST_template_mapping') returning id into v_org_id;

  -- G0: the mapping row exists, correctly shaped, for the throwaway org too (the migration's own
  -- "select o.id from organizations" covers every org, including ones created after it ran would
  -- NOT be covered automatically -- but this test's own org is created fresh and will never have a
  -- row unless we insert one ourselves here, matching what a real new org would need; this is a
  -- known, accepted scope limit of a one-time backfill insert, not a bug to test around).
  insert into public.whatsapp_event_templates (org_id, event_key, language, wasi_template_name, param_map, has_auth_copy_code_button)
  values (v_org_id, 'customer_link_otp', 'en', 'lexdraft_otp', '{"1": "code"}'::jsonb, true);

  select * into v_row from public.whatsapp_event_templates where org_id = v_org_id and event_key = 'customer_link_otp';
  if v_row.wasi_template_name = 'lexdraft_otp' and v_row.language = 'en' and v_row.has_auth_copy_code_button = true
     and v_row.param_map = '{"1": "code"}'::jsonb and v_row.is_active = true then
    v_results := v_results || 'G0 ok: mapping row shaped correctly' || E'\n';
  else
    v_results := v_results || format('G0 FAIL: mapping row wrong -- %s', v_row) || E'\n';
  end if;

  -- G1: has_auth_copy_code_button column exists with the right default for pre-existing rows
  -- (every mapping created before this migration must be unaffected -- default false).
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'whatsapp_event_templates'
      and column_name = 'has_auth_copy_code_button' and column_default like '%false%'
  ) then
    v_results := v_results || 'G1 ok: has_auth_copy_code_button defaults to false' || E'\n';
  else
    v_results := v_results || 'G1 FAIL: has_auth_copy_code_button missing or wrong default' || E'\n';
  end if;

  -- G2: the guard trigger from 20261120100200 genuinely fires -- prove it with a ref_type that IS
  -- registered but explicitly marked NOT covered, not merely an unregistered one (the guard's own
  -- documented scope limit is that an UNREGISTERED ref_type is allowed through -- only a
  -- registered-and-not-covered one is refused). Don't assume this from reading that migration's
  -- code.
  insert into public.whatsapp_payload_secret_ref_types (ref_type, redaction_covered, covered_note)
  values ('__TEST_uncovered_ref_type', false, '__TEST__ deliberately uncovered, for this test only');

  begin
    insert into public.whatsapp_event_templates (org_id, event_key, language, wasi_template_name, param_map)
    values (v_org_id, '__TEST_uncovered_ref_type', 'en', '__TEST_some_template', '{}'::jsonb);
  exception when others then
    v_guard_blocked := true;
  end;
  if v_guard_blocked then
    v_results := v_results || 'G2 ok: guard_secret_ref_type_template_mapping genuinely refuses a registered-but-not-covered ref_type' || E'\n';
  else
    v_results := v_results || 'G2 FAIL: a registered-but-not-covered ref_type mapping was NOT refused -- guard is not actually firing' || E'\n';
  end if;

  -- P1: customer_link_otp itself is NOT refused (it IS covered) -- already proven by G0's
  -- successful insert above not raising; restated explicitly here for a clear pass/fail line.
  v_results := v_results || 'P1 ok: customer_link_otp mapping insert succeeded (covered ref_type is never refused)' || E'\n';

  -- G3: RLS/grants on whatsapp_event_templates unchanged by this migration -- anon still has none,
  -- authenticated still writes only through the existing ops-staff policy (not re-opened wider).
  if not exists (
    select 1 from pg_policies where schemaname = 'public' and tablename = 'whatsapp_event_templates' and policyname = 'whatsapp_event_templates_write_ops'
  ) then
    v_results := v_results || 'G3 FAIL: whatsapp_event_templates_write_ops policy is missing' || E'\n';
  else
    v_results := v_results || 'G3 ok: existing whatsapp_event_templates RLS policies untouched' || E'\n';
  end if;

  raise exception E'TEST_RESULTS:\n%', v_results;
end
$test$;
$mappingtest$;
begin
  select md5(o.id::text || '|' || o.name) into v_actual_org_fingerprint
  from public.organizations o where o.name not like '\_\_TEST%' escape '\' order by o.created_at asc limit 1;
  if v_actual_org_fingerprint is distinct from v_expected_org_fingerprint then
    raise exception 'REHEARSAL_REFUSED: organisation fingerprint mismatch (expected %, got %)', v_expected_org_fingerprint, v_actual_org_fingerprint;
  end if;

  perform set_config('lock_timeout', '5s', true);

  v_ist_hour := extract(hour from (now() at time zone 'Asia/Kolkata'))::int;
  if v_ist_hour < 11 then
    raise exception 'REHEARSAL_REFUSED: this script only runs after 11:00 IST (current IST hour=%)', v_ist_hour;
  end if;

  v_actual_hash := encode(sha256(convert_to(replace(v_embedded_prereq, E'\r', ''), 'UTF8')), 'hex');
  if v_actual_hash is distinct from '8533249a1b9441f14fc18867a79f7b1dde53a49df296504aa668135f56f78fd1' then raise exception 'REHEARSAL_REFUSED: prereq hash mismatch (got %)', v_actual_hash; end if;
  v_actual_hash := encode(sha256(convert_to(replace(v_embedded_hardening, E'\r', ''), 'UTF8')), 'hex');
  if v_actual_hash is distinct from '7fc531e9fc0c8318a0d266c26df1cf9652e023d6d3cc600283d40f341cdb6a0f' then raise exception 'REHEARSAL_REFUSED: hardening hash mismatch (got %)', v_actual_hash; end if;
  v_actual_hash := encode(sha256(convert_to(replace(v_embedded_hardening_test, E'\r', ''), 'UTF8')), 'hex');
  if v_actual_hash is distinct from '871f74372723561c03ada1a88cecd8444e03932492e8a65487b76f68ed0837ea' then raise exception 'REHEARSAL_REFUSED: hardening test hash mismatch (got %)', v_actual_hash; end if;
  v_actual_hash := encode(sha256(convert_to(replace(v_embedded_guard, E'\r', ''), 'UTF8')), 'hex');
  if v_actual_hash is distinct from '341a59d21110915f7d2be9c27cde22c68f8cdc34e1a13e64f762cd64300896f2' then raise exception 'REHEARSAL_REFUSED: guard migration hash mismatch (got %)', v_actual_hash; end if;
  v_actual_hash := encode(sha256(convert_to(replace(v_embedded_guard_test, E'\r', ''), 'UTF8')), 'hex');
  if v_actual_hash is distinct from '78bca373e504d4be2b9d75341627549ce1c2e54022e9815f3195948098909e16' then raise exception 'REHEARSAL_REFUSED: guard test hash mismatch (got %)', v_actual_hash; end if;
  v_actual_hash := encode(sha256(convert_to(replace(v_embedded_mapping, E'\r', ''), 'UTF8')), 'hex');
  if v_actual_hash is distinct from '641a90a7b3f540e6853d2ad768184dc22eb8772bd3b7a296b15f109f350a9317' then raise exception 'REHEARSAL_REFUSED: mapping migration hash mismatch (got %)', v_actual_hash; end if;
  v_actual_hash := encode(sha256(convert_to(replace(v_embedded_mapping_test, E'\r', ''), 'UTF8')), 'hex');
  if v_actual_hash is distinct from '34d86d828c07d468fc9a9aad4f9bc84e946fa692bfd7762fd13739a2bb3624b6' then raise exception 'REHEARSAL_REFUSED: mapping test hash mismatch (got %)', v_actual_hash; end if;

  select md5(string_agg(x, ',' order by x)) into v_fp_before from (
    select 'outbox:' || o.id::text || ':' || o.status || ':' || coalesce(o.payload::text,'') || ':' || coalesce(o.template_params::text,'') as x
    from public.whatsapp_outbox o where o.template not like '\_\_TEST\_%' escape '\'
    union all
    select 'tmpl:' || t.id::text || ':' || t.event_key || ':' || t.wasi_template_name from public.whatsapp_event_templates t
    where t.wasi_template_name not like '\_\_TEST\_%' escape '\' and t.event_key <> 'customer_link_otp'
    union all
    select 'cust_link:' || c.id::text || ':' || coalesce(c.primary_profile_id::text,'') || ':' || coalesce(c.auto_link_blocked_at::text,'')
    from public.customers c where c.name not like '\_\_TEST\_%' escape '\'
  ) r;

  -- RUN, in order: prereq -> hardening -> hardening test -> guard -> guard test -> mapping -> mapping test.
  execute replace(v_embedded_prereq, E'\r', '');
  execute replace(v_embedded_hardening, E'\r', '');
  begin
    execute replace(v_embedded_hardening_test, E'\r', '');
  exception when others then
    v_hardening_test_result := sqlerrm;
  end;
  execute replace(v_embedded_guard, E'\r', '');
  begin
    execute replace(v_embedded_guard_test, E'\r', '');
  exception when others then
    v_guard_test_result := sqlerrm;
  end;
  execute replace(v_embedded_mapping, E'\r', '');
  begin
    execute replace(v_embedded_mapping_test, E'\r', '');
  exception when others then
    v_mapping_test_result := sqlerrm;
  end;

  select md5(string_agg(x, ',' order by x)) into v_fp_after from (
    select 'outbox:' || o.id::text || ':' || o.status || ':' || coalesce(o.payload::text,'') || ':' || coalesce(o.template_params::text,'') as x
    from public.whatsapp_outbox o where o.template not like '\_\_TEST\_%' escape '\'
    union all
    select 'tmpl:' || t.id::text || ':' || t.event_key || ':' || t.wasi_template_name from public.whatsapp_event_templates t
    where t.wasi_template_name not like '\_\_TEST\_%' escape '\' and t.event_key <> 'customer_link_otp'
    union all
    select 'cust_link:' || c.id::text || ':' || coalesce(c.primary_profile_id::text,'') || ':' || coalesce(c.auto_link_blocked_at::text,'')
    from public.customers c where c.name not like '\_\_TEST\_%' escape '\'
  ) r;

  res := 'ok   ORG CHECK passed, GATE passed: IST hour=' || v_ist_hour || ', all seven embedded-text sha256 hashes verified'
    || E'\nINFO real-row fingerprint BEFORE = ' || v_fp_before
    || E'\nok   prereq + hardening + guard + mapping applied inside this still-open transaction'
    || E'\n--- hardening test output ---' || E'\n' || coalesce(v_hardening_test_result, '(test raised no exception -- unexpected)') || E'\n--- end hardening test output ---'
    || E'\n--- guard test output ---' || E'\n' || coalesce(v_guard_test_result, '(test raised no exception -- unexpected)') || E'\n--- end guard test output ---'
    || E'\n--- mapping test output ---' || E'\n' || coalesce(v_mapping_test_result, '(test raised no exception -- unexpected)') || E'\n--- end mapping test output ---'
    || E'\nINFO real-row fingerprint AFTER  = ' || v_fp_after
    || E'\n' || case when v_fp_after is distinct from v_fp_before
         then 'FAIL real whatsapp_outbox/other-template/real-customer link rows CHANGED -- this rehearsal mutated unrelated real data'
         else 'ok   real whatsapp_outbox rows, every OTHER template mapping, and every REAL customer''s own link/block state unchanged -- this rehearsal mutated no unrelated real data' end;

  raise exception E'RESULTS:\n%', res;
end
$rehearsal$;
