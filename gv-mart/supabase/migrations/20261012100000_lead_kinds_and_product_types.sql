-- Master-managed lead kinds and lead product types (2026-10-12) — batch-17 items 2 and 4.
--
-- "Kind" (service/spare/product/amc) and "Product type" (ro/ac/inverter/battery) were hard-coded
-- Postgres enums (lead_kind, brand_category). brand_category is shared with brands, models,
-- complaint_types and installation_rates, so it must not grow. Masters now owns both lists, like lead_sources.
--
-- PHASE 1 (this migration, additive and backward compatible):
--   * lead_kinds / lead_product_types tables (system rows cannot be deleted; rows in use cannot be deleted).
--   * leads.kind_key / leads.product_type_key text columns, backfilled, kept in step with the old enum
--     columns by a BEFORE trigger in BOTH directions, so un-updated writers (RPCs, old frontend bundles) still work.
--   * list_followups / list_leads_without_followup: p_kind lead_kind -> text. The old signature is dropped in the
--     same transaction so no ambiguous overload exists; a JSON string argument works unchanged for old callers.
-- PHASE 2 (later migration, after the frontend has shipped): stop reading leads.kind / product_category.
-- PHASE 3 (later): drop the old enum columns.

create table public.lead_kinds (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  key text not null,
  label text not null,
  label_ta text,
  is_system boolean not null default false,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (org_id, key)
);
create index lead_kinds_org_id_idx on public.lead_kinds (org_id);

create table public.lead_product_types (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  key text not null,
  label text not null,
  label_ta text,
  is_system boolean not null default false,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (org_id, key)
);
create index lead_product_types_org_id_idx on public.lead_product_types (org_id);

alter table public.lead_kinds enable row level security;
alter table public.lead_product_types enable row level security;

create policy lead_kinds_select_org on public.lead_kinds for select using (org_id = public.current_org_id());
create policy lead_kinds_write_master on public.lead_kinds for all
  using (org_id = public.current_org_id() and public.is_master())
  with check (org_id = public.current_org_id() and public.is_master());
create policy lead_product_types_select_org on public.lead_product_types for select using (org_id = public.current_org_id());
create policy lead_product_types_write_master on public.lead_product_types for all
  using (org_id = public.current_org_id() and public.is_master())
  with check (org_id = public.current_org_id() and public.is_master());

create trigger audit_lead_kinds after insert or update or delete on public.lead_kinds for each row execute function public.audit_master_change();
create trigger audit_lead_product_types after insert or update or delete on public.lead_product_types for each row execute function public.audit_master_change();
create trigger set_updated_at before update on public.lead_kinds for each row execute function public.set_updated_at();
create trigger set_updated_at before update on public.lead_product_types for each row execute function public.set_updated_at();

-- seeds ---------------------------------------------------------------------------------------------
-- System rows are what code keys off (the four original kinds/categories). Warranty and Multigrade are
-- ordinary rows: label-only, renameable, deletable while unused.
create or replace function public.seed_lead_kinds(p_org_id uuid)
returns void language sql security definer set search_path = public as $$
  insert into public.lead_kinds (org_id, key, label, label_ta, is_system)
  values
    (p_org_id, 'service', 'Service', null, true),
    (p_org_id, 'spare', 'Spare', null, true),
    (p_org_id, 'product', 'Product', null, true),
    (p_org_id, 'amc', 'AMC', null, true),
    (p_org_id, 'warranty', 'Warranty', 'உத்தரவாதம்', false)
  on conflict (org_id, key) do nothing;
$$;
create or replace function public.seed_lead_product_types(p_org_id uuid)
returns void language sql security definer set search_path = public as $$
  insert into public.lead_product_types (org_id, key, label, label_ta, is_system)
  values
    (p_org_id, 'ro', 'RO / Water Purifier', null, true),
    (p_org_id, 'ac', 'AC', null, true),
    (p_org_id, 'inverter', 'Inverter', null, true),
    (p_org_id, 'battery', 'Battery', null, true),
    (p_org_id, 'multigrade', 'Multigrade', 'மல்டிகிரேட்', false)
  on conflict (org_id, key) do nothing;
