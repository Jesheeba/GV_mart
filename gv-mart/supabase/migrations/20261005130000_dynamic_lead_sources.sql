-- Dynamic lead sources (2026-10-05).
--
-- leads.source / customers.source were a hard-coded Postgres enum
-- (lead_source). Masters now owns the list: admins add their own sources
-- (e.g. "Facebook ad", "Exhibition"). The six original values are seeded as
-- is_system rows — code paths key off them (whatsapp, customer_app, field,
-- referral), so they can be renamed/deactivated but never deleted.
-- Both columns become plain text holding the source key.

create table public.lead_sources (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  key text not null,
  label text not null,
  is_system boolean not null default false,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (org_id, key)
);

create index lead_sources_org_id_idx on public.lead_sources (org_id);

alter table public.lead_sources enable row level security;

create policy lead_sources_select_org on public.lead_sources for select using (org_id = public.current_org_id());
create policy lead_sources_write_master on public.lead_sources for all
  using (org_id = public.current_org_id() and public.is_master())
  with check (org_id = public.current_org_id() and public.is_master());

create trigger audit_lead_sources after insert or update or delete on public.lead_sources for each row execute function public.audit_master_change();

create or replace function public.seed_lead_sources(p_org_id uuid)
returns void
language sql
security definer
set search_path = public
as $$
  insert into public.lead_sources (org_id, key, label, is_system)
  values
    (p_org_id, 'field', 'Field', true),
    (p_org_id, 'customer_app', 'Customer app', true),
    (p_org_id, 'whatsapp', 'WhatsApp', true),
    (p_org_id, 'walk_in', 'Walk-in', true),
    (p_org_id, 'referral', 'Referral', true),
    (p_org_id, 'other', 'Other', true)
  on conflict (org_id, key) do nothing;
$$;
revoke execute on function public.seed_lead_sources(uuid) from public, anon, authenticated;

select public.seed_lead_sources(id) from public.organizations;

create or replace function public.trg_seed_lead_sources()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.seed_lead_sources(new.id);
  return new;
end;
$$;
revoke execute on function public.trg_seed_lead_sources() from public, anon, authenticated;

create trigger seed_lead_sources_on_org after insert on public.organizations
  for each row execute function public.trg_seed_lead_sources();

-- enum -> text
alter table public.leads alter column source drop default;
alter table public.leads alter column source type text using source::text;
alter table public.leads alter column source set default 'other';
alter table public.customers alter column source type text using source::text;

-- create_customer_with_details: body verbatim from
-- 20260915130000_address_building_fields.sql; only p_source's type changes.
drop function if exists public.create_customer_with_details(uuid, text, lead_source, jsonb, jsonb);

create or replace function public.create_customer_with_details(
  p_org_id uuid,
  p_profession text,
  p_source text,
  p_members jsonb, -- [{ name, mobile, is_primary, relation }, ...] — 1..5 entries, exactly one is_primary
  p_address jsonb  -- { door_no, building_no, building_name, plot_no, street_cross, area, pincode, landmark, district, state, address_type, ownership, lat, lng }
)
returns uuid
language plpgsql
security invoker
as $$
declare
  v_customer_id uuid;
  v_primary jsonb;
  v_member jsonb;
  v_member_count int;
begin
  select count(*) into v_member_count from jsonb_array_elements(p_members);
  if v_member_count < 1 or v_member_count > 5 then
    raise exception 'create_customer_with_details: members must be between 1 and 5 (got %)', v_member_count;
  end if;

  select m into v_primary from jsonb_array_elements(p_members) m where (m ->> 'is_primary')::boolean is true limit 1;
  if v_primary is null then
    raise exception 'create_customer_with_details: exactly one member must be marked primary';
  end if;

  insert into public.customers (org_id, name, mobile, profession, source)
  values (p_org_id, v_primary ->> 'name', v_primary ->> 'mobile', p_profession, p_source)
  returning id into v_customer_id;

  for v_member in select * from jsonb_array_elements(p_members)
  loop
    insert into public.customer_members (org_id, customer_id, name, mobile, is_primary, relation)
    values (
      p_org_id, v_customer_id, v_member ->> 'name', v_member ->> 'mobile', (v_member ->> 'is_primary')::boolean,
      nullif(v_member ->> 'relation', '')::family_relation
    );
  end loop;

  insert into public.addresses (
    org_id, customer_id, door_no, building_no, building_name, plot_no, street_cross, area, pincode, landmark,
    district, state, address_type, ownership, is_primary, lat, lng
  )
  values (
    p_org_id, v_customer_id,
    nullif(p_address ->> 'door_no', ''), nullif(p_address ->> 'building_no', ''), nullif(p_address ->> 'building_name', ''),
    nullif(p_address ->> 'plot_no', ''), nullif(p_address ->> 'street_cross', ''),
    nullif(p_address ->> 'area', ''), nullif(p_address ->> 'pincode', ''), nullif(p_address ->> 'landmark', ''),
    nullif(p_address ->> 'district', ''), nullif(p_address ->> 'state', ''),
    coalesce((p_address ->> 'address_type')::address_type, 'residential'),
    coalesce((p_address ->> 'ownership')::ownership_type, 'own'),
    true,
    nullif(p_address ->> 'lat', '')::numeric(9, 6),
    nullif(p_address ->> 'lng', '')::numeric(9, 6)
  );

  return v_customer_id;
end;
$$;

grant execute on function public.create_customer_with_details(uuid, text, text, jsonb, jsonb) to authenticated;

drop type lead_source;
