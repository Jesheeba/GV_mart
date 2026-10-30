-- GO APPLY script for migration 20261120100200_whatsapp_outbox_secret_payload_scrub.sql
-- (closes the HIGH finding from the fast-dispatch Edge Function review: whatsapp_outbox's
-- existing redaction-on-send/give-up logic never cleared template_params -- this migration adds a
-- DB-level scrub trigger that does, plus a guard trigger refusing to map any secret-carrying
-- ref_type to a template until its redaction coverage is confirmed in a new registry table),
-- branch feat/customer-otp-link.
--
-- WRITTEN ONLY -- never executed against any database by the agent that produced this file
-- (standing hard rule: no DB access of any kind beyond the explicitly-allowed rehearsal). The
-- owner runs this by hand, after 11:00 IST and after typing the exact word "APPROVED" for this
-- specific migration, once satisfied the sha256-pinned migration text embedded below is
-- byte-for-byte the reviewed migration file.
--
-- Re-running this script after a successful apply is always a safe no-op refusal (step 3:
-- already-registered check), never a double-apply.


-- 1. Status table -- autocommitted on its own, independent of the DO block's outcome.
drop table if exists pg_temp.wa_outbox_scrub_apply_status;
create temp table wa_outbox_scrub_apply_status (
  migration_version text,
  version_registered boolean,
  registry_exists boolean,
  triggers_attached boolean,
  functions_not_anon_executable boolean,
  no_template_mapping boolean,
  newly_leaked_functions text[],
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
  v_expected_migration_hash  text := '8533249a1b9441f14fc18867a79f7b1dde53a49df296504aa668135f56f78fd1';
  v_actual_migration_hash    text;
  v_migration_version        text := '20261120100200';
  v_already_registered       boolean;
  v_leaked_before            text[];
  v_leaked_after             text[];
  v_newly_leaked             text[];
  v_embedded_migration       text := $migration$-- Fixes a HIGH finding from the independent security review of the customer-OTP-link fast-dispatch
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
$migration$;
begin
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

  -- 4. LIVE-DEFINITION PRE-CHECKS
  if to_regclass('public.whatsapp_outbox') is null or to_regclass('public.whatsapp_event_templates') is null then
    raise exception 'APPLY_REFUSED: whatsapp_outbox / whatsapp_event_templates do not both exist -- this migration depends on 20261016300000';
  end if;
  if to_regclass('public.whatsapp_payload_secret_ref_types') is not null then
    raise exception 'APPLY_REFUSED: public.whatsapp_payload_secret_ref_types already exists before this migration ran';
  end if;
  if to_regprocedure('public.scrub_whatsapp_outbox_secret_payload()') is not null then
    raise exception 'APPLY_REFUSED: public.scrub_whatsapp_outbox_secret_payload() already exists before this migration ran';
  end if;
  if to_regprocedure('public.guard_secret_ref_type_template_mapping()') is not null then
    raise exception 'APPLY_REFUSED: public.guard_secret_ref_type_template_mapping() already exists before this migration ran';
  end if;

  -- 5. LEAK SNAPSHOT (BEFORE)
  select coalesce(array_agg(sig order by sig), array[]::text[]) into v_leaked_before
  from (
    select distinct (p.oid::regprocedure)::text as sig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
    where n.nspname = 'public'
      and a.privilege_type = 'EXECUTE'
      and (a.grantee = 0 or a.grantee = (select oid from pg_roles where rolname = 'anon'))
  ) s;

  -- 6. PIN -- CR-tolerant sha256 of the embedded migration text must equal the pinned LF hash.
  v_actual_migration_hash := encode(sha256(convert_to(replace(v_embedded_migration, E'\r', ''), 'UTF8')), 'hex');
  if v_actual_migration_hash is distinct from v_expected_migration_hash then
    raise exception 'APPLY_REFUSED: embedded migration text does not match its pinned sha256 (expected %, got %)',
      v_expected_migration_hash, v_actual_migration_hash;
  end if;

  -- 7. RUN -- apply the pinned migration text verbatim (CR-tolerant).
  execute replace(v_embedded_migration, E'\r', '');

  -- 8. REGISTER
  insert into supabase_migrations.schema_migrations (version, name, statements)
  values (v_migration_version, 'whatsapp_outbox_secret_payload_scrub', array[replace(v_embedded_migration, E'\r', '')]);

  -- 9. POST-APPLY CHECKS
  if to_regclass('public.whatsapp_payload_secret_ref_types') is null then
    raise exception 'APPLY_REFUSED: post-apply check failed -- whatsapp_payload_secret_ref_types does not exist';
  end if;
  if to_regprocedure('public.scrub_whatsapp_outbox_secret_payload()') is null
     or to_regprocedure('public.guard_secret_ref_type_template_mapping()') is null then
    raise exception 'APPLY_REFUSED: post-apply check failed -- one of the two new trigger functions does not exist';
  end if;
  if not exists (select 1 from pg_trigger where tgname = 'scrub_whatsapp_outbox_secret_payload' and tgrelid = 'public.whatsapp_outbox'::regclass and not tgisinternal) then
    raise exception 'APPLY_REFUSED: post-apply check failed -- scrub_whatsapp_outbox_secret_payload trigger is not attached to whatsapp_outbox';
  end if;
  if not exists (select 1 from pg_trigger where tgname = 'guard_secret_ref_type_template_mapping' and tgrelid = 'public.whatsapp_event_templates'::regclass and not tgisinternal) then
    raise exception 'APPLY_REFUSED: post-apply check failed -- guard_secret_ref_type_template_mapping trigger is not attached to whatsapp_event_templates';
  end if;
  if not exists (select 1 from public.whatsapp_payload_secret_ref_types where ref_type = 'customer_link_otp' and redaction_covered = true) then
    raise exception 'APPLY_REFUSED: post-apply check failed -- customer_link_otp registry row missing or not marked covered';
  end if;
  if has_function_privilege('anon', 'public.scrub_whatsapp_outbox_secret_payload()', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.scrub_whatsapp_outbox_secret_payload()', 'EXECUTE')
     or has_function_privilege('anon', 'public.guard_secret_ref_type_template_mapping()', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.guard_secret_ref_type_template_mapping()', 'EXECUTE') then
    raise exception 'APPLY_REFUSED: post-apply check failed -- one of the two new functions is anon/authenticated-executable';
  end if;
  if exists (select 1 from public.whatsapp_event_templates where event_key = 'customer_link_otp') then
    raise exception 'APPLY_REFUSED: post-apply check failed -- a customer_link_otp whatsapp_event_templates row exists; this migration must never wire one';
  end if;

  -- 9x. DIFF-BASED leak check -- only NEW anon/PUBLIC-executable functions fail this.
  select coalesce(array_agg(sig order by sig), array[]::text[]) into v_leaked_after
  from (
    select distinct (p.oid::regprocedure)::text as sig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
    where n.nspname = 'public'
      and a.privilege_type = 'EXECUTE'
      and (a.grantee = 0 or a.grantee = (select oid from pg_roles where rolname = 'anon'))
  ) s;

  select coalesce(array_agg(x order by x), array[]::text[]) into v_newly_leaked
  from (select unnest(v_leaked_after) as x except select unnest(v_leaked_before)) d;

  if array_length(v_newly_leaked, 1) is not null then
    raise exception 'APPLY_REFUSED: post-apply check failed -- this migration newly exposed % function(s) to PUBLIC/anon that were not executable before it ran: %',
      array_length(v_newly_leaked, 1), v_newly_leaked;
  end if;

  -- 9y. real-organisation fingerprint unchanged.
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
  insert into pg_temp.wa_outbox_scrub_apply_status (migration_version, version_registered, registry_exists, triggers_attached, functions_not_anon_executable, no_template_mapping, newly_leaked_functions, org_fingerprint_before, org_fingerprint_after, applied_at)
  values (
    v_migration_version,
    true,
    (to_regclass('public.whatsapp_payload_secret_ref_types') is not null),
    (exists (select 1 from pg_trigger where tgname = 'scrub_whatsapp_outbox_secret_payload' and tgrelid = 'public.whatsapp_outbox'::regclass and not tgisinternal)
     and exists (select 1 from pg_trigger where tgname = 'guard_secret_ref_type_template_mapping' and tgrelid = 'public.whatsapp_event_templates'::regclass and not tgisinternal)),
    (not has_function_privilege('anon', 'public.scrub_whatsapp_outbox_secret_payload()', 'EXECUTE') and not has_function_privilege('authenticated', 'public.scrub_whatsapp_outbox_secret_payload()', 'EXECUTE')
     and not has_function_privilege('anon', 'public.guard_secret_ref_type_template_mapping()', 'EXECUTE') and not has_function_privilege('authenticated', 'public.guard_secret_ref_type_template_mapping()', 'EXECUTE')),
    (not exists (select 1 from public.whatsapp_event_templates where event_key = 'customer_link_otp')),
    v_newly_leaked,
    v_org_fingerprint_before,
    v_org_fingerprint_after,
    now()
  );
end
$apply$;

-- 3. The actual thing to look at: one row on success, zero rows if the DO block raised and rolled back.
select * from pg_temp.wa_outbox_scrub_apply_status;
