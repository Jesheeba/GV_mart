-- REHEARSAL (NOT RUN; for the owner's approval of this exact text): Stage B stack (items 1+2, then the four Stage B migrations): automation_phase3b
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
--   41eb62373f95aa9791ae394b2b23560080d78fdf0debf0f219af601649b64594  gv-mart/supabase/tests/automation_phase3b.test.sql

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

  v_text := $rh6$-- Rolled-back DB tests for Automation Phase 3 / Stage B:
--   20261029100000_automation_handoff, 20261029110000_automation_scanners_and_amc_visit_emit, 20261029120000_start_travel
-- (the dispatcher-side migration 20261029130000 has its own test). Run AFTER the three migrations (the runner concatenates
-- them in front, inside ONE transaction). Ends in RAISE; read RESULTS in the error. Throwaway __TEST_ organisation only;
-- nothing is sent (there is no sender); no real customer, number or message is touched.
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
create function pg_temp.raises(p_sql text) returns text language plpgsql as $f$
begin execute p_sql; return null;
exception when others then return sqlerrm; end $f$;

do $t$
declare
  v_org uuid; v_m uuid; v_tp1 uuid; v_tp2 uuid; v_cr uuid; v_sales uuid;
  v_tech1 uuid; v_tech2 uuid;
  v_c uuid; v_ct uuid; v_c_out uuid; v_c_nomap uuid;
  mA text := '9400000081'; mMember text := '9400000082'; mT text := '9400000083'; mOut text := '9400000084'; mOther text := '9400000085';
  v_rjob uuid; v_rfeed uuid; v_rkey uuid; v_rotw uuid;
  v_t uuid; v_t2 uuid; v_t3 uuid; v_ev uuid; v_res jsonb; v_q record;
  n int; n2 int; s text; v_ob1 int; v_ob2 int; v_fire timestamptz; v_brand uuid; v_model uuid; v_prod uuid; v_plan uuid;
  v_contract uuid; v_tk uuid; v_ap uuid; v_pid uuid;
begin
  -- ---------- schema / privileges ----------
  perform pg_temp.chk('hand-off, scanners and start_travel are not executable by anon or authenticated (travel: authenticated only)',
    not has_function_privilege('anon', 'public.automation_handoff_due(timestamptz,integer,integer)', 'execute')
    and not has_function_privilege('authenticated', 'public.automation_handoff_due(timestamptz,integer,integer)', 'execute')
    and has_function_privilege('service_role', 'public.automation_handoff_due(timestamptz,integer,integer)', 'execute')
    and not has_function_privilege('authenticated', 'public.automation_scan_amc_expiring(timestamptz,integer[])', 'execute')
    and not has_function_privilege('authenticated', 'public.automation_scan_feedback(timestamptz,integer,integer)', 'execute')
    and not has_function_privilege('authenticated', 'public.automation_scan_review(timestamptz,integer,integer)', 'execute')
    and not has_function_privilege('anon', 'public.start_travel(uuid)', 'execute')
    and has_function_privilege('authenticated', 'public.start_travel(uuid)', 'execute'));
  perform pg_temp.chk('no PUBLIC grant on the new functions',
    not exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                 where p.pronamespace = 'public'::regnamespace and a.grantee = 0
                   and p.proname in ('automation_handoff_due','automation_scan_amc_expiring','automation_scan_feedback','automation_scan_review',
                                     'start_travel','_automation_completed_tickets','_automation_ist_date','_trg_automation_emit_amc_visit')));
  perform pg_temp.chk('hand-off whitelist: only the three existing dispatcher ref types (amc_contract comes with the dispatcher commit)',
    (select array_agg(ref_type order by ref_type) from public.automation_handoff_ref_types) = array['invoice', 'service_ticket', 'service_visit']);
  perform pg_temp.chk('catalogue: emitters flagged for the new events',
    (select count(*) from public.automation_events where event_key in ('amc.expiring','feedback.requested','review.google_requested','amc.visit_scheduled','technician.on_the_way') and has_emitter) = 5);
  perform pg_temp.chk('travel setting default 30 and range-checked',
    (select column_default from information_schema.columns where table_name = 'settings' and column_name = 'automation_default_travel_eta_minutes') = '30');
  perform pg_temp.chk('the scanners never read the ratings table (every completed service is eligible)',
    (select prosrc !~* '(from|join)[[:space:]]+(public\.)?ratings' from pg_proc where proname = 'automation_scan_review' and pronamespace = 'public'::regnamespace)
    and (select prosrc !~* '(from|join)[[:space:]]+(public\.)?ratings' from pg_proc where proname = '_automation_completed_tickets' and pronamespace = 'public'::regnamespace));

  -- ---------- fixtures ----------
  insert into organizations (name) values ('__TEST_automation_3b') returning id into v_org;
  insert into settings (org_id) values (v_org) on conflict (org_id) do nothing;
  v_m := pg_temp.mkuser('master', v_org);
  v_sales := pg_temp.mkuser('sales_admin', v_org);
  v_cr := pg_temp.mkuser('customer', v_org);
  v_tp1 := pg_temp.mkuser('technician', v_org);
  v_tp2 := pg_temp.mkuser('technician', v_org);
  insert into technicians (org_id, profile_id, is_active) values (v_org, v_tp1, true) returning id into v_tech1;
  insert into technicians (org_id, profile_id, is_active) values (v_org, v_tp2, true) returning id into v_tech2;
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ main', mA) returning id into v_c;
  insert into customer_members (org_id, customer_id, name, mobile, is_primary) values (v_org, v_c, '__TEST_ member', mMember, false);
  insert into customers (org_id, name, mobile, is_test) values (v_org, '__TEST_ flagged', mT, true) returning id into v_ct;
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ opted', mOut) returning id into v_c_out;
  -- dispatcher: v2 ON, scope numbers, list = the main number and the flagged test number; mapping + approved mirror for the booked template
  update settings set wa_dispatch_v2_enabled = true, wa_dispatch_v2_scope = 'numbers', wa_dispatch_v2_numbers = array[mA, mT, mOut] where org_id = v_org;
  insert into whatsapp_wasi_templates (org_id, wasi_name, language, category, status) values
    (v_org, 'gvm_service_booked_en', 'en', 'utility', 'approved'),
    (v_org, 'gvm_feedback_request_en', 'en', 'utility', 'approved'),
    (v_org, 'gvm_service_booked_ta', 'ta', 'utility', 'pending');
  insert into whatsapp_event_templates (org_id, event_key, language, wasi_template_name, param_map) values
    (v_org, 'gvm_service_booked', 'en', 'gvm_service_booked_en', '{"customer_name":"name","ticket_ref":"ticket_ref","complaint":"complaint"}'),
    (v_org, 'gvm_service_booked', 'ta', 'gvm_service_booked_ta', '{"customer_name":"name"}'),
    (v_org, 'gvm_feedback_request', 'en', 'gvm_feedback_request_en', '{"customer_name":"name"}');

  perform pg_temp.as_user(v_m);
  v_rjob  := public.automation_rule_save(null, 'ticket.created', 'customer', 'whatsapp', '{}', 'gvm_service_booked_en', 'en', 0, 0, null, 'live');
  v_rfeed := public.automation_rule_save(null, 'feedback.requested', 'customer', 'whatsapp', '{}', 'gvm_feedback_request_en', 'en', 0, 0, null, 'live');
  perform pg_temp.as_pg();
  select rule_key into v_rkey from public.automation_rules where id = v_rjob;

  select count(*) into v_ob1 from public.whatsapp_outbox where org_id = v_org and template = 'gvm_service_booked';

  -- ---------- H1: no live rule means no outbox row ----------
  insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (v_org, v_c, 'paid', '__TEST_ h1') returning id into v_t;
  perform pg_temp.chk('H1 setup: the live rule produced a live-mode dry_run row for the main number',
    (select state from public.automation_queue where subject_id = v_t and rule_key = v_rkey) = 'dry_run'
    and (select mode from public.automation_queue where subject_id = v_t and rule_key = v_rkey) = 'live');
  perform pg_temp.as_user(v_m);
  v_rjob := public.automation_rule_save(v_rkey, 'ticket.created', 'customer', 'whatsapp', '{}', 'gvm_service_booked_en', 'en', 0, 0, null, 'test_only');
  perform pg_temp.as_pg();
  v_res := public.automation_handoff_due(now() + interval '1 minute');
  perform pg_temp.chk('H1 rule now test_only: nothing handed over, row untouched, no outbox row',
    (v_res ->> 'handed_over')::int = 0
    and (select state from public.automation_queue where subject_id = v_t and rule_key = v_rkey) = 'dry_run'
    and (select count(*) from public.whatsapp_outbox where org_id = v_org and template = 'gvm_service_booked') = v_ob1);
  perform pg_temp.as_user(v_m);
  v_rjob := public.automation_rule_save(v_rkey, 'ticket.created', 'customer', 'whatsapp', '{}', 'gvm_service_booked_en', 'en', 0, 0, null, 'paused');
  perform pg_temp.as_pg();
  v_res := public.automation_handoff_due(now() + interval '1 minute');
  perform pg_temp.chk('H1 rule paused: nothing handed over',
    (v_res ->> 'handed_over')::int = 0 and (select count(*) from public.whatsapp_outbox where org_id = v_org and template = 'gvm_service_booked') = v_ob1);
  perform pg_temp.as_user(v_m);
  v_rjob := public.automation_rule_save(v_rkey, 'ticket.created', 'customer', 'whatsapp', '{}', 'gvm_service_booked_en', 'en', 0, 0, null, 'shadow');
  perform pg_temp.as_pg();
  v_res := public.automation_handoff_due(now() + interval '1 minute');
  perform pg_temp.chk('H1 rule shadow: nothing handed over',
    (v_res ->> 'handed_over')::int = 0 and (select count(*) from public.whatsapp_outbox where org_id = v_org and template = 'gvm_service_booked') = v_ob1);
  -- a queue row whose rule does not exist at all
  insert into public.automation_queue (org_id, idempotency_key, rule_id, rule_key, rule_version, event_id, event_key, subject_type, subject_id,
         customer_id, recipient_role, recipient_masked, channel, template_name, language, fire_at, state, is_test, mode, message_class)
  values (v_org, 'orphan', gen_random_uuid(), gen_random_uuid(), 1, gen_random_uuid(), 'ticket.created', 'ticket', v_t, v_c,
          'customer', '******0081', 'whatsapp', 'gvm_service_booked_en', 'en', now() - interval '1 minute', 'dry_run', false, 'live', 'job');
  v_res := public.automation_handoff_due(now() + interval '1 minute');
  perform pg_temp.chk('H1 a row with no current rule at all: nothing handed over',
    (v_res ->> 'handed_over')::int = 0 and (select state from public.automation_queue where idempotency_key = 'orphan') = 'dry_run');
  delete from public.automation_queue where idempotency_key = 'orphan';
  perform pg_temp.chk('H1 summary: no outbox row of any kind was created by those four runs',
    (select count(*) from public.whatsapp_outbox where org_id = v_org and template = 'gvm_service_booked') = v_ob1);

  -- ---------- H2: live rule, mapping, approved template, number in scope: exactly one pending row ----------
  perform pg_temp.as_user(v_m);
  v_rjob := public.automation_rule_save(v_rkey, 'ticket.created', 'customer', 'whatsapp', '{}', 'gvm_service_booked_en', 'en', 0, 0, null, 'live');
  perform pg_temp.as_pg();
  v_res := public.automation_handoff_due(now() + interval '1 minute');
  select * into v_q from public.whatsapp_outbox where org_id = v_org and template = 'gvm_service_booked' order by created_at desc limit 1;
  perform pg_temp.chk('H2 exactly one outbox row handed over', (v_res ->> 'handed_over')::int = 1
    and (select count(*) from public.whatsapp_outbox where org_id = v_org and template = 'gvm_service_booked') = v_ob1 + 1, v_res::text);
  perform pg_temp.chk('H2 the row is pending (never an optimistic sent), a template row, to the MAIN number, for the ticket',
    v_q.status = 'pending' and v_q.type = 'template' and v_q.to_mobile = mA and v_q.ref_type = 'service_ticket' and v_q.ref_id = v_t
    and v_q.direction = 'outbound' and v_q.customer_id = v_c and v_q.template = 'gvm_service_booked' and v_q.wa_message_id is null);
  perform pg_temp.chk('H2 payload carries the queue id, rule key and language only (no number, no name)',
    v_q.payload ? 'automation_queue_id' and v_q.payload ->> 'language' = 'en' and v_q.payload ->> 'rule_key' = v_rkey::text
    and v_q.payload::text !~ '[0-9]{10}');
  perform pg_temp.chk('H2 queue row handed_over with the outbox id; audit handed_over',
    (select state from public.automation_queue where subject_id = v_t and rule_key = v_rkey) = 'handed_over'
    and (select outbox_id from public.automation_queue where subject_id = v_t and rule_key = v_rkey) = v_q.id
    and exists (select 1 from public.automation_audit where subject_id = v_t and decision = 'handed_over' and detail ->> 'outbox_id' = v_q.id::text));
  v_res := public.automation_handoff_due(now() + interval '1 minute');
  perform pg_temp.chk('H2 running it again adds nothing',
    (v_res ->> 'handed_over')::int = 0 and (select count(*) from public.whatsapp_outbox where org_id = v_org and template = 'gvm_service_booked') = v_ob1 + 1);
  perform pg_temp.chk('H2 hand-off never wrote the optimistic status the legacy writers use',
    not exists (select 1 from public.whatsapp_outbox where org_id = v_org and template = 'gvm_service_booked' and status = 'sent'));

  -- ---------- H3: dispatcher scope ----------
  update settings set wa_dispatch_v2_numbers = array[mT] where org_id = v_org;   -- main number no longer in scope
  insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (v_org, v_c, 'paid', '__TEST_ h3') returning id into v_t2;
  v_res := public.automation_handoff_due(now() + interval '1 minute');
  perform pg_temp.chk('H3 number outside wa_dispatch_v2_numbers: terminal blocked_not_in_dispatch_scope, no outbox row',
    (v_res ->> 'blocked_scope')::int = 1
    and (select state from public.automation_queue where subject_id = v_t2 and rule_key = v_rkey) = 'blocked_not_in_dispatch_scope'
    and exists (select 1 from public.automation_audit where subject_id = v_t2 and decision = 'blocked_not_in_dispatch_scope')
    and (select count(*) from public.whatsapp_outbox where org_id = v_org and template = 'gvm_service_booked') = v_ob1 + 1);
  update settings set wa_dispatch_v2_numbers = array[mA, mT, mOut], wa_dispatch_v2_enabled = false where org_id = v_org;
  insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (v_org, v_c, 'paid', '__TEST_ h3b') returning id into v_t3;
  v_res := public.automation_handoff_due(now() + interval '1 minute');
  perform pg_temp.chk('H3 dispatcher switched OFF: the row is held (left as it was), no outbox row',
    (v_res ->> 'handed_over')::int = 0 and (select state from public.automation_queue where subject_id = v_t3 and rule_key = v_rkey) = 'dry_run'
    and (select count(*) from public.whatsapp_outbox where org_id = v_org and template = 'gvm_service_booked') = v_ob1 + 1);
  update settings set wa_dispatch_v2_enabled = true where org_id = v_org;
  v_res := public.automation_handoff_due(now() + interval '1 minute');
  perform pg_temp.chk('H3 switched back on: the held row is now handed over',
    (v_res ->> 'handed_over')::int = 1 and (select state from public.automation_queue where subject_id = v_t3 and rule_key = v_rkey) = 'handed_over');

  -- ---------- H4: template mapping / approval ----------
  update customers set preferred_language = 'ta' where id = v_c;
  insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (v_org, v_c, 'paid', '__TEST_ h4 ta') returning id into v_t;
  v_res := public.automation_handoff_due(now() + interval '1 minute');
  perform pg_temp.chk('H4 Tamil mapping exists but its template is only pending in the mirror: skipped_no_template, no outbox row',
    (v_res ->> 'no_template')::int = 1 and (select state from public.automation_queue where subject_id = v_t and rule_key = v_rkey) = 'skipped_no_template'
    and (select language from public.automation_queue where subject_id = v_t and rule_key = v_rkey) = 'ta');
  update customers set preferred_language = null where id = v_c;
  update whatsapp_event_templates set is_active = false where org_id = v_org and event_key = 'gvm_service_booked' and language = 'en';
  insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (v_org, v_c, 'paid', '__TEST_ h4 inactive') returning id into v_t;
  v_res := public.automation_handoff_due(now() + interval '1 minute');
  perform pg_temp.chk('H4 inactive mapping: skipped_no_template', (v_res ->> 'no_template')::int = 1);
  update whatsapp_event_templates set is_active = true where org_id = v_org and event_key = 'gvm_service_booked' and language = 'en';
  update whatsapp_wasi_templates set status = 'paused' where org_id = v_org and wasi_name = 'gvm_service_booked_en';
  insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (v_org, v_c, 'paid', '__TEST_ h4 paused') returning id into v_t;
  v_res := public.automation_handoff_due(now() + interval '1 minute');
  perform pg_temp.chk('H4 template not approved in the mirror: skipped_no_template', (v_res ->> 'no_template')::int = 1);
  update whatsapp_wasi_templates set status = 'approved' where org_id = v_org and wasi_name = 'gvm_service_booked_en';
  perform pg_temp.chk('H4 none of the three produced an outbox row',
    (select count(*) from public.whatsapp_outbox where org_id = v_org and template = 'gvm_service_booked') = v_ob1 + 2);
  -- skipped rows do not count toward cooldown (S0a list extended)
  perform pg_temp.as_user(v_m);
  v_rotw := public.automation_rule_save(null, 'invoice.issued', 'customer', 'whatsapp', '{}', 'gvm_invoice_issued_en', 'en', 0, 24, null, 'live');
  perform pg_temp.as_pg();
  v_ev := public.automation_emit(v_org, 'invoice.issued', 'invoice', gen_random_uuid(), v_c, 'i1', '{}');
  v_res := public.automation_handoff_due(now() + interval '1 minute');   -- no mapping for the invoice template: skipped_no_template
  v_ev := public.automation_emit(v_org, 'invoice.issued', 'invoice', gen_random_uuid(), v_c, 'i2', '{}');
  select decision into s from public.automation_audit where event_id = v_ev and rule_id = v_rotw;
  perform pg_temp.chk('H4 a skipped_no_template row does not start a cooldown', s = 'dry_run', coalesce(s, '-'));

  -- ---------- H5: opt-out re-checked at hand-off ----------
  v_ev := public.automation_emit(v_org, 'feedback.requested', 'ticket', gen_random_uuid(), v_c_out, 'f1', '{}');
  perform public.wa_record_opt_out(v_org, mOut, 'stop');
  v_res := public.automation_handoff_due(now() + interval '1 minute');
  perform pg_temp.chk('H5 STOP after the row was queued: non-job row is skipped_opt_out at hand-off, no outbox row',
    (v_res ->> 'opted_out')::int = 1
    and (select state from public.automation_queue where event_id = v_ev and rule_id = v_rfeed) = 'skipped_opt_out'
    and not exists (select 1 from public.whatsapp_outbox where org_id = v_org and customer_id = v_c_out and template = 'gvm_feedback_request'));
  insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (v_org, v_c_out, 'paid', '__TEST_ h5 job') returning id into v_t;
  v_res := public.automation_handoff_due(now() + interval '1 minute');
  perform pg_temp.chk('H5 after STOP a JOB message (booked) still goes',
    (v_res ->> 'handed_over')::int = 1 and exists (select 1 from public.whatsapp_outbox where org_id = v_org and customer_id = v_c_out and template = 'gvm_service_booked'));

  -- ---------- H6: global switch, staleness ----------
  update settings set automation_enabled = false where org_id = v_org;
  insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (v_org, v_c, 'paid', '__TEST_ h6') returning id into v_t;
  update settings set automation_enabled = true where org_id = v_org;
  update public.automation_queue set fire_at = now() - interval '30 hours' where subject_id = v_t;
  v_ev := public.automation_emit(v_org, 'ticket.created', 'ticket', gen_random_uuid(), v_c, 'h6', '{}');
  update public.automation_queue set fire_at = now() - interval '30 hours' where event_id = v_ev;
  v_res := public.automation_handoff_due(now());
  perform pg_temp.chk('H6 a row older than 24 hours is dropped as expired_stale, never sent late',
    (v_res ->> 'expired_stale')::int >= 1 and (select state from public.automation_queue where event_id = v_ev) = 'expired_stale'
    and exists (select 1 from public.automation_audit where event_id = v_ev and decision = 'expired_stale'));
  update settings set automation_enabled = false where org_id = v_org;
  v_ev := public.automation_emit(v_org, 'ticket.created', 'ticket', gen_random_uuid(), v_c, 'h6b', '{}');
  update settings set automation_enabled = true where org_id = v_org;
  select count(*) into n from public.whatsapp_outbox where org_id = v_org;
  update settings set automation_enabled = false where org_id = v_org;
  v_res := public.automation_handoff_due(now() + interval '1 minute');
  select count(*) into n2 from public.whatsapp_outbox where org_id = v_org;
  perform pg_temp.chk('H6 global switch OFF: nothing is handed over', n = n2 and (v_res ->> 'handed_over')::int = 0);
  update settings set automation_enabled = true where org_id = v_org;

  -- ---------- H7: only live-mode customer rows on WhatsApp ----------
  perform pg_temp.chk('H7 shadow, blocked, staff and in-app rows are never selected',
    not exists (select 1 from public.automation_queue q join public.whatsapp_outbox o on o.id = q.outbox_id
                 where q.org_id = v_org and (q.mode = 'shadow' or q.recipient_role <> 'customer' or q.channel = 'in_app' or q.state = 'blocked_not_allowlisted')));
  -- a customer-less queue row for a supported subject: terminal skipped_no_recipient
  insert into public.automation_queue (org_id, idempotency_key, rule_id, rule_key, rule_version, event_id, event_key, subject_type, subject_id,
         customer_id, recipient_role, recipient_masked, channel, template_name, language, fire_at, state, is_test, mode, message_class)
  values (v_org, 'nocust', v_rjob, v_rkey, 1, gen_random_uuid(), 'ticket.created', 'ticket', gen_random_uuid(), null,
          'customer', null, 'whatsapp', 'gvm_service_booked_en', 'en', now() - interval '1 minute', 'dry_run', false, 'live', 'job');
  v_res := public.automation_handoff_due(now() + interval '1 minute');
  perform pg_temp.chk('H7 a row with no customer: skipped_no_recipient, no outbox row',
    (select state from public.automation_queue where idempotency_key = 'nocust') = 'skipped_no_recipient');
  -- unsupported subject (amc_contract has no dispatcher ref type yet): untouched
  insert into public.automation_queue (org_id, idempotency_key, rule_id, rule_key, rule_version, event_id, event_key, subject_type, subject_id,
         customer_id, recipient_role, recipient_masked, channel, template_name, language, fire_at, state, is_test, mode, message_class)
  values (v_org, 'amc-unsupported', v_rjob, v_rkey, 1, gen_random_uuid(), 'ticket.created', 'amc_contract', gen_random_uuid(), v_c,
          'customer', '******0081', 'whatsapp', 'gvm_service_booked_en', 'en', now() - interval '1 minute', 'dry_run', false, 'live', 'job');
  v_res := public.automation_handoff_due(now() + interval '1 minute');
  perform pg_temp.chk('H7 a subject type the dispatcher cannot resolve yet is left untouched',
    (select state from public.automation_queue where idempotency_key = 'amc-unsupported') = 'dry_run');
  delete from public.automation_queue where idempotency_key in ('nocust', 'amc-unsupported');

  -- ---------- H8: main customer's number only ----------
  perform pg_temp.chk('H8 no outbox row from automation ever went to the family member number',
    not exists (select 1 from public.whatsapp_outbox where org_id = v_org and to_mobile = mMember));

  -- ---------- H9: test subject and test mode ----------
  update settings set wa_test_mode_enabled = true, wa_test_allowed_numbers = array[mT] where org_id = v_org;
  insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (v_org, v_c, 'paid', '__TEST_ h9 real') returning id into v_t;
  -- emit already blocked it (not allow-listed); a row queued BEFORE test mode was switched on is blocked at hand-off
  update settings set wa_test_mode_enabled = false where org_id = v_org;
  insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (v_org, v_c, 'paid', '__TEST_ h9 queued') returning id into v_t2;
  update settings set wa_test_mode_enabled = true where org_id = v_org;
  v_res := public.automation_handoff_due(now() + interval '1 minute');
  perform pg_temp.chk('H9 test mode ON, number not on the list: blocked_not_allowlisted at hand-off, no outbox row',
    (v_res ->> 'blocked_allow_list')::int >= 1
    and (select state from public.automation_queue where subject_id = v_t2 and rule_key = v_rkey) = 'blocked_not_allowlisted');
  insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (v_org, v_ct, 'paid', '__TEST_ h9 flagged') returning id into v_t3;
  v_res := public.automation_handoff_due(now() + interval '1 minute');
  perform pg_temp.chk('H9 the flagged test customer (its own number is on the list) is handed over',
    exists (select 1 from public.whatsapp_outbox where org_id = v_org and customer_id = v_ct and to_mobile = mT and status = 'pending'));
  update settings set wa_test_mode_enabled = false, wa_test_allowed_numbers = '{}' where org_id = v_org;

  -- ---------- H10: queue context is small and non-personal ----------
  v_ev := public.automation_emit(v_org, 'ticket.created', 'ticket', gen_random_uuid(), v_c, 'ctx',
            jsonb_build_object('mobile', mMember, 'days_left', 7, 'eta_minutes', 30, 'name', 'Someone', 'ticket_type', 'paid'));
  perform pg_temp.chk('H10 only whitelisted, non-personal keys are kept in the queue context',
    (select context from public.automation_queue where event_id = v_ev and rule_key = v_rkey) = '{"days_left": 7, "eta_minutes": 30, "ticket_type": "paid"}'::jsonb);

  -- ---------- scanners ----------
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ scan', '9400000086') returning id into v_c_nomap;
  insert into brands (org_id, name, category) values (v_org, '__TEST_ brand', 'ro') returning id into v_brand;
  insert into models (org_id, brand_id, name) values (v_org, v_brand, '__TEST_ model') returning id into v_model;
  insert into products (org_id, name, category, brand_id, model_id, price) values (v_org, '__TEST_ RO', 'ro', v_brand, v_model, 10000) returning id into v_prod;
  insert into amc_plans (org_id, name, years, price, visits_per_year) values (v_org, '__TEST_ Silver', 1, 3000, 1) returning id into v_plan;
  perform pg_temp.as_user(v_m);
  perform public.automation_rule_save(null, 'amc.expiring', 'customer', 'whatsapp', '{}', 'gvm_amc_expiring_en', 'en', 0, 0, null, 'live');
  perform public.automation_rule_save(null, 'review.google_requested', 'customer', 'whatsapp', '{}', 'gvm_google_review_en', 'en', 0, 0, null, 'live');
  perform pg_temp.as_pg();
  insert into amc_contracts (org_id, customer_id, product_id, plan_id, start_date, expiry_date, status)
  select v_org, v_c_nomap, v_prod, v_plan, current_date - 300, public._automation_ist_date(now()) + d, 'active' from unnest(array[30, 15, 7, 10, 1]) d;
  insert into amc_contracts (org_id, customer_id, product_id, plan_id, start_date, expiry_date, status, cancelled_at, cancel_reason)
  values (v_org, v_c_nomap, v_prod, v_plan, current_date - 300, public._automation_ist_date(now()) + 30, 'active', now(), '__TEST_ cancelled');
  v_res := public.automation_scan_amc_expiring(now());
  perform pg_temp.chk('SCAN amc.expiring emits exactly the 30, 15 and 7 day windows (not 10, not 1, not a cancelled contract)',
    (v_res ->> 'emitted')::int >= 3
    and (select count(*) from public.automation_event_log where org_id = v_org and event_key = 'amc.expiring') = (v_res ->> 'emitted')::int
    and (select array_agg(occurrence_key order by occurrence_key) from public.automation_event_log where org_id = v_org and event_key = 'amc.expiring')
        = array['expiring@15', 'expiring@30', 'expiring@7'], v_res::text);
  perform pg_temp.chk('SCAN the queue row carries days_left and a window that ends tomorrow (a 7-day reminder is not late-sent)',
    (select (context ->> 'days_left')::int from public.automation_queue where event_key = 'amc.expiring' and org_id = v_org and detail ->> 'language' = 'en' and context ->> 'days_left' = '7' limit 1) = 7
    and (select (context ->> 'window_end')::timestamptz from public.automation_queue where event_key = 'amc.expiring' and org_id = v_org and context ->> 'days_left' = '7' limit 1)
        > now());
  select count(*) into n from public.automation_queue where org_id = v_org and event_key = 'amc.expiring';
  v_res := public.automation_scan_amc_expiring(now());
  select count(*) into n2 from public.automation_queue where org_id = v_org and event_key = 'amc.expiring';
  perform pg_temp.chk('SCAN running amc.expiring again adds no queue row (idempotent)', n = n2, n::text);
  perform pg_temp.chk('SCAN simulated p_now: a day later the 30-day contract is a 29-day contract, nothing new in the 30 window',
    (public.automation_scan_amc_expiring(now() + interval '1 day') ->> 'emitted')::int >= 0);

  -- completed tickets: 25 h ago (eligible), 5 h ago (too recent), 6 days ago (outside the lookback)
  insert into service_tickets (org_id, customer_id, type, name_of_complaint, status) values (v_org, v_c_nomap, 'paid', '__TEST_ done 25h', 'completed') returning id into v_t;
  insert into service_visits (org_id, ticket_id, technician_id, timer_end) values (v_org, v_t, v_tech1, now() - interval '25 hours');
  insert into service_tickets (org_id, customer_id, type, name_of_complaint, status) values (v_org, v_c_nomap, 'paid', '__TEST_ done 5h', 'completed') returning id into v_t2;
  insert into service_visits (org_id, ticket_id, technician_id, timer_end) values (v_org, v_t2, v_tech1, now() - interval '5 hours');
  insert into service_tickets (org_id, customer_id, type, name_of_complaint, status) values (v_org, v_c_nomap, 'paid', '__TEST_ done 6d', 'completed') returning id into v_t3;
  insert into service_visits (org_id, ticket_id, technician_id, timer_end) values (v_org, v_t3, v_tech1, now() - interval '6 days');
  v_res := public.automation_scan_feedback(now());
  perform pg_temp.chk('SCAN feedback: only the ticket completed 25 h ago',
    exists (select 1 from public.automation_event_log where event_key = 'feedback.requested' and subject_id = v_t)
    and not exists (select 1 from public.automation_event_log where event_key = 'feedback.requested' and subject_id in (v_t2, v_t3)));
  v_res := public.automation_scan_review(now());
  perform pg_temp.chk('SCAN review: same selection, every completed service (no rating, rule or staff condition)',
    exists (select 1 from public.automation_event_log where event_key = 'review.google_requested' and subject_id = v_t)
    and not exists (select 1 from public.automation_event_log where event_key = 'review.google_requested' and subject_id in (v_t2, v_t3)));
  select count(*) into n from public.automation_event_log where org_id = v_org and event_key in ('feedback.requested', 'review.google_requested');
  perform public.automation_scan_feedback(now());
  perform public.automation_scan_review(now());
  perform pg_temp.chk('SCAN re-running the scanners logs events again but queues nothing new',
    (select count(*) from public.automation_queue where org_id = v_org and subject_id = v_t and event_key in ('feedback.requested', 'review.google_requested')) <= 2);
  perform pg_temp.chk('SCAN scanners are dry-run: no outbox row was created by them',
    not exists (select 1 from public.whatsapp_outbox where org_id = v_org and template in ('gvm_amc_expiring', 'gvm_google_review', 'gvm_feedback_request') and customer_id = v_c_nomap));

  -- AMC visit emit
  select count(*) into n from public.automation_event_log where org_id = v_org and event_key = 'amc.visit_scheduled';
  perform pg_temp.as_user(v_m);
  v_pid := (public.sell_amc_plan(v_org, v_c_nomap, v_prod, v_plan, current_date + 5, null, null) ->> 'contract_id')::uuid;
  perform pg_temp.as_pg();
  select count(*) into n2 from public.automation_event_log where org_id = v_org and event_key = 'amc.visit_scheduled' and subject_id = v_pid;
  perform pg_temp.chk('VISIT a sale emits amc.visit_scheduled exactly ONCE for the contract, however many visits it generated',
    n2 = 1 and (select count(*) from public.service_tickets where contract_id = v_pid) >= 1, n2::text);
  perform pg_temp.chk('VISIT the announced visit is the nearest one (its ticket has the earliest scheduled appointment)',
    (select e.occurrence_key from public.automation_event_log e where e.event_key = 'amc.visit_scheduled' and e.subject_id = v_pid)
      = 'visit@' || (select t.id::text from public.service_tickets t join public.appointments a on a.ticket_id = t.id
                      where t.contract_id = v_pid order by a.scheduled_at, a.created_at limit 1));
  perform pg_temp.chk('VISIT the event carries visit_date and days_left, and the subject is the contract',
    exists (select 1 from public.automation_event_log where event_key = 'amc.visit_scheduled' and subject_id = v_pid and 'visit_date' = any (payload_keys) and 'days_left' = any (payload_keys)));
  -- ordering rule, built by hand on a fresh contract: a later visit and an equal-date visit stay silent; an earlier visit
  -- inserted afterwards is the new nearest and is announced (the generators insert in date order, so this does not happen in practice)
  insert into amc_contracts (org_id, customer_id, product_id, plan_id, start_date, expiry_date, status)
  values (v_org, v_c, v_prod, v_plan, current_date, current_date + 365, 'active') returning id into v_contract;
  insert into service_tickets (org_id, customer_id, type, name_of_complaint, contract_id) values (v_org, v_c, 'amc', '__TEST_ visit A', v_contract) returning id into v_t;
  insert into appointments (org_id, ticket_id, scheduled_at, mode, status) values (v_org, v_t, now() + interval '10 days', 'datetime', 'scheduled');
  perform pg_temp.chk('VISIT first visit of a contract is announced',
    (select count(*) from public.automation_event_log where event_key = 'amc.visit_scheduled' and subject_id = v_contract) = 1);
  insert into service_tickets (org_id, customer_id, type, name_of_complaint, contract_id) values (v_org, v_c, 'amc', '__TEST_ visit B', v_contract) returning id into v_t2;
  insert into appointments (org_id, ticket_id, scheduled_at, mode, status) values (v_org, v_t2, now() + interval '20 days', 'datetime', 'scheduled');
  insert into service_tickets (org_id, customer_id, type, name_of_complaint, contract_id) values (v_org, v_c, 'amc', '__TEST_ visit C', v_contract) returning id into v_t3;
  insert into appointments (org_id, ticket_id, scheduled_at, mode, status) values (v_org, v_t3, (select scheduled_at from appointments where ticket_id = v_t), 'datetime', 'scheduled');
  perform pg_temp.chk('VISIT a later visit and an equal-date visit stay silent',
    (select count(*) from public.automation_event_log where event_key = 'amc.visit_scheduled' and subject_id = v_contract) = 1);
  insert into service_tickets (org_id, customer_id, type, name_of_complaint, contract_id) values (v_org, v_c, 'amc', '__TEST_ visit D', v_contract) returning id into v_t3;
  insert into appointments (org_id, ticket_id, scheduled_at, mode, status) values (v_org, v_t3, now() + interval '5 days', 'datetime', 'scheduled');
  perform pg_temp.chk('VISIT an earlier visit inserted afterwards is the new nearest and is announced',
    (select count(*) from public.automation_event_log where event_key = 'amc.visit_scheduled' and subject_id = v_contract) = 2);
  insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (v_org, v_c, 'paid', '__TEST_ plain ticket') returning id into v_t;
  insert into appointments (org_id, ticket_id, technician_id, scheduled_at, mode, status) values (v_org, v_t, v_tech1, now() + interval '2 days', 'datetime', 'scheduled');
  perform pg_temp.chk('VISIT an ordinary (non-AMC) appointment emits no amc.visit_scheduled',
    not exists (select 1 from public.automation_event_log where event_key = 'amc.visit_scheduled' and occurrence_key = 'visit@' || v_t::text));

  -- ---------- start_travel ----------
  insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (v_org, v_c, 'paid', '__TEST_ travel') returning id into v_tk;
  insert into appointments (org_id, ticket_id, technician_id, scheduled_at, mode, status) values (v_org, v_tk, v_tech1, now() + interval '3 hours', 'datetime', 'scheduled') returning id into v_ap;
  update service_tickets set status = 'assigned' where id = v_tk;
  update settings set automation_default_travel_eta_minutes = 45 where org_id = v_org;
  perform pg_temp.as_user(v_tp2);
  s := pg_temp.raises(format($q$select public.start_travel(%L)$q$, v_tk));
  perform pg_temp.chk('TRAVEL another technician is refused', s like '%not assigned to you%', coalesce(s, 'accepted'));
  perform pg_temp.as_user(v_m);
  s := pg_temp.raises(format($q$select public.start_travel(%L)$q$, v_tk));
  perform pg_temp.chk('TRAVEL master (not a technician) is refused', s like '%only a technician%', coalesce(s, 'accepted'));
  perform pg_temp.as_user(v_cr);
  s := pg_temp.raises(format($q$select public.start_travel(%L)$q$, v_tk));
  perform pg_temp.chk('TRAVEL customer role is refused', s like '%only a technician%', coalesce(s, 'accepted'));
  perform pg_temp.as_anon();
  s := pg_temp.raises(format($q$select public.start_travel(%L)$q$, v_tk));
  perform pg_temp.chk('TRAVEL anon is refused', s like '%permission denied%', coalesce(s, 'accepted'));
  perform pg_temp.as_pg();
  perform pg_temp.chk('TRAVEL nothing was stamped by the refused calls',
    (select travel_started_at from public.appointments where id = v_ap) is null
    and not exists (select 1 from public.automation_event_log where event_key = 'technician.on_the_way' and subject_id = v_tk));
  perform pg_temp.as_user(v_tp1);
  v_res := public.start_travel(v_tk);
  perform pg_temp.as_pg();
  perform pg_temp.chk('TRAVEL the assigned technician starts travel: stamped, not already_started',
    (v_res ->> 'already_started')::boolean = false and (select travel_started_at from public.appointments where id = v_ap) is not null);
  perform pg_temp.chk('TRAVEL exactly one technician.on_the_way event, with the master-set estimate',
    (select count(*) from public.automation_event_log where event_key = 'technician.on_the_way' and subject_id = v_tk) = 1
    and exists (select 1 from public.automation_event_log where event_key = 'technician.on_the_way' and subject_id = v_tk and 'eta_minutes' = any (payload_keys)));
  perform pg_temp.as_user(v_tp1);
  v_res := public.start_travel(v_tk);
  perform pg_temp.as_pg();
  perform pg_temp.chk('TRAVEL a repeat tap changes nothing and emits nothing',
    (v_res ->> 'already_started')::boolean
    and (select count(*) from public.automation_event_log where event_key = 'technician.on_the_way' and subject_id = v_tk) = 1);
  -- a live rule for on_the_way (quiet-hours exempt): fire_at is now, even in quiet hours; context holds the eta
  perform pg_temp.as_user(v_m);
  v_rotw := public.automation_rule_save(null, 'technician.on_the_way', 'customer', 'whatsapp', '{}', 'gvm_technician_on_the_way_en', 'en', 0, 0, null, 'live');
  perform pg_temp.as_pg();
  insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (v_org, v_c, 'paid', '__TEST_ travel 2') returning id into v_t2;
  insert into appointments (org_id, ticket_id, technician_id, scheduled_at, mode, status) values (v_org, v_t2, v_tech1, now() + interval '6 hours', 'datetime', 'scheduled');
  update service_tickets set status = 'assigned' where id = v_t2;
  perform pg_temp.as_user(v_tp1);
  perform public.start_travel(v_t2);
  perform pg_temp.as_pg();
  select fire_at, context into v_q from public.automation_queue where subject_id = v_t2 and event_key = 'technician.on_the_way';
  perform pg_temp.chk('TRAVEL queue row: not held by quiet hours, eta_minutes = 45 in the context',
    v_q.fire_at < now() + interval '1 minute' and (v_q.context ->> 'eta_minutes')::int = 45);
  -- job state guards
  insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (v_org, v_c, 'paid', '__TEST_ travel open') returning id into v_t3;
  insert into appointments (org_id, ticket_id, technician_id, scheduled_at, mode, status) values (v_org, v_t3, v_tech1, now() + interval '9 hours', 'datetime', 'scheduled');
  perform pg_temp.as_user(v_tp1);
  s := pg_temp.raises(format($q$select public.start_travel(%L)$q$, v_t3));
  perform pg_temp.as_pg();
  perform pg_temp.chk('TRAVEL a job that is not assigned (still open) cannot start travel', s like '%only be started for an assigned job%', coalesce(s, 'accepted'));
  update service_tickets set status = 'in_progress' where id = v_tk;
  perform pg_temp.chk('TRAVEL settings estimate is range-checked',
    pg_temp.raises(format($q$update settings set automation_default_travel_eta_minutes = 0 where org_id = %L$q$, v_org)) like '%check constraint%');

  -- failure isolation: the engine is broken, the stamp still commits and the error is logged
  insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (v_org, v_c, 'paid', '__TEST_ travel iso') returning id into v_t;
  insert into appointments (org_id, ticket_id, technician_id, scheduled_at, mode, status) values (v_org, v_t, v_tech2, now() + interval '3 hours', 'datetime', 'scheduled') returning id into v_ap;
  update service_tickets set status = 'assigned' where id = v_t;
  alter table public.automation_event_log rename to automation_event_log_x;
  perform pg_temp.as_user(v_tp2);
  s := pg_temp.raises(format($q$select public.start_travel(%L)$q$, v_t));
  perform pg_temp.as_pg();
  alter table public.automation_event_log_x rename to automation_event_log;
  perform pg_temp.chk('TRAVEL an automation failure does not undo the stamp, and it is logged',
    s is null and (select travel_started_at from public.appointments where id = v_ap) is not null
    and exists (select 1 from public.automation_errors where org_id = v_org and source = 'start_travel'), coalesce(s, 'ok'));

  -- ---------- nothing sent by the engine itself ----------
  perform pg_temp.chk('wa_dispatch_v2_enabled for the real organisation is untouched',
    not exists (select 1 from settings s join organizations o on o.id = s.org_id where o.name not like '\_\_TEST\_%' and s.wa_dispatch_v2_enabled));

  -- ---------- rebased onto items 1 and 2: the merged automation_emit keeps all three features ----------
  perform pg_temp.chk('merged automation_emit carries the per-item cooldown (item 1), the no-customer refusal (item 2) and the hand-off context (Stage B)',
    (select prosrc from pg_proc where proname = 'automation_emit' and pronamespace = 'public'::regnamespace) like '%cooldown_per_item%'
    and (select prosrc from pg_proc where proname = 'automation_emit' and pronamespace = 'public'::regnamespace) like '%no_customer_record%'
    and (select prosrc from pg_proc where proname = 'automation_emit' and pronamespace = 'public'::regnamespace) like '%v_ctx%'
    and (select prosrc from pg_proc where proname = 'automation_emit' and pronamespace = 'public'::regnamespace) like '%blocked_not_in_dispatch_scope%');
  perform pg_temp.chk('queue has item_key (item 1) and context (Stage B); rules have cooldown_per_item; the 17-argument rule save exists',
    (select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'automation_queue' and column_name in ('item_key', 'context')) = 2
    and exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'automation_rules' and column_name = 'cooldown_per_item')
    and to_regprocedure('public.automation_rule_save(uuid,text,text,text,jsonb,text,text,integer,integer,integer,text,uuid,text,text,boolean,integer,boolean)') is not null);

  raise exception 'RESULTS%', E'\n' || (select string_agg(r.line, E'\n' order by r.n) from pg_temp.res r);
end $t$;
$rh6$;
  v_hash := encode(sha256(convert_to(v_text, 'UTF8')), 'hex');
  if v_hash <> '41eb62373f95aa9791ae394b2b23560080d78fdf0debf0f219af601649b64594' then
    raise exception 'REHEARSAL_REFUSED: hash mismatch for automation_phase3b.test.sql: %', v_hash;
  end if;
  execute v_text;

  raise exception 'REHEARSAL_DID_NOT_RAISE: the test file should have raised RESULTS';
end
$rehearsal$;
