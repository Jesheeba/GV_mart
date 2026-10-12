-- Automation Phase 2 (design: docs/plan-automation-flows.md) - DATABASE FOUNDATION ONLY, DRY-RUN ONLY.
--
--   * automation_events      code-owned catalogue of every event a master can build a trigger on (has_emitter says whether
--                            anything in the code emits it today; every event is configurable either way)
--   * automation_flow_defs   a named group of rules ("flow")
--   * automation_rules       master-edited rules, immutable versions (an edit inserts version n+1, old row is_current=false)
--   * automation_event_log   APPEND-ONLY: one row for every automation_emit() call, whether or not a rule matched
--   * automation_audit       APPEND-ONLY: one row per rule decision (dry_run, skipped_*, blocked_*, config_changed)
--   * automation_errors      APPEND-ONLY: failures inside the emit triggers (no personal data); the business write goes on
--   * automation_queue       work the engine WOULD do. State is CHECK-limited to 'dry_run' / 'blocked_not_allowlisted':
--                            nothing here is deliverable, and no sender reads this table in this migration.
--   * automation_emit()      the single entry point. SECURITY DEFINER, search_path fixed, EXECUTE revoked from PUBLIC, anon
--                            and authenticated (service_role only; the emit triggers below run as the table owner).
--   * emit triggers          one thin AFTER trigger per source table for events that ALREADY exist in the code. They add
--                            nothing to the existing milestone/WhatsApp paths and swallow their own errors.
--
-- NOT touched: whatsapp_outbox, sendMessage, wa_dispatch_v2_enabled, any dispatcher/cron, any template. Nothing is sent.
-- Test isolation: an event whose customer (or lead) has is_test = true is tagged is_test, only test_only/live rules for test
-- subjects can match, and a test subject can never be queued toward a number that is not a flagged test customer's number
-- or on the existing allow-list (settings.wa_test_allowed_numbers).
-- Allow-list: the existing F-08 setting (settings.wa_test_mode_enabled, OFF by default, wa_test_allowed_numbers) is reused,
-- not duplicated: when ON, a would-be send to a number that is not on the list is recorded as blocked_not_allowlisted.

-- ── global kill switch ──────────────────────────────────────────────────────────────────────────────────────────────────
alter table public.settings add column if not exists automation_enabled boolean not null default true;

-- ── catalogue ───────────────────────────────────────────────────────────────────────────────────────────────────────────
create table public.automation_events (
  event_key            text primary key check (event_key ~ '^[a-z0-9_]+(\.[a-z0-9_]+)+$'),
  group_key            text not null,
  label_en             text not null,
  label_ta             text,
  subject_type         text not null,
  supported_recipients text[] not null,
  is_scheduled         boolean not null default false,
  has_emitter          boolean not null default false,
  created_at           timestamptz not null default now()
);

