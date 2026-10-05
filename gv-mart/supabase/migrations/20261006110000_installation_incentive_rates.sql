-- Salary/Incentive system, Phase 3 (Part E): per-unit installation incentive
-- rates. ADDITIVE to the existing flat-threshold 'installation' incentive rule
-- (compute_incentives still evaluates incentive_rules exactly as before; a
-- master who wants only per-unit pay sets that rule's amount to ₹0).
--
-- Every rate ships empty: no rows are seeded, and flat_amount defaults to 0.
-- Nothing pays until the master adds rows and presses Compute.

-- ── 1. Rates table ─────────────────────────────────────────────────────────
create table public.installation_incentive_rates (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  -- Match keys. NULL = "any". At least one of product_id / category is
  -- required so a rate can never silently match every product.
  product_id uuid references public.products (id) on delete cascade,
  category public.brand_category,
  -- Matched (case-insensitive, trimmed) against the product's custom
  -- attribute whose product_attribute_keys.key_name is 'capacity' /
  -- 'configuration'. If that attribute key doesn't exist or the product has
  -- no value, a rate that names a capacity/configuration simply doesn't match
  -- (never over-pays by guessing).
  capacity text,
  configuration text,
  flat_amount numeric(12, 2) not null default 0 check (flat_amount >= 0),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (product_id is not null or category is not null)
);

create index installation_incentive_rates_org_id_idx on public.installation_incentive_rates (org_id);

alter table public.installation_incentive_rates enable row level security;

create policy installation_incentive_rates_master on public.installation_incentive_rates for all
  using (org_id = public.current_org_id() and public.is_master())
  with check (org_id = public.current_org_id() and public.is_master());

create trigger set_updated_at before update on public.installation_incentive_rates
  for each row execute function public.set_updated_at();

create trigger audit_installation_incentive_rates after insert or update or delete on public.installation_incentive_rates
  for each row execute function public.audit_master_change();

-- ── 2. incentives_earned: allow a row to come from a rate instead of a rule ──
alter table public.incentives_earned alter column rule_id drop not null;

alter table public.incentives_earned
  add column installation_rate_id uuid references public.installation_incentive_rates (id) on delete restrict;

alter table public.incentives_earned
  add constraint incentives_earned_one_source check ((rule_id is not null) <> (installation_rate_id is not null));

create unique index incentives_earned_rate_unique_idx
  on public.incentives_earned (technician_id, installation_rate_id, period)
  where installation_rate_id is not null;

-- ── 3. Best-matching rate for an installed product ─────────────────────────
-- Most specific active rate wins (product > capacity/configuration > category);
-- ties break on oldest row. One rate per installed line — rates never stack.
create or replace function public.installation_rate_for(p_org_id uuid, p_product_id uuid)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select r.id
  from public.installation_incentive_rates r
  join public.products p on p.id = p_product_id and p.org_id = p_org_id
  where r.org_id = p_org_id
    and r.is_active
    and (r.product_id is null or r.product_id = p.id)
    and (r.category is null or r.category = p.category)
    and (r.capacity is null or exists (
      select 1 from public.product_attribute_keys k
      where k.org_id = p_org_id and lower(k.key_name) = 'capacity'
        and lower(btrim(p.custom_attributes ->> k.id::text)) = lower(btrim(r.capacity))
    ))
    and (r.configuration is null or exists (
      select 1 from public.product_attribute_keys k
      where k.org_id = p_org_id and lower(k.key_name) = 'configuration'
        and lower(btrim(p.custom_attributes ->> k.id::text)) = lower(btrim(r.configuration))
    ))
  order by
    (r.product_id is not null)::int * 8
      + (r.capacity is not null)::int * 2
      + (r.configuration is not null)::int * 2
      + (r.category is not null)::int desc,
    r.created_at,
    r.id
  limit 1;
$$;

-- security definer helper called only from compute_incentives; never callable by clients.
revoke execute on function public.installation_rate_for(uuid, uuid) from public, anon, authenticated;

-- ── 4. compute_incentives: verbatim current body (20260925121000) + a per-unit
-- block after the rule loop. Per-unit rows are keyed (technician, rate, period)
-- and REFRESHED on re-compute (an install logged after the first compute is
-- picked up), unlike threshold rules which are one-shot per period. Zero
-- amounts never produce a row. ────────────────────────────────────────────
create or replace function public.compute_incentives(
  p_org_id uuid,
  p_period date
)
returns setof incentives_earned
language plpgsql
security definer
set search_path = public
as $$
declare
  v_period date := date_trunc('month', p_period)::date;
  v_rule record;
  v_tech record;
  v_rate record;
  v_metric numeric(12, 2);
  v_review_count integer;
  v_amount numeric(12, 2);
  v_existing_id uuid;
begin
  if not public.is_master() then
    raise exception 'compute_incentives: master role required';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'compute_incentives: org mismatch';
  end if;

  for v_rule in select * from public.incentive_rules where org_id = p_org_id loop
    for v_tech in select id from public.technicians where org_id = p_org_id and is_active loop
      if exists (
        select 1 from public.incentives_earned
        where org_id = p_org_id and technician_id = v_tech.id and rule_id = v_rule.id and period = v_period
      ) then
        continue;
      end if;

      if v_rule.type = 'service_income' then
        v_metric := public.technician_attributed_revenue(p_org_id, v_tech.id, v_period);
        if v_metric >= v_rule.threshold and v_rule.threshold > 0 then
          insert into public.incentives_earned (org_id, technician_id, rule_id, amount, period)
          values (p_org_id, v_tech.id, v_rule.id, v_rule.amount, v_period);
        end if;

      elsif v_rule.type = 'sales_income' then
        v_metric := public.technician_attributed_sales(p_org_id, v_tech.id, v_period);
        if v_metric >= v_rule.threshold and v_rule.threshold > 0 then
          insert into public.incentives_earned (org_id, technician_id, rule_id, amount, period)
          values (p_org_id, v_tech.id, v_rule.id, v_rule.amount, v_period);
        end if;

      elsif v_rule.type = 'review' then
        select count(*) into v_review_count
        from public.ratings r
        join public.service_visits v on v.id = r.visit_id
        where v.org_id = p_org_id
          and v.technician_id = v_tech.id
          and r.google_review_clicked = true
          and r.created_at >= date_trunc('month', v_period)
          and r.created_at < date_trunc('month', v_period) + interval '1 month';

        if v_review_count >= v_rule.threshold and v_rule.threshold > 0 then
          insert into public.incentives_earned (org_id, technician_id, rule_id, amount, period)
          values (p_org_id, v_tech.id, v_rule.id, v_rule.amount, v_period);
        end if;

      elsif v_rule.type = 'finder_credit' then
        v_metric := public.technician_finder_conversions(p_org_id, v_tech.id, v_period);
        if v_metric >= v_rule.threshold and v_rule.threshold > 0 then
          insert into public.incentives_earned (org_id, technician_id, rule_id, amount, period)
          values (p_org_id, v_tech.id, v_rule.id, v_rule.amount, v_period);
        end if;

      elsif v_rule.type = 'installation' then
        v_metric := public.technician_installation_count(p_org_id, v_tech.id, v_period);
        if v_metric >= v_rule.threshold and v_rule.threshold > 0 then
          insert into public.incentives_earned (org_id, technician_id, rule_id, amount, period)
          values (p_org_id, v_tech.id, v_rule.id, v_rule.amount, v_period);
        end if;
      end if;
    end loop;
  end loop;

  -- Per-unit installation rates (additive to the flat-threshold rule above).
  for v_tech in select id from public.technicians where org_id = p_org_id and is_active loop
    for v_rate in
      select m.rate_id, sum(m.qty)::int as qty, ra.flat_amount
      from (
        select il.qty, public.installation_rate_for(p_org_id, il.product_id) as rate_id
        from public.installations_logged il
        where il.org_id = p_org_id
          and il.technician_id = v_tech.id
          and il.created_at >= date_trunc('month', v_period)
          and il.created_at < date_trunc('month', v_period) + interval '1 month'
      ) m
      join public.installation_incentive_rates ra on ra.id = m.rate_id
      group by m.rate_id, ra.flat_amount
    loop
      v_amount := v_rate.qty * v_rate.flat_amount;
      if v_amount <= 0 then
        continue;
      end if;
      select id into v_existing_id from public.incentives_earned
        where technician_id = v_tech.id and installation_rate_id = v_rate.rate_id and period = v_period;
      if v_existing_id is null then
        insert into public.incentives_earned (org_id, technician_id, installation_rate_id, amount, period)
        values (p_org_id, v_tech.id, v_rate.rate_id, v_amount, v_period);
      else
        update public.incentives_earned set amount = v_amount where id = v_existing_id and amount is distinct from v_amount;
      end if;
    end loop;
  end loop;

  return query
    select * from public.incentives_earned
    where org_id = p_org_id and period = v_period
    order by technician_id;
end;
$$;

grant execute on function public.compute_incentives(uuid, date) to authenticated;
