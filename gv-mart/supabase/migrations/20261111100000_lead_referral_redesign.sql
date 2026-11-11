-- Lead referral/source redesign (2026-11-11).
--
-- 1. tds_status becomes free text, not a fixed Applicable/Not applicable/To be
--    confirmed dropdown -- staff asked to type the actual reading/note. Drop
--    the enum-style check constraint; column stays `text`, no data loss.
alter table public.leads drop constraint if exists leads_tds_status_check;

-- 1b. New seeded source "Reporting staff" (key reporting_staff), alongside the
--     existing 6 (field/customer_app/whatsapp/walk_in/referral/other) -- live
--     body pinned above, additive row only. Picking it on the lead form shows
--     the same Referred-by picker as "Technician" (source=field), just scoped
--     to staff (master/operation_admin/sales_admin) instead of technicians --
--     see ReferredBySection.tsx / ReferrerPicker's kindFilter.
CREATE OR REPLACE FUNCTION public.seed_lead_sources(p_org_id uuid)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  insert into public.lead_sources (org_id, key, label, is_system)
  values
    (p_org_id, 'field', 'Field', true),
    (p_org_id, 'customer_app', 'Customer app', true),
    (p_org_id, 'whatsapp', 'WhatsApp', true),
    (p_org_id, 'walk_in', 'Walk-in', true),
    (p_org_id, 'referral', 'Referral', true),
    (p_org_id, 'reporting_staff', 'Reporting staff', true),
    (p_org_id, 'other', 'Other', true)
  on conflict (org_id, key) do nothing;
$function$;

-- Backfill: every org that already ran the old seed is missing this one row.
insert into public.lead_sources (org_id, key, label, is_system)
select id, 'reporting_staff', 'Reporting staff', true from public.organizations
on conflict (org_id, key) do nothing;

