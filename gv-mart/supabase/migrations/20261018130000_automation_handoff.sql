-- Automation Phase 3 / Stage B, part 1: the hand-off from the automation queue to the dispatcher's outbox.
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
                and q.state not in ('blocked_not_allowlisted', 'blocked_not_in_dispatch_scope', 'deferred', 'expired', 'expired_stale', 'skipped_no_template', 'skipped_no_recipient', 'skipped_opt_out')) >= r.max_fires then
          perform public._automation_audit_row(p_org_id, v_event_id, p_event_key, p_subject_type, p_subject_id, r.id, r.rule_key, r.version,
            r.recipient_role, v_cust, v_masked, r.channel, r.template_name, 'skipped_max_fires', v_detail, v_test, v_key);
          continue;
        end if;

        -- S6: cooldown (rule value, raised to the event's floor: review requests 90 days)
        if v_cool > 0 and v_cust is not null and exists (
             select 1 from public.automation_queue q
              where q.org_id = p_org_id and q.rule_key = r.rule_key and q.customer_id = v_cust and q.mode = v_mode
                and q.state not in ('blocked_not_allowlisted', 'blocked_not_in_dispatch_scope', 'deferred', 'expired', 'expired_stale', 'skipped_no_template', 'skipped_no_recipient', 'skipped_opt_out')
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
                 fire_at, state, is_test, mode, message_class, recipient_profile_id, detail, context)
          values (p_org_id, v_key, r.id, r.rule_key, r.version, v_event_id, p_event_key, p_subject_type, p_subject_id, v_cust,
                  r.recipient_role, v_masked, r.channel, r.template_name, v_lang, v_fire, 'blocked_not_allowlisted', v_test,
                  v_mode, v_class, v_rec, v_detail, v_ctx)
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
                   fire_at, state, is_test, mode, message_class, expires_at, recipient_profile_id, detail, context)
            values (p_org_id, v_key, r.id, r.rule_key, r.version, v_event_id, p_event_key, p_subject_type, p_subject_id, v_cust,
                    r.recipient_role, v_masked, r.channel, r.template_name, v_lang, v_defer_to,
                    case when v_expires <= v_defer_to then 'expired' else 'deferred' end, v_test,
                    v_mode, v_class, v_expires, v_rec, v_detail, v_ctx)
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
               fire_at, state, is_test, mode, message_class, recipient_profile_id, detail, context)
        values (p_org_id, v_key, r.id, r.rule_key, r.version, v_event_id, p_event_key, p_subject_type, p_subject_id, v_cust,
                r.recipient_role, v_masked, r.channel, r.template_name, v_lang, v_fire, 'dry_run', v_test,
                v_mode, v_class, v_rec, v_detail, v_ctx)
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
