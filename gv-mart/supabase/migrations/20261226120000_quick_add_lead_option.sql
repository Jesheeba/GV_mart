-- quick-add F3b (2026-11-26): "+ Add" for Source / Kind / Product type on the
-- New Lead form and Edit Lead dialog.
--
-- lead_sources / lead_kinds / lead_product_types are write = master-only by
-- RLS, but leads are worked by master + sales_admin. Owner decision D3/D4:
-- let sales staff add a value from the form without widening RLS (they still
-- can't rename, archive or delete).
--
-- Same key rule as Masters (src/lib/lead-sources.ts leadSourceKeyFromLabel):
-- lowercase, non [a-z0-9] runs -> "_", trimmed of "_". An existing row with
-- that key (or the same label, any case) is returned instead of a duplicate;
-- an existing ARCHIVED row raises "archived" so only the master re-enables it.

create or replace function public.quick_add_lead_option(p_list text, p_label text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid := public.current_org_id();
  v_label text := regexp_replace(btrim(coalesce(p_label, '')), '\s+', ' ', 'g');
  v_key text;
  v_table text;
  v_found_key text;
  v_found_active boolean;
begin
  if v_org is null or not public.is_sales_staff() then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  v_table := case p_list when 'source' then 'lead_sources' when 'kind' then 'lead_kinds' when 'product_type' then 'lead_product_types' end;
  if v_table is null then
    raise exception 'unknown list %', p_list using errcode = '22023';
  end if;
  if length(v_label) = 0 or length(v_label) > 60 then
    raise exception 'label must be 1-60 characters' using errcode = '22023';
  end if;
  v_key := btrim(regexp_replace(lower(v_label), '[^a-z0-9]+', '_', 'g'), '_');
  if v_key = '' then
    raise exception 'label needs at least one letter or digit' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(v_org::text || ':' || v_table || ':' || v_key, 0));

  execute format('select key, is_active from public.%I where org_id = $1 and (key = $2 or lower(label) = lower($3)) order by (key = $2) desc limit 1', v_table)
    into v_found_key, v_found_active using v_org, v_key, v_label;
  if v_found_key is not null then
    if not v_found_active then
      raise exception 'archived' using errcode = 'P0001', hint = 'Ask the master to turn it back on in Masters.';
    end if;
    return v_found_key;
  end if;

  execute format('insert into public.%I (org_id, key, label, is_system, is_active) values ($1, $2, $3, false, true)', v_table)
    using v_org, v_key, v_label;
  return v_key;
end;
$$;

-- Project auto-grants EXECUTE to anon/PUBLIC on new functions — revoke explicitly.
revoke all on function public.quick_add_lead_option(text, text) from public, anon;
grant execute on function public.quick_add_lead_option(text, text) to authenticated;
