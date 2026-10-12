-- Automation Phase 3 / Stage A, part 3: engine rules (S0a, S0b, S1, S4, S5, S6, S7). STILL DRY RUN ONLY.
--
--   S0a  rows are tagged mode 'shadow' | 'live'. Cooldown, max-fires and the daily cap count only rows of the SAME mode and
--        only rows that were not blocked, deferred or dropped. A shadow row can never block a real send.
--   S0b  the idempotency key now ends in |<mode>|<recipient>, so a shadow row never suppresses the live send of the same
--        occurrence. Replay protection inside each mode is unchanged.
--   S1   a sales-role rule whose lead has no sales person goes to every active master (in-app; audited as fallback).
--   S4   quiet hours (settings, default 21:00 to 08:00 IST): fire_at is pushed to the end of the window. Events flagged
--        quiet_hours_exempt (technician.on_the_way, otp.issued) and rules with respect_quiet_hours = false are not held.
--   S5   daily cap (settings, default 3) for NON-JOB messages per customer per IST day. Class comes from the rule, else the
--        template class table, else the event default, else non_job. Job and invoice messages are never counted or capped.
--        Over the cap: state 'deferred' to next day's window end with an expiry; a deferred row whose window passed is
--        'expired', never sent. automation_release_deferred() re-checks and releases or expires them.
--   S6   review requests: event floor of 2160 hours (90 days) between sends to the same customer.
--   S7   a customer-role rule goes to customers.mobile only, never a family member's number.
--   S3   opted-out numbers are skipped by class (see customer_comm_prefs).
--
-- Queue states remain CHECK-limited to non-deliverable values; no sender reads the queue. Nothing is sent.

-- ── settings ────────────────────────────────────────────────────────────────────────────────────────────────────────────
alter table public.settings
  add column if not exists automation_quiet_start time not null default '21:00',
  add column if not exists automation_quiet_end time not null default '08:00',
  add column if not exists automation_non_job_daily_cap integer not null default 3;
alter table public.settings drop constraint if exists settings_automation_cap_check;
alter table public.settings add constraint settings_automation_cap_check check (automation_non_job_daily_cap >= 1);

-- ── catalogue defaults ──────────────────────────────────────────────────────────────────────────────────────────────────
alter table public.automation_events
  add column default_message_class text not null default 'non_job' check (default_message_class in ('job', 'non_job')),
  add column quiet_hours_exempt boolean not null default false,
  add column min_cooldown_hours integer not null default 0 check (min_cooldown_hours >= 0);

update public.automation_events set default_message_class = 'job'
 where event_key in ('ticket.created', 'ticket.assigned', 'ticket.completed', 'ticket.cancelled', 'ticket.rescheduled',
                     'technician.on_the_way', 'technician.arrived', 'otp.issued', 'invoice.issued', 'invoice.partial',
                     'invoice.paid', 'invoice.due_soon', 'sale.completed', 'amc.joined', 'amc.visit_scheduled',
                     'amc.visit_reminder', 'warranty.started');
update public.automation_events set quiet_hours_exempt = true where event_key in ('technician.on_the_way', 'otp.issued');
update public.automation_events set min_cooldown_hours = 2160 where event_key = 'review.google_requested';

