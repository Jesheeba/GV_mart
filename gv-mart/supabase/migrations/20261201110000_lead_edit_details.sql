-- Urgent item #3: Edit Lead screen (2026-11-02). Leads could not be edited at
-- all until now (checked: no EditLead component, no update RPC beyond status
-- changes / move-to-customer / delete -- see LeadDetailPanel.tsx,
-- NewLeadForm.tsx). This migration adds the one new column the screen needs
-- plus a single SECURITY DEFINER RPC that performs every edit, instead of
-- widening leads' own RLS.
--
-- NOT APPLIED. Needs: rehearsal via _local_only/reports/run_rehearsal.mjs,
-- DRYRUN-OK, independent review, and the owner's typed "APPROVED" before
-- anyone runs this against the live database.
--
-- ── Why a new column instead of reusing something ──────────────────────────
-- leads.mobile already exists (one field). There is no alternate-mobile
-- column on leads or on customers today (checked both Row shapes in
-- src/types/database.ts) -- so "carry alternate mobile over to the customer
-- on lead->customer conversion" has nothing to carry TO: customers has no
-- matching field, and the task's instruction was conditional ("if customers
-- has one"). Per that condition, move_lead_to_customer() and
-- _lead_apply_status() are therefore NOT touched by this migration -- adding
-- a customers.alternate_mobile column to invent a destination would be scope
-- the task didn't ask for. Flagging as a known gap: today, an alternate
-- mobile typed on a lead is lost when that lead becomes a customer.
--
-- leads.address_id is a FK into `addresses`, but addresses.customer_id is
-- NOT NULL -- that table only models a logged-in customer's own saved
-- addresses (product/spare enquiries from the customer app, AMC renewal
-- picks, etc. -- see 20260730110000_address_everywhere.sql), and most leads
-- created by staff (walk-in, field, WhatsApp) have no customer_id yet. A
-- free-text column is the only option that works for every lead, mirrors how
-- `notes` already works, and needs no new picker UI.
--
-- ── Who can use the new RPC ─────────────────────────────────────────────
-- leads_write_sales (20260701091300_rls.sql) only lets is_sales_staff()
-- (master/sales_admin) write to leads directly -- operation_admin has no
-- write policy on leads at all (confirmed: grepped every `create policy ...
-- on leads`/`on public.leads`, and the 20260715210000 comment explicitly
-- calls this out for a different RPC). The task requires operation_admin to
-- be able to edit leads too, so rather than widening leads_write_sales (which
-- would hand operation_admin blanket UPDATE on every column, including
-- status/owner_id/assigned_to -- a much bigger privilege grant than "can fix
-- a lead's name/number/notes"), update_lead_details() is its own narrow
-- SECURITY DEFINER function gated on is_staff() (master, operation_admin,
-- sales_admin -- the exact three roles the task names), the same style
-- already used for _whatsapp_lead_upsert (20260715210000) to let a wider
-- role reach a leads write it otherwise couldn't under plain RLS.

-- ── 1. New columns ──────────────────────────────────────────────────────
alter table public.leads
  add column if not exists alternate_mobile text,
  add column if not exists address_text text;

alter table public.leads
  drop constraint if exists leads_alternate_mobile_format_check;
alter table public.leads
  add constraint leads_alternate_mobile_format_check
  check (alternate_mobile is null or alternate_mobile ~ '^[6-9][0-9]{9}$');

comment on column public.leads.alternate_mobile is
  'Optional second contact number, 10-digit normalized Indian mobile. Added for the Edit Lead screen (2026-11-02). Not carried to customers on move_lead_to_customer() -- customers has no matching column (see migration header).';
comment on column public.leads.address_text is
  'Free-text address for leads with no customer_id yet (most staff-entered leads). Distinct from leads.address_id, which only ever points at an existing customer''s saved address. Added for the Edit Lead screen (2026-11-02).';

-- ── 2. Audit trail for edits, same pattern as audit_profile_changes ─────
-- (20261006180000_audit_profile_changes.sql): a trigger, not a manual insert
-- inside the RPC, so it fires no matter which code path changes these
-- columns and can't be forgotten by a future caller -- same rationale as the
-- very first audit trigger in this codebase (audit_master_change,
-- 20260702090000_audit_triggers.sql: "automatic, can't be bypassed by a
-- caller forgetting a step"). Only fires when one of the edit screen's own
-- columns actually changed -- a status/owner_id/assigned_to/follow-up change
-- elsewhere on the row does not produce a row here (those already have their
-- own trails: lead_activities / lead_stage_log).
create or replace function public.audit_lead_edit_fields()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid;
begin
  if new.name is not distinct from old.name
     and new.mobile is not distinct from old.mobile
     and new.alternate_mobile is not distinct from old.alternate_mobile
     and new.address_text is not distinct from old.address_text
     and new.source is not distinct from old.source
     and new.product_type_key is not distinct from old.product_type_key
     and new.notes is not distinct from old.notes then
    return new;
  end if;

  select id into v_actor from public.profiles where id = auth.uid();

  insert into public.audit_log (org_id, actor_id, action, table_name, row_id, before, after)
  values (
    new.org_id,
    v_actor,
    'UPDATE',
    'leads',
    new.id,
    jsonb_build_object(
      'name', old.name, 'mobile', old.mobile, 'alternate_mobile', old.alternate_mobile,
      'address_text', old.address_text, 'source', old.source,
      'product_type_key', old.product_type_key, 'notes', old.notes),
    jsonb_build_object(
      'name', new.name, 'mobile', new.mobile, 'alternate_mobile', new.alternate_mobile,
      'address_text', new.address_text, 'source', new.source,
      'product_type_key', new.product_type_key, 'notes', new.notes)
  );

  return new;
end;
$$;

drop trigger if exists audit_lead_edit_fields on public.leads;
create trigger audit_lead_edit_fields
  after update on public.leads
  for each row execute function public.audit_lead_edit_fields();

-- ── 3. update_lead_details: the one RPC the Edit Lead screen calls ──────
-- Deliberately does NOT take owner_id as a parameter at all -- it can never
-- be changed from this screen, full stop (see CRITICAL note below).
-- `source` IS a parameter, but moving to/from 'referral' is rejected: that
-- value is only ever set by the referral-capture flow
-- (_dedupe_referral_leads / technician_finder_conversions key off
-- source='referral' + owner_id together -- 20261117100002), so editing it by
-- hand here could either silently mint a fake, un-attributed "referral" lead
-- (source='referral' but owner_id null/wrong -- technician_finder_conversions
-- would simply never count it, harmless but confusing) or, worse, erase the
-- record of an already-earned finder credit by flipping an existing referral
-- lead to some other source. Rejecting the transition entirely in both
-- directions is simpler and safer than trying to re-run the referral capture
-- logic from inside an edit screen.
create or replace function public.update_lead_details(
  p_lead_id uuid,
  p_name text,
  p_mobile text,
  p_alternate_mobile text,
  p_address_text text,
  p_source text,
  p_product_type_key text,
  p_notes text
)
returns public.leads
language plpgsql
security definer
set search_path = public
as $$
declare
  v_lead public.leads;
  v_name text;
  v_mobile text;
  v_alt text;
begin
  if not public.is_staff() then
    raise exception 'not permitted: only master, operation_admin or sales_admin can edit a lead';
  end if;

  select * into v_lead from public.leads where id = p_lead_id and org_id = public.current_org_id() for update;
  if not found then
    raise exception 'lead % not found', p_lead_id;
  end if;

  v_name := btrim(coalesce(p_name, ''));
  if v_name = '' then
    raise exception 'lead name is required';
  end if;

  v_mobile := nullif(btrim(coalesce(p_mobile, '')), '');
  if v_mobile is not null and v_mobile !~ '^[6-9][0-9]{9}$' then
    raise exception 'invalid mobile number';
  end if;

  v_alt := nullif(btrim(coalesce(p_alternate_mobile, '')), '');
  if v_alt is not null and v_alt !~ '^[6-9][0-9]{9}$' then
    raise exception 'invalid alternate mobile number';
  end if;

  -- CRITICAL referral-safety guard: source can change freely among every
  -- non-referral value, but 'referral' itself is immutable in both
  -- directions via this screen. owner_id is not a parameter of this
  -- function at all, so it is unconditionally untouched by any call here.
  if p_source is distinct from v_lead.source and (v_lead.source = 'referral' or p_source = 'referral') then
    raise exception 'lead source cannot be changed to or from referral here -- it is set by the referral capture flow';
  end if;
  if not exists (select 1 from public.lead_sources where org_id = v_lead.org_id and key = p_source) then
    raise exception 'unknown lead source %', p_source;
  end if;

  update public.leads set
    name = v_name,
    mobile = v_mobile,
    alternate_mobile = v_alt,
    address_text = nullif(btrim(coalesce(p_address_text, '')), ''),
    source = p_source,
    product_type_key = nullif(btrim(coalesce(p_product_type_key, '')), ''),
    notes = nullif(btrim(coalesce(p_notes, '')), ''),
    updated_at = now()
  where id = p_lead_id
  returning * into v_lead;

  return v_lead;
end;
$$;

revoke all on function public.update_lead_details(uuid, text, text, text, text, text, text, text) from public, anon;
grant execute on function public.update_lead_details(uuid, text, text, text, text, text, text, text) to authenticated;
