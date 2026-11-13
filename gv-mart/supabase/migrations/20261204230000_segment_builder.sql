-- Segment Builder (advanced/secondary automation). See build-docs/features/segment-builder.md.
--
-- DEVIATION FROM SPEC, flagged here: the spec said standing mode should reuse `automation_rules`/
-- `automation_queue`. Read those tables first (20261017100000_automation_phase2_foundation.sql) —
-- automation_queue.state has a CHECK constraint allowing ONLY ('dry_run','blocked_not_allowlisted'):
-- it is structurally incapable of ever representing a real queued/sent row, not just "currently
-- configured" to dry-run. automation_rules also ties a rule to one fixed event_key from a closed
-- automation_events catalog, not an arbitrary cross-table condition tree. Forcing this feature into
-- that table would mean altering a CHECK constraint that exists specifically to make a real send
-- impossible from that path — out of scope and risky to touch here. Instead, standing mode reuses
-- the EXISTING whatsapp_outbox + whatsapp_event_templates + wa-milestone-dispatch machinery (the
-- same one the basic lifecycle automation already uses): each segment gets its own synthetic
-- event_key ('segment.<id>'), so the existing cron dispatcher delivers it with zero new send code.

-- ── opt-out (flagged as an open question in build-docs/MEMORY.md; resolved here) ───────────────
alter table public.customers
  add column if not exists marketing_opt_out boolean not null default false;

-- ── core tables ──────────────────────────────────────────────────────────────────────────────
create table public.audience_segments (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  name text not null,
  condition_tree jsonb not null,
  wasi_template_name text,                       -- set when a template is chosen (send-now or standing)
  is_standing boolean not null default false,
  dedupe_days integer not null default 7 check (dedupe_days >= 0),
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (org_id, name)
);
create index audience_segments_org_id_idx on public.audience_segments (org_id);
create index audience_segments_standing_idx on public.audience_segments (org_id) where is_standing;

create table public.audience_segment_runs (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  segment_id uuid not null references public.audience_segments (id) on delete cascade,
  wasi_template_name text not null,
  mode text not null check (mode in ('manual', 'standing')),
  matched_count integer not null default 0,
  queued_count integer not null default 0,
  skipped_opted_out_count integer not null default 0,
  skipped_recent_count integer not null default 0,
  fired_at timestamptz not null default now(),
  created_by uuid references public.profiles (id) on delete set null
);
create index audience_segment_runs_segment_idx on public.audience_segment_runs (segment_id, fired_at desc);

create table public.audience_segment_recipients (
  id uuid primary key default gen_random_uuid(),
  run_id uuid not null references public.audience_segment_runs (id) on delete cascade,
  segment_id uuid not null references public.audience_segments (id) on delete cascade,
  customer_id uuid not null references public.customers (id) on delete cascade,
  outbox_id uuid references public.whatsapp_outbox (id) on delete set null,
  status text not null check (status in ('queued', 'skipped_opted_out', 'skipped_recent_dup', 'skipped_missing_param')),
  created_at timestamptz not null default now()
);
create index audience_segment_recipients_run_idx on public.audience_segment_recipients (run_id);
-- dedupe lookback: "has this customer already been sent (any status='queued') for this segment in the last N days".
create index audience_segment_recipients_dedupe_idx on public.audience_segment_recipients (segment_id, customer_id, created_at desc) where status = 'queued';

alter table public.audience_segments enable row level security;
alter table public.audience_segment_runs enable row level security;
alter table public.audience_segment_recipients enable row level security;

-- Master-only throughout, per owner decision ("Master/admin only (Recommended)") — this app's role
-- vocabulary has no separate "admin" role; is_master() is the equivalent gate used elsewhere
-- (20261015110000_current_role_active_gate.sql).
create policy audience_segments_master_all on public.audience_segments
  for all using (org_id = public.current_org_id() and public.is_master())
  with check (org_id = public.current_org_id() and public.is_master());
create policy audience_segment_runs_master_select on public.audience_segment_runs
  for select using (org_id = public.current_org_id() and public.is_master());
create policy audience_segment_recipients_master_select on public.audience_segment_recipients
  for select using (public.is_master() and exists (
    select 1 from public.audience_segments s where s.id = audience_segment_recipients.segment_id and s.org_id = public.current_org_id()
  ));

revoke all on public.audience_segments from anon;
revoke all on public.audience_segment_runs from anon;
revoke all on public.audience_segment_recipients from anon;

