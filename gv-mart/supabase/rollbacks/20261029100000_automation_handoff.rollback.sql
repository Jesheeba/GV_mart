-- Rollback for 20261029100000_automation_handoff.sql (run AFTER the rollbacks of 20261029120000 and 20261029110000).
-- NOTE (rebased onto items 1 and 2): the emit restored below is the item 1 + item 2 body (20261026100000 / 20261026110000),
-- not the 20261018120000 one, so rolling this migration back does not also undo the per-item cooldown or the no-customer refusal.
-- Restores the Stage A engine and release function, drops the hand-off function, the whitelist table and the queue columns
-- (outbox_id, handed_over_at, context). Queue rows already 'handed_over' keep their state (history; their outbox rows are
-- untouched). The two widened CHECK constraints (queue state, audit decision) are deliberately LEFT WIDE because
-- append-only audit rows and handed-over queue rows may already use the new values.
begin;
drop function if exists public.automation_handoff_due(timestamptz, integer, integer);
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
  v_item       text;
  v_nocust     boolean;
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
    -- the item the event is about (lead events: product id or spare id); null when the event has no item
    v_item := nullif(btrim(v_payload ->> 'item_key'), '');

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
      v_mobile := null; v_recips := array[null::uuid]; v_fallback := false; v_resolved := true; v_nocust := false;
      if r.recipient_role = 'customer' then
        -- S7: the main customer's own number only. No customer record (none given, or not found in this org) means no
        -- recipient: the number typed into the payload is never used for a customer rule.
        if v_cust is null then
          v_nocust := true;
          v_resolved := false;
        else
          v_mobile := public._automation_customer_mobile(p_org_id, v_cust);
          v_resolved := v_mobile is not null;
        end if;
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
          r.recipient_role, v_cust, v_masked, r.channel, r.template_name, 'skipped_no_recipient',
          case when v_nocust then jsonb_build_object('reason', 'no_customer_record') end, v_test, null);
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
                    || case when v_fallback then jsonb_build_object('recipient_fallback', 'master') else '{}'::jsonb end
                    || case when v_item is not null then jsonb_build_object('item_key', v_item) else '{}'::jsonb end;

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

        -- S6: cooldown (rule value, raised to the event's floor: review requests 90 days).
        -- A per-item rule (cooldown_per_item) counts only rows for the same item, and also rows of any other rule that sends
        -- the same template (so "Enquiry created" and "Item added" share one at-most-once-per-item window). With no item on
        -- the event it falls back to the whole-customer cooldown of this rule, never weaker than before.
        if v_cool > 0 and v_cust is not null and exists (
             select 1 from public.automation_queue q
              where q.org_id = p_org_id
                and (q.rule_key = r.rule_key
                     or (r.cooldown_per_item and v_item is not null and r.template_name is not null
                         and regexp_replace(q.template_name, '_(en|ta)$', '') = regexp_replace(r.template_name, '_(en|ta)$', '')))
                and q.customer_id = v_cust and q.mode = v_mode
                and q.state not in ('blocked_not_allowlisted', 'deferred', 'expired')
                and q.created_at > now() - (v_cool * interval '1 hour')
                and (not r.cooldown_per_item or v_item is null or q.item_key = v_item)) then
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
                 fire_at, state, is_test, mode, message_class, recipient_profile_id, detail, item_key)
          values (p_org_id, v_key, r.id, r.rule_key, r.version, v_event_id, p_event_key, p_subject_type, p_subject_id, v_cust,
                  r.recipient_role, v_masked, r.channel, r.template_name, v_lang, v_fire, 'blocked_not_allowlisted', v_test,
                  v_mode, v_class, v_rec, v_detail, v_item)
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
                   fire_at, state, is_test, mode, message_class, expires_at, recipient_profile_id, detail, item_key)
            values (p_org_id, v_key, r.id, r.rule_key, r.version, v_event_id, p_event_key, p_subject_type, p_subject_id, v_cust,
                    r.recipient_role, v_masked, r.channel, r.template_name, v_lang, v_defer_to,
                    case when v_expires <= v_defer_to then 'expired' else 'deferred' end, v_test,
                    v_mode, v_class, v_expires, v_rec, v_detail, v_item)
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
               fire_at, state, is_test, mode, message_class, recipient_profile_id, detail, item_key)
        values (p_org_id, v_key, r.id, r.rule_key, r.version, v_event_id, p_event_key, p_subject_type, p_subject_id, v_cust,
                r.recipient_role, v_masked, r.channel, r.template_name, v_lang, v_fire, 'dry_run', v_test,
                v_mode, v_class, v_rec, v_detail, v_item)
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

create or replace function public.automation_release_deferred(p_now timestamptz default now())
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  q          record;
  v_cap      integer;
  v_count    integer;
  v_released integer := 0;
  v_expired  integer := 0;
  v_kept     integer := 0;
  v_fire     timestamptz;
begin
  for q in
    select * from public.automation_queue
     where state = 'deferred' and fire_at <= p_now
     order by fire_at, created_at
     for update skip locked
  loop
    if q.expires_at is not null and q.expires_at <= p_now then
      update public.automation_queue set state = 'expired' where id = q.id;
      perform public._automation_audit_row(q.org_id, q.event_id, q.event_key, q.subject_type, q.subject_id, q.rule_id, q.rule_key,
        q.rule_version, q.recipient_role, q.customer_id, q.recipient_masked, q.channel, q.template_name, 'expired_deferred',
        jsonb_build_object('expired_at', p_now), q.is_test, q.idempotency_key);
      v_expired := v_expired + 1;
      continue;
    end if;

    select coalesce(s.automation_non_job_daily_cap, 3) into v_cap from public.settings s where s.org_id = q.org_id;
    v_cap := coalesce(v_cap, 3);
    v_fire := greatest(p_now, q.fire_at);
    select count(*) into v_count from public.automation_queue o
     where o.org_id = q.org_id and o.customer_id = q.customer_id and o.mode = q.mode and o.message_class = 'non_job'
       and o.id <> q.id and o.state not in ('blocked_not_allowlisted', 'deferred', 'expired')
       and (o.fire_at at time zone 'Asia/Kolkata')::date = (v_fire at time zone 'Asia/Kolkata')::date;
    if v_count >= v_cap then
      update public.automation_queue
         set fire_at = public._automation_next_allowed(
               (((v_fire at time zone 'Asia/Kolkata')::date + 1) + '00:00'::time) at time zone 'Asia/Kolkata', q.org_id)
       where id = q.id;
      v_kept := v_kept + 1;
    else
      update public.automation_queue set state = 'dry_run', fire_at = v_fire where id = q.id;
      perform public._automation_audit_row(q.org_id, q.event_id, q.event_key, q.subject_type, q.subject_id, q.rule_id, q.rule_key,
        q.rule_version, q.recipient_role, q.customer_id, q.recipient_masked, q.channel, q.template_name, 'released_deferred',
        jsonb_build_object('released_at', p_now, 'fire_at', v_fire), q.is_test, q.idempotency_key);
      v_released := v_released + 1;
    end if;
  end loop;
  return jsonb_build_object('released', v_released, 'expired', v_expired, 'still_deferred', v_kept);
end;
$$;

revoke all on function public.automation_release_deferred(timestamptz) from public, anon, authenticated;
grant execute on function public.automation_release_deferred(timestamptz) to service_role;

drop index if exists public.automation_queue_handoff_idx;
alter table public.automation_queue drop column if exists outbox_id, drop column if exists handed_over_at, drop column if exists context;
drop table if exists public.automation_handoff_ref_types;
commit;