-- 2. list_followups -- live body pinned above, byte-identical except for the
--    one additive `when_needed` output column (My Day / daily follow-up list
--    now shows the customer's stated urgency alongside the due date).
CREATE OR REPLACE FUNCTION public.list_followups(p_bucket text DEFAULT 'all'::text, p_stage lead_status DEFAULT NULL::lead_status, p_source text DEFAULT NULL::text, p_kind text DEFAULT NULL::text, p_stuck_only boolean DEFAULT false, p_scope text DEFAULT 'auto'::text, p_assignee uuid DEFAULT NULL::uuid)
 RETURNS TABLE(followup_id uuid, lead_id uuid, lead_name text, mobile text, source text, kind text, enquiry_type enquiry_type, lead_status lead_status, product_name text, due_at timestamp with time zone, followup_type lead_followup_type, followup_note text, is_exact_time boolean, postpone_count integer, is_stuck boolean, bucket text, last_outcome_code text, last_outcome_label_en text, last_outcome_label_ta text, last_outcome_note text, last_outcome_at timestamp with time zone, assignee_id uuid, assignee_name text, when_needed text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_org uuid := public.current_org_id();
  v_uid uuid := auth.uid();
  v_today date := public._lead_ist_date(now());
  v_stuck integer;
  v_scope text;
begin
  if not public.is_sales_staff() then
    raise exception 'not permitted: only master or sales_admin can view follow-ups';
  end if;
  if p_bucket not in ('all', 'overdue', 'today', 'upcoming') then
    raise exception 'invalid bucket %', p_bucket;
  end if;
  v_scope := public._lead_resolve_scope(p_scope);
  if v_scope = 'person' and p_assignee is null then
    raise exception 'person scope needs an assignee';
  end if;
  select coalesce(s.lead_stuck_postpones, 3) into v_stuck from public.settings s where s.org_id = v_org;
  v_stuck := coalesce(v_stuck, 3);

  return query
  select
    f.id, l.id, coalesce(c.name, l.name), coalesce(l.mobile, c.mobile), l.source, coalesce(l.kind_key, l.kind::text), l.enquiry_type, l.status,
    coalesce(
      (select coalesce(sp.name, pr.name) from public.lead_items li
         left join public.spares sp on sp.id = li.spare_id
         left join public.products pr on pr.id = li.product_id
         where li.lead_id = l.id order by li.created_at limit 1),
      (select pr2.name from public.products pr2 where pr2.id = l.product_id)
    ),
    f.due_at, f.type, f.note, f.is_exact_time, l.postpone_count, (l.postpone_count >= v_stuck),
    case
      when public._lead_ist_date(f.due_at) < v_today then 'overdue'
      when public._lead_ist_date(f.due_at) = v_today then 'today'
      when public._lead_ist_date(f.due_at) <= v_today + 7 then 'upcoming'
      else 'later'
    end,
    lo.code, lo.label_en, lo.label_ta, lo.note, lo.at,
    ap.id, ap.full_name,
    l.when_needed
  from public.lead_followups f
  join public.leads l on l.id = f.lead_id
  left join public.customers c on c.id = l.customer_id
  left join public.profiles ap on ap.id = l.assigned_to and ap.is_active and ap.role in ('master', 'sales_admin')
  left join lateral (
    select o.code, o.label_en, o.label_ta, a.note, a.at
    from public.lead_activities a join public.lead_outcomes o on o.id = a.outcome_id
    where a.lead_id = l.id order by a.at desc limit 1
  ) lo on true
  where f.org_id = v_org and f.status = 'open' and l.status not in ('won', 'lost') and not l.is_test
    and (p_stage is null or l.status = p_stage)
    and (p_source is null or l.source = p_source)
    and (p_kind is null or coalesce(l.kind_key, l.kind::text) = p_kind)
    and (not p_stuck_only or l.postpone_count >= v_stuck)
    and (
      v_scope = 'all'
      or (v_scope = 'mine' and ap.id = v_uid)
      or (v_scope = 'unassigned' and ap.id is null)
      or (v_scope = 'mine_unassigned' and (ap.id = v_uid or ap.id is null))
      or (v_scope = 'person' and ap.id = p_assignee)
    )
    and (
      p_bucket = 'all'
      or (p_bucket = 'overdue' and public._lead_ist_date(f.due_at) < v_today)
      or (p_bucket = 'today' and public._lead_ist_date(f.due_at) = v_today)
      or (p_bucket = 'upcoming' and public._lead_ist_date(f.due_at) > v_today and public._lead_ist_date(f.due_at) <= v_today + 7)
    )
  order by f.due_at asc;
end;
$function$;

-- 3. list_leads_without_followup -- same additive `when_needed` column, live
--    body pinned above, otherwise byte-identical. This is the list staff see
--    BEFORE a follow-up even exists, so the customer's stated urgency is the
--    one thing most worth surfacing here.
CREATE OR REPLACE FUNCTION public.list_leads_without_followup(p_stage lead_status DEFAULT NULL::lead_status, p_source text DEFAULT NULL::text, p_kind text DEFAULT NULL::text, p_scope text DEFAULT 'auto'::text, p_assignee uuid DEFAULT NULL::uuid)
 RETURNS TABLE(lead_id uuid, lead_name text, mobile text, source text, kind text, enquiry_type enquiry_type, lead_status lead_status, product_name text, created_at timestamp with time zone, postpone_count integer, assignee_id uuid, assignee_name text, last_outcome_label_en text, last_outcome_label_ta text, last_outcome_note text, last_outcome_at timestamp with time zone, when_needed text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_org uuid := public.current_org_id();
  v_uid uuid := auth.uid();
  v_scope text;
begin
  if not public.is_sales_staff() then
    raise exception 'not permitted: only master or sales_admin can view leads without a follow-up';
  end if;
  v_scope := public._lead_resolve_scope(p_scope);
  if v_scope = 'person' and p_assignee is null then
    raise exception 'person scope needs an assignee';
  end if;

  return query
  select
    l.id, coalesce(c.name, l.name), coalesce(l.mobile, c.mobile), l.source, coalesce(l.kind_key, l.kind::text), l.enquiry_type, l.status,
    coalesce(
      (select coalesce(sp.name, pr.name) from public.lead_items li
         left join public.spares sp on sp.id = li.spare_id
         left join public.products pr on pr.id = li.product_id
         where li.lead_id = l.id order by li.created_at limit 1),
      (select pr2.name from public.products pr2 where pr2.id = l.product_id)
    ),
    l.created_at, l.postpone_count, ap.id, ap.full_name,
    lo.label_en, lo.label_ta, lo.note, lo.at,
    l.when_needed
  from public.leads l
  left join public.customers c on c.id = l.customer_id
  left join public.profiles ap on ap.id = l.assigned_to and ap.is_active and ap.role in ('master', 'sales_admin')
  left join lateral (
    select o.label_en, o.label_ta, a.note, a.at
    from public.lead_activities a join public.lead_outcomes o on o.id = a.outcome_id
    where a.lead_id = l.id order by a.at desc limit 1
  ) lo on true
  where l.org_id = v_org and l.status not in ('won', 'lost') and not l.is_test
    and not exists (select 1 from public.lead_followups f where f.lead_id = l.id and f.status = 'open')
    and (p_stage is null or l.status = p_stage)
    and (p_source is null or l.source = p_source)
    and (p_kind is null or coalesce(l.kind_key, l.kind::text) = p_kind)
    and (
      v_scope = 'all'
      or (v_scope = 'mine' and ap.id = v_uid)
      or (v_scope = 'unassigned' and ap.id is null)
      or (v_scope = 'mine_unassigned' and (ap.id = v_uid or ap.id is null))
      or (v_scope = 'person' and ap.id = p_assignee)
    )
  order by l.created_at asc, l.id asc;
end;
$function$;
