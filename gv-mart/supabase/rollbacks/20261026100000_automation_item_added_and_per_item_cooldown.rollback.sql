-- Rollback for 20261026100000_automation_item_added_and_per_item_cooldown.sql
-- Restores the 20261018120000 automation_emit and the 16-argument automation_rule_save, the Phase 2 lead trigger payload, and
-- removes the item_added trigger, the new columns, the index and the catalogue row.
-- Refuses to run if a rule on enquiry.item_added or a per-item rule exists: automation_rules rows are immutable and cannot be
-- deleted, and the event row is referenced by them. Pause such rules first (a paused version is a new immutable row); if any
-- remain, this rollback cannot proceed and the migration stays.
begin;
do $g$
begin
  if exists (select 1 from public.automation_rules where event_key = 'enquiry.item_added') then
    raise exception 'rollback refused: rules exist on enquiry.item_added (immutable rows reference the event)';
  end if;
  if exists (select 1 from public.automation_rules where is_current and cooldown_per_item and status <> 'paused') then
    raise exception 'rollback refused: a non-paused rule uses cooldown_per_item; pause it first';
  end if;
end $g$;

drop trigger if exists zz_automation_emit_lead_item on public.lead_items;
drop function if exists public._trg_automation_emit_lead_item();

-- previous lead trigger payload (Phase 2)
create or replace function public._trg_automation_emit_lead()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_payload jsonb;
begin
  begin
    v_payload := jsonb_build_object('kind', new.kind::text, 'source', new.source, 'status', new.status::text,
                                    'enquiry_type', new.enquiry_type::text, 'mobile', new.mobile,
                                    'sales_person_id', new.assigned_to);
    if tg_op = 'INSERT' then
      perform public.automation_emit(new.org_id, 'lead.created', 'lead', new.id, new.customer_id, 'created', v_payload);
      if new.kind::text = 'product' then
        perform public.automation_emit(new.org_id, 'product_enquiry.submitted', 'lead', new.id, new.customer_id, 'created', v_payload);
      elsif new.kind::text = 'spare' then
        perform public.automation_emit(new.org_id, 'spare_enquiry.submitted', 'lead', new.id, new.customer_id, 'created', v_payload);
      end if;
      return null;
    end if;

    -- the sales person is leads.assigned_to (a profile); leads.owner_id is the field technician and is not a sales person
    if new.assigned_to is distinct from old.assigned_to and new.assigned_to is not null then
      perform public.automation_emit(new.org_id, 'lead.assigned', 'lead', new.id, new.customer_id,
                                     new.assigned_to::text, v_payload);
    end if;
    if new.status is distinct from old.status then
      if new.status::text in ('contacted', 'quoted', 'won', 'lost') then
        perform public.automation_emit(new.org_id, 'lead.stage.' || new.status::text, 'lead', new.id, new.customer_id,
                                       new.status::text, v_payload);
      end if;
      if old.status::text in ('won', 'lost') and new.status::text not in ('won', 'lost') then
        perform public.automation_emit(new.org_id, 'lead.reopened', 'lead', new.id, new.customer_id,
                                       'reopened@' || new.updated_at::text, v_payload);
      end if;
    end if;
  exception when others then
    perform public._automation_log_error(new.org_id, tg_table_name || ':' || tg_op, null, 'lead', new.id, sqlstate, sqlerrm);
  end;
  return null;
end;
$$;