-- ── condition-tree evaluation (static SQL per branch, never dynamic/concatenated — no injection
-- surface: p_field/p_operator only ever select a hardcoded branch, p_value is bound as a normal
-- query parameter in every branch, never interpolated into SQL text) ──────────────────────────
create or replace function public._segment_leaf_match(p_customer_id uuid, p_org_id uuid, p_field text, p_operator text, p_value jsonb)
returns boolean
language plpgsql stable security definer set search_path to 'public'
as $$
declare
  v_text text := case when jsonb_typeof(p_value) = 'string' then p_value #>> '{}' else null end;
  v_bool boolean := case when jsonb_typeof(p_value) = 'boolean' then (p_value #>> '{}')::boolean else null end;
  v_list text[] := case when jsonb_typeof(p_value) = 'array' then (select array_agg(x) from jsonb_array_elements_text(p_value) x) else null end;
begin
  if p_field = 'customer.city' then
    if p_operator = 'in' then
      return exists (select 1 from public.addresses a where a.customer_id = p_customer_id and a.area = any (v_list));
    end if;
    return exists (select 1 from public.addresses a where a.customer_id = p_customer_id and a.area ilike v_text);

  elsif p_field = 'customer.tag' then
    return v_text = any (select unnest(c.tags) from public.customers c where c.id = p_customer_id);

  elsif p_field = 'lead.status' then
    return exists (select 1 from public.leads l where l.customer_id = p_customer_id and l.status::text = v_text);

  elsif p_field = 'product.brand' then
    return exists (
      select 1 from public.invoices i
      join public.invoice_items ii on ii.invoice_id = i.id and ii.item_type = 'product'
      join public.products p on p.id = ii.item_id
      join public.brands b on b.id = p.brand_id
      where i.customer_id = p_customer_id and b.name ilike v_text
    );

  elsif p_field = 'product.category' then
    return exists (
      select 1 from public.invoices i
      join public.invoice_items ii on ii.invoice_id = i.id and ii.item_type = 'product'
      join public.products p on p.id = ii.item_id
      where i.customer_id = p_customer_id and p.category::text = v_text
    );

  elsif p_field = 'product.name' then
    return exists (
      select 1 from public.invoices i
      join public.invoice_items ii on ii.invoice_id = i.id and ii.item_type = 'product'
      join public.products p on p.id = ii.item_id
      where i.customer_id = p_customer_id and p.name ilike v_text
    );

  elsif p_field = 'amc.active' then
    if coalesce(v_bool, true) then
      return exists (select 1 from public.amc_contracts ac where ac.customer_id = p_customer_id and ac.status = 'active');
    end if;
    return not exists (select 1 from public.amc_contracts ac where ac.customer_id = p_customer_id and ac.status = 'active');

  elsif p_field = 'warranty.active' then
    if coalesce(v_bool, true) then
      return exists (select 1 from public.warranties w where w.customer_id = p_customer_id and w.expiry_date >= current_date);
    end if;
    return not exists (select 1 from public.warranties w where w.customer_id = p_customer_id and w.expiry_date >= current_date);

  else
    raise exception 'audience segment: unknown field %', p_field;
  end if;
end;
$$;

create or replace function public._segment_tree_match(p_customer_id uuid, p_org_id uuid, p_tree jsonb)
returns boolean
language plpgsql stable security definer set search_path to 'public'
as $$
declare
  v_op text := p_tree ->> 'op';
  v_cond jsonb;
  v_result boolean;
  v_any_true boolean := false;
  v_all_true boolean := true;
begin
  if p_tree ? 'field' then
    return public._segment_leaf_match(p_customer_id, p_org_id, p_tree ->> 'field', coalesce(p_tree ->> 'operator', '='), p_tree -> 'value');
  end if;

  if v_op not in ('and', 'or') then
    raise exception 'audience segment: unknown op %', v_op;
  end if;

  for v_cond in select * from jsonb_array_elements(coalesce(p_tree -> 'conditions', '[]'::jsonb))
  loop
    v_result := public._segment_tree_match(p_customer_id, p_org_id, v_cond);
    v_any_true := v_any_true or v_result;
    v_all_true := v_all_true and v_result;
    if v_op = 'or' and v_any_true then
      return true; -- short-circuit
    end if;
  end loop;

  return case when v_op = 'and' then v_all_true else v_any_true end;
end;
$$;

-- Excludes is_test customers (20261016110000_test_customer_flag.sql) -- required by
-- src/lib/testCustomerGuard.test.ts for every *_count function, and correct on its own merits: a
-- demo/test customer must never inflate a real campaign's audience count or receive a live send.
create or replace function public.audience_segment_match_count(p_org_id uuid, p_condition_tree jsonb)
returns integer
language sql stable security definer set search_path to 'public'
as $$
  select count(*)::integer from public.customers c
  where c.org_id = p_org_id and not c.is_test and public._segment_tree_match(c.id, p_org_id, p_condition_tree);
$$;

create or replace function public.audience_segment_match_preview(p_org_id uuid, p_condition_tree jsonb, p_limit integer default 5)
returns table (customer_id uuid, name text, mobile text)
language sql stable security definer set search_path to 'public'
as $$
  select c.id, c.name, c.mobile from public.customers c
  where c.org_id = p_org_id and not c.is_test and public._segment_tree_match(c.id, p_org_id, p_condition_tree)
  order by c.created_at desc
  limit p_limit;
$$;

-- ── send-now: resolves matches, applies opt-out + dedupe, queues via the existing outbox path ──
create or replace function public.audience_segment_send_now(p_segment_id uuid)
returns uuid  -- the new run's id
language plpgsql security definer set search_path to 'public'
as $$
declare
  v_seg record;
  v_run_id uuid;
  v_customer record;
  v_outbox_id uuid;
  v_matched int := 0;
  v_queued int := 0;
  v_opted_out int := 0;
  v_recent int := 0;
  v_event_key text;
begin
  if not public.is_master() then
    raise exception 'audience_segment_send_now: master role required';
  end if;

  select * into v_seg from public.audience_segments where id = p_segment_id and org_id = public.current_org_id();
  if v_seg is null then
    raise exception 'audience_segment_send_now: segment not found';
  end if;
  if v_seg.wasi_template_name is null then
    raise exception 'audience_segment_send_now: no template chosen for this segment';
  end if;

  v_event_key := 'segment.' || v_seg.id::text;
  -- Keep the synthetic event mapping current — findApprovedMapping (_shared/whatsapp.ts) reads this.
  insert into public.whatsapp_event_templates (org_id, event_key, language, wasi_template_name, param_map, is_active)
  values (v_seg.org_id, v_event_key, 'en', v_seg.wasi_template_name, '{"customer_name":"customer_name","product_name":"product_name"}'::jsonb, true)
  on conflict (org_id, event_key, language) do update set wasi_template_name = excluded.wasi_template_name, is_active = true;

  insert into public.audience_segment_runs (org_id, segment_id, wasi_template_name, mode, fired_at, created_by)
  values (v_seg.org_id, v_seg.id, v_seg.wasi_template_name, 'manual', now(), auth.uid())
  returning id into v_run_id;

  for v_customer in
    select c.id, c.mobile from public.customers c
    where c.org_id = v_seg.org_id and not c.is_test and public._segment_tree_match(c.id, v_seg.org_id, v_seg.condition_tree)
  loop
    v_matched := v_matched + 1;

    if exists (select 1 from public.customers c2 where c2.id = v_customer.id and c2.marketing_opt_out) then
      v_opted_out := v_opted_out + 1;
      insert into public.audience_segment_recipients (run_id, segment_id, customer_id, status) values (v_run_id, v_seg.id, v_customer.id, 'skipped_opted_out');
      continue;
    end if;

    if exists (
      select 1 from public.audience_segment_recipients r
      where r.segment_id = v_seg.id and r.customer_id = v_customer.id and r.status = 'queued'
        and r.created_at > now() - make_interval(days => v_seg.dedupe_days)
    ) then
      v_recent := v_recent + 1;
      insert into public.audience_segment_recipients (run_id, segment_id, customer_id, status) values (v_run_id, v_seg.id, v_customer.id, 'skipped_recent_dup');
      continue;
    end if;

    v_queued := v_queued + 1;
    insert into public.whatsapp_outbox (org_id, direction, to_mobile, customer_id, milestone, template, payload, ref_type, ref_id, status)
    values (v_seg.org_id, 'outbound', v_customer.mobile, v_customer.id, 'segment_send', v_event_key,
            jsonb_build_object('segment_id', v_seg.id, 'run_id', v_run_id), 'audience_segment_match', v_seg.id, 'pending')
    returning id into v_outbox_id;

    insert into public.audience_segment_recipients (run_id, segment_id, customer_id, outbox_id, status)
    values (v_run_id, v_seg.id, v_customer.id, v_outbox_id, 'queued');
  end loop;

  update public.audience_segment_runs
  set matched_count = v_matched, queued_count = v_queued, skipped_opted_out_count = v_opted_out, skipped_recent_count = v_recent
  where id = v_run_id;

  return v_run_id;
end;
$$;

revoke all on function public.audience_segment_send_now(uuid) from public;
grant execute on function public.audience_segment_send_now(uuid) to authenticated;

create or replace function public.audience_segment_set_standing(p_segment_id uuid, p_is_standing boolean, p_wasi_template_name text default null)
returns void
language plpgsql security definer set search_path to 'public'
as $$
declare
  v_org uuid;
begin
  if not public.is_master() then
    raise exception 'audience_segment_set_standing: master role required';
  end if;
  select org_id into v_org from public.audience_segments where id = p_segment_id and org_id = public.current_org_id();
  if v_org is null then
    raise exception 'audience_segment_set_standing: segment not found';
  end if;
  if p_is_standing and p_wasi_template_name is null then
    raise exception 'audience_segment_set_standing: a template must be chosen before enabling standing mode';
  end if;

  update public.audience_segments
  set is_standing = p_is_standing, wasi_template_name = coalesce(p_wasi_template_name, wasi_template_name), updated_at = now()
  where id = p_segment_id;

  if p_is_standing then
    insert into public.whatsapp_event_templates (org_id, event_key, language, wasi_template_name, param_map, is_active)
    values (v_org, 'segment.' || p_segment_id::text, 'en', coalesce(p_wasi_template_name, (select wasi_template_name from public.audience_segments where id = p_segment_id)),
            '{"customer_name":"customer_name","product_name":"product_name"}'::jsonb, true)
    on conflict (org_id, event_key, language) do update set wasi_template_name = excluded.wasi_template_name, is_active = true;
  end if;
end;
$$;

revoke all on function public.audience_segment_set_standing(uuid, boolean, text) from public;
grant execute on function public.audience_segment_set_standing(uuid, boolean, text) to authenticated;

-- ── standing mode: fire once per new matching purchase, not a full re-scan ──────────────────────
create or replace function public._segment_standing_check_invoice_item()
returns trigger
language plpgsql security definer set search_path to 'public'
as $$
declare
  v_invoice record;
  v_seg record;
  v_run_id uuid;
  v_outbox_id uuid;
  v_already boolean;
begin
  select i.org_id, i.customer_id into v_invoice from public.invoices i where i.id = new.invoice_id;
  if v_invoice.customer_id is null or exists (select 1 from public.customers c where c.id = v_invoice.customer_id and c.is_test) then
    return new;
  end if;

  for v_seg in select * from public.audience_segments where org_id = v_invoice.org_id and is_standing and wasi_template_name is not null
  loop
    begin
      if not public._segment_tree_match(v_invoice.customer_id, v_invoice.org_id, v_seg.condition_tree) then
        continue;
      end if;

      select exists (
        select 1 from public.audience_segment_recipients r
        where r.segment_id = v_seg.id and r.customer_id = v_invoice.customer_id and r.status = 'queued'
          and r.created_at > now() - make_interval(days => v_seg.dedupe_days)
      ) into v_already;
      if v_already then
        continue;
      end if;

      insert into public.audience_segment_runs (org_id, segment_id, wasi_template_name, mode, fired_at, matched_count, queued_count)
      values (v_invoice.org_id, v_seg.id, v_seg.wasi_template_name, 'standing', now(), 1, 1)
      returning id into v_run_id;

      insert into public.whatsapp_outbox (org_id, direction, to_mobile, customer_id, milestone, template, payload, ref_type, ref_id, status)
      select v_invoice.org_id, 'outbound', c.mobile, c.id, 'segment_standing', 'segment.' || v_seg.id::text,
             jsonb_build_object('segment_id', v_seg.id, 'run_id', v_run_id, 'invoice_item_id', new.id), 'audience_segment_match', v_seg.id, 'pending'
      from public.customers c where c.id = v_invoice.customer_id
      returning id into v_outbox_id;

      insert into public.audience_segment_recipients (run_id, segment_id, customer_id, outbox_id, status)
      values (v_run_id, v_seg.id, v_invoice.customer_id, v_outbox_id, 'queued');
    exception when others then
      -- A standing-segment evaluation failure must never block the sale itself.
      raise warning 'segment standing check failed for segment % : %', v_seg.id, sqlerrm;
    end;
  end loop;

  return new;
end;
$$;

drop trigger if exists invoice_items_segment_standing_check on public.invoice_items;
create trigger invoice_items_segment_standing_check
  after insert on public.invoice_items
  for each row execute function public._segment_standing_check_invoice_item();