-- per-template classification (global seed; base name without _en/_ta). Unclassified templates are treated as non_job.
create table public.automation_template_classes (
  template_base text primary key check (template_base ~ '^[a-z0-9_]+$'),
  message_class text not null check (message_class in ('job', 'non_job')),
  note          text
);
insert into public.automation_template_classes (template_base, message_class, note) values
  ('gvm_service_booked',        'job',     'service lifecycle'),
  ('gvm_technician_assigned',   'job',     'service lifecycle'),
  ('gvm_technician_on_the_way', 'job',     'service lifecycle, time critical'),
  ('gvm_technician_arrived',    'job',     'service lifecycle'),
  ('gvm_service_completed',     'job',     'service lifecycle'),
  ('gvm_service_cancelled',     'job',     'service lifecycle'),
  ('gvm_service_rescheduled',   'job',     'service lifecycle'),
  ('gvm_invoice_issued',        'job',     'invoice: exempt from the cap'),
  ('invoice_document',          'job',     'invoice: exempt from the cap'),
  ('gvm_payment_received',      'job',     'invoice'),
  ('gvm_payment_due',           'job',     'invoice'),
  ('gvm_payment_overdue',       'job',     'invoice'),
  ('gvm_amc_welcome',           'job',     'AMC lifecycle'),
  ('gvm_amc_visit_scheduled',   'job',     'AMC lifecycle'),
  ('gvm_amc_visit_reminder',    'job',     'AMC lifecycle'),
  ('gvm_visit_otp',             'job',     'authentication code'),
  ('gvm_warranty_started',      'job',     'warranty record'),
  ('gvm_feedback_request',      'non_job', 'feedback: capped, stoppable'),
  ('gvm_google_review',         'non_job', 'review request: capped, stoppable, 90-day floor'),
  ('gvm_amc_expiring',          'non_job', 'renewal reminder'),
  ('gvm_amc_expired',           'non_job', 'renewal reminder'),
  ('gvm_amc_renewed',           'non_job', 'renewal'),
  ('gvm_quotation_expiring',    'non_job', 'promotion-like'),
  ('gvm_warranty_expiring',     'non_job', 'renewal-like'),
  ('gvm_enquiry_video',         'non_job', 'promotion-like'),
  ('gvm_referral_points',       'non_job', 'promotion-like');
alter table public.automation_template_classes enable row level security;
revoke all on public.automation_template_classes from public, anon, authenticated;
grant select on public.automation_template_classes to authenticated, service_role;
create policy automation_template_classes_select on public.automation_template_classes for select to authenticated using (public.is_staff());

-- ── rules: new knobs and a 'shadow' status ──────────────────────────────────────────────────────────────────────────────
alter table public.automation_rules
  add column message_class        text check (message_class in ('job', 'non_job')),
  add column respect_quiet_hours  boolean,
  add column max_defer_hours      integer not null default 72 check (max_defer_hours > 0);
alter table public.automation_rules drop constraint automation_rules_status_check;
alter table public.automation_rules
  add constraint automation_rules_status_check check (status in ('test_only', 'shadow', 'live', 'paused'));

-- ── queue / audit ───────────────────────────────────────────────────────────────────────────────────────────────────────
alter table public.automation_queue
  add column mode                 text not null default 'live' check (mode in ('shadow', 'live')),
  add column message_class        text,
  add column expires_at           timestamptz,
  add column recipient_profile_id uuid,
  add column detail               jsonb not null default '{}'::jsonb;
alter table public.automation_queue drop constraint automation_queue_state_check;
alter table public.automation_queue
  add constraint automation_queue_state_check check (state in ('dry_run', 'blocked_not_allowlisted', 'deferred', 'expired'));
create index automation_queue_deferred_idx on public.automation_queue (org_id, fire_at) where state = 'deferred';

alter table public.automation_audit drop constraint automation_audit_decision_check;
alter table public.automation_audit add constraint automation_audit_decision_check check (decision in (
  'dry_run', 'blocked_not_allowlisted', 'skipped_paused', 'skipped_condition', 'skipped_test_only', 'skipped_no_recipient',
  'skipped_duplicate', 'skipped_max_fires', 'skipped_cooldown', 'skipped_opt_out', 'deferred_daily_cap',
  'released_deferred', 'expired_deferred', 'config_changed'));

-- ── helpers ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
-- the earliest time at or after p_ts that is outside quiet hours (all in IST); the window may wrap midnight
create function public._automation_next_allowed(p_ts timestamptz, p_org uuid)
returns timestamptz
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_start time; v_end time; v_local timestamp; v_t time; v_day date; v_in_quiet boolean;
begin
  select s.automation_quiet_start, s.automation_quiet_end into v_start, v_end from public.settings s where s.org_id = p_org;
  v_start := coalesce(v_start, '21:00'); v_end := coalesce(v_end, '08:00');
  if v_start = v_end then return p_ts; end if;
  v_local := p_ts at time zone 'Asia/Kolkata';
  v_t := v_local::time; v_day := v_local::date;
  if v_start > v_end then
    v_in_quiet := v_t >= v_start or v_t < v_end;
    if not v_in_quiet then return p_ts; end if;
    if v_t >= v_start then v_day := v_day + 1; end if;
  else
    v_in_quiet := v_t >= v_start and v_t < v_end;
    if not v_in_quiet then return p_ts; end if;
  end if;
  return (v_day + v_end) at time zone 'Asia/Kolkata';
