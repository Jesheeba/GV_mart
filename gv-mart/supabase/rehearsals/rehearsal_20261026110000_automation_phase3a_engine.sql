-- REHEARSAL (NOT RUN; for the owner's approval of this exact text): item 2 stack: automation_phase3a_engine
-- One request, one DO block. It: (1) refuses to run before 18:00 IST (the clock is read from clock_timestamp()), (2) recomputes
-- the sha256 of every embedded file and refuses on any mismatch with the pinned value, (3) executes the migration text(s) and then the
-- test file in order, (4) always ends in an unconditional RAISE EXCEPTION, so nothing is ever committed.
-- No top-level begin / commit / savepoint / rollback. No schema_migrations row is written. Never concatenated with test code outside
-- this wrapper. Expected error text starts with RESULTS (or TIMING); anything else is a failure and also rolls back.
-- Pinned (sha256 of the LF blob at the commit this wrapper was generated from):
--   b7380711bd3c2e00f6565edbb707ad5324a5f9de54b1790585cdd7708083ca2b  gv-mart/supabase/migrations/20261026100000_automation_item_added_and_per_item_cooldown.sql
--   36fb993672ca65aa0a5b77ff3a892e3d04d38ab7b88aa580bc5653b5622772e9  gv-mart/supabase/migrations/20261026110000_automation_emit_requires_customer_record.sql
--   b21ac0aa6ebcfc4f50041d751fd19ff010a2041244bf4177c489c137aad8e154  gv-mart/supabase/tests/automation_phase3a_engine.test.sql

do $rehearsal$
declare
  v_ist time := (clock_timestamp() at time zone 'Asia/Kolkata')::time;
  v_text text;
  v_hash text;
begin
  if v_ist < time '18:00' then
    raise exception 'REHEARSAL_REFUSED: the clock reads % IST, before 18:00 IST', to_char(v_ist, 'HH24:MI:SS');
  end if;

  v_text := $rh0$-- Automation: enquiry.item_added event and the per-item cooldown (design: docs/automations-flows-design.md sections 8.1 and 10 item A;
-- queue item 1 of docs/backlog-product-gaps.md). STILL DRY RUN ONLY: nothing here sends a message, adds a queue state or touches
-- whatsapp_outbox, the dispatcher flag or any template. No rule is created (rules are created by the master).
--
--   1. automation_queue.item_key (text, nullable) and an index for the cooldown lookup.
--   2. automation_rules.cooldown_per_item (boolean, default false), so every existing rule behaves exactly as before.
--   3. automation_emit(): reads payload.item_key; with cooldown_per_item the cooldown counts only rows for the same item
--      (customer, mode and counted states unchanged), and also counts rows of ANY rule that sends the same template (language
--      suffix ignored), so "Enquiry created" and "Item added" share one at-most-once-per-item window. With no item on the event
--      it falls back to the whole-customer cooldown of the rule. item_key is stored at all three queue insert sites and is also
--      written into the audit detail. Everything else in the function is the live 20261018120000 text, unchanged.
--   4. automation_rule_save(): new last parameter p_cooldown_per_item (default false). The 16-argument version is dropped and
--      recreated with the same grants in the same transaction, as 20261018120000 did.
--   5. _trg_automation_emit_lead(): the payload gains product_id, spare_id, has_item and item_key (= product id, else spare id).
--   6. New event enquiry.item_added (recipients customer, sales) emitted by a new AFTER INSERT trigger on lead_items when:
--        - the item belongs to a lead that existed before this transaction (an enquiry merged into an open lead; a lead created
--          in the same transaction is lead.created, not item_added),
--        - the insert is not by a staff user (a staff member editing a lead's items is not a customer enquiry),
--        - it is the FIRST item of that lead in this transaction (design decision 3, first item only; a transaction-local flag).
--      Occurrence key is item:<lead_item id>, so a replay of the same item is a duplicate. Payload: kind (derived from the item),
--      source, status, enquiry_type, mobile, sales_person_id, product_id, spare_id, has_item, item_key, qty.
--      The trigger swallows its own errors into automation_errors, like the other emit triggers.
-- Not changed here (belongs to the video resolver, queue item 3): the skipped_no_video state and its exclusion from the counted lists.
-- Rollback: supabase/rollbacks/20261026100000_automation_item_added_and_per_item_cooldown.rollback.sql

-- 1 + 2: columns, index, catalogue entry
alter table public.automation_queue add column item_key text;
create index automation_queue_item_cooldown_idx
  on public.automation_queue (org_id, customer_id, item_key, created_at) where item_key is not null;
alter table public.automation_rules add column cooldown_per_item boolean not null default false;

insert into public.automation_events (event_key, group_key, label_en, subject_type, supported_recipients, is_scheduled, has_emitter)
values ('enquiry.item_added', 'leads', 'Item added to an open enquiry', 'lead', '{customer,sales}', false, true);

-- 3: the engine
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

-- 4: rule save with the new knob (replaces the 16-argument version; same leading arguments, the new one defaults)
drop function public.automation_rule_save(uuid, text, text, text, jsonb, text, text, integer, integer, integer, text, uuid, text, text, boolean, integer);
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
  p_max_defer_hours       integer default 72,
  p_cooldown_per_item     boolean default false
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
         respect_quiet_hours, max_defer_hours, cooldown_per_item, created_by)
  values (v_org, v_key, v_ver, p_flow_id, p_event_key, p_recipient_role, p_channel, coalesce(p_conditions, '{}'::jsonb),
          p_template_name, p_language, coalesce(p_delay_minutes, 0), coalesce(p_dedupe_cooldown_hours, 0), p_max_fires,
          coalesce(p_status, 'test_only'), p_note, p_message_class, p_respect_quiet_hours, coalesce(p_max_defer_hours, 72),
          coalesce(p_cooldown_per_item, false), auth.uid())
  returning id into v_id;

  insert into public.automation_audit (org_id, event_key, rule_id, rule_key, rule_version, recipient_role, channel, template_name,
         decision, detail, actor_id)
  values (v_org, p_event_key, v_id, v_key, v_ver, p_recipient_role, p_channel, p_template_name, 'config_changed',
          jsonb_build_object('status', coalesce(p_status, 'test_only'), 'previous_version', case when v_ver > 1 then v_ver - 1 end),
          auth.uid());
  return v_id;
end;
$$;
revoke all on function public.automation_rule_save(uuid, text, text, text, jsonb, text, text, integer, integer, integer, text, uuid, text, text, boolean, integer, boolean) from public, anon;
grant execute on function public.automation_rule_save(uuid, text, text, text, jsonb, text, text, integer, integer, integer, text, uuid, text, text, boolean, integer, boolean) to authenticated, service_role;

-- 5: lead trigger payload
create or replace function public._trg_automation_emit_lead()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_payload jsonb;
begin
  begin
    v_payload := jsonb_build_object('kind', new.kind::text, 'source', new.source, 'status', new.status::text,
                                    'enquiry_type', new.enquiry_type::text, 'mobile', new.mobile,
                                    'sales_person_id', new.assigned_to,
                                    'product_id', new.product_id, 'spare_id', new.spare_id,
                                    'has_item', (new.product_id is not null or new.spare_id is not null),
                                    'item_key', coalesce(new.product_id, new.spare_id)::text);
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

-- 6: enquiry.item_added emitter
create function public._trg_automation_emit_lead_item()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  l      record;
  v_flag text;
begin
  begin
    if new.product_id is null and new.spare_id is null then
      return null;
    end if;
    -- a staff member editing a lead's items is not a customer enquiry
    if coalesce(public.is_staff(), false) then
      return null;
    end if;
    select ld.customer_id, ld.source, ld.status::text as status, ld.enquiry_type::text as enquiry_type, ld.mobile,
           ld.assigned_to, ld.created_at
      into l
      from public.leads ld where ld.id = new.lead_id and ld.org_id = new.org_id;
    if not found then
      return null;
    end if;
    -- only an item added to a lead that already existed before this transaction (a merged enquiry)
    if l.created_at >= transaction_timestamp() then
      return null;
    end if;
    -- first item of this lead in this transaction only (design decision 3)
    v_flag := 'gv.item_added.' || new.lead_id::text;
    if current_setting(v_flag, true) = '1' then
      return null;
    end if;
    perform set_config(v_flag, '1', true);

    perform public.automation_emit(new.org_id, 'enquiry.item_added', 'lead', new.lead_id, l.customer_id,
      'item:' || new.id::text,
      jsonb_build_object('kind', case when new.product_id is not null then 'product' else 'spare' end,
                         'source', l.source, 'status', l.status, 'enquiry_type', l.enquiry_type, 'mobile', l.mobile,
                         'sales_person_id', l.assigned_to,
                         'product_id', new.product_id, 'spare_id', new.spare_id, 'has_item', true,
                         'item_key', coalesce(new.product_id, new.spare_id)::text, 'qty', new.qty));
  exception when others then
    perform public._automation_log_error(new.org_id, tg_table_name || ':' || tg_op, null, 'lead', new.lead_id, sqlstate, sqlerrm);
  end;
  return null;
end;
$$;
revoke all on function public._trg_automation_emit_lead_item() from public, anon, authenticated;
create trigger zz_automation_emit_lead_item after insert on public.lead_items
  for each row execute function public._trg_automation_emit_lead_item();
$rh0$;
  v_hash := encode(sha256(convert_to(v_text, 'UTF8')), 'hex');
  if v_hash <> 'b7380711bd3c2e00f6565edbb707ad5324a5f9de54b1790585cdd7708083ca2b' then
    raise exception 'REHEARSAL_REFUSED: hash mismatch for 20261026100000_automation_item_added_and_per_item_cooldown.sql: %', v_hash;
  end if;
  execute v_text;

  v_text := $rh1$-- Automation: emit refuses a customer rule that has no customer record (design: docs/automations-flows-design.md section 8.3,
-- decision C; queue item 2 of docs/backlog-product-gaps.md). STILL DRY RUN ONLY: nothing here sends a message.
--
-- Before: for a customer-recipient rule with no customer record the engine fell back to the number typed into the event payload
-- (S7 fallback), queued the row and audited it dry_run, so a shadow period overstated reach; the hand-off already refused it.
-- After: for EVERY rule with recipient_role = 'customer', if the event has no customer record (no customer id, or the customer
-- is not found in the organisation) no queue row is written and the audit row is skipped_no_recipient with
-- detail {"reason": "no_customer_record"}. The payload number is never read for a customer rule. A customer that exists but has
-- no mobile still ends as skipped_no_recipient with no detail, as before. skipped_no_recipient is already an allowed audit value,
-- so there is no CHECK change. Other recipient roles (sales, technician, master...) are untouched.
-- This is a deliberate behaviour change for every customer rule: the Phase 2 and Phase 3A tests must be re-run through the
-- approved rehearsal wrapper (see supabase/rehearsals/). One Phase 2 test probe used the payload number and is rewritten.
-- The function body is 20261026100000_automation_item_added_and_per_item_cooldown verbatim apart from this refusal.
-- Depends on: 20261026100000_automation_item_added_and_per_item_cooldown.sql (applied before this one).
-- Rollback: supabase/rollbacks/20261026110000_automation_emit_requires_customer_record.rollback.sql

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
$rh1$;
  v_hash := encode(sha256(convert_to(v_text, 'UTF8')), 'hex');
  if v_hash <> '36fb993672ca65aa0a5b77ff3a892e3d04d38ab7b88aa580bc5653b5622772e9' then
    raise exception 'REHEARSAL_REFUSED: hash mismatch for 20261026110000_automation_emit_requires_customer_record.sql: %', v_hash;
  end if;
  execute v_text;

  v_text := $rh2$-- Rolled-back DB tests for Automation Phase 3 / Stage A:
--   20261018100000_customer_comm_prefs, 20261018110000_customer_preferred_language, 20261018120000_automation_phase3a_engine.
-- Run AFTER the three migrations (the runner concatenates them in front, inside ONE transaction; the Phase 2 migration is
-- already live). Ends in RAISE; read RESULTS in the error. Throwaway __TEST_ organisations only; nothing is sent (there is no
-- sender); no real customer, number or message is touched.
create temp table res (n serial, line text);
grant all on res to public;
grant usage on sequence res_n_seq to public;
create function pg_temp.chk(p_name text, p_ok boolean, p_info text default '') returns void language plpgsql as $f$
begin insert into pg_temp.res(line) values (case when coalesce(p_ok,false) then 'PASS  ' else 'FAIL  ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end); end $f$;
create function pg_temp.mkuser(p_role text, p_org uuid, p_lang text default 'en', p_active boolean default true) returns uuid language plpgsql as $f$
declare v uuid := gen_random_uuid();
begin
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
  values (v, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '__t_' || p_role || '_' || v || '@test.invalid', 'x', now(), now(), now(), '{}', '{}');
  insert into public.profiles (id, org_id, full_name, role, is_active, language) values (v, p_org, '__TEST_ ' || p_role, p_role::public.user_role, p_active, p_lang)
    on conflict (id) do update set role = excluded.role, is_active = excluded.is_active, org_id = excluded.org_id, language = excluded.language;
  return v;
end $f$;
create function pg_temp.as_user(p_uid uuid) returns void language plpgsql as $f$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true); execute 'set local role authenticated'; end $f$;
create function pg_temp.as_anon() returns void language plpgsql as $f$
begin perform set_config('request.jwt.claims', '', true); execute 'set local role anon'; end $f$;
create function pg_temp.as_pg() returns void language plpgsql as $f$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $f$;
create function pg_temp.raises(p_sql text) returns text language plpgsql as $f$
begin execute p_sql; return null;
exception when others then return sqlerrm; end $f$;

do $t$
declare
  v_org uuid; v_org2 uuid; v_m1 uuid; v_m2 uuid; v_m_off uuid; v_ops uuid; v_sales uuid; v_cr uuid; v_login_ta uuid;
  v_c1 uuid; v_c5 uuid; v_c6 uuid; v_c2 uuid; v_c_ta uuid; v_c_login uuid; v_c_plain uuid; v_ct uuid;
  v_mob1 text := '9400000061'; v_member text := '9400000062'; v_mob2 text := '9400000063'; v_mobta text := '9400000064';
  v_rfeed uuid; v_rjob uuid; v_rinv uuid; v_rrev uuid; v_rshadow uuid; v_rsales uuid; v_rexempt uuid; v_rexempt2 uuid; v_rkey uuid;
  v_ev uuid; v_ev2 uuid; s text; n int; n2 int; rec record; v_fire timestamptz; v_ob1 int; v_ob2 int; v_t uuid;
  v_start time; v_end time; v_local time; v_q uuid; v_cnt int; v_lead uuid; v_res jsonb;
begin
  -- ---------- schema / privileges ----------
  perform pg_temp.chk('new tables exist with RLS',
    (select count(*) from pg_class c where c.relnamespace = 'public'::regnamespace and c.relrowsecurity
       and c.relname in ('customer_comm_prefs','customer_comm_pref_events','automation_template_classes')) = 3);
  perform pg_temp.chk('wa_record_opt_out / release / helpers: not executable by anon or authenticated',
    not has_function_privilege('anon', 'public.wa_record_opt_out(uuid,text,text,text)', 'execute')
    and not has_function_privilege('authenticated', 'public.wa_record_opt_out(uuid,text,text,text)', 'execute')
    and has_function_privilege('service_role', 'public.wa_record_opt_out(uuid,text,text,text)', 'execute')
    and not has_function_privilege('authenticated', 'public.automation_release_deferred(timestamptz)', 'execute')
    and not has_function_privilege('anon', 'public.automation_release_deferred(timestamptz)', 'execute')
    and not has_function_privilege('authenticated', 'public._automation_next_allowed(timestamptz,uuid)', 'execute')
    and not has_function_privilege('authenticated', 'public._automation_is_opted_out(uuid,text,text)', 'execute')
    and not has_function_privilege('authenticated', 'public._automation_audit_row(uuid,uuid,text,text,uuid,uuid,uuid,integer,text,uuid,text,text,text,text,jsonb,boolean,text)', 'execute')
    and has_function_privilege('authenticated', 'public.set_customer_comm_pref(uuid,boolean,boolean)', 'execute')
    and not has_function_privilege('anon', 'public.set_customer_comm_pref(uuid,boolean,boolean)', 'execute'));
  perform pg_temp.chk('no PUBLIC grant on any new function',
    not exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                where p.pronamespace = 'public'::regnamespace and a.grantee = 0
                  and (p.proname like '\_automation\_%' or p.proname in ('wa_record_opt_out','set_customer_comm_pref','automation_release_deferred','automation_emit'))));
  perform pg_temp.chk('no client write privilege on the new tables; anon cannot read them',
    not exists (select 1 from unnest(array['customer_comm_prefs','customer_comm_pref_events','automation_template_classes']) t,
                     unnest(array['anon','authenticated']) r, unnest(array['INSERT','UPDATE','DELETE','TRUNCATE']) pr
                where has_table_privilege(r, 'public.' || t, pr))
    and not exists (select 1 from unnest(array['customer_comm_prefs','customer_comm_pref_events','automation_template_classes']) t
                where has_table_privilege('anon', 'public.' || t, 'SELECT')));
  perform pg_temp.chk('catalogue: exempt events and the review floor',
    (select quiet_hours_exempt from public.automation_events where event_key = 'technician.on_the_way')
    and (select quiet_hours_exempt from public.automation_events where event_key = 'otp.issued')
    and not (select quiet_hours_exempt from public.automation_events where event_key = 'ticket.created')
    and (select min_cooldown_hours from public.automation_events where event_key = 'review.google_requested') = 2160);
  perform pg_temp.chk('settings defaults: quiet 21:00-08:00, cap 3',
    (select column_default from information_schema.columns where table_name = 'settings' and column_name = 'automation_non_job_daily_cap') = '3'
    and (select column_default from information_schema.columns where table_name = 'settings' and column_name = 'automation_quiet_start') like '%21:00%'
    and (select column_default from information_schema.columns where table_name = 'settings' and column_name = 'automation_quiet_end') like '%08:00%');
  perform pg_temp.chk('classification seed is exactly the owner list: 8 job, 3 non-job',
    (select count(*) from public.automation_template_classes where message_class = 'job') = 8
    and (select count(*) from public.automation_template_classes where message_class = 'non_job') = 3
    and not exists (select 1 from public.automation_template_classes where template_base in ('invoice_document', 'gvm_service_cancelled', 'gvm_payment_due'))
    and (select array_agg(template_base order by template_base) from public.automation_template_classes where message_class = 'job')
        = array['gvm_amc_visit_scheduled','gvm_amc_welcome','gvm_invoice_issued','gvm_service_booked','gvm_service_completed','gvm_technician_arrived','gvm_technician_assigned','gvm_technician_on_the_way']
    and (select array_agg(template_base order by template_base) from public.automation_template_classes where message_class = 'non_job')
        = array['gvm_amc_expiring','gvm_feedback_request','gvm_google_review']);
  perform pg_temp.chk('classification resolution: language suffix ignored, unclassified = non_job, rule override wins',
    public._automation_class('gvm_service_booked_ta', null, 'non_job') = 'job'
    and public._automation_class('gvm_invoice_issued_en', null, null) = 'job'
    and public._automation_class('gvm_feedback_request_en', null, 'job') = 'non_job'
    and public._automation_class('invoice_document', null, 'non_job') = 'non_job'
    and public._automation_class('gvm_amc_renewed_en', null, null) = 'non_job'
    and public._automation_class(null, null, null) = 'non_job'
    and public._automation_class('gvm_service_booked_en', 'non_job', null) = 'non_job'
    and public._automation_class('whatever_en', 'job', null) = 'job'
    and not exists (select 1 from public.automation_events where default_message_class <> 'non_job'));
  perform pg_temp.chk('S2 backfill: no real customer with a login language is left without preferred_language',
    not exists (select 1 from public.customers c join public.profiles p on p.id = c.primary_profile_id
                 where p.language in ('en','ta') and c.preferred_language is null
                   and c.org_id not in (select id from organizations where name like '\_\_TEST\_%')));

  -- ---------- fixtures ----------
  insert into organizations (name) values ('__TEST_automation_3a') returning id into v_org;
  insert into organizations (name) values ('__TEST_automation_3a_nomaster') returning id into v_org2;
  insert into settings (org_id) values (v_org) on conflict (org_id) do nothing;
  insert into settings (org_id) values (v_org2) on conflict (org_id) do nothing;
  v_m1 := pg_temp.mkuser('master', v_org);
  v_m2 := pg_temp.mkuser('master', v_org);
  v_m_off := pg_temp.mkuser('master', v_org, 'en', false);
  v_ops := pg_temp.mkuser('operation_admin', v_org);
  v_sales := pg_temp.mkuser('sales_admin', v_org);
  v_cr := pg_temp.mkuser('customer', v_org);
  v_login_ta := pg_temp.mkuser('customer', v_org, 'ta');
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ main', v_mob1) returning id into v_c1;
  insert into customer_members (org_id, customer_id, name, mobile, is_primary) values (v_org, v_c1, '__TEST_ member', v_member, false);
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ second', v_mob2) returning id into v_c2;
  insert into customers (org_id, name, mobile, preferred_language) values (v_org, '__TEST_ tamil pref', v_mobta, 'ta') returning id into v_c_ta;
  insert into customers (org_id, name, mobile, primary_profile_id) values (v_org, '__TEST_ login ta', '9400000065', v_login_ta) returning id into v_c_login;
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ plain', '9400000066') returning id into v_c_plain;
  insert into customers (org_id, name, mobile, is_test) values (v_org, '__TEST_ flagged', '9400000067', true) returning id into v_ct;
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ cap', '9400000068') returning id into v_c5;
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ review', '9400000069') returning id into v_c6;

  perform pg_temp.chk('S2 preferred_language accepts en/ta/null and refuses anything else',
    pg_temp.raises(format($q$update customers set preferred_language = 'fr' where id = %L$q$, v_c1)) like '%check constraint%'
    and pg_temp.raises(format($q$update customers set preferred_language = 'en' where id = %L$q$, v_c1)) is null
    and pg_temp.raises(format($q$update customers set preferred_language = null where id = %L$q$, v_c1)) is null);

  -- rules (master saves)
  perform pg_temp.as_user(v_m1);
  v_rfeed := public.automation_rule_save(null, 'feedback.requested', 'customer', 'whatsapp', '{}', 'gvm_feedback_request_en', 'en', 0, 0, null, 'live');
  v_rjob  := public.automation_rule_save(null, 'ticket.created', 'customer', 'whatsapp', '{}', 'gvm_service_booked_en', 'en', 0, 0, null, 'live');
  v_rinv  := public.automation_rule_save(null, 'invoice.issued', 'customer', 'whatsapp', '{}', 'gvm_invoice_issued_en', 'en', 0, 0, null, 'live');
  v_rrev  := public.automation_rule_save(null, 'review.google_requested', 'customer', 'whatsapp', '{}', 'gvm_google_review_en', 'en', 0, 0, null, 'live');
  v_rsales := public.automation_rule_save(null, 'lead.created', 'sales', 'in_app', '{}', null, null, 0, 0, null, 'live');
  perform pg_temp.chk('rule save accepts the new knobs and the shadow status; an invalid class is refused',
    public.automation_rule_save(null, 'amc.joined', 'customer', 'whatsapp', '{}', 'gvm_amc_welcome_en', 'en', 0, 0, null, 'shadow', null, null, 'job', false, 24) is not null
    and pg_temp.raises($q$select public.automation_rule_save(null, 'amc.joined', 'customer', 'whatsapp', '{}', null, null, 0, 0, null, 'live', null, null, 'urgent')$q$) like '%check constraint%'
    and pg_temp.raises($q$select public.automation_rule_save(null, 'amc.joined', 'customer', 'whatsapp', '{}', null, null, 0, 0, null, 'bogus')$q$) like '%check constraint%');
  perform pg_temp.as_pg();
  select count(*) into n from public.automation_audit where org_id = v_org and decision = 'config_changed';
  perform pg_temp.chk('rule saves are audited', n >= 6, n::text);

  select count(*) into v_ob1 from public.whatsapp_outbox where org_id = v_org;

  -- ---------- S7: main customer's mobile only ----------
  v_ev := public.automation_emit(v_org, 'ticket.created', 'ticket', gen_random_uuid(), v_c1, 'created',
            jsonb_build_object('mobile', v_member));
  select recipient_masked into s from public.automation_queue where event_id = v_ev and rule_id = v_rjob;
  perform pg_temp.chk('S7 customer rule uses the main number even when the payload carries a family member number',
    s = '******' || right(v_mob1, 4) and s <> '******' || right(v_member, 4), coalesce(s, 'none'));
  perform pg_temp.chk('S7 no queue or audit row ever carries the member number',
    not exists (select 1 from public.automation_queue where org_id = v_org and recipient_masked = '******' || right(v_member, 4))
    and not exists (select 1 from public.automation_audit where org_id = v_org and recipient_masked = '******' || right(v_member, 4)));

  -- ---------- S2: language order ----------
  v_ev := public.automation_emit(v_org, 'ticket.created', 'ticket', gen_random_uuid(), v_c_ta, 'created', '{}');
  perform pg_temp.chk('S2 preferred_language ta wins over the rule language en',
    (select language from public.automation_queue where event_id = v_ev and rule_id = v_rjob) = 'ta');
  v_ev := public.automation_emit(v_org, 'ticket.created', 'ticket', gen_random_uuid(), v_c_login, 'created', '{}');
  perform pg_temp.chk('S2 no preference: the login language (ta) is used',
    (select language from public.automation_queue where event_id = v_ev and rule_id = v_rjob) = 'ta');
  v_ev := public.automation_emit(v_org, 'ticket.created', 'ticket', gen_random_uuid(), v_c_plain, 'created', '{}');
  perform pg_temp.chk('S2 nothing set: the rule language (en)',
    (select language from public.automation_queue where event_id = v_ev and rule_id = v_rjob) = 'en');
  update customers set preferred_language = 'en' where id = v_c_login;
  v_ev := public.automation_emit(v_org, 'ticket.created', 'ticket', gen_random_uuid(), v_c_login, 'created', '{}');
  perform pg_temp.chk('S2 preferred en beats a ta login',
    (select language from public.automation_queue where event_id = v_ev and rule_id = v_rjob) = 'en');
  perform pg_temp.chk('S2 empty everywhere: English',
    public._automation_language(v_org, v_c_plain, null) = 'en');

  -- ---------- S3: STOP / STOP ALL / START ----------
  perform pg_temp.chk('S3 before any STOP: non-job and job both pass',
    not public._automation_is_opted_out(v_org, v_mob2, 'non_job') and not public._automation_is_opted_out(v_org, v_mob2, 'job'));
  perform public.wa_record_opt_out(v_org, '+91 ' || v_mob2, 'stop', 'whatsapp');
  perform pg_temp.chk('S3 STOP: non-job blocked, job (and invoices) continue',
    public._automation_is_opted_out(v_org, v_mob2, 'non_job') and not public._automation_is_opted_out(v_org, v_mob2, 'job'));
  v_ev := public.automation_emit(v_org, 'feedback.requested', 'ticket', gen_random_uuid(), v_c2, 'f', '{}');
  select decision into s from public.automation_audit where event_id = v_ev and rule_id = v_rfeed;
  perform pg_temp.chk('S3 engine: feedback (non-job) after STOP -> skipped_opt_out', s = 'skipped_opt_out', coalesce(s, '-'));
  v_ev := public.automation_emit(v_org, 'ticket.created', 'ticket', gen_random_uuid(), v_c2, 'c', '{}');
  select decision into s from public.automation_audit where event_id = v_ev and rule_id = v_rjob;
  perform pg_temp.chk('S3 engine: booking (job) after STOP -> still dry_run', s = 'dry_run', coalesce(s, '-'));
  v_ev := public.automation_emit(v_org, 'invoice.issued', 'invoice', gen_random_uuid(), v_c2, 'i', '{}');
  select decision into s from public.automation_audit where event_id = v_ev and rule_id = v_rinv;
  perform pg_temp.chk('S3 engine: invoice after STOP -> still dry_run', s = 'dry_run', coalesce(s, '-'));
  perform public.wa_record_opt_out(v_org, v_mob2, 'stop_all');
  v_ev := public.automation_emit(v_org, 'ticket.created', 'ticket', gen_random_uuid(), v_c2, 'c2', '{}');
  select decision into s from public.automation_audit where event_id = v_ev and rule_id = v_rjob;
  perform pg_temp.chk('S3 STOP ALL: even job messages are skipped_opt_out', s = 'skipped_opt_out', coalesce(s, '-'));
  perform public.wa_record_opt_out(v_org, v_mob2, 'stop');
  perform pg_temp.chk('S3 a later STOP does not clear STOP ALL',
    (select opt_out_all from public.customer_comm_prefs where org_id = v_org and mobile_key = v_mob2));
  perform public.wa_record_opt_out(v_org, v_mob2, 'start');
  perform pg_temp.chk('S3 START clears both',
    not (select opt_out_all or opt_out_non_job from public.customer_comm_prefs where org_id = v_org and mobile_key = v_mob2)
    and not public._automation_is_opted_out(v_org, v_mob2, 'non_job'));
  perform pg_temp.chk('S3 history: four events, last four digits only, linked customer set',
    (select count(*) from public.customer_comm_pref_events where org_id = v_org and mobile_last4 = right(v_mob2, 4)) = 4
    and not exists (select 1 from public.customer_comm_pref_events where org_id = v_org and mobile_last4 !~ '^[0-9]{4}$')
    and (select customer_id from public.customer_comm_prefs where org_id = v_org and mobile_key = v_mob2) = v_c2);
  rec := null;
  select (public.wa_record_opt_out(v_org, '9400000099', 'stop') ->> 'opt_out_non_job')::boolean as ok into rec;
  perform pg_temp.chk('S3 an unknown number (not a customer) can opt out too',
    rec.ok and (select customer_id is null from public.customer_comm_prefs where org_id = v_org and mobile_key = '9400000099'));
  s := pg_temp.raises(format($q$select public.wa_record_opt_out(%L, '9400000099', 'unsubscribe')$q$, v_org));
  perform pg_temp.chk('S3 unknown action refused', s like '%unknown action%', coalesce(s, 'accepted'));
  s := pg_temp.raises(format($q$select public.wa_record_opt_out(%L, '12345', 'stop')$q$, v_org));
  perform pg_temp.chk('S3 short number refused', s like '%10-digit%', coalesce(s, 'accepted'));
  s := pg_temp.raises($q$update public.customer_comm_pref_events set action = 'start'$q$);
  perform pg_temp.chk('S3 history is append-only', s like '%append-only%', coalesce(s, 'accepted'));
  perform pg_temp.as_anon();
  s := pg_temp.raises(format($q$select public.wa_record_opt_out(%L, '9400000099', 'start')$q$, v_org));
  perform pg_temp.chk('S3 anon cannot call wa_record_opt_out', s like '%permission denied%', coalesce(s, 'accepted'));
  s := pg_temp.raises($q$select * from public.customer_comm_prefs$q$);
  perform pg_temp.chk('S3 anon cannot read the opt-out record', s like '%permission denied%', coalesce(s, 'accepted'));
  perform pg_temp.as_user(v_sales);
  s := pg_temp.raises(format($q$select public.wa_record_opt_out(%L, '9400000099', 'start')$q$, v_org));
  perform pg_temp.chk('S3 authenticated staff cannot call wa_record_opt_out', s like '%permission denied%', coalesce(s, 'accepted'));
  perform pg_temp.chk('S3 sales_admin cannot read the record', (select count(*) from public.customer_comm_prefs) = 0);
  s := pg_temp.raises(format($q$select public.set_customer_comm_pref(%L, true, false)$q$, v_c1));
  perform pg_temp.chk('S3 sales_admin cannot set a preference', s like '%only master or operations%', coalesce(s, 'accepted'));
  perform pg_temp.as_user(v_cr);
  s := pg_temp.raises(format($q$select public.set_customer_comm_pref(%L, true, false)$q$, v_c1));
  perform pg_temp.chk('S3 customer role cannot set a preference', s like '%only master or operations%', coalesce(s, 'accepted'));
  perform pg_temp.as_user(v_ops);
  s := pg_temp.raises(format($q$select public.set_customer_comm_pref(%L, true, false)$q$, v_c1));
  perform pg_temp.chk('S3 operations can set a preference and reads the record',
    s is null and (select opt_out_non_job from public.customer_comm_prefs where mobile_key = v_mob1)
    and (select count(*) from public.customer_comm_prefs) > 0);
  perform pg_temp.as_pg();
  perform public.wa_record_opt_out(v_org, v_mob1, 'start');

  -- ---------- S0a / S0b: shadow rows never count, and never suppress the live send ----------
  perform pg_temp.as_user(v_m1);
  v_rshadow := public.automation_rule_save(null, 'quotation.converted', 'customer', 'whatsapp', '{}', 'gvm_thanks_en', 'en', 0, 24, 1, 'shadow');
  perform pg_temp.as_pg();
  select rule_key into v_rkey from public.automation_rules where id = v_rshadow;
  v_t := gen_random_uuid();
  v_ev := public.automation_emit(v_org, 'quotation.converted', 'quotation', v_t, v_c1, 'converted', '{}');
  perform pg_temp.chk('S0 shadow rule writes a shadow-mode row',
    (select mode from public.automation_queue where event_id = v_ev) = 'shadow');
  v_ev := public.automation_emit(v_org, 'quotation.converted', 'quotation', gen_random_uuid(), v_c1, 'converted', '{}');
  select decision into s from public.automation_audit where event_id = v_ev and rule_key = v_rkey;
  perform pg_temp.chk('S0 inside shadow mode cooldown/max-fires still simulate (second subject skipped)',
    s in ('skipped_cooldown', 'skipped_max_fires'), coalesce(s, '-'));
  perform pg_temp.as_user(v_m1);
  v_rshadow := public.automation_rule_save(v_rkey, 'quotation.converted', 'customer', 'whatsapp', '{}', 'gvm_thanks_en', 'en', 0, 24, 1, 'live');
  perform pg_temp.as_pg();
  v_lead := gen_random_uuid();
  v_ev := public.automation_emit(v_org, 'quotation.converted', 'quotation', v_lead, v_c1, 'converted', '{}');
  select decision into s from public.automation_audit where event_id = v_ev and rule_key = v_rkey;
  perform pg_temp.chk('S0a promoted to live: the earlier SHADOW row does not trigger cooldown or max-fires', s = 'dry_run', coalesce(s, '-'));
  perform pg_temp.chk('S0a that row is mode live',
    (select mode from public.automation_queue where event_id = v_ev and rule_key = v_rkey) = 'live');
  v_ev := public.automation_emit(v_org, 'quotation.converted', 'quotation', v_t, v_c1, 'converted', '{}');
  select decision into s from public.automation_audit where event_id = v_ev and rule_key = v_rkey;
  perform pg_temp.chk('S0b the SAME occurrence that was shadowed is not a duplicate for the live rule (keys differ by mode)',
    s in ('dry_run', 'skipped_cooldown', 'skipped_max_fires') and s <> 'skipped_duplicate', coalesce(s, '-'));
  perform pg_temp.chk('S0b live keys end in |live|- and shadow keys in |shadow|-',
    exists (select 1 from public.automation_queue where org_id = v_org and rule_key = v_rkey and idempotency_key like '%|shadow|-')
    and exists (select 1 from public.automation_queue where org_id = v_org and rule_key = v_rkey and idempotency_key like '%|live|-'));
  v_ev := public.automation_emit(v_org, 'quotation.converted', 'quotation', v_lead, v_c1, 'converted', '{}');
  select decision into s from public.automation_audit where event_id = v_ev and rule_key = v_rkey;
  perform pg_temp.chk('S0b a true replay inside live mode is skipped_duplicate', s = 'skipped_duplicate', coalesce(s, '-'));

  -- ---------- S1: master fallback ----------
  v_lead := gen_random_uuid();
  v_ev := public.automation_emit(v_org, 'lead.created', 'lead', v_lead, null, 'created', jsonb_build_object('kind', 'service'));
  select count(*) into n from public.automation_queue where event_id = v_ev and rule_id = v_rsales;
  perform pg_temp.chk('S1 no sales person: one row per ACTIVE master (2), none for the inactive master',
    n = 2
    and exists (select 1 from public.automation_queue where event_id = v_ev and recipient_profile_id = v_m1)
    and exists (select 1 from public.automation_queue where event_id = v_ev and recipient_profile_id = v_m2)
    and not exists (select 1 from public.automation_queue where event_id = v_ev and recipient_profile_id = v_m_off), n::text);
  perform pg_temp.chk('S1 fallback is recorded in the audit detail',
    (select count(*) from public.automation_audit where event_id = v_ev and detail ->> 'recipient_fallback' = 'master') = 2);
  v_ev := public.automation_emit(v_org, 'lead.created', 'lead', gen_random_uuid(), null, 'created', jsonb_build_object('sales_person_id', v_sales));
  perform pg_temp.chk('S1 with a sales person, only that person (no fallback)',
    (select count(*) from public.automation_queue where event_id = v_ev and rule_id = v_rsales) = 1
    and (select recipient_profile_id from public.automation_queue where event_id = v_ev and rule_id = v_rsales) = v_sales
    and not exists (select 1 from public.automation_audit where event_id = v_ev and detail ? 'recipient_fallback'));
  perform pg_temp.chk('S1 master fan-out replay is idempotent per master',
    (select count(*) from public.automation_queue where org_id = v_org and subject_id = v_lead) = 2
    and (public.automation_emit(v_org, 'lead.created', 'lead', v_lead, null, 'created', jsonb_build_object('kind', 'service')) is not null)
    and (select count(*) from public.automation_queue where org_id = v_org and subject_id = v_lead) = 2);
  -- an organisation with no active master and no sales person: nobody to notify
  update public.profiles set is_active = false where org_id = v_org and role = 'master';
  v_ev := public.automation_emit(v_org, 'lead.created', 'lead', gen_random_uuid(), null, 'created', '{}');
  select decision into s from public.automation_audit where event_id = v_ev and rule_id = v_rsales;
  perform pg_temp.chk('S1 no active master at all -> skipped_no_recipient', s = 'skipped_no_recipient', coalesce(s, '-'));
  update public.profiles set is_active = true where id in (v_m1, v_m2);

  -- ---------- S4: quiet hours ----------
  perform pg_temp.chk('S4 helper: 21:00 IST rolls to 08:00 next day; 20:59 unchanged; 03:00 rolls to 08:00 same day; 08:00 unchanged',
    public._automation_next_allowed('2026-01-10 21:00:00+05:30', v_org) = '2026-01-11 08:00:00+05:30'::timestamptz
    and public._automation_next_allowed('2026-01-10 20:59:59+05:30', v_org) = '2026-01-10 20:59:59+05:30'::timestamptz
    and public._automation_next_allowed('2026-01-10 03:00:00+05:30', v_org) = '2026-01-10 08:00:00+05:30'::timestamptz
    and public._automation_next_allowed('2026-01-10 08:00:00+05:30', v_org) = '2026-01-10 08:00:00+05:30'::timestamptz
    and public._automation_next_allowed('2026-01-10 23:30:00+05:30', v_org) = '2026-01-11 08:00:00+05:30'::timestamptz);
  update settings set automation_quiet_start = '13:00', automation_quiet_end = '14:00' where org_id = v_org;
  perform pg_temp.chk('S4 helper follows the setting (non-wrapping window)',
    public._automation_next_allowed('2026-01-10 13:30:00+05:30', v_org) = '2026-01-10 14:00:00+05:30'::timestamptz
    and public._automation_next_allowed('2026-01-10 21:30:00+05:30', v_org) = '2026-01-10 21:30:00+05:30'::timestamptz);
  -- make "now" fall inside quiet hours: window = [local now - 1h, local now + 1h)
  v_local := (now() at time zone 'Asia/Kolkata')::time;
  update settings set automation_quiet_start = (v_local - interval '1 hour')::time, automation_quiet_end = (v_local + interval '1 hour')::time where org_id = v_org;
  perform pg_temp.as_user(v_m1);
  v_rexempt := public.automation_rule_save(null, 'technician.on_the_way', 'customer', 'whatsapp', '{}', 'gvm_technician_on_the_way_en', 'en', 0, 0, null, 'live');
  v_rexempt2 := public.automation_rule_save(null, 'ticket.assigned', 'customer', 'whatsapp', '{}', 'gvm_technician_assigned_en', 'en', 0, 0, null, 'live', null, null, null, false);
  perform pg_temp.as_pg();
  v_ev := public.automation_emit(v_org, 'ticket.created', 'ticket', gen_random_uuid(), v_c1, 'created', '{}');
  select fire_at into v_fire from public.automation_queue where event_id = v_ev and rule_id = v_rjob;
  perform pg_temp.chk('S4 a held job message is pushed to the end of the quiet window (about +1h)',
    v_fire > now() + interval '50 minutes' and v_fire < now() + interval '70 minutes', (v_fire - now())::text);
  v_ev := public.automation_emit(v_org, 'technician.on_the_way', 'ticket', gen_random_uuid(), v_c1, 'otw', '{}');
  select fire_at into v_fire from public.automation_queue where event_id = v_ev and rule_id = v_rexempt;
  perform pg_temp.chk('S4 on_the_way is exempt: not held', v_fire < now() + interval '1 minute', (v_fire - now())::text);
  v_ev := public.automation_emit(v_org, 'ticket.assigned', 'ticket', gen_random_uuid(), v_c1, 'assigned', '{}');
  select fire_at into v_fire from public.automation_queue where event_id = v_ev and rule_id = v_rexempt2;
  perform pg_temp.chk('S4 a rule with respect_quiet_hours = false is not held', v_fire < now() + interval '1 minute', (v_fire - now())::text);
  update settings set automation_quiet_start = '21:00', automation_quiet_end = '08:00' where org_id = v_org;

  -- ---------- S5: daily cap for non-job only ----------
  for n in 1..3 loop
    v_ev := public.automation_emit(v_org, 'feedback.requested', 'ticket', gen_random_uuid(), v_c5, 'f' || n, '{}');
  end loop;
  perform pg_temp.chk('S5 three non-job messages in a day all pass',
    (select count(*) from public.automation_queue where org_id = v_org and customer_id = v_c5 and rule_id = v_rfeed and state = 'dry_run') = 3);
  v_ev := public.automation_emit(v_org, 'feedback.requested', 'ticket', gen_random_uuid(), v_c5, 'f4', '{}');
  select state, fire_at, expires_at into rec from public.automation_queue where event_id = v_ev and rule_id = v_rfeed;
  select decision into s from public.automation_audit where event_id = v_ev and rule_id = v_rfeed;
  perform pg_temp.chk('S5 the fourth non-job message is deferred with an expiry', rec.state = 'deferred' and s = 'deferred_daily_cap' and rec.expires_at is not null, coalesce(rec.state, '-') || '/' || coalesce(s, '-'));
  perform pg_temp.chk('S5 deferred to the next IST day at the end of quiet hours (08:00)',
    (rec.fire_at at time zone 'Asia/Kolkata')::time = '08:00'
    and (rec.fire_at at time zone 'Asia/Kolkata')::date > (now() at time zone 'Asia/Kolkata')::date - 1
    and rec.fire_at > now());
  v_q := (select id from public.automation_queue where event_id = v_ev and rule_id = v_rfeed);
  -- job messages and invoices are never counted or deferred, even over the cap
  for n in 1..4 loop
    v_ev2 := public.automation_emit(v_org, 'ticket.created', 'ticket', gen_random_uuid(), v_c5, 'jc' || n, '{}');
    v_ev2 := public.automation_emit(v_org, 'invoice.issued', 'invoice', gen_random_uuid(), v_c5, 'ji' || n, '{}');
  end loop;
  perform pg_temp.chk('S5 job and invoice messages are never deferred by the cap',
    not exists (select 1 from public.automation_queue where org_id = v_org and customer_id = v_c5 and message_class = 'job' and state = 'deferred')
    and (select count(*) from public.automation_queue where org_id = v_org and customer_id = v_c5 and rule_id in (v_rjob, v_rinv) and state = 'dry_run') >= 8);
  perform pg_temp.chk('S5 job messages do not use up the non-job allowance (still exactly 3 non-job today)',
    (select count(*) from public.automation_queue where org_id = v_org and customer_id = v_c5 and message_class = 'non_job' and state = 'dry_run') = 3);
  -- another customer is unaffected
  v_ev2 := public.automation_emit(v_org, 'feedback.requested', 'ticket', gen_random_uuid(), v_c_plain, 'f1', '{}');
  perform pg_temp.chk('S5 the cap is per customer', (select state from public.automation_queue where event_id = v_ev2 and rule_id = v_rfeed) = 'dry_run');
  -- release: before its window nothing moves; at the window the row is released
  v_res := public.automation_release_deferred(now());
  perform pg_temp.chk('S5 release before the window changes nothing',
    (v_res ->> 'released')::int = 0 and (select state from public.automation_queue where id = v_q) = 'deferred');
  select fire_at into v_fire from public.automation_queue where id = v_q;
  v_res := public.automation_release_deferred(v_fire + interval '1 minute');
  perform pg_temp.chk('S5 release at the window re-queues it and audits released_deferred',
    (v_res ->> 'released')::int >= 1
    and (select state from public.automation_queue where id = v_q) = 'dry_run'
    and exists (select 1 from public.automation_audit where decision = 'released_deferred' and idempotency_key = (select idempotency_key from public.automation_queue where id = v_q)));
  -- expiry: a deferred row whose window passed is dropped, never sent
  for n in 1..3 loop
    v_ev := public.automation_emit(v_org, 'feedback.requested', 'ticket', gen_random_uuid(), v_c2, 'g' || n, '{}');
  end loop;
  v_ev := public.automation_emit(v_org, 'feedback.requested', 'ticket', gen_random_uuid(), v_c2, 'g4', '{}');
  v_q := (select id from public.automation_queue where event_id = v_ev and rule_id = v_rfeed);
  perform pg_temp.chk('S5 (setup) fourth message for the second customer is deferred', (select state from public.automation_queue where id = v_q) = 'deferred');
  v_res := public.automation_release_deferred(now() + interval '10 days');
  perform pg_temp.chk('S5 release long after the expiry drops it (expired, audited, not re-queued)',
    (v_res ->> 'expired')::int >= 1
    and (select state from public.automation_queue where id = v_q) = 'expired'
    and exists (select 1 from public.automation_audit where decision = 'expired_deferred' and idempotency_key = (select idempotency_key from public.automation_queue where id = v_q)));
  -- an event whose own window ends before the next day's window is dropped at once (e.g. a 7-day AMC reminder)
  for n in 1..3 loop
    v_ev := public.automation_emit(v_org, 'feedback.requested', 'ticket', gen_random_uuid(), v_c_ta, 'h' || n, '{}');
  end loop;
  v_ev := public.automation_emit(v_org, 'feedback.requested', 'ticket', gen_random_uuid(), v_c_ta, 'h4',
            jsonb_build_object('window_end', (now() + interval '2 hours')::text));
  perform pg_temp.chk('S5 a window that ends before the next release is expired immediately, audited expired_deferred',
    (select state from public.automation_queue where event_id = v_ev and rule_id = v_rfeed) = 'expired'
    and exists (select 1 from public.automation_audit where event_id = v_ev and decision = 'expired_deferred'));
  perform pg_temp.chk('S5 deferred and expired rows are not counted toward the cap or the cooldown',
    (select count(*) from public.automation_queue where org_id = v_org and customer_id = v_c_ta and message_class = 'non_job' and state = 'dry_run') = 3);
  -- cap setting is honoured
  update settings set automation_non_job_daily_cap = 1 where org_id = v_org;
  v_ev := public.automation_emit(v_org, 'feedback.requested', 'ticket', gen_random_uuid(), v_c_login, 'k1', '{}');
  v_ev2 := public.automation_emit(v_org, 'feedback.requested', 'ticket', gen_random_uuid(), v_c_login, 'k2', '{}');
  perform pg_temp.chk('S5 the cap is the setting (1): second non-job deferred',
    (select state from public.automation_queue where event_id = v_ev and rule_id = v_rfeed) = 'dry_run'
    and (select state from public.automation_queue where event_id = v_ev2 and rule_id = v_rfeed) = 'deferred');
  update settings set automation_non_job_daily_cap = 3 where org_id = v_org;

  -- ---------- S6: 90-day review floor ----------
  v_ev := public.automation_emit(v_org, 'review.google_requested', 'ticket', gen_random_uuid(), v_c6, 'r1', '{}');
  perform pg_temp.chk('S6 first review request passes', (select state from public.automation_queue where event_id = v_ev and rule_id = v_rrev) = 'dry_run');
  v_ev := public.automation_emit(v_org, 'review.google_requested', 'ticket', gen_random_uuid(), v_c6, 'r2', '{}');
  select decision into s from public.automation_audit where event_id = v_ev and rule_id = v_rrev;
  perform pg_temp.chk('S6 a second request for the same customer inside 90 days -> skipped_cooldown (rule cooldown was 0)', s = 'skipped_cooldown', coalesce(s, '-'));
  v_ev := public.automation_emit(v_org, 'review.google_requested', 'ticket', gen_random_uuid(), v_c_login, 'r3', '{}');
  perform pg_temp.chk('S6 another customer is unaffected', (select state from public.automation_queue where event_id = v_ev and rule_id = v_rrev) = 'dry_run');
  perform pg_temp.chk('S6 the floor is 2160 hours',
    (select min_cooldown_hours from public.automation_events where event_key = 'review.google_requested') = 2160);
  update public.automation_queue set created_at = now() - interval '91 days' where org_id = v_org and rule_id = v_rrev and customer_id = v_c6;
  v_ev := public.automation_emit(v_org, 'review.google_requested', 'ticket', gen_random_uuid(), v_c6, 'r4', '{}');
  perform pg_temp.chk('S6 after 91 days a new request passes again', (select state from public.automation_queue where event_id = v_ev and rule_id = v_rrev) = 'dry_run');

  -- ---------- S2: who can write preferred_language ----------
  perform pg_temp.as_user(v_m1);
  perform pg_temp.chk('S2 master sets it through the RPC',
    pg_temp.raises(format($q$select public.set_customer_preferred_language(%L, 'ta')$q$, v_c_plain)) is null);
  perform pg_temp.as_user(v_ops);
  s := pg_temp.raises(format($q$select public.set_customer_preferred_language(%L, 'en')$q$, v_c_plain));
  perform pg_temp.chk('S2 operations-only staff CAN set it through the RPC (a direct UPDATE would silently change nothing)', s is null, coalesce(s, 'ok'));
  perform pg_temp.as_user(v_sales);
  perform pg_temp.chk('S2 sales_admin can set it through the RPC',
    pg_temp.raises(format($q$select public.set_customer_preferred_language(%L, 'ta')$q$, v_c_plain)) is null);
  s := pg_temp.raises(format($q$select public.set_customer_preferred_language(%L, 'fr')$q$, v_c_plain));
  perform pg_temp.chk('S2 an unknown language is refused', s like '%must be en or ta%', coalesce(s, 'accepted'));
  perform pg_temp.as_user(v_cr);
  s := pg_temp.raises(format($q$select public.set_customer_preferred_language(%L, 'ta')$q$, v_c_plain));
  perform pg_temp.chk('S2 the customer role cannot use the staff RPC', s like '%only master, operations or sales%', coalesce(s, 'accepted'));
  perform pg_temp.as_anon();
  s := pg_temp.raises(format($q$select public.set_customer_preferred_language(%L, 'ta')$q$, v_c_plain));
  perform pg_temp.chk('S2 anon cannot call it', s like '%permission denied%', coalesce(s, 'accepted'));
  perform pg_temp.as_pg();
  perform pg_temp.chk('S2 the value was written (last staff write was ta)',
    (select preferred_language from public.customers where id = v_c_plain) = 'ta');
  -- a customer editing their own record: language allowed, anything else still refused
  update customers set primary_profile_id = v_cr where id = v_c_plain;
  perform pg_temp.as_user(v_cr);
  s := pg_temp.raises(format($q$update customers set preferred_language = 'en' where id = %L$q$, v_c_plain));
  perform pg_temp.chk('S2 a customer can set their own message language', s is null and
    (select preferred_language from public.customers where id = v_c_plain) = 'en', coalesce(s, 'ok'));
  s := pg_temp.raises(format($q$update customers set mobile = '9999999999' where id = %L$q$, v_c_plain));
  perform pg_temp.chk('S2 a customer still cannot change their mobile', s like '%you can only edit your name, profession and message language%', coalesce(s, 'accepted'));
  s := pg_temp.raises(format($q$update customers set is_test = true where id = %L$q$, v_c_plain));
  perform pg_temp.chk('S2 a customer still cannot flag themselves as a test customer', s is not null, coalesce(s, 'accepted'));
  perform pg_temp.as_pg();

  -- ---------- nothing sendable ----------
  select count(*) into v_ob2 from public.whatsapp_outbox where org_id = v_org;
  perform pg_temp.chk('the engine wrote nothing to whatsapp_outbox', v_ob1 = v_ob2, v_ob1::text || ' -> ' || v_ob2::text);
  perform pg_temp.chk('queue states are still only non-deliverable values',
    not exists (select 1 from public.automation_queue where org_id = v_org and state not in ('dry_run', 'blocked_not_allowlisted', 'deferred', 'expired')));
  s := pg_temp.raises(format($q$insert into public.automation_queue (org_id, idempotency_key, rule_id, rule_key, rule_version, event_id, event_key, subject_type, subject_id, recipient_role, channel, fire_at, state)
        values (%L, 'x2', gen_random_uuid(), gen_random_uuid(), 1, gen_random_uuid(), 'a.b', 'ticket', gen_random_uuid(), 'customer', 'whatsapp', now(), 'pending')$q$, v_org));
  perform pg_temp.chk('queue CHECK still refuses a deliverable state', s like '%check constraint%', coalesce(s, 'accepted'));
  perform pg_temp.chk('wa_dispatch_v2_enabled untouched',
    not coalesce((select wa_dispatch_v2_enabled from settings where org_id = v_org), false));

  raise exception 'RESULTS%', E'\n' || (select string_agg(r.line, E'\n' order by r.n) from pg_temp.res r);
end $t$;
$rh2$;
  v_hash := encode(sha256(convert_to(v_text, 'UTF8')), 'hex');
  if v_hash <> 'b21ac0aa6ebcfc4f50041d751fd19ff010a2041244bf4177c489c137aad8e154' then
    raise exception 'REHEARSAL_REFUSED: hash mismatch for automation_phase3a_engine.test.sql: %', v_hash;
  end if;
  execute v_text;

  raise exception 'REHEARSAL_DID_NOT_RAISE: the test file should have raised RESULTS';
end
$rehearsal$;
