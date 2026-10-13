-- Rollback for 20261018120000_automation_phase3a_engine.sql  (run BEFORE the rollbacks of 20261018110000 and 20261018100000)
-- Restores the Phase 2 automation_emit and the 13-argument automation_rule_save, drops the new helpers, columns and tables.
-- Queue rows in the new 'deferred' / 'expired' states are dry-run records only (nothing was ever sent) and are deleted so the
-- Phase 2 state CHECK can be restored. Two CHECK constraints are deliberately LEFT WIDE (automation_audit.decision and
-- automation_rules.status) because append-only / immutable rows may already use the new values; the extra allowed values are
-- harmless to the Phase 2 engine.
begin;
delete from public.automation_queue where state in ('deferred', 'expired');
drop function if exists public.automation_release_deferred(timestamptz);
drop function if exists public.automation_rule_save(uuid, text, text, text, jsonb, text, text, integer, integer, integer, text, uuid, text, text, boolean, integer);

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
  v_cust       uuid := p_customer_id;
  v_test       boolean := false;
  r            record;
  v_considered integer := 0;
  v_queued     integer := 0;
  v_dups       integer := 0;
  v_mobile     text;
  v_profile    uuid;
  v_masked     text;
  v_key        text;
  v_resolved   boolean;
  v_blocked    boolean;
  v_reason     text;
  v_rows       integer;
  v_outcome    text;