insert into public.automation_events (event_key, group_key, label_en, subject_type, supported_recipients, is_scheduled, has_emitter) values
  ('lead.created',               'leads',      'Lead created',                         'lead',       '{customer,sales,master}', false, true),
  ('lead.assigned',              'leads',      'Lead owner set or changed',            'lead',       '{sales}',                 false, true),
  ('lead.stage.contacted',       'leads',      'Lead moved to contacted',              'lead',       '{customer,sales}',        false, true),
  ('lead.stage.quoted',          'leads',      'Lead moved to quoted',                 'lead',       '{customer,sales}',        false, true),
  ('lead.stage.won',             'leads',      'Lead won',                             'lead',       '{customer,sales,master}', false, true),
  ('lead.stage.lost',            'leads',      'Lead lost',                            'lead',       '{customer,sales,master}', false, true),
  ('lead.reopened',              'leads',      'Lead reopened',                        'lead',       '{sales}',                 false, true),
  ('lead.followup.due',          'leads',      'Lead follow-up due',                   'lead',       '{sales}',                 true,  false),
  ('lead.followup.overdue',      'leads',      'Lead follow-up overdue',               'lead',       '{sales,master}',          true,  false),
  ('lead.stuck',                 'leads',      'Lead stuck (repeated postpones)',      'lead',       '{sales,master}',          true,  false),
  ('callback.requested',         'leads',      'Callback requested',                   'lead',       '{customer,sales,master}', false, false),
  ('product_enquiry.submitted',  'leads',      'Product enquiry submitted',            'lead',       '{customer,sales}',        false, true),
  ('spare_enquiry.submitted',    'leads',      'Spare enquiry submitted',              'lead',       '{customer,sales,operations}', false, true),
  ('enquiry.keyword_flow',       'leads',      'Keyword flow matched',                 'customer',   '{customer}',              false, false),
  ('quotation.created',          'quotations', 'Quotation created',                    'quotation',  '{sales}',                 false, true),
  ('quotation.sent',             'quotations', 'Quotation sent to customer',           'quotation',  '{customer}',              false, false),
  ('quotation.expiring',         'quotations', 'Quotation about to expire',            'quotation',  '{customer,sales}',        true,  false),
  ('quotation.converted',        'quotations', 'Quotation converted',                  'quotation',  '{customer,sales}',        false, true),
  ('quotation.lost',             'quotations', 'Quotation lost',                       'quotation',  '{sales}',                 false, true),
  ('sale.completed',             'sales',      'Sale completed',                       'invoice',    '{customer,sales,master}', false, false),
  ('invoice.issued',             'sales',      'Invoice issued',                       'invoice',    '{customer}',              false, true),
  ('invoice.partial',            'sales',      'Partial payment recorded',             'invoice',    '{customer}',              false, true),
  ('invoice.paid',               'sales',      'Invoice fully paid',                   'invoice',    '{customer,operations}',   false, true),
  ('invoice.due_soon',           'sales',      'Invoice due soon',                     'invoice',    '{customer}',              true,  false),
  ('invoice.overdue',            'sales',      'Invoice overdue',                      'invoice',    '{customer,operations}',   true,  false),
  ('payment.proof_uploaded',     'sales',      'Payment proof uploaded',               'invoice',    '{operations,master}',     false, false),
  ('ticket.created',             'service',    'Service ticket booked',                'ticket',     '{customer,operations}',   false, true),
  ('ticket.assigned',            'service',    'Technician assigned',                  'ticket',     '{customer,technician}',   false, true),
  ('ticket.rescheduled',         'service',    'Appointment rescheduled',              'ticket',     '{customer,technician}',   false, false),
  ('technician.on_the_way',      'service',    'Technician on the way',                'ticket',     '{customer}',              false, false),
  ('technician.arrived',         'service',    'Technician arrived (visit started)',   'visit',      '{customer}',              false, true),
  ('otp.issued',                 'service',    'Visit OTP issued',                     'visit',      '{customer}',              false, false),
  ('ticket.completed',           'service',    'Service completed',                    'ticket',     '{customer,sales,operations}', false, true),
  ('ticket.cancelled',           'service',    'Service ticket cancelled',             'ticket',     '{customer,technician}',   false, true),
  ('ticket.unassigned_escalated','service',    'No technician found, escalated',       'ticket',     '{operations,master}',     false, false),
  ('post_service.call_due',      'service',    'Post-service call due',                'ticket',     '{sales,operations}',      true,  false),
  ('feedback.requested',         'service',    'Feedback requested after service',     'ticket',     '{customer}',              true,  false),
  ('rating.low',                 'service',    'Low rating received',                  'ticket',     '{operations,master}',     false, false),
  ('review.google_requested',    'service',    'Google review request',                'ticket',     '{customer}',              true,  false),
  ('warranty.started',           'warranty',   'Warranty started',                     'warranty',   '{customer}',              false, true),
  ('warranty.expiring',          'warranty',   'Warranty expiring',                    'warranty',   '{customer}',              true,  false),
  ('warranty.expired',           'warranty',   'Warranty expired',                     'warranty',   '{customer}',              true,  false),
  ('amc.joined',                 'amc',        'AMC plan joined',                      'amc_contract','{customer,sales}',       false, true),
  ('amc.visit_scheduled',        'amc',        'AMC visit scheduled',                  'amc_contract','{customer,technician}',  false, false),
  ('amc.visit_reminder',         'amc',        'AMC visit reminder',                   'amc_contract','{customer,technician}',  true,  false),
  ('amc.expiring',               'amc',        'AMC expiring (30/15/7 days)',          'amc_contract','{customer,sales}',       true,  false),
  ('amc.expired',                'amc',        'AMC expired',                          'amc_contract','{customer,sales}',       false, true),
  ('amc.renewed',                'amc',        'AMC renewed',                          'amc_contract','{customer}',             false, false),
  ('rental.created',             'rental',     'Rental created',                       'customer',   '{customer,operations}',   false, false),
  ('rental.billing_due',         'rental',     'Rental bill due',                      'customer',   '{customer,operations}',   true,  false),
  ('rental.returned',            'rental',     'Rental returned',                      'customer',   '{customer,operations}',   false, false),
  ('referral.points_awarded',    'referral',   'Referral points awarded',              'customer',   '{customer}',              false, false),
  ('po.approval_pending',        'internal',   'Purchase order awaiting approval',     'other',      '{master,operations}',     false, false),
  ('po.payment_reminder',        'internal',   'Purchase order payment reminder',      'other',      '{master,operations}',     true,  false),
  ('po.overdue_escalated',       'internal',   'Purchase order overdue, escalated',    'other',      '{master}',                true,  false),
  ('rfq.monthly_opened',         'internal',   'Monthly RFQ opened',                   'other',      '{supplier,operations}',   true,  false),
  ('rfq.quote_received',         'internal',   'Supplier quote received',              'other',      '{operations}',            false, false),
  ('rfq.po_sent',                'internal',   'Purchase order sent to supplier',      'other',      '{supplier}',              false, false),
  ('stock.low',                  'internal',   'Low stock',                            'other',      '{operations,technician}', true,  false),
  ('task.assigned',              'internal',   'Task assigned',                        'other',      '{technician,sales,operations}', false, false),
  ('huddle.reminder',            'internal',   'Daily huddle reminder',                'other',      '{technician,sales,operations}', true, false),
  ('tier.promotion_flagged',     'internal',   'Technician tier promotion flagged',    'other',      '{master}',                true,  false),
  ('wa.send_gave_up',            'internal',   'WhatsApp send abandoned',              'other',      '{master,operations}',     false, false);

