-- REHEARSAL (NOT RUN; for the owner's approval of this exact text): item 2 stack: automation_item_added_and_per_item_cooldown
-- One request, one DO block. It: (1) refuses to run before 18:00 IST (the clock is read from clock_timestamp()), (2) recomputes
-- the sha256 of every embedded file and refuses on any mismatch with the pinned value, (3) executes the migration text(s) and then the
-- test file in order, (4) always ends in an unconditional RAISE EXCEPTION, so nothing is ever committed.
-- No top-level begin / commit / savepoint / rollback. No schema_migrations row is written. Never concatenated with test code outside
-- this wrapper. Expected error text starts with RESULTS (or TIMING); anything else is a failure and also rolls back.
-- Pinned (sha256 of the LF blob at the commit this wrapper was generated from):
--   b7380711bd3c2e00f6565edbb707ad5324a5f9de54b1790585cdd7708083ca2b  gv-mart/supabase/migrations/20261026100000_automation_item_added_and_per_item_cooldown.sql
--   36fb993672ca65aa0a5b77ff3a892e3d04d38ab7b88aa580bc5653b5622772e9  gv-mart/supabase/migrations/20261026110000_automation_emit_requires_customer_record.sql
--   0a121b58de51debb1335fb4185338d4faacb1e57530f97989dca2b7802629a49  gv-mart/supabase/tests/automation_item_added_and_per_item_cooldown.test.sql

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

  v_text := $rh2$-- Rolled-back DB tests for 20261026100000_automation_item_added_and_per_item_cooldown.
-- NOT RUN (written for review). Run only through the rehearsal wrapper the owner approves: the wrapper applies the migration
-- inside ONE transaction, then runs this file, which ends in an unconditional RAISE so nothing is ever committed. Throwaway
-- __TEST_ organisation only; no real customer, number or message is touched; nothing is sent (the engine has no sender).
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
  v_org uuid; v_master uuid; v_sales uuid;
  v_c1 uuid; v_c2 uuid; v_c3 uuid; v_c4 uuid;
  v_m1 text := '9400000071'; v_m2 text := '9400000072'; v_m3 text := '9400000073'; v_m4 text := '9400000074';
  v_brand uuid; v_model uuid; v_pa uuid; v_pb uuid; v_sp uuid;
  v_ka text; v_kb text; v_kc text;
  v_r_item uuid; v_r_added uuid; v_r_wide uuid; v_r_old uuid;
  v_ev uuid; v_ev2 uuid; s text; n int; rec record;
  v_lead uuid; v_old_lead uuid; v_new_lead uuid; v_li uuid;
  v_ob1 int; v_ob2 int;
begin
  -- ---------- schema / catalogue / grants ----------
  perform pg_temp.chk('automation_queue.item_key exists, nullable text',
    (select data_type || '/' || is_nullable from information_schema.columns
      where table_schema = 'public' and table_name = 'automation_queue' and column_name = 'item_key') = 'text/YES');
  perform pg_temp.chk('automation_rules.cooldown_per_item exists, boolean not null default false',
    (select data_type || '/' || is_nullable || '/' || column_default from information_schema.columns
      where table_schema = 'public' and table_name = 'automation_rules' and column_name = 'cooldown_per_item') = 'boolean/NO/false');
  perform pg_temp.chk('catalogue: enquiry.item_added has an emitter, lead subject, customer + sales recipients',
    exists (select 1 from public.automation_events where event_key = 'enquiry.item_added' and has_emitter and not is_scheduled
              and subject_type = 'lead' and supported_recipients = '{customer,sales}'));
  perform pg_temp.chk('automation_rule_save: the 16-argument version is gone, the 17-argument one exists',
    to_regprocedure('public.automation_rule_save(uuid,text,text,text,jsonb,text,text,integer,integer,integer,text,uuid,text,text,boolean,integer)') is null
    and to_regprocedure('public.automation_rule_save(uuid,text,text,text,jsonb,text,text,integer,integer,integer,text,uuid,text,text,boolean,integer,boolean)') is not null);
  perform pg_temp.chk('automation_rule_save grants: authenticated and service_role yes, anon and PUBLIC no',
    has_function_privilege('authenticated', 'public.automation_rule_save(uuid,text,text,text,jsonb,text,text,integer,integer,integer,text,uuid,text,text,boolean,integer,boolean)', 'execute')
    and has_function_privilege('service_role', 'public.automation_rule_save(uuid,text,text,text,jsonb,text,text,integer,integer,integer,text,uuid,text,text,boolean,integer,boolean)', 'execute')
    and not has_function_privilege('anon', 'public.automation_rule_save(uuid,text,text,text,jsonb,text,text,integer,integer,integer,text,uuid,text,text,boolean,integer,boolean)', 'execute')
    and not exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                     where p.proname = 'automation_rule_save' and p.pronamespace = 'public'::regnamespace and a.grantee = 0));
  perform pg_temp.chk('automation_emit still service_role only; the new trigger function is not callable by clients',
    not has_function_privilege('authenticated', 'public.automation_emit(uuid,text,text,uuid,uuid,text,jsonb)', 'execute')
    and not has_function_privilege('anon', 'public.automation_emit(uuid,text,text,uuid,uuid,text,jsonb)', 'execute')
    and has_function_privilege('service_role', 'public.automation_emit(uuid,text,text,uuid,uuid,text,jsonb)', 'execute')
    and not has_function_privilege('authenticated', 'public._trg_automation_emit_lead_item()', 'execute')
    and not has_function_privilege('anon', 'public._trg_automation_emit_lead_item()', 'execute'));
  perform pg_temp.chk('the lead_items trigger exists and is an AFTER INSERT row trigger',
    exists (select 1 from pg_trigger t where t.tgrelid = 'public.lead_items'::regclass and t.tgname = 'zz_automation_emit_lead_item'
             and not t.tgisinternal and (t.tgtype & 1) = 1 and (t.tgtype & 4) = 4 and (t.tgtype & 2) = 0));

  -- ---------- fixtures ----------
  insert into organizations (name) values ('__TEST_automation_item') returning id into v_org;
  insert into settings (org_id) values (v_org) on conflict (org_id) do nothing;
  v_master := pg_temp.mkuser('master', v_org);
  v_sales := pg_temp.mkuser('sales_admin', v_org);
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ c1', v_m1) returning id into v_c1;
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ c2', v_m2) returning id into v_c2;
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ c3', v_m3) returning id into v_c3;
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ c4', v_m4) returning id into v_c4;
  insert into brands (org_id, name, category) values (v_org, '__TEST_ brand', 'ro') returning id into v_brand;
  insert into models (org_id, brand_id, name) values (v_org, v_brand, '__TEST_ model') returning id into v_model;
  insert into products (org_id, name, category, brand_id, model_id, price) values (v_org, '__TEST_ RO A', 'ro', v_brand, v_model, 10000) returning id into v_pa;
  insert into products (org_id, name, category, brand_id, model_id, price) values (v_org, '__TEST_ RO B', 'ro', v_brand, v_model, 12000) returning id into v_pb;
  insert into spares (org_id, name, price) values (v_org, '__TEST_ spare', 100) returning id into v_sp;
  v_ka := v_pa::text; v_kb := v_pb::text; v_kc := v_sp::text;

  -- ---------- rule save: the new knob ----------
  perform pg_temp.as_user(v_master);
  v_r_item  := public.automation_rule_save(null, 'lead.created', 'customer', 'whatsapp', '{"has_item": true}', 'gvm_enquiry_video_en', 'en', 0, 720, null, 'live', null, null, null, null, 72, true);
  v_r_added := public.automation_rule_save(null, 'enquiry.item_added', 'customer', 'whatsapp', '{"has_item": true}', 'gvm_enquiry_video_ta', 'ta', 0, 720, null, 'live', null, null, null, null, 72, true);
  v_r_wide  := public.automation_rule_save(null, 'lead.stage.won', 'customer', 'whatsapp', '{}', 'gvm_thanks_en', 'en', 0, 720, null, 'live');
  perform pg_temp.as_pg();
  perform pg_temp.chk('rule save stores cooldown_per_item; omitted it is false',
    (select cooldown_per_item from public.automation_rules where id = v_r_item)
    and (select cooldown_per_item from public.automation_rules where id = v_r_added)
    and not (select cooldown_per_item from public.automation_rules where id = v_r_wide));
  perform pg_temp.as_user(v_sales);
  s := pg_temp.raises($q$select public.automation_rule_save(null, 'lead.created', 'customer', 'whatsapp', '{}', null, null, 0, 0, null, 'live', null, null, null, null, 72, true)$q$);
  perform pg_temp.as_pg();
  perform pg_temp.chk('a non-master still cannot save a rule', s like '%only the master%', coalesce(s, 'accepted'));
  -- a new version keeps the knob only if it is passed again (immutable versions): v2 without the flag is false
  perform pg_temp.as_user(v_master);
  v_r_old := public.automation_rule_save((select rule_key from public.automation_rules where id = v_r_wide), 'lead.stage.won', 'customer', 'whatsapp', '{}', 'gvm_thanks_en', 'en', 0, 720, null, 'live', null, 'v2');
  perform pg_temp.as_pg();
  perform pg_temp.chk('a saved version 2 has its own cooldown_per_item (false when not passed)',
    not (select cooldown_per_item from public.automation_rules where id = v_r_old) and (select version from public.automation_rules where id = v_r_old) = 2);

  -- ---------- per-item cooldown ----------
  v_ev := public.automation_emit(v_org, 'lead.created', 'lead', gen_random_uuid(), v_c1, 'created',
            jsonb_build_object('kind', 'product', 'has_item', true, 'item_key', v_ka));
  select decision into s from public.automation_audit where event_id = v_ev and rule_id = v_r_item;
  perform pg_temp.chk('first enquiry for item A is queued (dry_run)', s = 'dry_run', coalesce(s, '-'));
  perform pg_temp.chk('the queue row stores item_key A and the audit detail carries it',
    (select item_key from public.automation_queue where event_id = v_ev and rule_id = v_r_item) = v_ka
    and (select detail ->> 'item_key' from public.automation_audit where event_id = v_ev and rule_id = v_r_item) = v_ka);

  v_ev := public.automation_emit(v_org, 'lead.created', 'lead', gen_random_uuid(), v_c1, 'created',
            jsonb_build_object('kind', 'product', 'has_item', true, 'item_key', v_ka));
  select decision into s from public.automation_audit where event_id = v_ev and rule_id = v_r_item;
  perform pg_temp.chk('same customer, same item, another lead inside 720 h: skipped_cooldown', s = 'skipped_cooldown', coalesce(s, '-'));

  v_ev := public.automation_emit(v_org, 'lead.created', 'lead', gen_random_uuid(), v_c1, 'created',
            jsonb_build_object('kind', 'product', 'has_item', true, 'item_key', v_kb));
  select decision into s from public.automation_audit where event_id = v_ev and rule_id = v_r_item;
  perform pg_temp.chk('same customer, a DIFFERENT item B: queued (the cooldown is per item)', s = 'dry_run', coalesce(s, '-'));

  v_ev := public.automation_emit(v_org, 'lead.created', 'lead', gen_random_uuid(), v_c2, 'created',
            jsonb_build_object('kind', 'product', 'has_item', true, 'item_key', v_ka));
  select decision into s from public.automation_audit where event_id = v_ev and rule_id = v_r_item;
  perform pg_temp.chk('a DIFFERENT customer, same item A: queued (the cooldown is per customer)', s = 'dry_run', coalesce(s, '-'));

  v_ev := public.automation_emit(v_org, 'lead.created', 'lead', gen_random_uuid(), v_c1, 'created',
            jsonb_build_object('kind', 'product', 'has_item', true));
  select decision into s from public.automation_audit where event_id = v_ev and rule_id = v_r_item;
  perform pg_temp.chk('no item_key on the event: falls back to the whole-customer cooldown (never weaker)', s = 'skipped_cooldown', coalesce(s, '-'));

  -- the other rule sends the same template base (_ta vs _en): the window is shared across the two events
  v_ev := public.automation_emit(v_org, 'enquiry.item_added', 'lead', gen_random_uuid(), v_c1, 'item:x1',
            jsonb_build_object('kind', 'product', 'has_item', true, 'item_key', v_ka));
  select decision into s from public.automation_audit where event_id = v_ev and rule_id = v_r_added;
  perform pg_temp.chk('Item added for item A after Enquiry created for item A: skipped_cooldown (shared template window)', s = 'skipped_cooldown', coalesce(s, '-'));
  v_ev := public.automation_emit(v_org, 'enquiry.item_added', 'lead', gen_random_uuid(), v_c1, 'item:x2',
            jsonb_build_object('kind', 'spare', 'has_item', true, 'item_key', v_kc));
  select decision into s from public.automation_audit where event_id = v_ev and rule_id = v_r_added;
  perform pg_temp.chk('Item added for a new item C: queued', s = 'dry_run', coalesce(s, '-'));

  -- a rule WITHOUT cooldown_per_item keeps the old whole-customer behaviour whatever the item is
  v_ev := public.automation_emit(v_org, 'lead.stage.won', 'lead', gen_random_uuid(), v_c2, 'won',
            jsonb_build_object('item_key', v_ka));
  select decision into s from public.automation_audit where event_id = v_ev and rule_id = v_r_old;
  perform pg_temp.chk('rule without cooldown_per_item: first send is queued', s = 'dry_run', coalesce(s, '-'));
  v_ev2 := public.automation_emit(v_org, 'lead.stage.won', 'lead', gen_random_uuid(), v_c2, 'won',
            jsonb_build_object('item_key', v_kb));
  select decision into s from public.automation_audit where event_id = v_ev2 and rule_id = v_r_old;
  perform pg_temp.chk('a rule without cooldown_per_item: a second item inside the window is still skipped_cooldown (unchanged)', s = 'skipped_cooldown', coalesce(s, '-'));

  -- replay protection: the same occurrence for the same lead is a duplicate, not a second send
  v_lead := gen_random_uuid();
  v_ev := public.automation_emit(v_org, 'enquiry.item_added', 'lead', v_lead, v_c3, 'item:replay',
            jsonb_build_object('kind', 'product', 'has_item', true, 'item_key', v_ka));
  v_ev2 := public.automation_emit(v_org, 'enquiry.item_added', 'lead', v_lead, v_c3, 'item:replay',
            jsonb_build_object('kind', 'product', 'has_item', true, 'item_key', v_ka));
  select decision into s from public.automation_audit where event_id = v_ev2 and rule_id = v_r_added;
  perform pg_temp.chk('replaying the same item occurrence is skipped_duplicate', s = 'skipped_duplicate', coalesce(s, '-'));

  -- ---------- item_key is stored at the blocked and deferred insert sites too ----------
  update settings set wa_test_mode_enabled = true, wa_test_allowed_numbers = '{}'::text[] where org_id = v_org;
  v_ev := public.automation_emit(v_org, 'lead.created', 'lead', gen_random_uuid(), v_c4, 'created',
            jsonb_build_object('kind', 'product', 'has_item', true, 'item_key', v_kb));
  perform pg_temp.chk('blocked site: state blocked_not_allowlisted and item_key stored',
    (select state || '/' || coalesce(item_key, '-') from public.automation_queue where event_id = v_ev and rule_id = v_r_item)
      = 'blocked_not_allowlisted/' || v_kb);
  v_ev2 := public.automation_emit(v_org, 'lead.created', 'lead', gen_random_uuid(), v_c4, 'created',
            jsonb_build_object('kind', 'product', 'has_item', true, 'item_key', v_kb));
  select decision into s from public.automation_audit where event_id = v_ev2 and rule_id = v_r_item;
  perform pg_temp.chk('a blocked row does not count toward the cooldown (same item, next attempt is not skipped_cooldown)',
    s = 'blocked_not_allowlisted', coalesce(s, '-'));
  update settings set wa_test_mode_enabled = false, wa_test_allowed_numbers = '{}'::text[], automation_non_job_daily_cap = 1 where org_id = v_org;
  -- c3 has one non-job row today (the replay probe); cap 1 -> the next different item is deferred
  v_ev := public.automation_emit(v_org, 'lead.created', 'lead', gen_random_uuid(), v_c3, 'created',
            jsonb_build_object('kind', 'product', 'has_item', true, 'item_key', v_kb));
  perform pg_temp.chk('deferred site: state deferred and item_key stored',
    (select state || '/' || coalesce(item_key, '-') from public.automation_queue where event_id = v_ev and rule_id = v_r_item)
      = 'deferred/' || v_kb,
    coalesce((select state from public.automation_queue where event_id = v_ev and rule_id = v_r_item), 'no row'));
  update settings set automation_non_job_daily_cap = 3 where org_id = v_org;

  -- ---------- lead payload fields ----------
  v_lead := null;
  insert into leads (org_id, customer_id, name, mobile, source, status, kind, product_id, qty)
    values (v_org, v_c1, '__TEST_ L with item', v_m1, 'customer_app', 'new', 'product', v_pa, 1) returning id into v_lead;
  perform pg_temp.chk('lead.created payload carries product_id, spare_id, has_item and item_key',
    (select payload_keys from public.automation_event_log where org_id = v_org and subject_id = v_lead and event_key = 'lead.created')
      @> array['product_id', 'spare_id', 'has_item', 'item_key']);
  perform pg_temp.chk('the rule with condition has_item = true matched the new lead (queued or skipped_cooldown, not skipped_condition)',
    exists (select 1 from public.automation_audit a join public.automation_event_log e on e.id = a.event_id
             where e.subject_id = v_lead and e.event_key = 'lead.created' and a.rule_id = v_r_item
               and a.decision in ('dry_run', 'skipped_cooldown')));
  insert into leads (org_id, customer_id, name, mobile, source, status, kind)
    values (v_org, v_c2, '__TEST_ L no item', v_m2, 'walk_in', 'new', 'service') returning id into v_new_lead;
  perform pg_temp.chk('a lead with no item does not satisfy has_item = true (skipped_condition)',
    exists (select 1 from public.automation_audit a join public.automation_event_log e on e.id = a.event_id
             where e.subject_id = v_new_lead and e.event_key = 'lead.created' and a.rule_id = v_r_item and a.decision = 'skipped_condition'));

  -- ---------- the enquiry.item_added trigger ----------
  -- a lead created in THIS transaction: its items are lead.created material, not item_added
  insert into lead_items (org_id, lead_id, product_id, qty) values (v_org, v_lead, v_pa, 1);
  perform pg_temp.chk('an item added to a lead created in the same transaction emits no enquiry.item_added',
    not exists (select 1 from public.automation_event_log where org_id = v_org and subject_id = v_lead and event_key = 'enquiry.item_added'));

  -- an older open lead: items inserted by the system (merged enquiry) emit once, for the first item only
  insert into leads (org_id, customer_id, name, mobile, source, status, kind, created_at)
    values (v_org, v_c4, '__TEST_ L old open', v_m4, 'customer_app', 'new', 'product', now() - interval '2 days') returning id into v_old_lead;
  insert into lead_items (org_id, lead_id, product_id, qty) values (v_org, v_old_lead, v_pa, 1), (v_org, v_old_lead, v_pb, 1);
  select count(*) into n from public.automation_event_log where org_id = v_org and subject_id = v_old_lead and event_key = 'enquiry.item_added';
  perform pg_temp.chk('two items added to an older lead in one submission: exactly ONE enquiry.item_added (first item only)', n = 1, n::text);
  perform pg_temp.chk('the event is for the customer of the lead and carries the first item as item_key',
    (select customer_id from public.automation_event_log where org_id = v_org and subject_id = v_old_lead and event_key = 'enquiry.item_added') = v_c4
    and exists (select 1 from public.automation_queue q where q.org_id = v_org and q.subject_id = v_old_lead and q.event_key = 'enquiry.item_added'
                  and q.item_key = v_pa::text));
  perform pg_temp.chk('the item_added audit row is recorded for the item_added rule',
    exists (select 1 from public.automation_audit a join public.automation_event_log e on e.id = a.event_id
             where e.subject_id = v_old_lead and e.event_key = 'enquiry.item_added' and a.rule_id = v_r_added));
  perform pg_temp.chk('payload keys of the item_added event include item_key, has_item, product_id, spare_id, kind',
    (select payload_keys from public.automation_event_log where org_id = v_org and subject_id = v_old_lead and event_key = 'enquiry.item_added')
      @> array['item_key', 'has_item', 'product_id', 'spare_id', 'kind', 'sales_person_id', 'mobile']);

  -- a spare-only item: kind is derived as spare
  insert into leads (org_id, customer_id, name, mobile, source, status, kind, created_at)
    values (v_org, v_c2, '__TEST_ L old spare', v_m2, 'customer_app', 'new', 'spare', now() - interval '3 days') returning id into v_lead;
  insert into lead_items (org_id, lead_id, spare_id, qty) values (v_org, v_lead, v_sp, 2);
  perform pg_temp.chk('a spare item on an older lead emits item_added with item_key = the spare id',
    exists (select 1 from public.automation_queue q where q.org_id = v_org and q.subject_id = v_lead and q.event_key = 'enquiry.item_added'
                and q.item_key = v_sp::text)
    or exists (select 1 from public.automation_audit a join public.automation_event_log e on e.id = a.event_id
                where e.subject_id = v_lead and e.event_key = 'enquiry.item_added' and a.detail ->> 'item_key' = v_sp::text));

  -- a staff member adding an item through the app is not a customer enquiry
  insert into leads (org_id, customer_id, name, mobile, source, status, kind, created_at)
    values (v_org, v_c3, '__TEST_ L old staff', v_m3, 'customer_app', 'new', 'product', now() - interval '4 days') returning id into v_lead;
  perform pg_temp.as_user(v_sales);
  s := pg_temp.raises(format($q$insert into public.lead_items (org_id, lead_id, product_id, qty) values (%L, %L, %L, 1)$q$, v_org, v_lead, v_pa));
  perform pg_temp.as_pg();
  perform pg_temp.chk('staff insert of an item is allowed by RLS and emits no enquiry.item_added',
    s is null and not exists (select 1 from public.automation_event_log where org_id = v_org and subject_id = v_lead and event_key = 'enquiry.item_added'),
    coalesce(s, 'ok'));

  -- an item row with neither a product nor a spare emits nothing
  insert into leads (org_id, customer_id, name, mobile, source, status, kind, created_at)
    values (v_org, v_c3, '__TEST_ L old empty', v_m3, 'customer_app', 'new', 'product', now() - interval '5 days') returning id into v_lead;
  insert into lead_items (org_id, lead_id, qty) values (v_org, v_lead, 1);
  perform pg_temp.chk('an item with no product and no spare emits nothing',
    not exists (select 1 from public.automation_event_log where org_id = v_org and subject_id = v_lead and event_key = 'enquiry.item_added'));

  -- the trigger swallows its own failure: a lead_items insert must still succeed
  insert into leads (org_id, customer_id, name, mobile, source, status, kind, created_at)
    values (v_org, v_c3, '__TEST_ L old fail', v_m3, 'customer_app', 'new', 'product', now() - interval '6 days') returning id into v_lead;
  update settings set automation_enabled = false where org_id = v_org;
  s := pg_temp.raises(format($q$insert into public.lead_items (org_id, lead_id, product_id, qty) values (%L, %L, %L, 1)$q$, v_org, v_lead, v_pb));
  perform pg_temp.chk('with automation switched off the insert still succeeds and the event is logged as global_off',
    s is null and (select outcome from public.automation_event_log where org_id = v_org and subject_id = v_lead and event_key = 'enquiry.item_added') = 'global_off',
    coalesce(s, 'ok'));
  update settings set automation_enabled = true where org_id = v_org;

  -- ---------- unchanged guarantees ----------
  perform pg_temp.chk('queue states are still only non-deliverable values',
    not exists (select 1 from public.automation_queue where org_id = v_org and state not in ('dry_run', 'blocked_not_allowlisted', 'deferred', 'expired')));
  select count(*) into v_ob2 from public.whatsapp_outbox where org_id = v_org;
  perform pg_temp.chk('the engine wrote nothing to whatsapp_outbox', v_ob2 = 0, v_ob2::text);
  perform pg_temp.chk('wa_dispatch_v2_enabled untouched',
    not coalesce((select wa_dispatch_v2_enabled from settings where org_id = v_org), false));
  perform pg_temp.chk('no full phone number is stored in queue or audit',
    not exists (select 1 from public.automation_queue where org_id = v_org and recipient_masked ~ '[0-9]{7,}')
    and not exists (select 1 from public.automation_audit where org_id = v_org and recipient_masked ~ '[0-9]{7,}'));

  raise exception 'RESULTS%', E'\n' || (select string_agg(r.line, E'\n' order by r.n) from pg_temp.res r);
end $t$;
$rh2$;
  v_hash := encode(sha256(convert_to(v_text, 'UTF8')), 'hex');
  if v_hash <> '0a121b58de51debb1335fb4185338d4faacb1e57530f97989dca2b7802629a49' then
    raise exception 'REHEARSAL_REFUSED: hash mismatch for automation_item_added_and_per_item_cooldown.test.sql: %', v_hash;
  end if;
  execute v_text;

  raise exception 'REHEARSAL_DID_NOT_RAISE: the test file should have raised RESULTS';
end
$rehearsal$;