begin
  if p_org_id is null or p_event_key is null or p_subject_type is null or p_subject_id is null then
    raise exception 'automation_emit: org, event, subject type and subject id are required';
  end if;

  select s.automation_enabled, s.wa_test_mode_enabled, s.wa_test_allowed_numbers
    into v_enabled, v_test_mode, v_list
    from public.settings s where s.org_id = p_org_id;
  v_enabled   := coalesce(v_enabled, true);
  v_test_mode := coalesce(v_test_mode, false);
  v_list      := coalesce(v_list, '{}'::text[]);

  -- customer must belong to the organisation; test flag comes from the customer or from the lead itself
  if v_cust is not null then
    select c.is_test into v_test from public.customers c where c.id = v_cust and c.org_id = p_org_id;
    if not found then v_cust := null; v_test := false; end if;
    v_test := coalesce(v_test, false);
  end if;
  if p_subject_type = 'lead' then
    v_test := v_test or coalesce((select l.is_test from public.leads l where l.id = p_subject_id and l.org_id = p_org_id), false);
  end if;

  if not exists (select 1 from public.automation_events e where e.event_key = p_event_key) then
    v_outcome := 'unknown_event';
  elsif not v_enabled then
    v_outcome := 'global_off';
  else
    v_outcome := 'no_rule';
    for r in
      select * from public.automation_rules
       where org_id = p_org_id and event_key = p_event_key and is_current
       order by created_at, id
    loop
      v_considered := v_considered + 1;
      v_outcome := 'processed';
      v_mobile := null; v_profile := null; v_masked := null; v_resolved := true;

      if r.status = 'paused' then
        insert into public.automation_audit (org_id, event_id, event_key, subject_type, subject_id, rule_id, rule_key, rule_version,
               recipient_role, channel, template_name, decision, is_test)
        values (p_org_id, v_event_id, p_event_key, p_subject_type, p_subject_id, r.id, r.rule_key, r.version,
                r.recipient_role, r.channel, r.template_name, 'skipped_paused', v_test);
        continue;
      end if;

      if not public._automation_conditions_match(r.conditions, v_payload) then
        insert into public.automation_audit (org_id, event_id, event_key, subject_type, subject_id, rule_id, rule_key, rule_version,
               recipient_role, channel, template_name, decision, is_test)
        values (p_org_id, v_event_id, p_event_key, p_subject_type, p_subject_id, r.id, r.rule_key, r.version,
                r.recipient_role, r.channel, r.template_name, 'skipped_condition', v_test);
        continue;
      end if;

      if r.status = 'test_only' and not v_test then
        insert into public.automation_audit (org_id, event_id, event_key, subject_type, subject_id, rule_id, rule_key, rule_version,
               recipient_role, channel, template_name, decision, is_test)
        values (p_org_id, v_event_id, p_event_key, p_subject_type, p_subject_id, r.id, r.rule_key, r.version,
                r.recipient_role, r.channel, r.template_name, 'skipped_test_only', v_test);
        continue;
      end if;

      -- recipient: customer -> the customer's own number (or the lead's); staff roles are resolved to a profile id only
      if r.recipient_role = 'customer' then
        select public._mobile_key(c.mobile) into v_mobile from public.customers c where c.id = v_cust;
        v_mobile := coalesce(v_mobile, public._mobile_key(v_payload ->> 'mobile'));
        v_resolved := v_mobile is not null;
      elsif r.recipient_role = 'sales' then
        begin v_profile := nullif(v_payload ->> 'sales_person_id', '')::uuid; exception when others then v_profile := null; end;
        v_resolved := v_profile is not null;
      elsif r.recipient_role = 'technician' then
        begin v_profile := nullif(v_payload ->> 'technician_id', '')::uuid; exception when others then v_profile := null; end;
        v_resolved := v_profile is not null;
      end if;
      if v_mobile is not null then v_masked := '******' || right(v_mobile, 4); end if;

      if not v_resolved then
        insert into public.automation_audit (org_id, event_id, event_key, subject_type, subject_id, rule_id, rule_key, rule_version,
               recipient_role, recipient_customer_id, channel, template_name, decision, is_test)
        values (p_org_id, v_event_id, p_event_key, p_subject_type, p_subject_id, r.id, r.rule_key, r.version,
                r.recipient_role, v_cust, r.channel, r.template_name, 'skipped_no_recipient', v_test);
        continue;
      end if;

      v_key := r.rule_key::text || '|' || coalesce(v_cust::text, '-') || '|' || p_subject_id::text || '|' || v_occ;

      if exists (select 1 from public.automation_queue q where q.org_id = p_org_id and q.idempotency_key = v_key) then
        v_dups := v_dups + 1;
        insert into public.automation_audit (org_id, event_id, event_key, subject_type, subject_id, rule_id, rule_key, rule_version,
               recipient_role, recipient_customer_id, recipient_masked, channel, template_name, decision, is_test, idempotency_key)
        values (p_org_id, v_event_id, p_event_key, p_subject_type, p_subject_id, r.id, r.rule_key, r.version,
                r.recipient_role, v_cust, v_masked, r.channel, r.template_name, 'skipped_duplicate', v_test, v_key);
        continue;
      end if;

      if r.max_fires is not null and (
           select count(*) from public.automation_queue q
            where q.org_id = p_org_id and q.rule_key = r.rule_key and q.subject_id = p_subject_id) >= r.max_fires then
        insert into public.automation_audit (org_id, event_id, event_key, subject_type, subject_id, rule_id, rule_key, rule_version,
               recipient_role, recipient_customer_id, recipient_masked, channel, template_name, decision, is_test, idempotency_key)
        values (p_org_id, v_event_id, p_event_key, p_subject_type, p_subject_id, r.id, r.rule_key, r.version,
                r.recipient_role, v_cust, v_masked, r.channel, r.template_name, 'skipped_max_fires', v_test, v_key);
        continue;
      end if;

      if r.dedupe_cooldown_hours > 0 and v_cust is not null and exists (
           select 1 from public.automation_queue q
            where q.org_id = p_org_id and q.rule_key = r.rule_key and q.customer_id = v_cust
              and q.created_at > now() - (r.dedupe_cooldown_hours * interval '1 hour')) then
        insert into public.automation_audit (org_id, event_id, event_key, subject_type, subject_id, rule_id, rule_key, rule_version,
               recipient_role, recipient_customer_id, recipient_masked, channel, template_name, decision, is_test, idempotency_key)
        values (p_org_id, v_event_id, p_event_key, p_subject_type, p_subject_id, r.id, r.rule_key, r.version,
                r.recipient_role, v_cust, v_masked, r.channel, r.template_name, 'skipped_cooldown', v_test, v_key);
        continue;
      end if;

      -- allow-list / test isolation (only meaningful when a destination number is known)
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

      insert into public.automation_queue (org_id, idempotency_key, rule_id, rule_key, rule_version, event_id, event_key,
             subject_type, subject_id, customer_id, recipient_role, recipient_masked, channel, template_name, language,
             fire_at, state, is_test)
      values (p_org_id, v_key, r.id, r.rule_key, r.version, v_event_id, p_event_key,
              p_subject_type, p_subject_id, v_cust, r.recipient_role, v_masked, r.channel, r.template_name, r.language,
              now() + (r.delay_minutes * interval '1 minute'),
              case when v_blocked then 'blocked_not_allowlisted' else 'dry_run' end, v_test)
      on conflict (org_id, idempotency_key) do nothing;
      get diagnostics v_rows = row_count;

      if v_rows = 0 then
        v_dups := v_dups + 1;
        insert into public.automation_audit (org_id, event_id, event_key, subject_type, subject_id, rule_id, rule_key, rule_version,
               recipient_role, recipient_customer_id, recipient_masked, channel, template_name, decision, is_test, idempotency_key)
        values (p_org_id, v_event_id, p_event_key, p_subject_type, p_subject_id, r.id, r.rule_key, r.version,
                r.recipient_role, v_cust, v_masked, r.channel, r.template_name, 'skipped_duplicate', v_test, v_key);
        continue;
      end if;

      insert into public.automation_audit (org_id, event_id, event_key, subject_type, subject_id, rule_id, rule_key, rule_version,
             recipient_role, recipient_customer_id, recipient_masked, channel, template_name, decision, detail, is_test, idempotency_key)
      values (p_org_id, v_event_id, p_event_key, p_subject_type, p_subject_id, r.id, r.rule_key, r.version,
              r.recipient_role, v_cust, v_masked, r.channel, r.template_name,
              case when v_blocked then 'blocked_not_allowlisted' else 'dry_run' end,
              case when v_blocked then jsonb_build_object('reason', v_reason) else '{}'::jsonb end,
              v_test, v_key);

      if v_blocked then
        -- same trail the F-08 gate leaves for a blocked real send (last four digits only)
        insert into public.audit_log (org_id, actor_id, action, table_name, row_id, after)
        values (p_org_id, null, 'WA_SEND_BLOCKED', 'automation_queue', p_subject_id,
                jsonb_build_object('reason', v_reason, 'via', 'automation_emit', 'event_key', p_event_key,
                                   'template', r.template_name, 'to_last4', right(v_mobile, 4)));
      else
        v_queued := v_queued + 1;
      end if;
    end loop;

    if v_considered > 0 and v_dups = v_considered then v_outcome := 'duplicate'; end if;
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
  p_note                  text default null
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
         template_name, language, delay_minutes, dedupe_cooldown_hours, max_fires, status, note, created_by)
  values (v_org, v_key, v_ver, p_flow_id, p_event_key, p_recipient_role, p_channel, coalesce(p_conditions, '{}'::jsonb),
          p_template_name, p_language, coalesce(p_delay_minutes, 0), coalesce(p_dedupe_cooldown_hours, 0), p_max_fires,
          coalesce(p_status, 'test_only'), p_note, auth.uid())
  returning id into v_id;

  insert into public.automation_audit (org_id, event_key, rule_id, rule_key, rule_version, recipient_role, channel, template_name,
         decision, detail, actor_id)
  values (v_org, p_event_key, v_id, v_key, v_ver, p_recipient_role, p_channel, p_template_name, 'config_changed',
          jsonb_build_object('status', coalesce(p_status, 'test_only'), 'previous_version', case when v_ver > 1 then v_ver - 1 end),
          auth.uid());
  return v_id;