$$;
revoke execute on function public.seed_lead_kinds(uuid) from public, anon, authenticated;
revoke execute on function public.seed_lead_product_types(uuid) from public, anon, authenticated;

create or replace function public.trg_seed_lead_lists()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.seed_lead_kinds(new.id);
  perform public.seed_lead_product_types(new.id);
  return new;
end;
$$;
revoke execute on function public.trg_seed_lead_lists() from public, anon, authenticated;
create trigger seed_lead_lists_on_org after insert on public.organizations
  for each row execute function public.trg_seed_lead_lists();

select public.seed_lead_kinds(id) from public.organizations;
select public.seed_lead_product_types(id) from public.organizations;

-- guards on the list tables --------------------------------------------------------------------------
-- key and is_system are fixed at creation. Delete is refused for system rows and for keys still carried by a lead.
-- Test/cleanup escape hatch: `set local app.lead_lists_cleanup = 'on'` lets a throwaway organisation's rows be removed
-- (an org cascade cannot do it for audited master tables: the audit trigger would write a row for a deleted org).
create or replace function public._trg_lead_list_guard()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_in_use boolean;
begin
  if tg_op = 'UPDATE' then
    if new.key is distinct from old.key then raise exception 'lead list keys cannot be changed'; end if;
    if new.is_system is distinct from old.is_system then raise exception 'is_system cannot be changed'; end if;
    if new.org_id is distinct from old.org_id then raise exception 'org_id cannot be changed'; end if;
    return new;
  end if;
  -- DELETE
  if coalesce(current_setting('app.lead_lists_cleanup', true), '') = 'on' then
    return old;
  end if;
  if old.is_system then
    raise exception 'built-in % cannot be deleted; deactivate it instead', old.key;
  end if;
  if tg_table_name = 'lead_kinds' then
    select exists (select 1 from public.leads l where l.org_id = old.org_id and l.kind_key = old.key) into v_in_use;
  else
    select exists (select 1 from public.leads l where l.org_id = old.org_id and l.product_type_key = old.key) into v_in_use;
  end if;
  if v_in_use then
    raise exception '% is used by existing leads; deactivate it instead', old.key;
  end if;
  return old;
end;
$$;
revoke execute on function public._trg_lead_list_guard() from public, anon, authenticated;
create trigger lead_kinds_guard before update or delete on public.lead_kinds for each row execute function public._trg_lead_list_guard();
create trigger lead_product_types_guard before update or delete on public.lead_product_types for each row execute function public._trg_lead_list_guard();

-- leads columns + backfill -----------------------------------------------------------------------------
alter table public.leads add column kind_key text;
alter table public.leads add column product_type_key text;

-- the backfill must not touch updated_at on existing leads
alter table public.leads disable trigger set_updated_at;
update public.leads set kind_key = kind::text where kind is not null and kind_key is null;
update public.leads set product_type_key = product_category::text where product_category is not null and product_type_key is null;
alter table public.leads enable trigger set_updated_at;

create index leads_kind_key_idx on public.leads (org_id, kind_key);
create index leads_product_type_key_idx on public.leads (org_id, product_type_key);

