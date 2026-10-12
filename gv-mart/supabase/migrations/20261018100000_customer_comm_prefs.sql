-- Automation Phase 3 / Stage A, part 1 (S3): the opt-out record for WhatsApp STOP / STOP ALL / START.
--
--   STOP      -> opt_out_non_job = true : feedback, review, renewal reminders and promotions stop; job updates and
--                                         invoices continue
--   STOP ALL  -> opt_out_all = true     : nothing is sent
--   START     -> both cleared (resubscribe)
--
-- Keyed by the 10-digit number (a STOP can arrive from a number that is a lead, not yet a customer). Written only by
-- wa_record_opt_out() (service role: the webhook) or set_customer_comm_pref() (staff). Every change is also written to an
-- append-only history with the last four digits only. Nothing here sends anything.

create table public.customer_comm_prefs (
  org_id          uuid not null references public.organizations(id) on delete cascade,
  mobile_key      text not null check (mobile_key ~ '^[0-9]{10}$'),
  customer_id     uuid references public.customers(id) on delete set null,
  opt_out_non_job boolean not null default false,
  opt_out_all     boolean not null default false,
  source          text not null default 'whatsapp' check (source in ('whatsapp', 'staff', 'app')),
  updated_at      timestamptz not null default now(),
  primary key (org_id, mobile_key)
);
create index customer_comm_prefs_customer_idx on public.customer_comm_prefs (customer_id) where customer_id is not null;

create table public.customer_comm_pref_events (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references public.organizations(id) on delete cascade,
  occurred_at  timestamptz not null default now(),
  mobile_last4 text not null,
  action       text not null check (action in ('stop', 'stop_all', 'start', 'staff_set')),
  source       text not null,
  actor_id     uuid
);
create index customer_comm_pref_events_org_time on public.customer_comm_pref_events (org_id, occurred_at desc);

-- same append-only door as the other automation logs (owner-only purge flag)
create trigger customer_comm_pref_events_append_only before update or delete on public.customer_comm_pref_events
  for each row execute function public._trg_automation_append_only();
create trigger customer_comm_pref_events_no_truncate before truncate on public.customer_comm_pref_events
  for each statement execute function public._trg_automation_append_only();

alter table public.customer_comm_prefs enable row level security;
alter table public.customer_comm_pref_events enable row level security;
revoke all on public.customer_comm_prefs, public.customer_comm_pref_events from public, anon, authenticated;
grant select on public.customer_comm_prefs, public.customer_comm_pref_events to authenticated, service_role;
create policy customer_comm_prefs_select on public.customer_comm_prefs for select to authenticated
  using (org_id = public.current_org_id() and public.is_ops_staff());
create policy customer_comm_pref_events_select on public.customer_comm_pref_events for select to authenticated
  using (org_id = public.current_org_id() and public.is_ops_staff());

-- the webhook's door (service role only)
create function public.wa_record_opt_out(p_org uuid, p_mobile text, p_action text, p_source text default 'whatsapp')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_key  text := public._mobile_key(p_mobile);
  v_cust uuid;
  v_non  boolean;
  v_all  boolean;
begin
  if p_action not in ('stop', 'stop_all', 'start') then
    raise exception 'wa_record_opt_out: unknown action %', p_action;
  end if;
  if v_key is null or v_key !~ '^[0-9]{10}$' then
    raise exception 'wa_record_opt_out: a 10-digit mobile is required';
  end if;
  if not exists (select 1 from public.organizations o where o.id = p_org) then
    raise exception 'wa_record_opt_out: organisation not found';
  end if;

  select c.id into v_cust from public.customers c where c.org_id = p_org and public._mobile_key(c.mobile) = v_key limit 1;

  v_non := p_action in ('stop', 'stop_all');
  v_all := p_action = 'stop_all';

  insert into public.customer_comm_prefs as p (org_id, mobile_key, customer_id, opt_out_non_job, opt_out_all, source, updated_at)
  values (p_org, v_key, v_cust, v_non, v_all, case when p_source in ('whatsapp', 'staff', 'app') then p_source else 'whatsapp' end, now())
  on conflict (org_id, mobile_key) do update
    set opt_out_non_job = case p_action when 'start' then false else true end,
        -- STOP never clears an earlier STOP ALL; only START does
        opt_out_all     = case p_action when 'start' then false when 'stop_all' then true else p.opt_out_all end,
        customer_id     = coalesce(excluded.customer_id, p.customer_id),
        source          = excluded.source,
        updated_at      = now();

  insert into public.customer_comm_pref_events (org_id, mobile_last4, action, source)
  values (p_org, right(v_key, 4), p_action, p_source);

  select opt_out_non_job, opt_out_all into v_non, v_all from public.customer_comm_prefs where org_id = p_org and mobile_key = v_key;
  return jsonb_build_object('action', p_action, 'opt_out_non_job', v_non, 'opt_out_all', v_all);
end;
$$;
revoke all on function public.wa_record_opt_out(uuid, text, text, text) from public, anon, authenticated;
grant execute on function public.wa_record_opt_out(uuid, text, text, text) to service_role;

-- staff way to record or clear an opt-out (ops staff of the same organisation)
create function public.set_customer_comm_pref(p_customer_id uuid, p_opt_out_non_job boolean, p_opt_out_all boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid := public.current_org_id();
  v_key text;
begin
  if auth.uid() is null or not coalesce(public.is_ops_staff(), false) then
    raise exception 'set_customer_comm_pref: only master or operations staff can change this';
  end if;
  select public._mobile_key(c.mobile) into v_key from public.customers c where c.id = p_customer_id and c.org_id = v_org;
  if v_key is null then
    raise exception 'set_customer_comm_pref: customer not found or has no mobile';
  end if;
  insert into public.customer_comm_prefs as p (org_id, mobile_key, customer_id, opt_out_non_job, opt_out_all, source, updated_at)
  values (v_org, v_key, p_customer_id, coalesce(p_opt_out_non_job, false) or coalesce(p_opt_out_all, false), coalesce(p_opt_out_all, false), 'staff', now())
  on conflict (org_id, mobile_key) do update
    set opt_out_non_job = excluded.opt_out_non_job, opt_out_all = excluded.opt_out_all,
        customer_id = excluded.customer_id, source = 'staff', updated_at = now();
  insert into public.customer_comm_pref_events (org_id, mobile_last4, action, source, actor_id)
  values (v_org, right(v_key, 4), 'staff_set', 'staff', auth.uid());
end;
$$;
revoke all on function public.set_customer_comm_pref(uuid, boolean, boolean) from public, anon;
grant execute on function public.set_customer_comm_pref(uuid, boolean, boolean) to authenticated, service_role;

-- engine helper: is this number opted out for this message class ('job' or 'non_job')?
-- job messages respect only STOP ALL; non-job messages respect STOP and STOP ALL.
create function public._automation_is_opted_out(p_org uuid, p_mobile text, p_class text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((
    select case when p_class = 'job' then p.opt_out_all else (p.opt_out_non_job or p.opt_out_all) end
      from public.customer_comm_prefs p
     where p.org_id = p_org and p.mobile_key = public._mobile_key(p_mobile)), false)
$$;
revoke all on function public._automation_is_opted_out(uuid, text, text) from public, anon, authenticated;
grant execute on function public._automation_is_opted_out(uuid, text, text) to service_role;