end;
$$;
revoke all on function public._automation_next_allowed(timestamptz, uuid) from public, anon, authenticated;
grant execute on function public._automation_next_allowed(timestamptz, uuid) to service_role;

create function public._automation_class(p_template text, p_rule_class text, p_event_class text)
returns text
language sql
stable
set search_path = public
as $$
  select coalesce(
    p_rule_class,
    (select c.message_class from public.automation_template_classes c
      where c.template_base = regexp_replace(coalesce(p_template, ''), '_(en|ta)$', '')),
    p_event_class,
    'non_job')
$$;
revoke all on function public._automation_class(text, text, text) from public, anon, authenticated;
grant execute on function public._automation_class(text, text, text) to service_role;

-- main customer's mobile only (never customer_members)
create function public._automation_customer_mobile(p_org uuid, p_customer uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select public._mobile_key(c.mobile) from public.customers c where c.id = p_customer and c.org_id = p_org
$$;
revoke all on function public._automation_customer_mobile(uuid, uuid) from public, anon, authenticated;
grant execute on function public._automation_customer_mobile(uuid, uuid) to service_role;

-- language: preferred_language, then the login's language, then the rule's, then English
create function public._automation_language(p_org uuid, p_customer uuid, p_rule_language text)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select c.preferred_language from public.customers c where c.id = p_customer and c.org_id = p_org),
    (select pr.language from public.customers c join public.profiles pr on pr.id = c.primary_profile_id
      where c.id = p_customer and c.org_id = p_org and pr.language in ('en', 'ta')),
    p_rule_language,
    'en')
$$;
revoke all on function public._automation_language(uuid, uuid, text) from public, anon, authenticated;
grant execute on function public._automation_language(uuid, uuid, text) to service_role;

create function public._automation_active_masters(p_org uuid)
returns uuid[]
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(array_agg(p.id order by p.id), '{}'::uuid[])
    from public.profiles p where p.org_id = p_org and p.role = 'master' and p.is_active
$$;
revoke all on function public._automation_active_masters(uuid) from public, anon, authenticated;
grant execute on function public._automation_active_masters(uuid) to service_role;

create function public._automation_audit_row(
  p_org uuid, p_event_id uuid, p_event_key text, p_subject_type text, p_subject_id uuid,
  p_rule_id uuid, p_rule_key uuid, p_rule_version integer, p_role text, p_customer uuid, p_masked text,
  p_channel text, p_template text, p_decision text, p_detail jsonb, p_is_test boolean, p_key text)
returns void
language sql
security definer
set search_path = public
as $$
  insert into public.automation_audit (org_id, event_id, event_key, subject_type, subject_id, rule_id, rule_key, rule_version,
         recipient_role, recipient_customer_id, recipient_masked, channel, template_name, decision, detail, is_test, idempotency_key)
  values (p_org, p_event_id, p_event_key, p_subject_type, p_subject_id, p_rule_id, p_rule_key, p_rule_version,
          p_role, p_customer, p_masked, p_channel, p_template, p_decision, coalesce(p_detail, '{}'::jsonb), p_is_test, p_key)
$$;
revoke all on function public._automation_audit_row(uuid, uuid, text, text, uuid, uuid, uuid, integer, text, uuid, text, text, text, text, jsonb, boolean, text) from public, anon, authenticated;
grant execute on function public._automation_audit_row(uuid, uuid, text, text, uuid, uuid, uuid, integer, text, uuid, text, text, text, text, jsonb, boolean, text) to service_role;

-- ── the engine ──────────────────────────────────────────────────────────────────────────────────────────────────────────
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

-- ── deferred rows: release or drop (S5). Scheduled in Stage B; callable now by the service role / tests ────────────────────
create function public.automation_release_deferred(p_now timestamptz default now())
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

-- ── rule save with the new knobs (replaces the 13-argument version; same leading arguments, new ones default) ───────────────
drop function public.automation_rule_save(uuid, text, text, text, jsonb, text, text, integer, integer, integer, text, uuid, text);
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
