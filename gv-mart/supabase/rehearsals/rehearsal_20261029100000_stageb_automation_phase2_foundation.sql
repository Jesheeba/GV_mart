-- REHEARSAL (NOT RUN; for the owner's approval of this exact text): Stage B stack (items 1+2, then the four Stage B migrations): automation_phase2_foundation
-- One request, one DO block. It: (1) refuses to run before 18:00 IST (the clock is read from clock_timestamp()), (2) recomputes
-- the sha256 of every embedded file and refuses on any mismatch with the pinned value, (3) executes the migration text(s) and then the
-- test file in order, (4) always ends in an unconditional RAISE EXCEPTION, so nothing is ever committed.
-- No top-level begin / commit / savepoint / rollback. No schema_migrations row is written. Never concatenated with test code outside
-- this wrapper. Expected error text starts with RESULTS (or TIMING); anything else is a failure and also rolls back.
-- Pinned (sha256 of the LF blob at the commit this wrapper was generated from):
--   b7380711bd3c2e00f6565edbb707ad5324a5f9de54b1790585cdd7708083ca2b  gv-mart/supabase/migrations/20261026100000_automation_item_added_and_per_item_cooldown.sql
--   36fb993672ca65aa0a5b77ff3a892e3d04d38ab7b88aa580bc5653b5622772e9  gv-mart/supabase/migrations/20261026110000_automation_emit_requires_customer_record.sql
--   0ac82abca66c983942b76a8ba6958e8ebc8f955447d27705a8d07bc9e2eb9fd2  gv-mart/supabase/migrations/20261029100000_automation_handoff.sql
--   e7a181c1a5c4eef042e39652ba3abdd2472f7831476ac8cd09230970d7afa4d9  gv-mart/supabase/migrations/20261029110000_automation_scanners_and_amc_visit_emit.sql
--   a67ea4a0b53b400c1d861f41348add553aa2444b7e7a0ee8b69ef76c7e44f949  gv-mart/supabase/migrations/20261029120000_start_travel.sql
--   e2bf071eb94f9a6269c798e9aab04bd1a09a32742e5cde8b39796cfe8be386d3  gv-mart/supabase/migrations/20261029130000_automation_handoff_amc_ref_type.sql
--   fae29baa9b015420e86054985fc51ac2f053969c7da9b32d38fbfaabd96c1389  gv-mart/supabase/tests/automation_phase2_foundation.test.sql

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

  v_text := $rh2$-- Automation Phase 3 / Stage B, part 1: the hand-off from the automation queue to the dispatcher's outbox.
-- DEPENDS ON (rebased 2026-10-15): 20261026100000_automation_item_added_and_per_item_cooldown and
-- 20261026110000_automation_emit_requires_customer_record, applied BEFORE this file. The automation_emit below is the item 2 body
-- (which includes item 1) with the Stage B additions merged in: the whitelisted hand-off context (v_ctx, queue.context), the wider
-- counted-state lists, and the 'context' column on all three queue inserts next to 'item_key'.
--
-- automation_handoff_due() is the ONLY place automation writes whatsapp_outbox. It is service_role only and is NOT scheduled
-- by this migration. It inserts nothing unless ALL of these hold for a queue row:
--   * the row is mode 'live' (never 'shadow'), state 'dry_run', due, WhatsApp channel, customer recipient;
--   * the organisation's automation_enabled is true;
--   * the CURRENT version of the row's rule exists and its status is 'live' (test_only / shadow / paused / missing: nothing);
--   * the dispatcher applies to the number: settings.wa_dispatch_v2_enabled is true AND the number is in
--     wa_dispatch_v2_numbers (or scope 'org'); a number outside it is recorded as blocked_not_in_dispatch_scope, so a
--     real customer can never be reached through the legacy path;
--   * the F-08 test-mode allow-list and the test-subject hard stop pass;
--   * the number has not opted out for the message class (STOP / STOP ALL);
--   * an ACTIVE mapping (whatsapp_event_templates, keyed by the template base name and language) points at an APPROVED
--     template in the mirror (whatsapp_wasi_templates);
--   * the subject type has a whitelisted dispatcher ref type (automation_handoff_ref_types).
-- The outbox row is inserted as 'pending' (never an optimistic 'sent'); the dispatcher claims and sends it. Rows that are
-- stale (older than 24 h, 60 minutes for time-critical events) are dropped, never sent late. Nothing here sends anything.

create table public.automation_handoff_ref_types (
  ref_type     text primary key,
  subject_type text not null
);
insert into public.automation_handoff_ref_types (ref_type, subject_type) values
  ('service_ticket', 'ticket'),
  ('service_visit',  'visit'),
  ('invoice',        'invoice');
alter table public.automation_handoff_ref_types enable row level security;
revoke all on public.automation_handoff_ref_types from public, anon, authenticated;
grant select on public.automation_handoff_ref_types to authenticated, service_role;
create policy automation_handoff_ref_types_select on public.automation_handoff_ref_types for select to authenticated using (public.is_staff());

alter table public.automation_queue
  add column outbox_id        uuid,
  add column handed_over_at   timestamptz,
  add column context          jsonb not null default '{}'::jsonb;
alter table public.automation_queue drop constraint automation_queue_state_check;
alter table public.automation_queue add constraint automation_queue_state_check check (state in (
  'dry_run', 'blocked_not_allowlisted', 'deferred', 'expired',
  'handed_over', 'blocked_not_in_dispatch_scope', 'skipped_no_template', 'skipped_no_recipient', 'skipped_opt_out', 'expired_stale'));
alter table public.automation_audit drop constraint automation_audit_decision_check;
alter table public.automation_audit add constraint automation_audit_decision_check check (decision in (
  'dry_run', 'blocked_not_allowlisted', 'skipped_paused', 'skipped_condition', 'skipped_test_only', 'skipped_no_recipient',
  'skipped_duplicate', 'skipped_max_fires', 'skipped_cooldown', 'skipped_opt_out', 'deferred_daily_cap',
  'released_deferred', 'expired_deferred', 'config_changed',
  'handed_over', 'blocked_not_in_dispatch_scope', 'skipped_no_template', 'expired_stale'));
create index automation_queue_handoff_idx on public.automation_queue (org_id, fire_at) where state = 'dry_run' and mode = 'live';

-- the engine and the deferred-row release, re-issued with (a) the new terminal states excluded from every count and
-- (b) the small non-personal context stored with each row. Behaviour is otherwise the Stage A engine, unchanged.
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
  v_ctx        jsonb;
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
    -- a whitelisted, non-personal subset of the payload travels with the queue row (never a number or a name)
    select coalesce(jsonb_object_agg(e.k, e.v), '{}'::jsonb) into v_ctx
      from jsonb_each(v_payload) as e(k, v)
     where e.k = any (array['days_left', 'eta_minutes', 'visit_date', 'expiry_date', 'window_end', 'product_id', 'plan_id', 'ticket_type', 'technician_id']);

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
                and q.state not in ('blocked_not_allowlisted', 'blocked_not_in_dispatch_scope', 'deferred', 'expired', 'expired_stale', 'skipped_no_template', 'skipped_no_recipient', 'skipped_opt_out')) >= r.max_fires then
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
                and q.state not in ('blocked_not_allowlisted', 'blocked_not_in_dispatch_scope', 'deferred', 'expired', 'expired_stale', 'skipped_no_template', 'skipped_no_recipient', 'skipped_opt_out')
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
                 fire_at, state, is_test, mode, message_class, recipient_profile_id, detail, context, item_key)
          values (p_org_id, v_key, r.id, r.rule_key, r.version, v_event_id, p_event_key, p_subject_type, p_subject_id, v_cust,
                  r.recipient_role, v_masked, r.channel, r.template_name, v_lang, v_fire, 'blocked_not_allowlisted', v_test,
                  v_mode, v_class, v_rec, v_detail, v_ctx, v_item)
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
             and q.state not in ('blocked_not_allowlisted', 'blocked_not_in_dispatch_scope', 'deferred', 'expired', 'expired_stale', 'skipped_no_template', 'skipped_no_recipient', 'skipped_opt_out')
             and (q.fire_at at time zone 'Asia/Kolkata')::date = (v_fire at time zone 'Asia/Kolkata')::date;
          if v_count >= v_cap then
            v_defer_to := public._automation_next_allowed(
              (((v_fire at time zone 'Asia/Kolkata')::date + 1) + '00:00'::time) at time zone 'Asia/Kolkata', p_org_id);
            v_expires := least(now() + (r.max_defer_hours * interval '1 hour'), coalesce(v_window_end, 'infinity'::timestamptz));
            insert into public.automation_queue (org_id, idempotency_key, rule_id, rule_key, rule_version, event_id, event_key,
                   subject_type, subject_id, customer_id, recipient_role, recipient_masked, channel, template_name, language,
                   fire_at, state, is_test, mode, message_class, expires_at, recipient_profile_id, detail, context, item_key)
            values (p_org_id, v_key, r.id, r.rule_key, r.version, v_event_id, p_event_key, p_subject_type, p_subject_id, v_cust,
                    r.recipient_role, v_masked, r.channel, r.template_name, v_lang, v_defer_to,
                    case when v_expires <= v_defer_to then 'expired' else 'deferred' end, v_test,
                    v_mode, v_class, v_expires, v_rec, v_detail, v_ctx, v_item)
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
               fire_at, state, is_test, mode, message_class, recipient_profile_id, detail, context, item_key)
        values (p_org_id, v_key, r.id, r.rule_key, r.version, v_event_id, p_event_key, p_subject_type, p_subject_id, v_cust,
                r.recipient_role, v_masked, r.channel, r.template_name, v_lang, v_fire, 'dry_run', v_test,
                v_mode, v_class, v_rec, v_detail, v_ctx, v_item)
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
       and o.id <> q.id and o.state not in ('blocked_not_allowlisted', 'blocked_not_in_dispatch_scope', 'deferred', 'expired', 'expired_stale', 'skipped_no_template', 'skipped_no_recipient', 'skipped_opt_out')
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