end;
$$;

revoke all on function public.automation_rule_save(uuid, text, text, text, jsonb, text, text, integer, integer, integer, text, uuid, text) from public, anon;
grant execute on function public.automation_rule_save(uuid, text, text, text, jsonb, text, text, integer, integer, integer, text, uuid, text) to authenticated, service_role;

drop function if exists public._automation_audit_row(uuid, uuid, text, text, uuid, uuid, uuid, integer, text, uuid, text, text, text, text, jsonb, boolean, text);
drop function if exists public._automation_active_masters(uuid);
drop function if exists public._automation_language(uuid, uuid, text);
drop function if exists public._automation_customer_mobile(uuid, uuid);
drop function if exists public._automation_class(text, text, text);
drop function if exists public._automation_next_allowed(timestamptz, uuid);
drop index if exists public.automation_queue_deferred_idx;
alter table public.automation_queue drop constraint if exists automation_queue_state_check;
alter table public.automation_queue add constraint automation_queue_state_check check (state in ('dry_run', 'blocked_not_allowlisted'));
alter table public.automation_queue drop column if exists mode, drop column if exists message_class, drop column if exists expires_at,
  drop column if exists recipient_profile_id, drop column if exists detail;
alter table public.automation_rules drop column if exists message_class, drop column if exists respect_quiet_hours, drop column if exists max_defer_hours;
drop table if exists public.automation_template_classes;
alter table public.automation_events drop column if exists default_message_class, drop column if exists quiet_hours_exempt, drop column if exists min_cooldown_hours;
alter table public.settings drop constraint if exists settings_automation_cap_check;
alter table public.settings drop column if exists automation_quiet_start, drop column if exists automation_quiet_end, drop column if exists automation_non_job_daily_cap;
commit;
