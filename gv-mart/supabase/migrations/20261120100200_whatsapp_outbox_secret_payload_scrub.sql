-- Fixes a HIGH finding from the independent security review of the customer-OTP-link fast-dispatch
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