-- ── flows and rules ─────────────────────────────────────────────────────────────────────────────────────────────────────
create table public.automation_flow_defs (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.organizations(id) on delete cascade,
  name        text not null check (length(btrim(name)) between 1 and 120),
  description text,
  is_active   boolean not null default true,
  created_by  uuid references public.profiles(id) on delete set null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create unique index automation_flow_defs_name_uniq on public.automation_flow_defs (org_id, lower(name));

create table public.automation_rules (
  id                    uuid primary key default gen_random_uuid(),
  org_id                uuid not null references public.organizations(id) on delete cascade,
  rule_key              uuid not null default gen_random_uuid(),
  version               integer not null default 1 check (version >= 1),
  is_current            boolean not null default true,
  flow_id               uuid references public.automation_flow_defs(id),
  event_key             text not null references public.automation_events(event_key),
  recipient_role        text not null check (recipient_role in ('customer','technician','sales','master','operations','supplier')),
  channel               text not null default 'whatsapp' check (channel in ('whatsapp','in_app','both')),
  conditions            jsonb not null default '{}'::jsonb check (jsonb_typeof(conditions) = 'object'),
  template_name         text,
  language              text check (language in ('en','ta')),
  delay_minutes         integer not null default 0 check (delay_minutes >= 0),
  dedupe_cooldown_hours integer not null default 0 check (dedupe_cooldown_hours >= 0),
  max_fires             integer check (max_fires is null or max_fires > 0),
  status                text not null default 'test_only' check (status in ('test_only','live','paused')),
  note                  text,
  created_by            uuid references public.profiles(id) on delete set null,
  created_at            timestamptz not null default now(),
  unique (org_id, rule_key, version)
);
create unique index automation_rules_one_current on public.automation_rules (org_id, rule_key) where is_current;
create index automation_rules_event_idx on public.automation_rules (org_id, event_key) where is_current;

-- ── append-only logs ────────────────────────────────────────────────────────────────────────────────────────────────────
create table public.automation_event_log (
  id               uuid primary key,
  org_id           uuid not null references public.organizations(id) on delete cascade,
  occurred_at      timestamptz not null default now(),
  event_key        text not null,
  subject_type     text not null,
  subject_id       uuid not null,
  customer_id      uuid,
  is_test          boolean not null default false,
  occurrence_key   text not null default '',
  payload_keys     text[] not null default '{}',
  actor_id         uuid,
  rules_considered integer not null default 0,
  rules_queued     integer not null default 0,
  outcome          text not null check (outcome in ('unknown_event','global_off','no_rule','processed','duplicate'))
);
create index automation_event_log_org_time on public.automation_event_log (org_id, occurred_at desc);
create index automation_event_log_subject on public.automation_event_log (org_id, subject_id);

create table public.automation_audit (
  id                    uuid primary key default gen_random_uuid(),
  org_id                uuid not null references public.organizations(id) on delete cascade,
  occurred_at           timestamptz not null default now(),
  event_id              uuid,
  event_key             text,
  subject_type          text,
  subject_id            uuid,
  rule_id               uuid,
  rule_key              uuid,
  rule_version          integer,
  recipient_role        text,
  recipient_customer_id uuid,
  recipient_masked      text,
  channel               text,
  template_name         text,
  decision              text not null check (decision in (
                          'dry_run','blocked_not_allowlisted','skipped_paused','skipped_condition','skipped_test_only',
                          'skipped_no_recipient','skipped_duplicate','skipped_max_fires','skipped_cooldown','config_changed')),
  detail                jsonb not null default '{}'::jsonb,
  is_test               boolean not null default false,
  idempotency_key       text,
  actor_id              uuid
);
create index automation_audit_event on public.automation_audit (org_id, event_id);
create index automation_audit_time on public.automation_audit (org_id, occurred_at desc);

create table public.automation_queue (
  id               uuid primary key default gen_random_uuid(),
  org_id           uuid not null references public.organizations(id) on delete cascade,
  idempotency_key  text not null,
  rule_id          uuid not null,
  rule_key         uuid not null,
  rule_version     integer not null,
  event_id         uuid not null,
  event_key        text not null,
  subject_type     text not null,
  subject_id       uuid not null,
  customer_id      uuid,
  recipient_role   text not null,
  recipient_masked text,
  channel          text not null,
  template_name    text,
  language         text,
  fire_at          timestamptz not null,
  state            text not null check (state in ('dry_run','blocked_not_allowlisted')),
  is_test          boolean not null default false,
  created_at       timestamptz not null default now(),
  unique (org_id, idempotency_key)
);
create index automation_queue_rule_idx on public.automation_queue (org_id, rule_key, subject_id);
create index automation_queue_customer_idx on public.automation_queue (org_id, rule_key, customer_id, created_at);

-- the append-only guard: same shape as audit_log's (20261011110000); test-organisation purge goes through the same flag.
create function public._trg_automation_append_only()
returns trigger language plpgsql set search_path = public as $$
begin
  if tg_op = 'TRUNCATE' then
    raise exception '% is append-only: TRUNCATE is not allowed', tg_table_name;
  end if;
  if tg_op = 'DELETE' and current_user = 'postgres' and coalesce(current_setting('app.audit_purge_ok', true), '') = '1' then
    return old;
  end if;
  raise exception '% is append-only (% refused)', tg_table_name, tg_op;
end;
$$;
revoke all on function public._trg_automation_append_only() from public, anon, authenticated;
create trigger automation_event_log_append_only before update or delete on public.automation_event_log
  for each row execute function public._trg_automation_append_only();
create trigger automation_event_log_no_truncate before truncate on public.automation_event_log
  for each statement execute function public._trg_automation_append_only();
create trigger automation_audit_append_only before update or delete on public.automation_audit
  for each row execute function public._trg_automation_append_only();
create trigger automation_audit_no_truncate before truncate on public.automation_audit
  for each statement execute function public._trg_automation_append_only();

-- rules are immutable versions: the only allowed change is is_current true -> false (a newer version replaced it)
create function public._trg_automation_rules_immutable()
returns trigger language plpgsql set search_path = public as $$
begin
  if tg_op = 'DELETE' then
    if current_user = 'postgres' and coalesce(current_setting('app.audit_purge_ok', true), '') = '1' then
      return old;
    end if;
    raise exception 'automation_rules rows are immutable (DELETE refused)';
  end if;
  if old.is_current and not new.is_current
     and (to_jsonb(new) - 'is_current') = (to_jsonb(old) - 'is_current') then
    return new;
  end if;
  -- FK action "created_by ON DELETE SET NULL" after the author's profile was removed: the only other allowed change
  if old.created_by is not null and new.created_by is null
     and not exists (select 1 from public.profiles where id = old.created_by)
     and (to_jsonb(new) - 'created_by') = (to_jsonb(old) - 'created_by') then
    return new;
  end if;
  raise exception 'automation_rules rows are immutable: save a new version instead';
end;
$$;
revoke all on function public._trg_automation_rules_immutable() from public, anon, authenticated;
create trigger automation_rules_immutable before update or delete on public.automation_rules
  for each row execute function public._trg_automation_rules_immutable();

-- ── privileges and RLS (read for master/operations; no client write path at all) ───────────────────────────────────────
alter table public.automation_events    enable row level security;
alter table public.automation_flow_defs enable row level security;
alter table public.automation_rules     enable row level security;
alter table public.automation_event_log enable row level security;
alter table public.automation_audit     enable row level security;
alter table public.automation_queue     enable row level security;

revoke all on public.automation_events, public.automation_flow_defs, public.automation_rules,
              public.automation_event_log, public.automation_audit, public.automation_queue from public, anon, authenticated;
grant select on public.automation_events, public.automation_flow_defs, public.automation_rules,
                public.automation_event_log, public.automation_audit, public.automation_queue to authenticated, service_role;

create policy automation_events_select on public.automation_events for select to authenticated using (public.is_staff());
create policy automation_flow_defs_select on public.automation_flow_defs for select to authenticated
  using (org_id = public.current_org_id() and public.is_ops_staff());
create policy automation_rules_select on public.automation_rules for select to authenticated
  using (org_id = public.current_org_id() and public.is_ops_staff());
create policy automation_event_log_select on public.automation_event_log for select to authenticated
  using (org_id = public.current_org_id() and public.is_ops_staff());
create policy automation_audit_select on public.automation_audit for select to authenticated
  using (org_id = public.current_org_id() and public.is_ops_staff());
create policy automation_queue_select on public.automation_queue for select to authenticated
  using (org_id = public.current_org_id() and public.is_ops_staff());

-- ── failure isolation: emit failures are logged here, never raised into the business write ───────────────────────────
-- No personal data: only the table/operation, event key, subject id, SQLSTATE and a scrubbed message (digit runs of 7+,
-- e-mail-like tokens removed, 300 chars max).
create table public.automation_errors (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references public.organizations(id) on delete cascade,
  occurred_at  timestamptz not null default now(),
  source       text not null,
  event_key    text,
  subject_type text,
  subject_id   uuid,
  sqlstate     text,
  message      text
);
create index automation_errors_org_time on public.automation_errors (org_id, occurred_at desc);
alter table public.automation_errors enable row level security;
revoke all on public.automation_errors from public, anon, authenticated;
grant select on public.automation_errors to authenticated, service_role;
create policy automation_errors_select on public.automation_errors for select to authenticated
  using (org_id = public.current_org_id() and public.is_ops_staff());
create trigger automation_errors_append_only before update or delete on public.automation_errors
  for each row execute function public._trg_automation_append_only();
create trigger automation_errors_no_truncate before truncate on public.automation_errors
  for each statement execute function public._trg_automation_append_only();

create function public._automation_log_error(
  p_org uuid, p_source text, p_event_key text, p_subject_type text, p_subject_id uuid, p_sqlstate text, p_message text)
returns void language plpgsql security definer set search_path = public as $$
begin
  begin
    insert into public.automation_errors (org_id, source, event_key, subject_type, subject_id, sqlstate, message)
    values (p_org, p_source, p_event_key, p_subject_type, p_subject_id, p_sqlstate,
            left(regexp_replace(regexp_replace(coalesce(p_message, ''), '[0-9]{7,}', '#', 'g'), '\S+@\S+', '#', 'g'), 300));
  exception when others then
    -- the error log itself must never block a business write either
    raise warning 'automation error log failed (%)', sqlstate;
  end;
end;
$$;
revoke all on function public._automation_log_error(uuid, text, text, text, uuid, text, text) from public, anon, authenticated;
grant execute on function public._automation_log_error(uuid, text, text, text, uuid, text, text) to service_role;

-- ── helpers ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
-- conditions: {"key": "value"} equality on payload text; {"key": ["a","b"]} any-of; {"min_total": 1000} / {"max_total": 5000}
-- numeric bounds on payload.total. A key missing from the payload never matches.
create function public._automation_conditions_match(p_conditions jsonb, p_payload jsonb)
returns boolean language plpgsql immutable set search_path = public as $$
declare
  c record; v_actual text; v_field text;
begin
  for c in select key, value from jsonb_each(coalesce(p_conditions, '{}'::jsonb)) loop
    if c.key like 'min\_%' or c.key like 'max\_%' then
      v_field := substr(c.key, 5);
      v_actual := p_payload ->> v_field;
      if v_actual is null or v_actual !~ '^-?[0-9]+(\.[0-9]+)?$' or jsonb_typeof(c.value) <> 'number' then
        return false;
      end if;
      if c.key like 'min\_%' and v_actual::numeric < (c.value #>> '{}')::numeric then return false; end if;
      if c.key like 'max\_%' and v_actual::numeric > (c.value #>> '{}')::numeric then return false; end if;
    else
      v_actual := p_payload ->> c.key;
      if v_actual is null then return false; end if;
      if jsonb_typeof(c.value) = 'array' then
        if not exists (select 1 from jsonb_array_elements_text(c.value) e where e = v_actual) then return false; end if;
      elsif (c.value #>> '{}') is distinct from v_actual then
        return false;
      end if;
    end if;
  end loop;
  return true;
end;
$$;
revoke all on function public._automation_conditions_match(jsonb, jsonb) from public, anon, authenticated;
grant execute on function public._automation_conditions_match(jsonb, jsonb) to service_role;

-- ── the engine entry point ──────────────────────────────────────────────────────────────────────────────────────────────
create function public.automation_emit(
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

-- ── master: save a rule (creates version 1, or the next version of an existing rule_key) ───────────────────────────────
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

-- ── emit hooks for events that already exist in the code ───────────────────────────────────────────────────────────────
-- Each trigger function is SECURITY DEFINER (the signed-in session has no EXECUTE on automation_emit), early-exits on
-- no-op updates, and can never fail the business statement: any error (EXCEPTION WHEN OTHERS) is written to
-- automation_errors and swallowed. (Only QUERY_CANCELED, i.e. a statement timeout, is not catchable in PL/pgSQL.)

create function public._trg_automation_emit_ticket()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_tech uuid;
begin
  begin
    if tg_op = 'INSERT' then
      perform public.automation_emit(new.org_id, 'ticket.created', 'ticket', new.id, new.customer_id, 'created',
        jsonb_build_object('ticket_type', new.type::text, 'priority', new.priority::text, 'channel', new.channel::text,
                           'product_id', new.product_id, 'status', new.status::text));
    elsif new.status is distinct from old.status and new.status::text in ('assigned', 'completed', 'cancelled') then
      select a.technician_id into v_tech from public.appointments a where a.ticket_id = new.id order by a.created_at desc limit 1;
      perform public.automation_emit(new.org_id, 'ticket.' || new.status::text, 'ticket', new.id, new.customer_id, new.status::text,
        jsonb_build_object('ticket_type', new.type::text, 'priority', new.priority::text, 'channel', new.channel::text,
                           'product_id', new.product_id, 'status', new.status::text, 'technician_id', v_tech,
                           'has_lead', new.lead_id is not null));
    end if;
  exception when others then
    perform public._automation_log_error(new.org_id, tg_table_name || ':' || tg_op, null, 'ticket', new.id, sqlstate, sqlerrm);
  end;
  return null;
end;
$$;
revoke all on function public._trg_automation_emit_ticket() from public, anon, authenticated;
create trigger zz_automation_emit_ticket after insert or update of status on public.service_tickets
  for each row execute function public._trg_automation_emit_ticket();

create function public._trg_automation_emit_visit()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_cust uuid;
begin
  begin
    select t.customer_id into v_cust from public.service_tickets t where t.id = new.ticket_id;
    -- the visit row is created when the technician ARRIVES (there is no departure signal in the app yet), so this is
    -- technician.arrived; technician.on_the_way has no emitter until a "start travel" action exists.
    perform public.automation_emit(new.org_id, 'technician.arrived', 'visit', new.id, v_cust, 'arrived',
      jsonb_build_object('ticket_id', new.ticket_id, 'technician_id', new.technician_id));
  exception when others then
    perform public._automation_log_error(new.org_id, tg_table_name || ':' || tg_op, null, 'visit', new.id, sqlstate, sqlerrm);
  end;
  return null;
end;
$$;
revoke all on function public._trg_automation_emit_visit() from public, anon, authenticated;
create trigger zz_automation_emit_visit after insert on public.service_visits
  for each row execute function public._trg_automation_emit_visit();

create function public._trg_automation_emit_invoice()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_payload jsonb;
begin
  begin
    v_payload := jsonb_build_object('invoice_type', new.type::text, 'total', new.total, 'amount_paid', new.amount_paid,
                                    'payment_status', new.payment_status::text);
    if tg_op = 'INSERT' then
      perform public.automation_emit(new.org_id, 'invoice.issued', 'invoice', new.id, new.customer_id, 'issued', v_payload);
    elsif new.payment_status is distinct from old.payment_status then
      if new.payment_status::text = 'partial' then
        perform public.automation_emit(new.org_id, 'invoice.partial', 'invoice', new.id, new.customer_id,
                                       'partial@' || coalesce(new.amount_paid, 0)::text, v_payload);
      elsif new.payment_status::text = 'paid' then
        perform public.automation_emit(new.org_id, 'invoice.paid', 'invoice', new.id, new.customer_id, 'paid', v_payload);
      end if;
    end if;
  exception when others then
    perform public._automation_log_error(new.org_id, tg_table_name || ':' || tg_op, null, 'invoice', new.id, sqlstate, sqlerrm);
  end;
  return null;
end;
$$;
revoke all on function public._trg_automation_emit_invoice() from public, anon, authenticated;
create trigger zz_automation_emit_invoice after insert or update of payment_status on public.invoices
  for each row execute function public._trg_automation_emit_invoice();

create function public._trg_automation_emit_lead()
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
revoke all on function public._trg_automation_emit_lead() from public, anon, authenticated;
create trigger zz_automation_emit_lead after insert or update of status, assigned_to on public.leads
  for each row execute function public._trg_automation_emit_lead();

create function public._trg_automation_emit_amc()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  begin
    if tg_op = 'INSERT' then
      perform public.automation_emit(new.org_id, 'amc.joined', 'amc_contract', new.id, new.customer_id, 'joined',
        jsonb_build_object('plan_id', new.plan_id, 'product_id', new.product_id, 'expiry_date', new.expiry_date::text));
    elsif new.status is distinct from old.status and new.status::text = 'expired' then
      perform public.automation_emit(new.org_id, 'amc.expired', 'amc_contract', new.id, new.customer_id,
        'expired@' || new.expiry_date::text,
        jsonb_build_object('plan_id', new.plan_id, 'product_id', new.product_id, 'expiry_date', new.expiry_date::text));
    end if;
  exception when others then
    perform public._automation_log_error(new.org_id, tg_table_name || ':' || tg_op, null, 'amc_contract', new.id, sqlstate, sqlerrm);
  end;
  return null;
end;
$$;
revoke all on function public._trg_automation_emit_amc() from public, anon, authenticated;
create trigger zz_automation_emit_amc after insert or update of status on public.amc_contracts
  for each row execute function public._trg_automation_emit_amc();

create function public._trg_automation_emit_warranty()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  begin
    perform public.automation_emit(new.org_id, 'warranty.started', 'warranty', new.id, new.customer_id, 'started',
      jsonb_build_object('product_id', new.product_id, 'expiry_date', new.expiry_date::text));
  exception when others then
    perform public._automation_log_error(new.org_id, tg_table_name || ':' || tg_op, null, 'warranty', new.id, sqlstate, sqlerrm);
  end;
  return null;
end;
$$;
revoke all on function public._trg_automation_emit_warranty() from public, anon, authenticated;
create trigger zz_automation_emit_warranty after insert on public.warranties
  for each row execute function public._trg_automation_emit_warranty();

create function public._trg_automation_emit_quotation()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  begin
    if tg_op = 'INSERT' then
      perform public.automation_emit(new.org_id, 'quotation.created', 'quotation', new.id, new.customer_id, 'created',
        jsonb_build_object('total', new.total, 'lead_id', new.lead_id));
    elsif new.status is distinct from old.status and new.status::text in ('converted', 'lost') then
      perform public.automation_emit(new.org_id, 'quotation.' || new.status::text, 'quotation', new.id, new.customer_id,
        new.status::text, jsonb_build_object('total', new.total, 'lead_id', new.lead_id));
    end if;
  exception when others then
    perform public._automation_log_error(new.org_id, tg_table_name || ':' || tg_op, null, 'quotation', new.id, sqlstate, sqlerrm);
  end;
  return null;
end;
$$;
revoke all on function public._trg_automation_emit_quotation() from public, anon, authenticated;
create trigger zz_automation_emit_quotation after insert or update of status on public.quotations
  for each row execute function public._trg_automation_emit_quotation();