-- ── the hand-off ────────────────────────────────────────────────────────────────────────────────────────────────────────
create function public.automation_handoff_due(
  p_now           timestamptz default now(),
  p_limit         integer default 200,
  p_max_age_hours integer default 24
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  q            record;
  r            public.automation_rules%rowtype;
  ev           public.automation_events%rowtype;
  v_enabled    boolean;
  v_test_mode  boolean;
  v_list       text[];
  v_v2         boolean;
  v_mobile     text;
  v_ref        text;
  v_base       text;
  v_map        public.whatsapp_event_templates%rowtype;
  v_outbox     uuid;
  v_max_age    interval;
  v_masked     text;
  c_handed integer := 0; c_scope integer := 0; c_allow integer := 0; c_optout integer := 0;
  c_notpl integer := 0; c_norec integer := 0; c_stale integer := 0; c_held integer := 0;
begin
  for q in
    select * from public.automation_queue
     where state = 'dry_run' and mode = 'live' and fire_at <= p_now
       and recipient_role = 'customer' and channel in ('whatsapp', 'both')
     order by fire_at, created_at
     limit greatest(p_limit, 0)
     for update skip locked
  loop
    select s.automation_enabled, s.wa_test_mode_enabled, s.wa_test_allowed_numbers
      into v_enabled, v_test_mode, v_list from public.settings s where s.org_id = q.org_id;
    if not coalesce(v_enabled, true) then c_held := c_held + 1; continue; end if;

    -- the rule must be the current version AND live; anything else leaves the row exactly as it is
    select * into r from public.automation_rules where org_id = q.org_id and rule_key = q.rule_key and is_current;
    if not found or r.status <> 'live' then c_held := c_held + 1; continue; end if;

    select * into ev from public.automation_events e where e.event_key = q.event_key;
    v_max_age := case when coalesce(ev.quiet_hours_exempt, false) then interval '60 minutes'
                      else greatest(p_max_age_hours, 1) * interval '1 hour' end;
    if q.fire_at < p_now - v_max_age then
      update public.automation_queue set state = 'expired_stale' where id = q.id;
      perform public._automation_audit_row(q.org_id, q.event_id, q.event_key, q.subject_type, q.subject_id, q.rule_id, q.rule_key,
        q.rule_version, q.recipient_role, q.customer_id, q.recipient_masked, q.channel, q.template_name, 'expired_stale',
        jsonb_build_object('fire_at', q.fire_at, 'checked_at', p_now), q.is_test, q.idempotency_key);
      c_stale := c_stale + 1; continue;
    end if;

    -- main customer's number only
    v_mobile := case when q.customer_id is null then null else public._automation_customer_mobile(q.org_id, q.customer_id) end;
    if v_mobile is null then
      update public.automation_queue set state = 'skipped_no_recipient' where id = q.id;
      perform public._automation_audit_row(q.org_id, q.event_id, q.event_key, q.subject_type, q.subject_id, q.rule_id, q.rule_key,
        q.rule_version, q.recipient_role, q.customer_id, q.recipient_masked, q.channel, q.template_name, 'skipped_no_recipient',
        '{}'::jsonb, q.is_test, q.idempotency_key);
      c_norec := c_norec + 1; continue;
    end if;
    v_masked := '******' || right(v_mobile, 4);

    select h.ref_type into v_ref from public.automation_handoff_ref_types h where h.subject_type = q.subject_type;
    if v_ref is null then c_held := c_held + 1; continue; end if;   -- no dispatcher support for this subject yet: untouched

    -- dispatcher scope. v2 switched off: hold (the row waits, bounded by the stale rule). Switched on but this number is not
    -- in scope: terminal, so the new flows can never reach a number the dispatcher does not own.
    select s.wa_dispatch_v2_enabled into v_v2 from public.settings s where s.org_id = q.org_id;
    if not coalesce(v_v2, false) then c_held := c_held + 1; continue; end if;
    if not public.wa_dispatch_v2_applies(q.org_id, v_mobile) then
      update public.automation_queue set state = 'blocked_not_in_dispatch_scope' where id = q.id;
      perform public._automation_audit_row(q.org_id, q.event_id, q.event_key, q.subject_type, q.subject_id, q.rule_id, q.rule_key,
        q.rule_version, q.recipient_role, q.customer_id, v_masked, q.channel, q.template_name, 'blocked_not_in_dispatch_scope',
        jsonb_build_object('reason', 'number_not_in_wa_dispatch_v2_scope'), q.is_test, q.idempotency_key);
      c_scope := c_scope + 1; continue;
    end if;

    -- F-08 allow-list and the test-subject hard stop
    if (coalesce(v_test_mode, false) and not (v_mobile = any (coalesce(v_list, '{}'::text[]))))
       or (q.is_test and not (v_mobile = any (coalesce(v_list, '{}'::text[])))
           and not exists (select 1 from public.customers c where c.org_id = q.org_id and c.is_test
                            and public._mobile_key(c.mobile) = v_mobile)) then
      update public.automation_queue set state = 'blocked_not_allowlisted' where id = q.id;
      perform public._automation_audit_row(q.org_id, q.event_id, q.event_key, q.subject_type, q.subject_id, q.rule_id, q.rule_key,
        q.rule_version, q.recipient_role, q.customer_id, v_masked, q.channel, q.template_name, 'blocked_not_allowlisted',
        jsonb_build_object('reason', 'handoff_allow_list'), q.is_test, q.idempotency_key);
      insert into public.audit_log (org_id, actor_id, action, table_name, row_id, after)
      values (q.org_id, null, 'WA_SEND_BLOCKED', 'automation_queue', q.subject_id,
              jsonb_build_object('reason', 'handoff_allow_list', 'via', 'automation_handoff_due', 'event_key', q.event_key,
                                 'template', q.template_name, 'to_last4', right(v_mobile, 4)));
      c_allow := c_allow + 1; continue;
    end if;

    -- opt-out, re-checked at send time
    if public._automation_is_opted_out(q.org_id, v_mobile, coalesce(q.message_class, 'non_job')) then
      update public.automation_queue set state = 'skipped_opt_out' where id = q.id;
      perform public._automation_audit_row(q.org_id, q.event_id, q.event_key, q.subject_type, q.subject_id, q.rule_id, q.rule_key,
        q.rule_version, q.recipient_role, q.customer_id, v_masked, q.channel, q.template_name, 'skipped_opt_out',
        jsonb_build_object('class', q.message_class), q.is_test, q.idempotency_key);
      c_optout := c_optout + 1; continue;
    end if;

    -- an active mapping to an APPROVED template, by the template base name and the resolved language
    v_base := regexp_replace(coalesce(q.template_name, ''), '_(en|ta)$', '');
    select * into v_map from public.whatsapp_event_templates t
     where t.org_id = q.org_id and t.event_key = v_base and t.language = coalesce(q.language, 'en') and t.is_active;
    if v_base = '' or not found or not exists (
         select 1 from public.whatsapp_wasi_templates w
          where w.org_id = q.org_id and w.wasi_name = v_map.wasi_template_name and w.status = 'approved') then
      update public.automation_queue set state = 'skipped_no_template' where id = q.id;
      perform public._automation_audit_row(q.org_id, q.event_id, q.event_key, q.subject_type, q.subject_id, q.rule_id, q.rule_key,
        q.rule_version, q.recipient_role, q.customer_id, v_masked, q.channel, q.template_name, 'skipped_no_template',
        jsonb_build_object('template_base', v_base, 'language', q.language), q.is_test, q.idempotency_key);
      c_notpl := c_notpl + 1; continue;
    end if;

    insert into public.whatsapp_outbox (org_id, direction, to_mobile, customer_id, milestone, template, type, payload, ref_type, ref_id, status)
    values (q.org_id, 'outbound', v_mobile, q.customer_id, q.event_key, v_base, 'template',
            jsonb_build_object('automation_queue_id', q.id, 'rule_key', q.rule_key, 'event_key', q.event_key,
                               'language', coalesce(q.language, 'en')) || coalesce(q.context, '{}'::jsonb),
            v_ref, q.subject_id, 'pending')
    returning id into v_outbox;

    update public.automation_queue set state = 'handed_over', outbox_id = v_outbox, handed_over_at = p_now where id = q.id;
    perform public._automation_audit_row(q.org_id, q.event_id, q.event_key, q.subject_type, q.subject_id, q.rule_id, q.rule_key,
      q.rule_version, q.recipient_role, q.customer_id, v_masked, q.channel, q.template_name, 'handed_over',
      jsonb_build_object('outbox_id', v_outbox, 'template_base', v_base, 'language', q.language), q.is_test, q.idempotency_key);
    c_handed := c_handed + 1;
  end loop;

  return jsonb_build_object('handed_over', c_handed, 'blocked_scope', c_scope, 'blocked_allow_list', c_allow,
    'opted_out', c_optout, 'no_template', c_notpl, 'no_recipient', c_norec, 'expired_stale', c_stale, 'held', c_held);
end;
$$;
revoke all on function public.automation_handoff_due(timestamptz, integer, integer) from public, anon, authenticated;
grant execute on function public.automation_handoff_due(timestamptz, integer, integer) to service_role;
$rh2$;
  v_hash := encode(sha256(convert_to(v_text, 'UTF8')), 'hex');
  if v_hash <> '0ac82abca66c983942b76a8ba6958e8ebc8f955447d27705a8d07bc9e2eb9fd2' then
    raise exception 'REHEARSAL_REFUSED: hash mismatch for 20261029100000_automation_handoff.sql: %', v_hash;
  end if;
  execute v_text;

  v_text := $rh3$-- Automation Phase 3 / Stage B, part 2: SQL scanners (amc.expiring, feedback.requested, review.google_requested) and the
-- AMC visit emit. EVERYTHING HERE ONLY CALLS automation_emit(): rows land as dry-run queue rows. No scanner is scheduled by
-- this migration (callable by service_role / tests with a p_now), nothing is handed over, nothing is sent.
--
--   automation_scan_amc_expiring(p_now, p_windows)   contracts whose expiry_date is exactly 30 / 15 / 7 IST days away
--   automation_scan_feedback(p_now, delay, lookback)  tickets completed (delay .. delay+lookback) hours ago
--   automation_scan_review(p_now, delay, lookback)    same selection, event review.google_requested: EVERY completed service,
--                                                     no rating condition (the 90-day cooldown floor is in the engine)
--   appointments AFTER INSERT trigger                 amc.visit_scheduled for an AMC visit ticket, ONLY when it is the nearest
--                                                     open visit of the contract (owner decision 2026-10-13): at sale time the
--                                                     contract's other visits are left for the Wave 2 visit reminders
-- Window safety: each emit carries payload.window_end, so a deferred (over the daily cap) message that outlives its window is
-- dropped, never sent late (S5). Idempotency: the engine's key (rule | customer | subject | occurrence | mode), so re-running a
-- scanner adds nothing.

create function public._automation_ist_date(p_ts timestamptz)
returns date language sql immutable as $$ select (p_ts at time zone 'Asia/Kolkata')::date $$;
revoke all on function public._automation_ist_date(timestamptz) from public, anon, authenticated;
grant execute on function public._automation_ist_date(timestamptz) to service_role;

create function public.automation_scan_amc_expiring(p_now timestamptz default now(), p_windows integer[] default array[30, 15, 7])
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  c       record;
  w       integer;
  v_today date := public._automation_ist_date(p_now);
  v_n     integer := 0;
  v_end   timestamptz;
begin
  foreach w in array p_windows loop
    v_end := ((v_today + 1) + '00:00'::time) at time zone 'Asia/Kolkata';   -- the reminder is only meaningful that day
    for c in
      select ac.id, ac.org_id, ac.customer_id, ac.product_id, ac.plan_id, ac.expiry_date
        from public.amc_contracts ac
       where ac.expiry_date = v_today + w
         and ac.cancelled_at is null
         and ac.status in ('active', 'due_soon')
    loop
      perform public.automation_emit(c.org_id, 'amc.expiring', 'amc_contract', c.id, c.customer_id, 'expiring@' || w,
        jsonb_build_object('days_left', w, 'expiry_date', c.expiry_date::text, 'product_id', c.product_id, 'plan_id', c.plan_id,
                           'window_end', v_end::text));
      v_n := v_n + 1;
    end loop;
  end loop;
  return jsonb_build_object('emitted', v_n, 'windows', to_jsonb(p_windows), 'ist_date', v_today);
end;
$$;
revoke all on function public.automation_scan_amc_expiring(timestamptz, integer[]) from public, anon, authenticated;
grant execute on function public.automation_scan_amc_expiring(timestamptz, integer[]) to service_role;

-- completed tickets in a time window: completion time = the last visit's timer_end, else the ticket's updated_at
create function public._automation_completed_tickets(p_now timestamptz, p_delay_hours integer, p_lookback_hours integer)
returns table (org_id uuid, ticket_id uuid, customer_id uuid, ticket_type text, completed_at timestamptz)
language sql
stable
security definer
set search_path = public
as $$
  select t.org_id, t.id, t.customer_id, t.type::text, x.done
    from public.service_tickets t
    cross join lateral (
      select coalesce((select max(v.timer_end) from public.service_visits v where v.ticket_id = t.id), t.updated_at) as done
    ) x
   where t.status = 'completed'
     and x.done <= p_now - (p_delay_hours * interval '1 hour')
     and x.done >  p_now - ((p_delay_hours + p_lookback_hours) * interval '1 hour')
$$;
revoke all on function public._automation_completed_tickets(timestamptz, integer, integer) from public, anon, authenticated;
grant execute on function public._automation_completed_tickets(timestamptz, integer, integer) to service_role;

create function public.automation_scan_feedback(p_now timestamptz default now(), p_delay_hours integer default 24, p_lookback_hours integer default 72)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  t record; v_n integer := 0;
begin
  for t in select * from public._automation_completed_tickets(p_now, p_delay_hours, p_lookback_hours) loop
    perform public.automation_emit(t.org_id, 'feedback.requested', 'ticket', t.ticket_id, t.customer_id, 'feedback',
      jsonb_build_object('ticket_type', t.ticket_type,
                         'window_end', (t.completed_at + ((p_delay_hours + p_lookback_hours) * interval '1 hour'))::text));
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('emitted', v_n);
end;
$$;
revoke all on function public.automation_scan_feedback(timestamptz, integer, integer) from public, anon, authenticated;
grant execute on function public.automation_scan_feedback(timestamptz, integer, integer) to service_role;

create function public.automation_scan_review(p_now timestamptz default now(), p_delay_hours integer default 24, p_lookback_hours integer default 72)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  t record; v_n integer := 0;
begin
  -- Every completed service, whatever the rating: no rating, satisfaction or staff condition exists here (Google policy).
  for t in select * from public._automation_completed_tickets(p_now, p_delay_hours, p_lookback_hours) loop
    perform public.automation_emit(t.org_id, 'review.google_requested', 'ticket', t.ticket_id, t.customer_id, 'review',
      jsonb_build_object('ticket_type', t.ticket_type,
                         'window_end', (t.completed_at + ((p_delay_hours + p_lookback_hours) * interval '1 hour'))::text));
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('emitted', v_n);
end;
$$;
revoke all on function public.automation_scan_review(timestamptz, integer, integer) from public, anon, authenticated;
grant execute on function public.automation_scan_review(timestamptz, integer, integer) to service_role;

-- AMC visit scheduled: the appointment of a visit ticket that belongs to an AMC contract. Additive trigger (no live function
-- body replaced); failures are logged to automation_errors and never block the appointment write.
create function public._trg_automation_emit_amc_visit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  t record;
begin
  begin
    select st.id, st.org_id, st.customer_id, st.contract_id, st.product_id into t
      from public.service_tickets st where st.id = new.ticket_id;
    -- Only the nearest open visit is announced. The generators insert visits in date order, so the first insert is the
    -- nearest and every later one finds an earlier (or equal) open visit and stays silent. A renewal, whose earlier
    -- visits are completed or cancelled, announces its own first visit.
    if t.contract_id is not null and new.scheduled_at is not null and not exists (
         select 1
           from public.appointments a2
           join public.service_tickets t2 on t2.id = a2.ticket_id
          where t2.contract_id = t.contract_id
            and a2.id <> new.id
            and a2.status = 'scheduled'
            and a2.scheduled_at is not null
            and a2.scheduled_at <= new.scheduled_at) then
      perform public.automation_emit(t.org_id, 'amc.visit_scheduled', 'amc_contract', t.contract_id, t.customer_id,
        'visit@' || t.id::text,
        jsonb_build_object('visit_date', public._automation_ist_date(new.scheduled_at)::text,
                           'days_left', greatest(public._automation_ist_date(new.scheduled_at) - public._automation_ist_date(now()), 0),
                           'product_id', t.product_id, 'technician_id', new.technician_id));
    end if;
  exception when others then
    perform public._automation_log_error(new.org_id, tg_table_name || ':' || tg_op, 'amc.visit_scheduled', 'amc_contract', new.id, sqlstate, sqlerrm);
  end;
  return null;
end;
$$;
revoke all on function public._trg_automation_emit_amc_visit() from public, anon, authenticated;
create trigger zz_automation_emit_amc_visit after insert on public.appointments
  for each row execute function public._trg_automation_emit_amc_visit();

-- the catalogue now says these events have an emitter
update public.automation_events set has_emitter = true
 where event_key in ('amc.expiring', 'feedback.requested', 'review.google_requested', 'amc.visit_scheduled');
$rh3$;
  v_hash := encode(sha256(convert_to(v_text, 'UTF8')), 'hex');
  if v_hash <> 'e7a181c1a5c4eef042e39652ba3abdd2472f7831476ac8cd09230970d7afa4d9' then
    raise exception 'REHEARSAL_REFUSED: hash mismatch for 20261029110000_automation_scanners_and_amc_visit_emit.sql: %', v_hash;
  end if;
  execute v_text;

  v_text := $rh4$-- Automation Phase 3 / Stage B, part 3: "Start travel" - the departure signal technician.on_the_way has been missing.
--
--   appointments.travel_started_at           stamped once, by the assigned technician, while the job is assigned
--   settings.automation_default_travel_eta_minutes   the estimate passed to the message (master-editable, default 30)
--   start_travel(ticket)                     the one door; emits technician.on_the_way through automation_emit
--
-- The emit is failure-isolated: if the automation engine raises, the travel stamp still commits and the error goes to
-- automation_errors. Nothing here sends anything; with no live rule and an unscheduled hand-off, a stamp produces at most a
-- dry-run queue row.

alter table public.appointments add column travel_started_at timestamptz;
alter table public.settings
  add column automation_default_travel_eta_minutes integer not null default 30 check (automation_default_travel_eta_minutes between 1 and 240);

create function public.start_travel(p_ticket_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tech   uuid := public.current_technician_id();
  a        public.appointments%rowtype;
  t        public.service_tickets%rowtype;
  v_eta    integer;
  v_now    timestamptz := now();
begin
  if auth.uid() is null or v_tech is null then
    raise exception 'start_travel: only a technician can start travel';
  end if;

  select * into t from public.service_tickets where id = p_ticket_id;
  if not found then raise exception 'start_travel: job not found'; end if;

  select * into a from public.appointments x
   where x.ticket_id = p_ticket_id and x.technician_id = v_tech and x.status = 'scheduled'
   order by x.created_at desc limit 1
   for update;
  if not found then raise exception 'start_travel: this job is not assigned to you'; end if;
  if t.status::text <> 'assigned' then
    raise exception 'start_travel: travel can only be started for an assigned job';
  end if;

  if a.travel_started_at is not null then
    return jsonb_build_object('started_at', a.travel_started_at, 'already_started', true);
  end if;

  update public.appointments set travel_started_at = v_now where id = a.id;

  select s.automation_default_travel_eta_minutes into v_eta from public.settings s where s.org_id = t.org_id;
  begin
    perform public.automation_emit(t.org_id, 'technician.on_the_way', 'ticket', t.id, t.customer_id, 'on_the_way@' || a.id::text,
      jsonb_build_object('technician_id', v_tech, 'eta_minutes', coalesce(v_eta, 30), 'ticket_type', t.type::text));
  exception when others then
    perform public._automation_log_error(t.org_id, 'start_travel', 'technician.on_the_way', 'ticket', t.id, sqlstate, sqlerrm);
  end;

  return jsonb_build_object('started_at', v_now, 'already_started', false);
end;
$$;
revoke all on function public.start_travel(uuid) from public, anon;
grant execute on function public.start_travel(uuid) to authenticated, service_role;

update public.automation_events set has_emitter = true where event_key = 'technician.on_the_way';
$rh4$;
  v_hash := encode(sha256(convert_to(v_text, 'UTF8')), 'hex');
  if v_hash <> 'a67ea4a0b53b400c1d861f41348add553aa2444b7e7a0ee8b69ef76c7e44f949' then
    raise exception 'REHEARSAL_REFUSED: hash mismatch for 20261029120000_start_travel.sql: %', v_hash;
  end if;
  execute v_text;

  v_text := $rh5$-- Automation Phase 3 / Stage B, dispatcher side: the hand-off may now write outbox rows for AMC contracts.
--
-- Goes together with the Edge Function change in the SAME commit (wa-milestone-dispatch-core.ts: MILESTONE_REF_TYPES gains
-- 'amc_contract'; wa-event-context.ts resolves product, plan, expiry and visit date for it). Apply this migration ONLY after
-- those functions are deployed: a pending 'amc_contract' row the deployed dispatcher does not know would never be picked up.
-- It changes nothing else: a one-row insert into the hand-off whitelist, no function body, no schema.
insert into public.automation_handoff_ref_types (ref_type, subject_type)
values ('amc_contract', 'amc_contract')
on conflict (ref_type) do nothing;
$rh5$;
  v_hash := encode(sha256(convert_to(v_text, 'UTF8')), 'hex');
  if v_hash <> 'e2bf071eb94f9a6269c798e9aab04bd1a09a32742e5cde8b39796cfe8be386d3' then
    raise exception 'REHEARSAL_REFUSED: hash mismatch for 20261029130000_automation_handoff_amc_ref_type.sql: %', v_hash;
  end if;
  execute v_text;

  v_text := $rh6$-- Rolled-back DB tests for migration 20261017100000_automation_phase2_foundation (automation Phase 2).
-- Run AFTER the migration (the runner concatenates the migration in front of this file inside ONE transaction, so even the
-- DDL is rolled back). The block ends in RAISE; read RESULTS in the error. A throwaway __TEST_ organisation is created
-- inside the transaction; no real customer, number or message is touched, and nothing is sent (there is no sender here).
create temp table res (n serial, line text);
grant all on res to public;
grant usage on sequence res_n_seq to public;
create function pg_temp.chk(p_name text, p_ok boolean, p_info text default '') returns void language plpgsql as $f$
begin insert into pg_temp.res(line) values (case when coalesce(p_ok,false) then 'PASS  ' else 'FAIL  ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end); end $f$;
create function pg_temp.mkuser(p_role text, p_org uuid) returns uuid language plpgsql as $f$
declare v uuid := gen_random_uuid();
begin
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
  values (v, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '__t_' || p_role || '_' || v || '@test.invalid', 'x', now(), now(), now(), '{}', '{}');
  insert into public.profiles (id, org_id, full_name, role, is_active) values (v, p_org, '__TEST_ ' || p_role, p_role::public.user_role, true)
    on conflict (id) do update set role = excluded.role, is_active = true, org_id = excluded.org_id;
  return v;
end $f$;
create function pg_temp.as_user(p_uid uuid) returns void language plpgsql as $f$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true); execute 'set local role authenticated'; end $f$;
create function pg_temp.as_anon() returns void language plpgsql as $f$
begin perform set_config('request.jwt.claims', '', true); execute 'set local role anon'; end $f$;
create function pg_temp.as_pg() returns void language plpgsql as $f$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $f$;
-- run a statement; record a FAIL with the error text instead of aborting the whole test
create function pg_temp.try(p_name text, p_sql text) returns boolean language plpgsql as $f$
begin execute p_sql; return true;
exception when others then
  insert into pg_temp.res(line) values ('FAIL  ' || p_name || '  [' || sqlerrm || ']'); return false;
end $f$;
-- true when the statement raises
create function pg_temp.raises(p_sql text) returns text language plpgsql as $f$
begin execute p_sql; return null;
exception when others then return sqlerrm; end $f$;

do $t$
declare
  v_org uuid; v_org2 uuid; v_master uuid; v_master2 uuid; v_ops uuid; v_sales uuid; v_tp uuid; v_custrole uuid;
  v_cust uuid; v_cust_t uuid; v_ticket uuid; v_ticket_t uuid; v_tech uuid; v_brand uuid; v_model uuid; v_prod uuid; v_plan uuid;
  v_inv uuid; v_lead uuid; v_lead_t uuid; v_rule_c uuid; v_rule_n uuid; v_rule_k uuid; v_rule_paused uuid; v_rk uuid;
  v_ev uuid; v_mob text := '9400000077'; v_real text := '9400000066';
  n int; n2 int; s text; b boolean; rec record; fp_cust text; fp_out int; v_ver int; v_cur int;
  v_ob1 int; v_ob2 int; v_e1 int; v_e2 int; v_l uuid; v_tk2 uuid;
begin
  select md5(coalesce(string_agg(id::text||name||coalesce(mobile,''), ',' order by id),'')) into fp_cust
    from public.customers where org_id not in (select id from organizations where name like '\_\_TEST\_%');

  -- ---------- schema / privileges ----------
  perform pg_temp.chk('seven automation tables exist and have RLS enabled',
    (select count(*) from pg_class c where c.relnamespace = 'public'::regnamespace and c.relrowsecurity
       and c.relname in ('automation_events','automation_flow_defs','automation_rules','automation_event_log','automation_audit','automation_queue','automation_errors')) = 7);
  perform pg_temp.chk('automation_emit: not executable by PUBLIC / anon / authenticated, executable by service_role',
    not has_function_privilege('anon', 'public.automation_emit(uuid,text,text,uuid,uuid,text,jsonb)', 'execute')
    and not has_function_privilege('authenticated', 'public.automation_emit(uuid,text,text,uuid,uuid,text,jsonb)', 'execute')
    and has_function_privilege('service_role', 'public.automation_emit(uuid,text,text,uuid,uuid,text,jsonb)', 'execute')
    and not exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                    where p.oid = 'public.automation_emit(uuid,text,text,uuid,uuid,text,jsonb)'::regprocedure and a.grantee = 0));
  perform pg_temp.chk('automation_emit is SECURITY DEFINER with a fixed search_path',
    (select p.prosecdef and exists (select 1 from unnest(p.proconfig) c where c like 'search_path=%')
       from pg_proc p where p.oid = 'public.automation_emit(uuid,text,text,uuid,uuid,text,jsonb)'::regprocedure));
  perform pg_temp.chk('every emit trigger function is SECURITY DEFINER, fixed search_path, not executable by anon/authenticated',
    (select count(*) = 8 and bool_and(p.prosecdef and exists (select 1 from unnest(p.proconfig) c where c like 'search_path=%')
        and not has_function_privilege('anon', p.oid, 'execute') and not has_function_privilege('authenticated', p.oid, 'execute'))
       from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname like '\_trg\_automation\_emit\_%'));
  perform pg_temp.chk('no client write privilege on any automation table; anon cannot read them',
    not exists (select 1 from unnest(array['automation_events','automation_flow_defs','automation_rules','automation_event_log','automation_audit','automation_queue','automation_errors']) t,
                     unnest(array['anon','authenticated']) r, unnest(array['INSERT','UPDATE','DELETE','TRUNCATE']) pr
                where has_table_privilege(r, 'public.' || t, pr))
    and not exists (select 1 from unnest(array['automation_events','automation_flow_defs','automation_rules','automation_event_log','automation_audit','automation_queue','automation_errors']) t
                where has_table_privilege('anon', 'public.' || t, 'SELECT')));
  perform pg_temp.chk('automation_rule_save: authenticated + service_role only',
    has_function_privilege('authenticated', 'public.automation_rule_save(uuid,text,text,text,jsonb,text,text,integer,integer,integer,text,uuid,text,text,boolean,integer)', 'execute')
    and not has_function_privilege('anon', 'public.automation_rule_save(uuid,text,text,text,jsonb,text,text,integer,integer,integer,text,uuid,text,text,boolean,integer)', 'execute'));
  perform pg_temp.chk('catalogue holds the events the owner named (AMC join/end, spare + product enquiry) and every group',
    (select count(*) from public.automation_events where event_key in ('amc.joined','amc.expired','amc.expiring','spare_enquiry.submitted','product_enquiry.submitted','review.google_requested')) = 6
    and (select count(distinct group_key) from public.automation_events) >= 8
    and (select count(*) from public.automation_events) >= 60);
  -- Phase 2 asserted that technician.on_the_way had NO emitter. Stage B (migration 20261029120000, start_travel) adds the
  -- departure signal, so the visit-start event is still technician.arrived and on_the_way now has its own emitter.
  perform pg_temp.chk('technician.arrived has an emitter (visit start); on_the_way is emitted only by start_travel, never by the visit insert',
    (select has_emitter from public.automation_events where event_key = 'technician.arrived')
    and (select prosrc ~ 'automation_emit\(new\.org_id, ''technician\.arrived''' and prosrc !~ 'automation_emit\([^;]*''technician\.on_the_way'''
           from pg_proc where proname = '_trg_automation_emit_visit' and pronamespace = 'public'::regnamespace));
  perform pg_temp.chk('automation is enabled by default and the F-08 allow-list is OFF by default',
    (select column_default from information_schema.columns where table_name = 'settings' and column_name = 'automation_enabled') = 'true'
    and (select column_default from information_schema.columns where table_name = 'settings' and column_name = 'wa_test_mode_enabled') = 'false');
  perform pg_temp.chk('conditions: equality, any-of, min/max, missing key',
    public._automation_conditions_match('{"t":"paid"}', '{"t":"paid"}')
    and not public._automation_conditions_match('{"t":"paid"}', '{"t":"amc"}')
    and public._automation_conditions_match('{"t":["paid","amc"]}', '{"t":"amc"}')
    and public._automation_conditions_match('{"min_total":100,"max_total":500}', '{"total":250}')
    and not public._automation_conditions_match('{"min_total":100}', '{"total":50}')
    and not public._automation_conditions_match('{"x":"1"}', '{}')
    and public._automation_conditions_match('{}', '{"a":1}'));

  -- ---------- throwaway org ----------
  insert into organizations (name) values ('__TEST_automation_p2') returning id into v_org;
  insert into organizations (name) values ('__TEST_automation_p2_other') returning id into v_org2;
  insert into settings (org_id) values (v_org) on conflict (org_id) do nothing;
  insert into settings (org_id) values (v_org2) on conflict (org_id) do nothing;
  v_master := pg_temp.mkuser('master', v_org);
  v_master2 := pg_temp.mkuser('master', v_org2);
  v_ops := pg_temp.mkuser('operation_admin', v_org);
  v_sales := pg_temp.mkuser('sales_admin', v_org);
  v_tp := pg_temp.mkuser('technician', v_org);
  v_custrole := pg_temp.mkuser('customer', v_org);
  insert into technicians (org_id, profile_id, is_active) values (v_org, v_tp, true) returning id into v_tech;
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ Real-ish', v_real) returning id into v_cust;
  insert into customers (org_id, name, mobile, is_test) values (v_org, '__TEST_ Flagged', v_mob, true) returning id into v_cust_t;
  insert into brands (org_id, name, category) values (v_org, '__TEST_ brand', 'ro') returning id into v_brand;
  insert into models (org_id, brand_id, name) values (v_org, v_brand, '__TEST_ model') returning id into v_model;
  insert into products (org_id, name, category, brand_id, model_id, price) values (v_org, '__TEST_ RO', 'ro', v_brand, v_model, 10000) returning id into v_prod;
  insert into amc_plans (org_id, name, years, price, visits_per_year) values (v_org, '__TEST_ Silver', 1, 3000, 1) returning id into v_plan;

  -- ---------- rules: master saves; others cannot ----------
  perform pg_temp.as_user(v_master);
  v_rule_c := public.automation_rule_save(null, 'ticket.completed', 'customer', 'whatsapp', '{"ticket_type":"paid"}', 'gvm_service_completed_en', 'en', 0, 0, null, 'live');
  v_rule_n := public.automation_rule_save(null, 'ticket.completed', 'customer', 'whatsapp', '{"ticket_type":"warranty"}', 'gvm_service_completed_en', 'en', 0, 0, null, 'live');
  v_rule_k := public.automation_rule_save(null, 'ticket.completed', 'operations', 'in_app', '{}', null, null, 0, 0, null, 'test_only');
  v_rule_paused := public.automation_rule_save(null, 'ticket.completed', 'sales', 'in_app', '{}', null, null, 0, 0, null, 'paused');
  perform pg_temp.chk('master saved four rules (version 1, current)',
    (select count(*) from public.automation_rules where org_id = v_org and version = 1 and is_current) = 4);
  perform pg_temp.chk('rule save writes a config_changed audit row each',
    (select count(*) from public.automation_audit where org_id = v_org and decision = 'config_changed') = 4);
  s := pg_temp.raises(format($q$select public.automation_rule_save(null, 'amc.expiring', 'technician', 'whatsapp')$q$));
  perform pg_temp.chk('rule for a recipient the event does not support is refused', s like '%does not support recipient%', coalesce(s,'accepted'));
  s := pg_temp.raises($q$select public.automation_rule_save(null, 'no.such_event', 'customer', 'whatsapp')$q$);
  perform pg_temp.chk('rule for an unknown event is refused', s like '%unknown event%', coalesce(s,'accepted'));
  perform pg_temp.as_user(v_sales);
  s := pg_temp.raises($q$select public.automation_rule_save(null, 'ticket.completed', 'customer', 'whatsapp')$q$);
  perform pg_temp.chk('sales_admin cannot save a rule', s like '%only the master%', coalesce(s,'accepted'));
  perform pg_temp.as_user(v_ops);
  s := pg_temp.raises($q$select public.automation_rule_save(null, 'ticket.completed', 'customer', 'whatsapp')$q$);
  perform pg_temp.chk('operation_admin cannot save a rule', s like '%only the master%', coalesce(s,'accepted'));
  perform pg_temp.as_user(v_tp);
  s := pg_temp.raises($q$select public.automation_rule_save(null, 'ticket.completed', 'customer', 'whatsapp')$q$);
  perform pg_temp.chk('technician cannot save a rule', s like '%only the master%', coalesce(s,'accepted'));
  perform pg_temp.as_user(v_custrole);
  s := pg_temp.raises($q$select public.automation_rule_save(null, 'ticket.completed', 'customer', 'whatsapp')$q$);
  perform pg_temp.chk('customer role cannot save a rule', s like '%only the master%', coalesce(s,'accepted'));
  perform pg_temp.as_anon();
  s := pg_temp.raises($q$select public.automation_rule_save(null, 'ticket.completed', 'customer', 'whatsapp')$q$);
  perform pg_temp.chk('anon cannot call automation_rule_save', s like '%permission denied%', coalesce(s,'accepted'));
  s := pg_temp.raises(format($q$select public.automation_emit(%L, 'ticket.created', 'ticket', gen_random_uuid())$q$, v_org));
  perform pg_temp.chk('anon cannot call automation_emit', s like '%permission denied%', coalesce(s,'accepted'));
  perform pg_temp.as_user(v_master);
  s := pg_temp.raises(format($q$select public.automation_emit(%L, 'ticket.created', 'ticket', gen_random_uuid())$q$, v_org));
  perform pg_temp.chk('even the master (authenticated) cannot call automation_emit directly', s like '%permission denied%', coalesce(s,'accepted'));
  perform pg_temp.as_pg();

  -- ---------- every existing event is audited (no rule needed): one event_log row each ----------
  -- tickets (rules exist for ticket.completed only; the other ticket events have none -> outcome no_rule)
  insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (v_org, v_cust, 'paid', '__TEST_ real ticket') returning id into v_ticket;
  insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (v_org, v_cust_t, 'paid', '__TEST_ flagged ticket') returning id into v_ticket_t;
  select count(*) into n from public.automation_event_log where org_id = v_org and event_key = 'ticket.created';
  perform pg_temp.chk('ticket.created: one event_log row per ticket, even with no matching rule', n = 2, n::text);
  perform pg_temp.chk('ticket.created rows say no_rule and carry the right test tag',
    (select count(*) from public.automation_event_log where org_id = v_org and event_key = 'ticket.created' and outcome = 'no_rule') = 2
    and (select is_test from public.automation_event_log where org_id = v_org and event_key = 'ticket.created' and subject_id = v_ticket_t)
    and not (select is_test from public.automation_event_log where org_id = v_org and event_key = 'ticket.created' and subject_id = v_ticket));

  update service_tickets set status = 'assigned' where id in (v_ticket, v_ticket_t);
  select count(*) into n from public.automation_event_log where org_id = v_org and event_key = 'ticket.assigned';
  perform pg_temp.chk('ticket.assigned: one row per ticket', n = 2, n::text);

  -- visits
  perform pg_temp.try('visit insert (real)', format($q$insert into service_visits (org_id, ticket_id, technician_id) values (%L, %L, %L)$q$, v_org, v_ticket, v_tech));
  select count(*) into n from public.automation_event_log where org_id = v_org and event_key = 'technician.arrived' and subject_type = 'visit';
  perform pg_temp.chk('technician.arrived emitted on visit insert', n = 1, n::text);
  perform pg_temp.chk('technician.on_the_way never emitted',
    not exists (select 1 from public.automation_event_log where org_id = v_org and event_key = 'technician.on_the_way'));

  -- completion: real ticket (paid) and flagged ticket (paid) -> 4 rules each
  update service_tickets set status = 'completed' where id = v_ticket;
  update service_tickets set status = 'completed' where id = v_ticket_t;
  select count(*) into n from public.automation_event_log where org_id = v_org and event_key = 'ticket.completed';
  perform pg_temp.chk('ticket.completed: one row per ticket', n = 2, n::text);

  -- rule that matches / does not match
  select decision into s from public.automation_audit where org_id = v_org and subject_id = v_ticket and rule_id = v_rule_c and event_key = 'ticket.completed';
  perform pg_temp.chk('MATCHING rule (live, ticket_type=paid) on the real customer -> dry_run', s = 'dry_run', coalesce(s, 'no row'));
  select decision into s from public.automation_audit where org_id = v_org and subject_id = v_ticket and rule_id = v_rule_n and event_key = 'ticket.completed';
  perform pg_temp.chk('NON-matching rule (ticket_type=warranty) -> skipped_condition', s = 'skipped_condition', coalesce(s, 'no row'));
  select decision into s from public.automation_audit where org_id = v_org and subject_id = v_ticket and rule_id = v_rule_k and event_key = 'ticket.completed';
  perform pg_temp.chk('test_only rule on a REAL customer -> skipped_test_only (never queued)', s = 'skipped_test_only', coalesce(s, 'no row'));
  select decision into s from public.automation_audit where org_id = v_org and subject_id = v_ticket_t and rule_id = v_rule_k and event_key = 'ticket.completed';
  perform pg_temp.chk('test_only rule on the FLAGGED customer -> dry_run', s = 'dry_run', coalesce(s, 'no row'));
  select decision into s from public.automation_audit where org_id = v_org and subject_id = v_ticket and rule_id = v_rule_paused and event_key = 'ticket.completed';
  perform pg_temp.chk('paused rule -> skipped_paused', s = 'skipped_paused', coalesce(s, 'no row'));
  perform pg_temp.chk('every considered rule has an audit row (4 rules x 2 events = 8)',
    (select count(*) from public.automation_audit where org_id = v_org and event_key = 'ticket.completed' and decision <> 'config_changed') = 8);
  perform pg_temp.chk('event_log counts: considered 4, queued as dry_run',
    (select rules_considered = 4 and outcome = 'processed' from public.automation_event_log where org_id = v_org and event_key = 'ticket.completed' and subject_id = v_ticket));
  perform pg_temp.chk('queue rows only ever dry_run, never a deliverable state',
    not exists (select 1 from public.automation_queue where org_id = v_org and state not in ('dry_run','blocked_not_allowlisted')));
  s := pg_temp.raises(format($q$insert into public.automation_queue (org_id, idempotency_key, rule_id, rule_key, rule_version, event_id, event_key, subject_type, subject_id, recipient_role, channel, fire_at, state)
        values (%L, 'x', gen_random_uuid(), gen_random_uuid(), 1, gen_random_uuid(), 'a.b', 'ticket', gen_random_uuid(), 'customer', 'whatsapp', now(), 'pending')$q$, v_org));
  perform pg_temp.chk('queue CHECK refuses a "pending"/deliverable state', s like '%check constraint%', coalesce(s,'accepted'));

  -- ---------- test-flag isolation ----------
  perform pg_temp.chk('flagged customer events and queue rows are tagged is_test',
    (select bool_and(is_test) from public.automation_queue where org_id = v_org and subject_id = v_ticket_t)
    and (select bool_and(is_test) from public.automation_audit where org_id = v_org and subject_id = v_ticket_t and decision <> 'config_changed'));
  perform pg_temp.chk('nothing for a test subject is addressed anywhere but the test number',
    not exists (select 1 from public.automation_queue q where q.org_id = v_org and q.is_test
                  and q.recipient_masked is not null and q.recipient_masked <> '******' || right(v_mob, 4)));
  perform pg_temp.chk('the real customer queue row is addressed to the real (masked) number only',
    (select recipient_masked from public.automation_queue where org_id = v_org and subject_id = v_ticket and rule_id = v_rule_c) = '******' || right(v_real, 4));
  perform pg_temp.chk('no full phone number is stored in queue or audit',
    not exists (select 1 from public.automation_queue where org_id = v_org and recipient_masked ~ '[0-9]{7,}')
    and not exists (select 1 from public.automation_audit where org_id = v_org and recipient_masked ~ '[0-9]{7,}'));

  -- a flagged lead (by mobile) pointed at a real number is blocked even with test mode OFF
  insert into leads (org_id, name, mobile, source, status, kind) values (v_org, '__TEST_ L by mobile', '+91 ' || v_mob, 'field', 'new', 'service') returning id into v_lead_t;
  perform pg_temp.chk('lead sharing the test number is flagged is_test (existing sync) and logged lead.created is_test',
    (select is_test from leads where id = v_lead_t)
    and (select is_test from public.automation_event_log where org_id = v_org and subject_id = v_lead_t and event_key = 'lead.created'));
  perform pg_temp.as_user(v_master);
  v_rk := public.automation_rule_save(null, 'lead.created', 'customer', 'whatsapp', '{}', 'gvm_lead_welcome_en', 'en', 0, 0, null, 'live');
  perform pg_temp.as_pg();
  -- (changed for migration 20261026110000: a customer rule needs a customer record, so the probes now pass one. The lead is the
  -- flagged test lead; the customer is the real-number one, then the flagged test one)
  v_ev := public.automation_emit(v_org, 'lead.created', 'lead', v_lead_t, v_cust, 'probe-real-dest', jsonb_build_object('mobile', v_real));
  select decision, detail ->> 'reason' as reason into rec from public.automation_audit where event_id = v_ev and rule_id = v_rk;
  perform pg_temp.chk('test subject aimed at a NON-test number is blocked (hard stop, test mode OFF)',
    rec.decision = 'blocked_not_allowlisted' and rec.reason = 'test_subject_destination_not_a_test_number', coalesce(rec.decision,'-') || '/' || coalesce(rec.reason,'-'));
  v_ev := public.automation_emit(v_org, 'lead.created', 'lead', v_lead_t, v_cust_t, 'probe-test-dest', jsonb_build_object('mobile', v_mob));
  select decision into s from public.automation_audit where event_id = v_ev and rule_id = v_rk;
  perform pg_temp.chk('test subject aimed at the test number is allowed (dry_run)', s = 'dry_run', coalesce(s,'-'));
  -- migration 20261026110000: a customer rule with no customer record is refused, and the payload number is not used
  v_ev := public.automation_emit(v_org, 'lead.created', 'lead', v_lead_t, null, 'probe-no-customer', jsonb_build_object('mobile', v_mob));
  select decision, detail ->> 'reason' as reason into rec from public.automation_audit where event_id = v_ev and rule_id = v_rk;
  perform pg_temp.chk('customer rule with no customer record is skipped_no_recipient / no_customer_record (payload number not used)',
    rec.decision = 'skipped_no_recipient' and rec.reason = 'no_customer_record', coalesce(rec.decision,'-') || '/' || coalesce(rec.reason,'-'));
  perform pg_temp.chk('and no queue row was written for it',
    not exists (select 1 from public.automation_queue where event_id = v_ev));

  -- ---------- allow-list (F-08 setting, reused) ----------
  select count(*) into n from public.audit_log where org_id = v_org and action = 'WA_SEND_BLOCKED';
  update settings set wa_test_mode_enabled = true, wa_test_allowed_numbers = array[v_mob] where org_id = v_org;
  v_ev := public.automation_emit(v_org, 'ticket.completed', 'ticket', v_ticket, v_cust, 'allowlist-probe', jsonb_build_object('ticket_type', 'paid'));
  select decision, detail ->> 'reason' as reason into rec from public.automation_audit where event_id = v_ev and rule_id = v_rule_c;
  perform pg_temp.chk('allow-list ON: non-test number not on the list -> blocked_not_allowlisted',
    rec.decision = 'blocked_not_allowlisted' and rec.reason = 'test_mode_not_allow_listed', coalesce(rec.decision,'-'));
  perform pg_temp.chk('blocked queue row is state blocked_not_allowlisted and counted as not queued',
    (select state from public.automation_queue where event_id = v_ev and rule_id = v_rule_c) = 'blocked_not_allowlisted'
    and (select rules_queued from public.automation_event_log where id = v_ev) = 0);
  select count(*) into n2 from public.audit_log where org_id = v_org and action = 'WA_SEND_BLOCKED';
  perform pg_temp.chk('block is logged in audit_log with last four digits only',
    n2 = n + 1
    and not exists (select 1 from public.audit_log where org_id = v_org and action = 'WA_SEND_BLOCKED' and after::text ~ '[0-9]{7,}'));
  v_ev := public.automation_emit(v_org, 'ticket.completed', 'ticket', v_ticket_t, v_cust_t, 'allowlist-probe', jsonb_build_object('ticket_type', 'paid'));
  select decision into s from public.automation_audit where event_id = v_ev and rule_id = v_rule_c;
  perform pg_temp.chk('allow-list ON: the test number itself passes (dry_run)', s = 'dry_run', coalesce(s,'-'));
  update settings set wa_test_allowed_numbers = array[v_mob, v_real] where org_id = v_org;
  v_ev := public.automation_emit(v_org, 'ticket.completed', 'ticket', v_ticket, v_cust, 'allowlist-probe-2', jsonb_build_object('ticket_type', 'paid'));
  select decision into s from public.automation_audit where event_id = v_ev and rule_id = v_rule_c;
  perform pg_temp.chk('allow-list ON: a listed number passes', s = 'dry_run', coalesce(s,'-'));
  update settings set wa_test_mode_enabled = false, wa_test_allowed_numbers = '{}' where org_id = v_org;
  v_ev := public.automation_emit(v_org, 'ticket.completed', 'ticket', v_ticket, v_cust, 'allowlist-probe-3', jsonb_build_object('ticket_type', 'paid'));
  select decision into s from public.automation_audit where event_id = v_ev and rule_id = v_rule_c;
  perform pg_temp.chk('allow-list OFF (default): not blocked, still only a dry_run', s = 'dry_run', coalesce(s,'-'));

  -- ---------- duplicate emit idempotency ----------
  select count(*) into n from public.automation_queue where org_id = v_org and subject_id = v_ticket and rule_id = v_rule_c;
  v_ev := public.automation_emit(v_org, 'ticket.completed', 'ticket', v_ticket, v_cust, 'completed', jsonb_build_object('ticket_type', 'paid'));
  select count(*) into n2 from public.automation_queue where org_id = v_org and subject_id = v_ticket and rule_id = v_rule_c;
  perform pg_temp.chk('re-emitting the same event/subject/occurrence adds NO queue row', n2 = n, n::text || ' -> ' || n2::text);
  select decision into s from public.automation_audit where event_id = v_ev and rule_id = v_rule_c;
  perform pg_temp.chk('the repeat is audited as skipped_duplicate and the event log still has the entry',
    s = 'skipped_duplicate' and (select outcome from public.automation_event_log where id = v_ev) in ('duplicate', 'processed'),
    coalesce(s,'-'));
  v_ev := public.automation_emit(v_org, 'ticket.completed', 'ticket', v_ticket, v_cust, 'completed', jsonb_build_object('ticket_type', 'paid'));
  perform pg_temp.chk('a flip-flopped status (trigger fires again) cannot re-notify either',
    (select count(*) from public.automation_queue where org_id = v_org and subject_id = v_ticket and rule_id = v_rule_c and idempotency_key like '%|completed|live|-') = 1);

  -- ---------- rule versions: an edit never re-fires old occurrences ----------
  perform pg_temp.as_user(v_master);
  v_rk := (select rule_key from public.automation_rules where id = v_rule_c);
  v_rule_c := public.automation_rule_save(v_rk, 'ticket.completed', 'customer', 'whatsapp', '{"ticket_type":"paid"}', 'gvm_service_completed_en', 'en', 0, 0, null, 'live', null, 'v2');
  perform pg_temp.as_pg();
  select count(*) filter (where is_current), max(version) into v_cur, v_ver from public.automation_rules where org_id = v_org and rule_key = v_rk;
  perform pg_temp.chk('editing a rule inserts version 2 and leaves exactly one current', v_cur = 1 and v_ver = 2);
  select count(*) into n from public.automation_queue where org_id = v_org and subject_id = v_ticket and rule_key = v_rk;
  v_ev := public.automation_emit(v_org, 'ticket.completed', 'ticket', v_ticket, v_cust, 'completed', jsonb_build_object('ticket_type', 'paid'));
  select count(*) into n2 from public.automation_queue where org_id = v_org and subject_id = v_ticket and rule_key = v_rk;
  perform pg_temp.chk('version 2 does not re-fire an occurrence version 1 already handled', n = n2);

  -- ---------- cooldown / max fires ----------
  perform pg_temp.as_user(v_master);
  v_rk := public.automation_rule_save(null, 'invoice.issued', 'customer', 'whatsapp', '{}', null, null, 0, 24, null, 'live');
  v_rule_n := public.automation_rule_save(null, 'invoice.paid', 'customer', 'whatsapp', '{}', null, null, 0, 0, 1, 'live');
  perform pg_temp.as_pg();
  v_ev := public.automation_emit(v_org, 'invoice.issued', 'invoice', gen_random_uuid(), v_cust, 'a', '{}');
  v_ev := public.automation_emit(v_org, 'invoice.issued', 'invoice', gen_random_uuid(), v_cust, 'a', '{}');
  perform pg_temp.chk('cooldown: second send to the same customer inside the window -> skipped_cooldown',
    (select count(*) from public.automation_audit where org_id = v_org and event_id = v_ev and decision = 'skipped_cooldown') = 1);
  v_inv := gen_random_uuid();
  v_ev := public.automation_emit(v_org, 'invoice.paid', 'invoice', v_inv, v_cust, 'paid-1', '{}');
  v_ev := public.automation_emit(v_org, 'invoice.paid', 'invoice', v_inv, v_cust, 'paid-2', '{}');
  perform pg_temp.chk('max_fires=1: second occurrence for the same subject -> skipped_max_fires',
    (select count(*) from public.automation_audit where org_id = v_org and event_id = v_ev and decision = 'skipped_max_fires') = 1);

  -- ---------- global kill switch + unknown event ----------
  update settings set automation_enabled = false where org_id = v_org;
  select count(*) into n from public.automation_audit where org_id = v_org;
  select count(*) into n2 from public.automation_queue where org_id = v_org;
  v_ev := public.automation_emit(v_org, 'ticket.completed', 'ticket', gen_random_uuid(), v_cust, 'kill-1', jsonb_build_object('ticket_type', 'paid'));
  perform pg_temp.chk('global OFF: event is still logged (global_off) but nothing is audited or queued',
    (select outcome from public.automation_event_log where id = v_ev) = 'global_off'
    and (select count(*) from public.automation_audit where org_id = v_org) = n
    and (select count(*) from public.automation_queue where org_id = v_org) = n2);
  update settings set automation_enabled = true where org_id = v_org;
  v_ev := public.automation_emit(v_org, 'not.an_event', 'ticket', gen_random_uuid(), null, '', '{}');
  perform pg_temp.chk('unknown event key is logged as unknown_event, not rejected',
    (select outcome from public.automation_event_log where id = v_ev) = 'unknown_event');

  -- ---------- more existing emitters (each logged once, no rule required) ----------
  insert into invoices (org_id, customer_id, type, subtotal, total, payment_status) values (v_org, v_cust, 'product', 100, 100, 'due') returning id into v_inv;
  update invoices set payment_status = 'partial', amount_paid = 40 where id = v_inv;
  update invoices set payment_status = 'paid', amount_paid = 100 where id = v_inv;
  perform pg_temp.chk('invoice.issued / partial / paid each logged once',
    (select count(*) from public.automation_event_log where org_id = v_org and subject_id = v_inv and event_key = 'invoice.issued') = 1
    and (select count(*) from public.automation_event_log where org_id = v_org and subject_id = v_inv and event_key = 'invoice.partial') = 1
    and (select count(*) from public.automation_event_log where org_id = v_org and subject_id = v_inv and event_key = 'invoice.paid') = 1);

  insert into leads (org_id, customer_id, name, mobile, source, status, kind) values (v_org, v_cust, '__TEST_ L product', '9400000055', 'customer_app', 'new', 'product') returning id into v_lead;
  insert into leads (org_id, customer_id, name, mobile, source, status, kind) values (v_org, v_cust, '__TEST_ L spare', '9400000054', 'customer_app', 'new', 'spare');
  perform pg_temp.chk('product lead -> lead.created + product_enquiry.submitted; spare lead -> spare_enquiry.submitted',
    (select count(*) from public.automation_event_log where org_id = v_org and event_key = 'product_enquiry.submitted' and subject_id = v_lead) = 1
    and (select count(*) from public.automation_event_log where org_id = v_org and event_key = 'spare_enquiry.submitted') = 1
    and (select count(*) from public.automation_event_log where org_id = v_org and event_key = 'lead.created' and subject_id = v_lead) = 1);
  update leads set status = 'contacted' where id = v_lead;
  update leads set status = 'quoted' where id = v_lead;
  update leads set status = 'lost', lost_reason = '__TEST_' where id = v_lead;
  perform pg_temp.chk('lead stage changes logged per stage', (select count(*) from public.automation_event_log where org_id = v_org and subject_id = v_lead and event_key in ('lead.stage.contacted','lead.stage.quoted','lead.stage.lost')) = 3);
  insert into leads (org_id, customer_id, name, mobile, source, status, kind) values (v_org, v_cust, '__TEST_ L assign', '9400000053', 'customer_app', 'new', 'service') returning id into v_inv;
  perform pg_temp.as_user(v_master);
  perform public.assign_lead(v_inv, v_sales, 'test');
  perform pg_temp.as_pg();
  perform pg_temp.chk('lead sales-person change logs lead.assigned',
    (select count(*) from public.automation_event_log where org_id = v_org and subject_id = v_inv and event_key = 'lead.assigned') >= 1);

  if pg_temp.try('amc contract insert', format($q$insert into amc_contracts (org_id, customer_id, product_id, plan_id, start_date, expiry_date, status) values (%L, %L, %L, %L, current_date, current_date + 365, 'active')$q$, v_org, v_cust, v_prod, v_plan)) then
    perform pg_temp.chk('amc.joined logged', (select count(*) from public.automation_event_log where org_id = v_org and event_key = 'amc.joined') = 1);
    update amc_contracts set status = 'expired' where org_id = v_org and customer_id = v_cust;
    perform pg_temp.chk('amc.expired logged on status change', (select count(*) from public.automation_event_log where org_id = v_org and event_key = 'amc.expired') = 1);
  end if;
  if pg_temp.try('warranty insert', format($q$insert into warranties (org_id, customer_id, product_id, start_date, expiry_date) values (%L, %L, %L, current_date, current_date + 365)$q$, v_org, v_cust, v_prod)) then
    perform pg_temp.chk('warranty.started logged', (select count(*) from public.automation_event_log where org_id = v_org and event_key = 'warranty.started') = 1);
  end if;
  if pg_temp.try('quotation insert', format($q$insert into quotations (org_id, customer_id, status, total) values (%L, %L, 'open', 500)$q$, v_org, v_cust)) then
    update quotations set status = 'converted' where org_id = v_org and customer_id = v_cust;
    perform pg_temp.chk('quotation.created and quotation.converted logged',
      (select count(*) from public.automation_event_log where org_id = v_org and event_key in ('quotation.created','quotation.converted')) = 2);
  end if;
  update service_tickets set status = 'cancelled' where id = (select id from service_tickets where org_id = v_org and status = 'open' limit 1);
  insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (v_org, v_cust, 'paid', '__TEST_ to cancel') returning id into v_ticket;
  update service_tickets set status = 'cancelled' where id = v_ticket;
  perform pg_temp.chk('ticket.cancelled logged', (select count(*) from public.automation_event_log where org_id = v_org and event_key = 'ticket.cancelled' and subject_id = v_ticket) = 1);

  perform pg_temp.chk('payload VALUES are never stored in the event log (keys only)',
    not exists (select 1 from public.automation_event_log where org_id = v_org and payload_keys::text ~ '[0-9]{7,}'));

  -- ---------- triggers fire only on the intended changes ----------
  perform pg_temp.chk('trigger definitions: column-limited UPDATE OF, and insert-only where intended',
    (select count(*) = 8 from pg_trigger where tgname like 'zz\_automation\_emit\_%' and not tgisinternal)
    and pg_get_triggerdef((select oid from pg_trigger where tgname = 'zz_automation_emit_ticket')) ~ 'AFTER INSERT OR UPDATE OF status ON'
    and pg_get_triggerdef((select oid from pg_trigger where tgname = 'zz_automation_emit_invoice')) ~ 'AFTER INSERT OR UPDATE OF payment_status ON'
    and pg_get_triggerdef((select oid from pg_trigger where tgname = 'zz_automation_emit_lead')) ~ 'AFTER INSERT OR UPDATE OF status, assigned_to ON'
    and pg_get_triggerdef((select oid from pg_trigger where tgname = 'zz_automation_emit_amc')) ~ 'AFTER INSERT OR UPDATE OF status ON'
    and pg_get_triggerdef((select oid from pg_trigger where tgname = 'zz_automation_emit_quotation')) ~ 'AFTER INSERT OR UPDATE OF status ON'
    and pg_get_triggerdef((select oid from pg_trigger where tgname = 'zz_automation_emit_visit')) !~ 'UPDATE'
    and pg_get_triggerdef((select oid from pg_trigger where tgname = 'zz_automation_emit_warranty')) !~ 'UPDATE'
    and pg_get_triggerdef((select oid from pg_trigger where tgname = 'zz_automation_emit_amc_visit')) !~ 'UPDATE');
  insert into leads (org_id, customer_id, name, mobile, source, status, kind) values (v_org, v_cust, '__TEST_ L specificity', '9400000052', 'customer_app', 'new', 'service') returning id into v_l;
  insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (v_org, v_cust, 'paid', '__TEST_ specificity') returning id into v_tk2;
  select count(*) into v_e1 from public.automation_event_log where org_id = v_org;
  update leads set notes = '__TEST_ note' where id = v_l;
  update leads set name = name, mobile = mobile, status = status where id = v_l;
  update service_tickets set name_of_complaint = '__TEST_ renamed' where id = v_tk2;
  update service_tickets set status = status, priority = priority where id = v_tk2;
  update invoices set total = total, discount = discount, payment_status = payment_status where id = v_inv;
  update customers set name = name where id = v_cust;
  update amc_contracts set next_service_date = next_service_date, status = status where org_id = v_org;
  select count(*) into v_e2 from public.automation_event_log where org_id = v_org;
  perform pg_temp.chk('updates that change no emitting column, and repeated no-op UPDATEs, emit nothing', v_e1 = v_e2, v_e1::text || ' -> ' || v_e2::text);
  update leads set status = 'contacted' where id = v_l;
  select count(*) into v_e1 from public.automation_event_log where org_id = v_org;
  perform pg_temp.chk('a real stage change emits exactly one event',
    v_e1 = v_e2 + 1 and (select count(*) from public.automation_event_log where org_id = v_org and subject_id = v_l and event_key = 'lead.stage.contacted') = 1);
  update leads set status = 'contacted' where id = v_l;
  update leads set status = 'contacted', notes = '__TEST_ again' where id = v_l;
  select count(*) into v_e2 from public.automation_event_log where org_id = v_org;
  perform pg_temp.chk('repeating the same stage UPDATE emits nothing', v_e1 = v_e2, v_e1::text || ' -> ' || v_e2::text);
  update service_tickets set status = 'assigned' where id = v_tk2;
  update service_tickets set status = 'assigned' where id = v_tk2;
  perform pg_temp.chk('a repeated ticket status UPDATE emits once',
    (select count(*) from public.automation_event_log where org_id = v_org and subject_id = v_tk2 and event_key = 'ticket.assigned') = 1);
  update service_tickets set status = 'in_progress' where id = v_tk2;
  perform pg_temp.chk('a status the catalogue has no event for (in_progress) emits nothing',
    (select count(*) from public.automation_event_log where org_id = v_org and subject_id = v_tk2) = 2);

  -- ---------- nothing delivered: the engine never touches the outbox ----------
  select count(*) into v_ob1 from public.whatsapp_outbox where org_id = v_org;
  perform public.automation_emit(v_org, 'ticket.completed', 'ticket', gen_random_uuid(), v_cust, 'outbox-probe', jsonb_build_object('ticket_type', 'paid'));
  perform public.automation_emit(v_org, 'lead.created', 'lead', v_lead_t, null, 'outbox-probe', jsonb_build_object('mobile', v_mob));
  select count(*) into v_ob2 from public.whatsapp_outbox where org_id = v_org;
  perform pg_temp.chk('automation_emit wrote nothing to whatsapp_outbox (no send path)', v_ob1 = v_ob2, v_ob1::text || ' -> ' || v_ob2::text);
  perform pg_temp.chk('wa_dispatch_v2_enabled untouched by the migration (still its default / not set true here)',
    not coalesce((select wa_dispatch_v2_enabled from settings where org_id = v_org), false));

  -- ---------- append-only ----------
  s := pg_temp.raises(format($q$update public.automation_event_log set outcome = 'no_rule' where org_id = %L$q$, v_org));
  perform pg_temp.chk('event_log: UPDATE refused (owner)', s like '%append-only%', coalesce(s,'accepted'));
  s := pg_temp.raises(format($q$delete from public.automation_audit where org_id = %L$q$, v_org));
  perform pg_temp.chk('audit: DELETE refused (owner)', s like '%append-only%', coalesce(s,'accepted'));
  s := pg_temp.raises($q$truncate public.automation_event_log$q$);
  perform pg_temp.chk('event_log: TRUNCATE refused', s like '%append-only%', coalesce(s,'accepted'));
  s := pg_temp.raises($q$truncate public.automation_audit$q$);
  perform pg_temp.chk('audit: TRUNCATE refused', s like '%append-only%', coalesce(s,'accepted'));
  execute 'set local role service_role';
  s := pg_temp.raises(format($q$update public.automation_audit set decision = 'dry_run' where org_id = %L$q$, v_org));
  perform pg_temp.chk('audit: UPDATE refused even for service_role', s is not null, coalesce(s,'accepted'));
  perform pg_temp.as_pg();
  s := pg_temp.raises(format($q$update public.automation_rules set conditions = '{}' where org_id = %L$q$, v_org));
  perform pg_temp.chk('rules: in-place edit refused (immutable versions)', s like '%immutable%', coalesce(s,'accepted'));
  s := pg_temp.raises(format($q$delete from public.automation_rules where org_id = %L$q$, v_org));
  perform pg_temp.chk('rules: DELETE refused', s like '%immutable%', coalesce(s,'accepted'));

  -- ---------- deleting an author's profile must not be blocked by rule immutability ----------
  v_ops := pg_temp.mkuser('master', v_org);
  perform pg_temp.as_user(v_ops);
  v_rk := public.automation_rule_save(null, 'invoice.partial', 'customer', 'whatsapp', '{}', null, null, 0, 0, null, 'paused');
  perform pg_temp.as_pg();
  if pg_temp.try('delete author profile', format($q$delete from public.profiles where id = %L$q$, v_ops)) then
    perform pg_temp.chk('rule survives its author being deleted, created_by set to NULL',
      (select created_by is null from public.automation_rules where id = v_rk));
  end if;
  v_ops := pg_temp.mkuser('operation_admin', v_org);

  -- ---------- RLS: who can read what ----------
  perform pg_temp.as_user(v_master);
  select count(*) into n from public.automation_event_log;
  select count(*) into n2 from public.automation_audit where org_id <> v_org;
  perform pg_temp.chk('master reads own org event_log and no other org', n > 0 and n2 = 0 and not exists (select 1 from public.automation_event_log where org_id <> v_org), n::text);
  perform pg_temp.as_user(v_ops);
  perform pg_temp.chk('operation_admin reads event_log, audit, rules and queue',
    (select count(*) from public.automation_event_log) > 0 and (select count(*) from public.automation_audit) > 0
    and (select count(*) from public.automation_rules) > 0 and (select count(*) from public.automation_queue) > 0);
  perform pg_temp.as_user(v_sales);
  perform pg_temp.chk('sales_admin sees no automation rows (but may read the catalogue)',
    (select count(*) from public.automation_event_log) = 0 and (select count(*) from public.automation_audit) = 0
    and (select count(*) from public.automation_rules) = 0 and (select count(*) from public.automation_queue) = 0
    and (select count(*) from public.automation_events) > 0);
  perform pg_temp.as_user(v_tp);
  perform pg_temp.chk('technician sees no automation rows',
    (select count(*) from public.automation_event_log) = 0 and (select count(*) from public.automation_audit) = 0
    and (select count(*) from public.automation_rules) = 0 and (select count(*) from public.automation_queue) = 0);
  perform pg_temp.as_user(v_custrole);
  perform pg_temp.chk('customer role sees no automation rows and not even the catalogue',
    (select count(*) from public.automation_event_log) = 0 and (select count(*) from public.automation_audit) = 0
    and (select count(*) from public.automation_rules) = 0 and (select count(*) from public.automation_queue) = 0
    and (select count(*) from public.automation_events) = 0);
  perform pg_temp.as_user(v_master2);
  perform pg_temp.chk('another organisation master sees none of this org',
    (select count(*) from public.automation_event_log where org_id = v_org) = 0
    and (select count(*) from public.automation_rules where org_id = v_org) = 0
    and (select count(*) from public.automation_audit where org_id = v_org) = 0);
  perform pg_temp.as_anon();
  s := pg_temp.raises($q$select count(*) from public.automation_event_log$q$);
  perform pg_temp.chk('anon: read refused', s like '%permission denied%', coalesce(s,'accepted'));
  s := pg_temp.raises(format($q$insert into public.automation_rules (org_id, event_key, recipient_role) values (%L, 'ticket.created', 'customer')$q$, v_org));
  perform pg_temp.chk('anon: direct rule insert refused', s like '%permission denied%', coalesce(s,'accepted'));
  perform pg_temp.as_user(v_master);
  s := pg_temp.raises(format($q$insert into public.automation_rules (org_id, event_key, recipient_role) values (%L, 'ticket.created', 'customer')$q$, v_org));
  perform pg_temp.chk('master: direct rule insert refused (only via automation_rule_save)', s like '%permission denied%', coalesce(s,'accepted'));
  s := pg_temp.raises(format($q$insert into public.automation_event_log (id, org_id, event_key, subject_type, subject_id, outcome) values (gen_random_uuid(), %L, 'ticket.created', 'ticket', gen_random_uuid(), 'no_rule')$q$, v_org));
  perform pg_temp.chk('master: cannot forge an event_log row', s like '%permission denied%', coalesce(s,'accepted'));
  perform pg_temp.as_pg();

  -- ---------- an emit failure never fails the business statement ----------
  s := pg_temp.raises(format($q$insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (%L, %L, 'paid', '__TEST_ after kill')$q$, v_org, v_cust));
  perform pg_temp.chk('business insert still succeeds', s is null, coalesce(s,'ok'));

  -- ---------- failure isolation: automation can never block a business write ----------
  -- scenario 1: the engine's own log table is unreachable, so every automation_emit raises
  alter table public.automation_event_log rename to automation_event_log_x;
  select count(*) into v_e1 from public.automation_errors where org_id = v_org;
  s := pg_temp.raises(format($q$insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (%L, %L, 'paid', '__TEST_ iso ticket')$q$, v_org, v_cust));
  perform pg_temp.chk('S1 ticket insert succeeds although automation_emit raises', s is null, coalesce(s,'ok'));
  s := pg_temp.raises(format($q$insert into invoices (org_id, customer_id, type, subtotal, total, payment_status) values (%L, %L, 'product', 10, 10, 'due')$q$, v_org, v_cust));
  perform pg_temp.chk('S1 invoice insert succeeds', s is null, coalesce(s,'ok'));
  s := pg_temp.raises(format($q$insert into leads (org_id, customer_id, name, mobile, source, status, kind) values (%L, %L, '__TEST_ iso lead', '9400000051', 'customer_app', 'new', 'service')$q$, v_org, v_cust));
  perform pg_temp.chk('S1 lead insert succeeds', s is null, coalesce(s,'ok'));
  s := pg_temp.raises(format($q$insert into quotations (org_id, customer_id, status, total) values (%L, %L, 'open', 5)$q$, v_org, v_cust));
  perform pg_temp.chk('S1 quotation insert succeeds', s is null, coalesce(s,'ok'));
  s := pg_temp.raises(format($q$insert into service_visits (org_id, ticket_id, technician_id) values (%L, (select id from service_tickets where org_id = %L and name_of_complaint = '__TEST_ iso ticket'), %L)$q$, v_org, v_org, v_tech));
  perform pg_temp.chk('S1 visit insert succeeds', s is null, coalesce(s,'ok'));
  s := pg_temp.raises(format($q$insert into amc_contracts (org_id, customer_id, product_id, plan_id, start_date, expiry_date, status) values (%L, %L, %L, %L, current_date, current_date + 30, 'active')$q$, v_org, v_cust, v_prod, v_plan));
  perform pg_temp.chk('S1 AMC contract insert succeeds', s is null, coalesce(s,'ok'));
  s := pg_temp.raises(format($q$insert into warranties (org_id, customer_id, product_id, start_date, expiry_date) values (%L, %L, %L, current_date, current_date + 30)$q$, v_org, v_cust, v_prod));
  perform pg_temp.chk('S1 warranty insert succeeds', s is null, coalesce(s,'ok'));
  s := pg_temp.raises(format($q$update service_tickets set status = 'completed' where org_id = %L and name_of_complaint = '__TEST_ iso ticket'$q$, v_org));
  perform pg_temp.chk('S1 ticket status UPDATE succeeds', s is null, coalesce(s,'ok'));
  perform pg_temp.chk('S1 the business rows really exist',
    exists (select 1 from service_tickets where org_id = v_org and name_of_complaint = '__TEST_ iso ticket' and status = 'completed')
    and exists (select 1 from leads where org_id = v_org and name = '__TEST_ iso lead')
    and exists (select 1 from quotations where org_id = v_org and total = 5)
    and exists (select 1 from invoices where org_id = v_org and total = 10));
  select count(*) into v_e2 from public.automation_errors where org_id = v_org;
  perform pg_temp.chk('S1 every failure was logged to automation_errors (>= 8 emitting writes)', v_e2 - v_e1 >= 8, (v_e2 - v_e1)::text);
  perform pg_temp.chk('S1 logged sources cover ticket, invoice, lead, visit, quotation, AMC and warranty tables',
    (select count(distinct source) from public.automation_errors where org_id = v_org
        and source in ('service_tickets:INSERT','invoices:INSERT','leads:INSERT','service_visits:INSERT','quotations:INSERT','amc_contracts:INSERT','warranties:INSERT')) = 7);
  perform pg_temp.chk('S1 error rows hold an sqlstate',
    (select bool_and(sqlstate is not null) from public.automation_errors where org_id = v_org));
  alter table public.automation_event_log_x rename to automation_event_log;

  -- scenario 2: automation_emit replaced by a function that raises with a phone number and e-mail in the message
  create or replace function public.automation_emit(p_org_id uuid, p_event_key text, p_subject_type text, p_subject_id uuid,
    p_customer_id uuid default null, p_occurrence_key text default '', p_payload jsonb default '{}'::jsonb)
  returns uuid language plpgsql security definer set search_path = public as $f$
  begin raise exception 'forced failure for 9400000066 and someone@example.com'; end $f$;
  select count(*) into v_e1 from public.automation_errors where org_id = v_org;
  s := pg_temp.raises(format($q$insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (%L, %L, 'paid', '__TEST_ iso 2')$q$, v_org, v_cust));
  perform pg_temp.chk('S2 ticket insert succeeds with a hostile automation_emit', s is null, coalesce(s,'ok'));
  s := pg_temp.raises(format($q$insert into leads (org_id, customer_id, name, mobile, source, status, kind) values (%L, %L, '__TEST_ iso lead 2', '9400000050', 'customer_app', 'new', 'service')$q$, v_org, v_cust));
  perform pg_temp.chk('S2 lead insert succeeds', s is null, coalesce(s,'ok'));
  s := pg_temp.raises(format($q$insert into quotations (org_id, customer_id, status, total) values (%L, %L, 'open', 6)$q$, v_org, v_cust));
  perform pg_temp.chk('S2 quotation insert succeeds', s is null, coalesce(s,'ok'));
  s := pg_temp.raises(format($q$insert into invoices (org_id, customer_id, type, subtotal, total, payment_status) values (%L, %L, 'product', 11, 11, 'due')$q$, v_org, v_cust));
  perform pg_temp.chk('S2 invoice insert succeeds', s is null, coalesce(s,'ok'));
  select count(*) into v_e2 from public.automation_errors where org_id = v_org;
  perform pg_temp.chk('S2 four more errors logged', v_e2 - v_e1 >= 4, (v_e2 - v_e1)::text);
  perform pg_temp.chk('S2 logged messages are scrubbed (no 7+ digit run, no e-mail)',
    not exists (select 1 from public.automation_errors where org_id = v_org and (message ~ '[0-9]{7,}' or message ~ '@'))
    and exists (select 1 from public.automation_errors where org_id = v_org and message like 'forced failure%'));
  perform pg_temp.chk('S2 the error table has no customer, mobile, name or payload column',
    not exists (select 1 from information_schema.columns where table_name = 'automation_errors' and column_name in ('mobile','customer_id','payload','name','phone')));

  -- scenario 3: the error log itself is broken too: the business write still goes through
  alter table public.automation_errors rename to automation_errors_x;
  s := pg_temp.raises(format($q$insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (%L, %L, 'paid', '__TEST_ iso 3')$q$, v_org, v_cust));
  perform pg_temp.chk('S3 ticket insert succeeds even when the error log is unavailable', s is null, coalesce(s,'ok'));
  alter table public.automation_errors_x rename to automation_errors;

  -- errors table is append-only and not client-writable; readable by ops only
  s := pg_temp.raises(format($q$delete from public.automation_errors where org_id = %L$q$, v_org));
  perform pg_temp.chk('errors: DELETE refused', s like '%append-only%', coalesce(s,'accepted'));
  perform pg_temp.as_user(v_sales);
  perform pg_temp.chk('sales_admin sees no automation_errors', (select count(*) from public.automation_errors) = 0);
  s := pg_temp.raises(format($q$insert into public.automation_errors (org_id, source) values (%L, 'x')$q$, v_org));
  perform pg_temp.chk('authenticated cannot write automation_errors', s like '%permission denied%', coalesce(s,'accepted'));
  perform pg_temp.as_user(v_master);
  perform pg_temp.chk('master reads automation_errors of own org', (select count(*) from public.automation_errors) > 0);
  perform pg_temp.as_pg();

  -- ---------- real data unchanged ----------
  perform pg_temp.chk('real customers unchanged',
    fp_cust = (select md5(coalesce(string_agg(id::text||name||coalesce(mobile,''), ',' order by id),'')) from public.customers
                where org_id not in (select id from organizations where name like '\_\_TEST\_%')));

  raise exception 'RESULTS%', E'\n' || (select string_agg(r.line, E'\n' order by r.n) from pg_temp.res r);
end $t$;
$rh6$;
  v_hash := encode(sha256(convert_to(v_text, 'UTF8')), 'hex');
  if v_hash <> 'fae29baa9b015420e86054985fc51ac2f053969c7da9b32d38fbfaabd96c1389' then
    raise exception 'REHEARSAL_REFUSED: hash mismatch for automation_phase2_foundation.test.sql: %', v_hash;
  end if;
  execute v_text;

  raise exception 'REHEARSAL_DID_NOT_RAISE: the test file should have raised RESULTS';
end
$rehearsal$;