-- two-way sync (old enum column <-> new text key) --------------------------------------------------------
-- Explicit new key wins. A custom key (not an enum label) leaves the old enum column untouched.
create or replace function public._trg_lead_lists_sync()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  -- kind
  if tg_op = 'INSERT' then
    if new.kind_key is null and new.kind is not null then
      new.kind_key := new.kind::text;
    elsif new.kind_key is not null and new.kind_key = any (enum_range(null::public.lead_kind)::text[]) then
      new.kind := new.kind_key::public.lead_kind;
    end if;
  else
    if new.kind_key is distinct from old.kind_key then
      if new.kind_key is null then
        new.kind := null;
      elsif new.kind_key = any (enum_range(null::public.lead_kind)::text[]) then
        new.kind := new.kind_key::public.lead_kind;
      end if;
    elsif new.kind is distinct from old.kind then
      new.kind_key := new.kind::text;
    end if;
  end if;
  -- product type
  if tg_op = 'INSERT' then
    if new.product_type_key is null and new.product_category is not null then
      new.product_type_key := new.product_category::text;
    elsif new.product_type_key is not null and new.product_type_key = any (enum_range(null::public.brand_category)::text[]) then
      new.product_category := new.product_type_key::public.brand_category;
    end if;
  else
    if new.product_type_key is distinct from old.product_type_key then
      if new.product_type_key is null then
        new.product_category := null;
      elsif new.product_type_key = any (enum_range(null::public.brand_category)::text[]) then
        new.product_category := new.product_type_key::public.brand_category;
      end if;
    elsif new.product_category is distinct from old.product_category then
      new.product_type_key := new.product_category::text;
    end if;
  end if;
  -- a key that is being set must exist in the org's list (inactive is allowed: existing leads keep theirs)
  if new.kind_key is not null and (tg_op = 'INSERT' or new.kind_key is distinct from old.kind_key)
     and not exists (select 1 from public.lead_kinds k where k.org_id = new.org_id and k.key = new.kind_key) then
    raise exception 'unknown lead kind %', new.kind_key;
  end if;
  if new.product_type_key is not null and (tg_op = 'INSERT' or new.product_type_key is distinct from old.product_type_key)
     and not exists (select 1 from public.lead_product_types p where p.org_id = new.org_id and p.key = new.product_type_key) then
    raise exception 'unknown lead product type %', new.product_type_key;
  end if;
  return new;
end;
$$;
revoke execute on function public._trg_lead_lists_sync() from public, anon, authenticated;
create trigger leads_lists_sync before insert or update of kind, kind_key, product_category, product_type_key on public.leads
  for each row execute function public._trg_lead_lists_sync();

-- list functions: p_kind lead_kind -> text ------------------------------------------------------------------
-- Bodies are the LIVE definitions (2026-10-12); only the kind parameter, the kind return column and the kind
-- filter change. The kind column is returned as text (the key), which serialises exactly like the old enum did.
drop function public.list_followups(text, public.lead_status, text, public.lead_kind, boolean, text, uuid);
drop function public.list_leads_without_followup(public.lead_status, text, public.lead_kind, text, uuid);


CREATE FUNCTION public.list_followups(p_bucket text DEFAULT 'all'::text, p_stage lead_status DEFAULT NULL::lead_status, p_source text DEFAULT NULL::text, p_kind text DEFAULT NULL::text, p_stuck_only boolean DEFAULT false, p_scope text DEFAULT 'auto'::text, p_assignee uuid DEFAULT NULL::uuid)
 RETURNS TABLE(followup_id uuid, lead_id uuid, lead_name text, mobile text, source text, kind text, enquiry_type enquiry_type, lead_status lead_status, product_name text, due_at timestamp with time zone, followup_type lead_followup_type, followup_note text, is_exact_time boolean, postpone_count integer, is_stuck boolean, bucket text, last_outcome_code text, last_outcome_label_en text, last_outcome_label_ta text, last_outcome_note text, last_outcome_at timestamp with time zone, assignee_id uuid, assignee_name text)
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
revoke all on function public.list_followups(text, public.lead_status, text, text, boolean, text, uuid) from public, anon, authenticated;
grant execute on function public.list_followups(text, public.lead_status, text, text, boolean, text, uuid) to authenticated, service_role;

CREATE FUNCTION public.list_leads_without_followup(p_stage lead_status DEFAULT NULL::lead_status, p_source text DEFAULT NULL::text, p_kind text DEFAULT NULL::text, p_scope text DEFAULT 'auto'::text, p_assignee uuid DEFAULT NULL::uuid)
 RETURNS TABLE(lead_id uuid, lead_name text, mobile text, source text, kind text, enquiry_type enquiry_type, lead_status lead_status, product_name text, created_at timestamp with time zone, postpone_count integer, assignee_id uuid, assignee_name text, last_outcome_label_en text, last_outcome_label_ta text, last_outcome_note text, last_outcome_at timestamp with time zone)
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
revoke all on function public.list_leads_without_followup(public.lead_status, text, text, text, uuid) from public, anon, authenticated;
grant execute on function public.list_leads_without_followup(public.lead_status, text, text, text, uuid) to authenticated, service_role;

notify pgrst, 'reload schema';
