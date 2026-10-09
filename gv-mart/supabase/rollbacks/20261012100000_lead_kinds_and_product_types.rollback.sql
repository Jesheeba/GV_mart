-- Rollback for 20261012100000_lead_kinds_and_product_types.sql (restores the live pre-migration state).
-- Safe only while no lead carries a custom kind or product type (warranty / multigrade or your own);
-- check first:  select count(*) from leads where kind_key not in ('service','spare','product','amc')
--                                              or product_type_key not in ('ro','ac','inverter','battery');
drop trigger if exists leads_lists_sync on public.leads;
drop function if exists public._trg_lead_lists_sync();

drop function if exists public.list_followups(text, public.lead_status, text, text, boolean, text, uuid);
drop function if exists public.list_leads_without_followup(public.lead_status, text, text, text, uuid);


CREATE OR REPLACE FUNCTION public.list_followups(p_bucket text DEFAULT 'all'::text, p_stage lead_status DEFAULT NULL::lead_status, p_source text DEFAULT NULL::text, p_kind lead_kind DEFAULT NULL::lead_kind, p_stuck_only boolean DEFAULT false, p_scope text DEFAULT 'auto'::text, p_assignee uuid DEFAULT NULL::uuid)
 RETURNS TABLE(followup_id uuid, lead_id uuid, lead_name text, mobile text, source text, kind lead_kind, enquiry_type enquiry_type, lead_status lead_status, product_name text, due_at timestamp with time zone, followup_type lead_followup_type, followup_note text, is_exact_time boolean, postpone_count integer, is_stuck boolean, bucket text, last_outcome_code text, last_outcome_label_en text, last_outcome_label_ta text, last_outcome_note text, last_outcome_at timestamp with time zone, assignee_id uuid, assignee_name text)
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
    f.id, l.id, coalesce(c.name, l.name), coalesce(l.mobile, c.mobile), l.source, l.kind, l.enquiry_type, l.status,
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
    ap.id, ap.full_name
  from public.lead_followups f
  join public.leads l on l.id = f.lead_id
  left join public.customers c on c.id = l.customer_id
  left join public.profiles ap on ap.id = l.assigned_to and ap.is_active and ap.role in ('master', 'sales_admin')
  left join lateral (
    select o.code, o.label_en, o.label_ta, a.note, a.at
    from public.lead_activities a join public.lead_outcomes o on o.id = a.outcome_id
    where a.lead_id = l.id order by a.at desc limit 1
  ) lo on true
  where f.org_id = v_org and f.status = 'open' and l.status not in ('won', 'lost')
    and (p_stage is null or l.status = p_stage)
    and (p_source is null or l.source = p_source)
    and (p_kind is null or l.kind = p_kind)
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
revoke all on function public.list_followups(text, public.lead_status, text, public.lead_kind, boolean, text, uuid) from public, anon, authenticated;
grant execute on function public.list_followups(text, public.lead_status, text, public.lead_kind, boolean, text, uuid) to authenticated, service_role;

CREATE OR REPLACE FUNCTION public.list_leads_without_followup(p_stage lead_status DEFAULT NULL::lead_status, p_source text DEFAULT NULL::text, p_kind lead_kind DEFAULT NULL::lead_kind, p_scope text DEFAULT 'auto'::text, p_assignee uuid DEFAULT NULL::uuid)
 RETURNS TABLE(lead_id uuid, lead_name text, mobile text, source text, kind lead_kind, enquiry_type enquiry_type, lead_status lead_status, product_name text, created_at timestamp with time zone, postpone_count integer, assignee_id uuid, assignee_name text, last_outcome_label_en text, last_outcome_label_ta text, last_outcome_note text, last_outcome_at timestamp with time zone)
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
    l.id, coalesce(c.name, l.name), coalesce(l.mobile, c.mobile), l.source, l.kind, l.enquiry_type, l.status,
    coalesce(
      (select coalesce(sp.name, pr.name) from public.lead_items li
         left join public.spares sp on sp.id = li.spare_id
         left join public.products pr on pr.id = li.product_id
         where li.lead_id = l.id order by li.created_at limit 1),
      (select pr2.name from public.products pr2 where pr2.id = l.product_id)
    ),
    l.created_at, l.postpone_count, ap.id, ap.full_name,
    lo.label_en, lo.label_ta, lo.note, lo.at
  from public.leads l
  left join public.customers c on c.id = l.customer_id
  left join public.profiles ap on ap.id = l.assigned_to and ap.is_active and ap.role in ('master', 'sales_admin')
  left join lateral (
    select o.label_en, o.label_ta, a.note, a.at
    from public.lead_activities a join public.lead_outcomes o on o.id = a.outcome_id
    where a.lead_id = l.id order by a.at desc limit 1
  ) lo on true
  where l.org_id = v_org and l.status not in ('won', 'lost')
    and not exists (select 1 from public.lead_followups f where f.lead_id = l.id and f.status = 'open')
    and (p_stage is null or l.status = p_stage)
    and (p_source is null or l.source = p_source)
    and (p_kind is null or l.kind = p_kind)
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
revoke all on function public.list_leads_without_followup(public.lead_status, text, public.lead_kind, text, uuid) from public, anon, authenticated;
grant execute on function public.list_leads_without_followup(public.lead_status, text, public.lead_kind, text, uuid) to authenticated, service_role;

drop index if exists public.leads_kind_key_idx;
drop index if exists public.leads_product_type_key_idx;
alter table public.leads drop column if exists kind_key;
alter table public.leads drop column if exists product_type_key;

drop trigger if exists seed_lead_lists_on_org on public.organizations;
drop function if exists public.trg_seed_lead_lists();
drop table if exists public.lead_kinds;
drop table if exists public.lead_product_types;
drop function if exists public._trg_lead_list_guard();
drop function if exists public.seed_lead_kinds(uuid);
drop function if exists public.seed_lead_product_types(uuid);

notify pgrst, 'reload schema';