-- previous engine (20261018120000)
create or replace function public.automation_emit(
  p_org_id          uuid,
  p_event_key       text,
  p_subject_type    text,
  p_subject_id      uuid,
  p_customer_id     uuid default null,
  p_occurrence_key  text default '',
  p_payload         jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event_id   uuid := gen_random_uuid();
  v_payload    jsonb := coalesce(p_payload, '{}'::jsonb);
  v_occ        text := coalesce(p_occurrence_key, '');
  v_enabled    boolean;
  v_test_mode  boolean;
  v_list       text[];
  v_cap        integer;
  v_cust       uuid := p_customer_id;
  v_test       boolean := false;
  ev           public.automation_events%rowtype;
  r            record;
  v_considered integer := 0;
  v_queued     integer := 0;
  v_dups       integer := 0;
  v_mode       text;
  v_class      text;
  v_lang       text;
  v_respect    boolean;
  v_cool       integer;
  v_recips     uuid[];
  v_rec        uuid;
  v_fallback   boolean;
  v_resolved   boolean;
  v_mobile     text;
  v_masked     text;
  v_key        text;
  v_fire       timestamptz;
  v_expires    timestamptz;
  v_window_end timestamptz;
  v_count      integer;
  v_blocked    boolean;
  v_reason     text;
  v_rows       integer;
  v_outcome    text;
  v_detail     jsonb;
  v_defer_to   timestamptz;
begin
  if p_org_id is null or p_event_key is null or p_subject_type is null or p_subject_id is null then
    raise exception 'automation_emit: org, event, subject type and subject id are required';
  end if;

  select s.automation_enabled, s.wa_test_mode_enabled, s.wa_test_allowed_numbers, s.automation_non_job_daily_cap
    into v_enabled, v_test_mode, v_list, v_cap
    from public.settings s where s.org_id = p_org_id;
  v_enabled   := coalesce(v_enabled, true);
  v_test_mode := coalesce(v_test_mode, false);
  v_list      := coalesce(v_list, '{}'::text[]);
  v_cap       := coalesce(v_cap, 3);

  if v_cust is not null then
    select c.is_test into v_test from public.customers c where c.id = v_cust and c.org_id = p_org_id;
    if not found then v_cust := null; v_test := false; end if;
    v_test := coalesce(v_test, false);
  end if;
  if p_subject_type = 'lead' then
    v_test := v_test or coalesce((select l.is_test from public.leads l where l.id = p_subject_id and l.org_id = p_org_id), false);
  end if;

  select * into ev from public.automation_events e where e.event_key = p_event_key;
  if not found then
    v_outcome := 'unknown_event';
  elsif not v_enabled then
    v_outcome := 'global_off';
  else
    v_outcome := 'no_rule';
    begin v_window_end := nullif(v_payload ->> 'window_end', '')::timestamptz; exception when others then v_window_end := null; end;

    for r in
      select * from public.automation_rules
       where org_id = p_org_id and event_key = p_event_key and is_current
       order by created_at, id
    loop
      v_considered := v_considered + 1;
      v_outcome := 'processed';

      if r.status = 'paused' then
        perform public._automation_audit_row(p_org_id, v_event_id, p_event_key, p_subject_type, p_subject_id, r.id, r.rule_key, r.version,
          r.recipient_role, null, null, r.channel, r.template_name, 'skipped_paused', null, v_test, null);
        continue;
      end if;
      if not public._automation_conditions_match(r.conditions, v_payload) then
        perform public._automation_audit_row(p_org_id, v_event_id, p_event_key, p_subject_type, p_subject_id, r.id, r.rule_key, r.version,
          r.recipient_role, null, null, r.channel, r.template_name, 'skipped_condition', null, v_test, null);
        continue;
      end if;
      if r.status = 'test_only' and not v_test then
        perform public._automation_audit_row(p_org_id, v_event_id, p_event_key, p_subject_type, p_subject_id, r.id, r.rule_key, r.version,
          r.recipient_role, null, null, r.channel, r.template_name, 'skipped_test_only', null, v_test, null);
        continue;
      end if;

      -- S0a: shadow rules write shadow rows; everything else (live, test_only for a test subject) writes live-mode rows
      v_mode  := case when r.status = 'shadow' then 'shadow' else 'live' end;
      v_class := public._automation_class(r.template_name, r.message_class, ev.default_message_class);
      v_lang  := public._automation_language(p_org_id, v_cust, r.language);
      v_respect := coalesce(r.respect_quiet_hours, not ev.quiet_hours_exempt);
      v_cool  := greatest(r.dedupe_cooldown_hours, ev.min_cooldown_hours);

      -- recipients
      v_mobile := null; v_recips := array[null::uuid]; v_fallback := false; v_resolved := true;
      if r.recipient_role = 'customer' then
        -- S7: the main customer's own number only; the payload number is used only when there is no customer record at all
        if v_cust is not null then
          v_mobile := public._automation_customer_mobile(p_org_id, v_cust);
        else
          v_mobile := public._mobile_key(v_payload ->> 'mobile');
        end if;
        v_resolved := v_mobile is not null;
      elsif r.recipient_role = 'sales' then
        begin v_rec := nullif(v_payload ->> 'sales_person_id', '')::uuid; exception when others then v_rec := null; end;
        if v_rec is not null then
          v_recips := array[v_rec];
        else
          -- S1: no sales person -> every active master (in-app)
          v_recips := public._automation_active_masters(p_org_id);
          v_fallback := true;
          v_resolved := coalesce(array_length(v_recips, 1), 0) > 0;
        end if;
      elsif r.recipient_role = 'technician' then
        begin v_rec := nullif(v_payload ->> 'technician_id', '')::uuid; exception when others then v_rec := null; end;
        v_resolved := v_rec is not null;
        v_recips := array[v_rec];
      end if;
      v_masked := case when v_mobile is not null then '******' || right(v_mobile, 4) end;

      if not v_resolved then
        perform public._automation_audit_row(p_org_id, v_event_id, p_event_key, p_subject_type, p_subject_id, r.id, r.rule_key, r.version,
          r.recipient_role, v_cust, v_masked, r.channel, r.template_name, 'skipped_no_recipient', null, v_test, null);
        continue;
      end if;

      -- opt-out (customer numbers): STOP blocks non-job, STOP ALL blocks everything
      if v_mobile is not null and public._automation_is_opted_out(p_org_id, v_mobile, v_class) then
        perform public._automation_audit_row(p_org_id, v_event_id, p_event_key, p_subject_type, p_subject_id, r.id, r.rule_key, r.version,
          r.recipient_role, v_cust, v_masked, r.channel, r.template_name, 'skipped_opt_out',
          jsonb_build_object('class', v_class, 'mode', v_mode), v_test, null);
        continue;
      end if;

      -- when would this go out (S4)
      v_fire := now() + (r.delay_minutes * interval '1 minute');
      if v_respect then v_fire := public._automation_next_allowed(v_fire, p_org_id); end if;

      foreach v_rec in array v_recips loop
        v_key := r.rule_key::text || '|' || coalesce(v_cust::text, '-') || '|' || p_subject_id::text || '|' || v_occ
                 || '|' || v_mode || '|' || coalesce(v_rec::text, '-');
        v_detail := jsonb_build_object('mode', v_mode, 'class', v_class, 'language', v_lang, 'fire_at', v_fire)
                    || case when v_fallback then jsonb_build_object('recipient_fallback', 'master') else '{}'::jsonb end;

        -- S0b: replay protection inside the mode
        if exists (select 1 from public.automation_queue q where q.org_id = p_org_id and q.idempotency_key = v_key) then
          v_dups := v_dups + 1;
          perform public._automation_audit_row(p_org_id, v_event_id, p_event_key, p_subject_type, p_subject_id, r.id, r.rule_key, r.version,
            r.recipient_role, v_cust, v_masked, r.channel, r.template_name, 'skipped_duplicate', v_detail, v_test, v_key);
          continue;
        end if;

        -- S0a: counted rows are the same mode and were not blocked, deferred or dropped
        if r.max_fires is not null and (
             select count(*) from public.automation_queue q
              where q.org_id = p_org_id and q.rule_key = r.rule_key and q.subject_id = p_subject_id and q.mode = v_mode
                and q.state not in ('blocked_not_allowlisted', 'deferred', 'expired')) >= r.max_fires then
          perform public._automation_audit_row(p_org_id, v_event_id, p_event_key, p_subject_type, p_subject_id, r.id, r.rule_key, r.version,
            r.recipient_role, v_cust, v_masked, r.channel, r.template_name, 'skipped_max_fires', v_detail, v_test, v_key);
          continue;
        end if;

        -- S6: cooldown (rule value, raised to the event's floor: review requests 90 days)
        if v_cool > 0 and v_cust is not null and exists (
             select 1 from public.automation_queue q
              where q.org_id = p_org_id and q.rule_key = r.rule_key and q.customer_id = v_cust and q.mode = v_mode
                and q.state not in ('blocked_not_allowlisted', 'deferred', 'expired')
                and q.created_at > now() - (v_cool * interval '1 hour')) then
          perform public._automation_audit_row(p_org_id, v_event_id, p_event_key, p_subject_type, p_subject_id, r.id, r.rule_key, r.version,
            r.recipient_role, v_cust, v_masked, r.channel, r.template_name, 'skipped_cooldown', v_detail, v_test, v_key);
          continue;
        end if;

        -- allow-list / test isolation (as in Phase 2)
        v_blocked := false; v_reason := null;
        if v_mobile is not null then
          if v_test then
            if not (v_mobile = any (v_list))
               and not exists (select 1 from public.customers c
                                where c.org_id = p_org_id and c.is_test and public._mobile_key(c.mobile) = v_mobile) then
              v_blocked := true; v_reason := 'test_subject_destination_not_a_test_number';
            end if;
          elsif v_test_mode and not (v_mobile = any (v_list)) then
            v_blocked := true; v_reason := 'test_mode_not_allow_listed';
          end if;
        end if;

        if v_blocked then
          insert into public.automation_queue (org_id, idempotency_key, rule_id, rule_key, rule_version, event_id, event_key,
                 subject_type, subject_id, customer_id, recipient_role, recipient_masked, channel, template_name, language,
                 fire_at, state, is_test, mode, message_class, recipient_profile_id, detail)
          values (p_org_id, v_key, r.id, r.rule_key, r.version, v_event_id, p_event_key, p_subject_type, p_subject_id, v_cust,
                  r.recipient_role, v_masked, r.channel, r.template_name, v_lang, v_fire, 'blocked_not_allowlisted', v_test,
                  v_mode, v_class, v_rec, v_detail)
          on conflict (org_id, idempotency_key) do nothing;
          perform public._automation_audit_row(p_org_id, v_event_id, p_event_key, p_subject_type, p_subject_id, r.id, r.rule_key, r.version,
            r.recipient_role, v_cust, v_masked, r.channel, r.template_name, 'blocked_not_allowlisted',
            v_detail || jsonb_build_object('reason', v_reason), v_test, v_key);
          insert into public.audit_log (org_id, actor_id, action, table_name, row_id, after)
          values (p_org_id, null, 'WA_SEND_BLOCKED', 'automation_queue', p_subject_id,
                  jsonb_build_object('reason', v_reason, 'via', 'automation_emit', 'event_key', p_event_key,
                                     'template', r.template_name, 'to_last4', right(v_mobile, 4)));
          continue;
        end if;

        -- S5: daily cap for non-job messages, per customer per IST day
        if v_class = 'non_job' and v_cust is not null then
          select count(*) into v_count from public.automation_queue q
           where q.org_id = p_org_id and q.customer_id = v_cust and q.mode = v_mode and q.message_class = 'non_job'
             and q.state not in ('blocked_not_allowlisted', 'deferred', 'expired')
             and (q.fire_at at time zone 'Asia/Kolkata')::date = (v_fire at time zone 'Asia/Kolkata')::date;
          if v_count >= v_cap then
            v_defer_to := public._automation_next_allowed(
              (((v_fire at time zone 'Asia/Kolkata')::date + 1) + '00:00'::time) at time zone 'Asia/Kolkata', p_org_id);
            v_expires := least(now() + (r.max_defer_hours * interval '1 hour'), coalesce(v_window_end, 'infinity'::timestamptz));
            insert into public.automation_queue (org_id, idempotency_key, rule_id, rule_key, rule_version, event_id, event_key,
                   subject_type, subject_id, customer_id, recipient_role, recipient_masked, channel, template_name, language,
                   fire_at, state, is_test, mode, message_class, expires_at, recipient_profile_id, detail)
            values (p_org_id, v_key, r.id, r.rule_key, r.version, v_event_id, p_event_key, p_subject_type, p_subject_id, v_cust,
                    r.recipient_role, v_masked, r.channel, r.template_name, v_lang, v_defer_to,
                    case when v_expires <= v_defer_to then 'expired' else 'deferred' end, v_test,
                    v_mode, v_class, v_expires, v_rec, v_detail)
            on conflict (org_id, idempotency_key) do nothing;
            perform public._automation_audit_row(p_org_id, v_event_id, p_event_key, p_subject_type, p_subject_id, r.id, r.rule_key, r.version,
              r.recipient_role, v_cust, v_masked, r.channel, r.template_name,
              case when v_expires <= v_defer_to then 'expired_deferred' else 'deferred_daily_cap' end,
              v_detail || jsonb_build_object('cap', v_cap, 'release_at', v_defer_to, 'expires_at', v_expires), v_test, v_key);
            continue;
          end if;
        end if;

        insert into public.automation_queue (org_id, idempotency_key, rule_id, rule_key, rule_version, event_id, event_key,
               subject_type, subject_id, customer_id, recipient_role, recipient_masked, channel, template_name, language,
               fire_at, state, is_test, mode, message_class, recipient_profile_id, detail)
        values (p_org_id, v_key, r.id, r.rule_key, r.version, v_event_id, p_event_key, p_subject_type, p_subject_id, v_cust,
                r.recipient_role, v_masked, r.channel, r.template_name, v_lang, v_fire, 'dry_run', v_test,
                v_mode, v_class, v_rec, v_detail)
        on conflict (org_id, idempotency_key) do nothing;
        get diagnostics v_rows = row_count;
        if v_rows = 0 then
          v_dups := v_dups + 1;
          perform public._automation_audit_row(p_org_id, v_event_id, p_event_key, p_subject_type, p_subject_id, r.id, r.rule_key, r.version,
            r.recipient_role, v_cust, v_masked, r.channel, r.template_name, 'skipped_duplicate', v_detail, v_test, v_key);
          continue;
        end if;
        perform public._automation_audit_row(p_org_id, v_event_id, p_event_key, p_subject_type, p_subject_id, r.id, r.rule_key, r.version,
          r.recipient_role, v_cust, v_masked, r.channel, r.template_name, 'dry_run', v_detail, v_test, v_key);
        v_queued := v_queued + 1;
      end loop;
    end loop;

    if v_considered > 0 and v_dups > 0 and v_queued = 0 and v_dups >= v_considered then v_outcome := 'duplicate'; end if;
  end if;

  insert into public.automation_event_log (id, org_id, event_key, subject_type, subject_id, customer_id, is_test,
         occurrence_key, payload_keys, actor_id, rules_considered, rules_queued, outcome)
  values (v_event_id, p_org_id, p_event_key, p_subject_type, p_subject_id, v_cust, v_test,
          v_occ, coalesce((select array_agg(k order by k) from jsonb_object_keys(v_payload) k), '{}'::text[]),
          auth.uid(), v_considered, v_queued, v_outcome);

  return v_event_id;
end;
$$;
revoke all on function public.automation_emit(uuid, text, text, uuid, uuid, text, jsonb) from public, anon, authenticated;
grant execute on function public.automation_emit(uuid, text, text, uuid, uuid, text, jsonb) to service_role;

-- previous rule save (16 arguments)
drop function if exists public.automation_rule_save(uuid, text, text, text, jsonb, text, text, integer, integer, integer, text, uuid, text, text, boolean, integer, boolean);
create function public.automation_rule_save(
  p_rule_key              uuid,
  p_event_key             text,
  p_recipient_role        text,
  p_channel               text default 'whatsapp',
  p_conditions            jsonb default '{}'::jsonb,
  p_template_name         text default null,
  p_language              text default null,
  p_delay_minutes         integer default 0,
  p_dedupe_cooldown_hours integer default 0,
  p_max_fires             integer default null,
  p_status                text default 'test_only',
  p_flow_id               uuid default null,
  p_note                  text default null,
  p_message_class         text default null,
  p_respect_quiet_hours   boolean default null,
  p_max_defer_hours       integer default 72
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid := public.current_org_id();
  v_ev  public.automation_events%rowtype;
  v_old public.automation_rules%rowtype;
  v_id  uuid;
  v_ver integer := 1;
  v_key uuid := p_rule_key;
begin
  if auth.uid() is null or not coalesce(public.is_master(), false) then
    raise exception 'automation_rule_save: only the master can save rules';
  end if;
  select * into v_ev from public.automation_events where event_key = p_event_key;
  if not found then raise exception 'automation_rule_save: unknown event %', p_event_key; end if;
  if not (p_recipient_role = any (v_ev.supported_recipients)) then
    raise exception 'automation_rule_save: event % does not support recipient %', p_event_key, p_recipient_role;
  end if;
  if p_flow_id is not null and not exists (select 1 from public.automation_flow_defs f where f.id = p_flow_id and f.org_id = v_org) then
    raise exception 'automation_rule_save: flow not found';
  end if;

  if v_key is not null then
    select * into v_old from public.automation_rules where org_id = v_org and rule_key = v_key and is_current for update;
    if not found then raise exception 'automation_rule_save: rule not found'; end if;
    v_ver := v_old.version + 1;
    update public.automation_rules set is_current = false where id = v_old.id;
  else
    v_key := gen_random_uuid();
  end if;

  insert into public.automation_rules (org_id, rule_key, version, flow_id, event_key, recipient_role, channel, conditions,
         template_name, language, delay_minutes, dedupe_cooldown_hours, max_fires, status, note, message_class,
         respect_quiet_hours, max_defer_hours, created_by)
  values (v_org, v_key, v_ver, p_flow_id, p_event_key, p_recipient_role, p_channel, coalesce(p_conditions, '{}'::jsonb),
          p_template_name, p_language, coalesce(p_delay_minutes, 0), coalesce(p_dedupe_cooldown_hours, 0), p_max_fires,
          coalesce(p_status, 'test_only'), p_note, p_message_class, p_respect_quiet_hours, coalesce(p_max_defer_hours, 72), auth.uid())
  returning id into v_id;

  insert into public.automation_audit (org_id, event_key, rule_id, rule_key, rule_version, recipient_role, channel, template_name,
         decision, detail, actor_id)
  values (v_org, p_event_key, v_id, v_key, v_ver, p_recipient_role, p_channel, p_template_name, 'config_changed',
          jsonb_build_object('status', coalesce(p_status, 'test_only'), 'previous_version', case when v_ver > 1 then v_ver - 1 end),
          auth.uid());
  return v_id;
end;
$$;
revoke all on function public.automation_rule_save(uuid, text, text, text, jsonb, text, text, integer, integer, integer, text, uuid, text, text, boolean, integer) from public, anon;
grant execute on function public.automation_rule_save(uuid, text, text, text, jsonb, text, text, integer, integer, integer, text, uuid, text, text, boolean, integer) to authenticated, service_role;

drop index if exists public.automation_queue_item_cooldown_idx;
alter table public.automation_queue drop column if exists item_key;
alter table public.automation_rules drop column if exists cooldown_per_item;
delete from public.automation_events where event_key = 'enquiry.item_added';
commit;
