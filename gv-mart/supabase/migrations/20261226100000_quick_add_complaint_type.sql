-- quick-add (F3, 2026-11-26): "+ Add" for Name of complaint on New Complaint.
--
-- complaint_types is write = master-only by RLS (complaint_types_write_master),
-- but New Complaint is open to master + operation_admin. Owner decision D3:
-- let both roles add a complaint *name* from the form, without widening the
-- table's RLS (operation_admin still can't edit/delete/re-scope existing rows).
--
-- Narrow SECURITY DEFINER: org comes from current_org_id() (never a param),
-- label is trimmed/space-collapsed and length-checked, and an existing label
-- for the same org+category (case-insensitive) is returned instead of
-- inserting a duplicate. Category-level row only (product_id null), same as
-- the rows Masters -> Complaint types creates.

create or replace function public.quick_add_complaint_type(p_label text, p_category public.brand_category)
returns public.complaint_types
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid := public.current_org_id();
  v_label text := regexp_replace(btrim(coalesce(p_label, '')), '\s+', ' ', 'g');
  v_row public.complaint_types;
begin
  if v_org is null or not public.is_ops_staff() then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if p_category is null then
    raise exception 'category required' using errcode = '22023';
  end if;
  if length(v_label) = 0 or length(v_label) > 120 then
    raise exception 'label must be 1-120 characters' using errcode = '22023';
  end if;

  -- Serialise concurrent adds of the same name so the dedupe check can't race.
  perform pg_advisory_xact_lock(hashtextextended(v_org::text || ':' || p_category::text || ':' || lower(v_label), 0));

  select * into v_row
  from public.complaint_types
  where org_id = v_org and product_category = p_category and product_id is null and lower(label) = lower(v_label)
  limit 1;
  if found then
    return v_row;
  end if;

  insert into public.complaint_types (org_id, product_category, label)
  values (v_org, p_category, v_label)
  returning * into v_row;
  return v_row;
end;
$$;

-- Project auto-grants EXECUTE to anon on new functions (see memory
-- default-privileges anon EXECUTE leak) — revoke explicitly.
revoke all on function public.quick_add_complaint_type(text, public.brand_category) from public, anon;
grant execute on function public.quick_add_complaint_type(text, public.brand_category) to authenticated;
