-- GV.md §1 "SOP checklist & task timing" — resolves Build Order Guardrails'
-- DECISION item D4 (SOP checklist data model) now that the owner has picked
-- an answer: the checklist is populated from the job's actual inventory
-- items, each carrying an admin-set standard time (GV.md 1.1), which also
-- feeds the technician's "estimated + allowed time" (GV.md 1.2/1.3).
--
-- Three pieces, all additive:
--   1. `standard_time_minutes` on products AND spares (GV.md 1.1's own
--      example — "back wheel 10 min, horn 5 min, tank clean 5 min" — mixes
--      physical parts and service tasks, both of which live in `spares` in
--      this schema per 20260701090300_catalog_inventory.sql; `products` gets
--      the same column for completeness since GV.md says "product / inventory
--      item").
--   2. `settings.review_time_allowance_minutes` /
--      `enquiry_time_allowance_minutes` — the two new admin-set allowances
--      GV.md 1.2 describes, mirroring the existing `default_duration_*`
--      pattern (20260721090000_technician_assignment_phase1_data.sql).
--   3. The plumbing the *conditional* part of 1.2 needs to actually be
--      checkable: `leads.visit_id` (so "was an enquiry logged during THIS
--      visit" is a real join, not a fragile time-window guess) and a new
--      `mark_google_review_clicked` RPC (GV.md's own `ratings.
--      google_review_clicked` column has existed since Phase 1 but nothing
--      in the app has ever set it true — RatingPage.tsx's Google-review link
--      is a plain <a> tag with no click handler; see the frontend change in
--      the same batch as this migration for the wiring).

-- ── 1.1 Admin-set standard time per item ────────────────────────────────
alter table public.products
  add column if not exists standard_time_minutes integer
    check (standard_time_minutes is null or standard_time_minutes > 0);

alter table public.spares
  add column if not exists standard_time_minutes integer
    check (standard_time_minutes is null or standard_time_minutes > 0);

comment on column public.products.standard_time_minutes is
  'GV.md 1.1: admin/operation_admin-set standard service time for this item, editable anytime. Feeds the SOP checklist (1.1/D4) and the estimated/allowed-time calculation (1.2). Null = not yet timed.';
comment on column public.spares.standard_time_minutes is
  'GV.md 1.1: admin/operation_admin-set standard service time for this item, editable anytime. Feeds the SOP checklist (1.1/D4) and the estimated/allowed-time calculation (1.2). Null = not yet timed.';

-- Master already has full read/write on products/spares (products_write_master
-- / spares_write_master, 20260701091300_rls.sql) — this column rides along
-- for free there (ProductsTab/SparesTab). operation_admin does NOT have
-- table-level write access to products/spares (deliberately narrow per that
-- migration's role model) and GV.md 1.1 explicitly wants operation_admin to
-- be able to set this one field too. Rather than widening full CRUD access
-- to products/spares for operation_admin (a bigger blast-radius change GV.md
-- didn't ask for), this adds one narrow SECURITY DEFINER RPC scoped to
-- exactly this column, gated on is_ops_staff() (master OR operation_admin) —
-- exposed in the Inventory screen (already operation_admin-accessible),
-- alongside the existing min/max/reorder threshold editor.
create or replace function public.set_item_standard_time(
  p_org_id uuid,
  p_item_type item_type,
  p_item_id uuid,
  p_minutes integer
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_ops_staff() then
    raise exception 'set_item_standard_time: caller is not ops staff';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'set_item_standard_time: org mismatch';
  end if;
  if p_minutes is not null and p_minutes <= 0 then
    raise exception 'set_item_standard_time: minutes must be positive';
  end if;

  if p_item_type = 'product' then
    update public.products set standard_time_minutes = p_minutes, updated_at = now()
    where id = p_item_id and org_id = p_org_id;
  else
    update public.spares set standard_time_minutes = p_minutes, updated_at = now()
    where id = p_item_id and org_id = p_org_id;
  end if;

  if not found then
    raise exception 'set_item_standard_time: item % not found in org', p_item_id;
  end if;
end;
$$;

grant execute on function public.set_item_standard_time(uuid, item_type, uuid, integer) to authenticated;

-- ── 1.2 Review / enquiry time allowances (settings) ─────────────────────
alter table public.settings
  add column if not exists review_time_allowance_minutes integer not null default 5
    check (review_time_allowance_minutes > 0),
  add column if not exists enquiry_time_allowance_minutes integer not null default 5
    check (enquiry_time_allowance_minutes > 0);

comment on column public.settings.review_time_allowance_minutes is
  'GV.md 1.2: minutes added to a job''s allowed time when this visit actually collected a Google review click (ratings.google_review_clicked). Admin-editable, Masters > Settings.';
comment on column public.settings.enquiry_time_allowance_minutes is
  'GV.md 1.2: minutes added to a job''s allowed time when a new enquiry (leads.visit_id) was logged during this visit. Admin-editable, Masters > Settings.';

-- ── 1.2 "logged during THIS visit" — a real join, not a guess ───────────
-- generate_enquiry_lead (20260702120000_technician_phase7_functions.sql)
-- already stamps owner_id = the calling technician, but had no link back to
-- *which visit* the field enquiry was raised on — inferring that from
-- owner_id + a created_at time-window would be fragile (concurrent jobs,
-- clock skew). Nullable: only field-raised enquiries logged via the on-site
-- flow have a visit at all; walk-in/WhatsApp/other leads correctly have none.
alter table public.leads add column if not exists visit_id uuid references public.service_visits (id) on delete set null;

create index if not exists leads_visit_id_idx on public.leads (visit_id) where visit_id is not null;

create or replace function public.generate_enquiry_lead(
  p_org_id uuid,
  p_customer_id uuid,
  p_name text,
  p_mobile text,
  p_enquiry_type enquiry_type,
  p_note text,
  p_visit_id uuid default null
)
returns uuid
language plpgsql
security invoker
as $$
declare
  v_tech_id uuid;
  v_lead_id uuid;
begin
  v_tech_id := public.current_technician_id();
  if v_tech_id is null then
    raise exception 'generate_enquiry_lead: caller is not a technician';
  end if;
  if p_name is null or btrim(p_name) = '' then
    raise exception 'generate_enquiry_lead: name is required';
  end if;
  if p_visit_id is not null and not exists (
    select 1 from public.service_visits v where v.id = p_visit_id and v.technician_id = v_tech_id
  ) then
    raise exception 'generate_enquiry_lead: visit % does not belong to the calling technician', p_visit_id;
  end if;

  insert into public.leads (org_id, customer_id, name, mobile, source, enquiry_type, status, owner_id, visit_id)
  values (p_org_id, p_customer_id, p_name, nullif(p_mobile, ''), 'field', p_enquiry_type, 'new', v_tech_id, p_visit_id)
  returning id into v_lead_id;

  if p_note is not null and btrim(p_note) <> '' then
    insert into public.lead_activities (org_id, lead_id, type, note)
    values (p_org_id, v_lead_id, 'enquiry_captured', p_note);
  end if;

  return v_lead_id;
end;
$$;

grant execute on function public.generate_enquiry_lead(uuid, uuid, text, text, enquiry_type, text, uuid) to authenticated;

-- ── 1.2 wiring the review-collected condition: mark the click ───────────
-- `ratings.google_review_clicked` (20260701090600_service.sql) has existed
-- since Phase 1 but was never set anywhere — RatingPage.tsx renders the
-- Google-review link as a plain <a href> with no click handler. Needed now
-- that GV.md 1.2 makes this column the live gate for the review-time
-- allowance. `ratings_write_own_technician` (20260701091300_rls.sql) already
-- lets a technician update their own visit's rating row directly, so this
-- could be a plain client update — wrapped as an RPC purely to keep the
-- "does this visit/technician pairing check out" validation server-side and
-- consistent with submit_rating/generate_enquiry_lead above.
create or replace function public.mark_google_review_clicked(
  p_org_id uuid,
  p_visit_id uuid
)
returns void
language plpgsql
security invoker
as $$
declare
  v_tech_id uuid;
begin
  v_tech_id := public.current_technician_id();
  if v_tech_id is null then
    raise exception 'mark_google_review_clicked: caller is not a technician';
  end if;

  update public.ratings r
  set google_review_clicked = true, updated_at = now()
  from public.service_visits v
  where r.visit_id = v.id
    and r.visit_id = p_visit_id
    and r.org_id = p_org_id
    and v.technician_id = v_tech_id;

  if not found then
    raise exception 'mark_google_review_clicked: no rating found for visit % owned by calling technician', p_visit_id;
  end if;
end;
$$;

grant execute on function public.mark_google_review_clicked(uuid, uuid) to authenticated;
