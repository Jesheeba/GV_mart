-- REHEARSAL (NOT RUN; for the owner's approval of this exact text): existing post-service follow-up tests (ACL line updated for the 6-argument signature) after migration 20261027100000
-- One request, one DO block. It: (1) refuses to run before 18:00 IST (the clock is read from clock_timestamp()), (2) recomputes
-- the sha256 of every embedded file and refuses on any mismatch with the pinned value, (3) executes the migration text(s) and then the
-- test file in order, (4) always ends in an unconditional RAISE EXCEPTION, so nothing is ever committed.
-- No top-level begin / commit / savepoint / rollback. No schema_migrations row is written. Never concatenated with test code outside
-- this wrapper. Expected error text starts with RESULTS (or TIMING); anything else is a failure and also rolls back.
-- Pinned (sha256 of the LF blob at the commit this wrapper was generated from):
--   29795b2ebeb1f1569795114ea978e14bd2795af5a2397f61da7e9256932a154c  gv-mart/supabase/migrations/20261027100000_followup_questions.sql
--   086ba1e29fd5a1a43c688315addda53ce4e2e0f007d604a9286f929831802ee4  gv-mart/supabase/tests/post_service_followup.test.sql

do $rehearsal$
declare
  v_ist time := (clock_timestamp() at time zone 'Asia/Kolkata')::time;
  v_text text;
  v_hash text;
begin
  if v_ist < time '18:00' then
    raise exception 'REHEARSAL_REFUSED: the clock reads % IST, before 18:00 IST', to_char(v_ist, 'HH24:MI:SS');
  end if;

  v_text := $rh0$-- Master-defined questions for follow-up calls (post-service calls first). Design: gv-mart/docs/design-followup-questions.md
--
--   followup_questions              master-edited question list (org-scoped). Soft delete only: a question is deactivated, never
--                                   deleted, so old answers keep their wording. answer_type is fixed once created.
--   followup_question_ticket_types  optional restriction: a question with NO rows here applies to every ticket type, a row
--                                   restricts it to that type (several rows = any of them).
--   post_service_call_answers       one row per question per call, written only by log_post_service_call. Carries a SNAPSHOT of
--                                   the question text (en + ta), type and choices, so a later edit never rewrites history.
--   post_service_calls.followup_needed  boolean, nullable: the caller's answer to "Follow-up needed?" (NULL = not asked / retry).
--   log_post_service_call           new 6-argument signature (answers, followup_needed); the old 4-argument one is DROPPED.
--   get_post_service_questions      the questions the call sheet shows for one follow-up.
--   report_followup_question_answers  master-only, read-only distribution per question for a date range.
--
-- Separate from the Google-review flow: nothing here reads or writes ratings, ratings.google_review_clicked or any review link.
-- No reward or incentive wording exists in this feature. There is no per-technician review column.
--
-- Scope is a free nullable text column: 'post_service' now (NULL is treated the same), other scopes (for example a lead-call scope)
-- can be added later by data. Ticket-type restriction is the link table.
--
-- Backward compatibility: a call without answers and without followup_needed behaves exactly as before (same checks, same
-- writes, same notification); the JSON result gains keys. See the signature note at the function.

-- 1. questions -----------------------------------------------------------------------------------------------------
create table public.followup_questions (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  code text not null default ('q_' || replace(gen_random_uuid()::text, '-', '')),
  scope text check (scope is null or scope ~ '^[a-z][a-z_]{0,39}$'),
  text_en text not null check (char_length(btrim(text_en)) between 1 and 300),
  text_ta text not null default '' check (char_length(text_ta) <= 300),
  answer_type text not null check (answer_type in ('yes_no', 'choice', 'rating', 'text')),
  choices jsonb,
  is_required boolean not null default false,
  is_active boolean not null default true,
  sort_order integer not null default 0,
  created_by uuid references public.profiles (id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (org_id, code),
  unique (id, org_id),
  constraint followup_questions_choices_shape check (
    (answer_type = 'choice' and jsonb_typeof(choices) = 'array' and jsonb_array_length(choices) between 2 and 10)
    or (answer_type <> 'choice' and choices is null))
);
create index followup_questions_org_idx on public.followup_questions (org_id, sort_order);

create table public.followup_question_ticket_types (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null,
  question_id uuid not null,
  ticket_type text not null check (ticket_type in ('paid', 'warranty', 'amc', 'installation', 'rental')),
  created_at timestamptz not null default now(),
  unique (question_id, ticket_type),
  foreign key (question_id, org_id) references public.followup_questions (id, org_id) on delete cascade
);
create index followup_question_ticket_types_q_idx on public.followup_question_ticket_types (question_id);

-- 2. answers -------------------------------------------------------------------------------------------------------
alter table public.post_service_calls add column followup_needed boolean;

create table public.post_service_call_answers (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  call_id uuid not null references public.post_service_calls (id) on delete cascade,
  question_id uuid not null,
  ticket_id uuid not null references public.service_tickets (id) on delete cascade,
  customer_id uuid references public.customers (id) on delete set null,
  question_text_en text not null,
  question_text_ta text not null default '',
  answer_type text not null check (answer_type in ('yes_no', 'choice', 'rating', 'text')),
  question_choices jsonb,
  answer_bool boolean,
  answer_int integer,
  answer_text text,
  created_at timestamptz not null default now(),
  -- NO ACTION, DEFERRED to the end of the transaction. A question can only be removed by purge_test_organisation() (the guard
  -- trigger refuses every other delete); that cascade deletes questions and answers in an order the database does not
  -- promise, so the check must wait until both are gone. A stray delete of a question that still has answers is still
  -- refused: at commit, and earlier by the guard trigger.
  foreign key (question_id, org_id) references public.followup_questions (id, org_id) on delete no action
    deferrable initially deferred,
  constraint post_service_call_answers_value_matches_type check (
    (answer_type = 'yes_no' and answer_bool is not null and answer_int is null and answer_text is null)
    or (answer_type = 'rating' and answer_int between 1 and 5 and answer_bool is null and answer_text is null)
    or (answer_type = 'choice' and answer_text is not null and answer_bool is null and answer_int is null)
    or (answer_type = 'text' and answer_text is not null and char_length(answer_text) <= 2000 and answer_bool is null and answer_int is null))
);
create unique index post_service_call_answers_call_question_uniq on public.post_service_call_answers (call_id, question_id);
create index post_service_call_answers_customer_idx on public.post_service_call_answers (org_id, customer_id, created_at desc);
create index post_service_call_answers_question_idx on public.post_service_call_answers (org_id, question_id, created_at);

-- 3. RLS and grants ------------------------------------------------------------------------------------------------
alter table public.followup_questions enable row level security;
alter table public.followup_question_ticket_types enable row level security;
alter table public.post_service_call_answers enable row level security;

create policy followup_questions_select_staff on public.followup_questions for select
  using (org_id = public.current_org_id() and (public.is_sales_staff() or public.is_ops_staff()));
create policy followup_questions_write_master on public.followup_questions for all
  using (org_id = public.current_org_id() and public.is_master())
  with check (org_id = public.current_org_id() and public.is_master());

create policy followup_question_ticket_types_select_staff on public.followup_question_ticket_types for select
  using (org_id = public.current_org_id() and (public.is_sales_staff() or public.is_ops_staff()));
create policy followup_question_ticket_types_write_master on public.followup_question_ticket_types for all
  using (org_id = public.current_org_id() and public.is_master())
  with check (org_id = public.current_org_id() and public.is_master());

-- read-only for staff; every write goes through log_post_service_call
create policy post_service_call_answers_select_staff on public.post_service_call_answers for select
  using (org_id = public.current_org_id() and (public.is_sales_staff() or public.is_ops_staff()));

revoke all on public.followup_questions, public.followup_question_ticket_types, public.post_service_call_answers
  from public, anon, authenticated;
grant select, insert, update on public.followup_questions to authenticated;          -- no DELETE: soft delete only
grant select, insert, update, delete on public.followup_question_ticket_types to authenticated;
grant select on public.post_service_call_answers to authenticated;
grant select, insert, update, delete on public.followup_questions, public.followup_question_ticket_types,
  public.post_service_call_answers to service_role;

create trigger set_updated_at before update on public.followup_questions for each row execute function public.set_updated_at();
create trigger audit_followup_questions after insert or update or delete on public.followup_questions
  for each row execute function public.audit_master_change();
create trigger audit_followup_question_ticket_types after insert or update or delete on public.followup_question_ticket_types
  for each row execute function public.audit_master_change();

-- 4. guard: answer_type and org are fixed, choices are well formed, no delete -----------------------------------------
create or replace function public._trg_followup_question_guard()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  c jsonb;
begin
  if tg_op = 'DELETE' then
    -- escape hatch for throwaway-organisation removal (same flag as the other built-in list guards)
    if coalesce(current_setting('app.lead_lists_cleanup', true), '') = 'on' then
      return old;
    end if;
    raise exception 'questions are never deleted: set is_active = false so earlier answers keep their wording';
  end if;
  if tg_op = 'UPDATE' then
    if new.answer_type is distinct from old.answer_type then
      raise exception 'answer_type cannot be changed: add a new question instead';
    end if;
    if new.org_id is distinct from old.org_id then
      raise exception 'org_id cannot be changed';
    end if;
  end if;
  if new.answer_type = 'choice' then
    for c in select * from jsonb_array_elements(new.choices) loop
      if jsonb_typeof(c) <> 'object'
         or coalesce(btrim(c ->> 'value'), '') = '' or char_length(c ->> 'value') > 60
         or coalesce(btrim(c ->> 'label_en'), '') = '' or char_length(c ->> 'label_en') > 120 then
        raise exception 'each choice needs a value (max 60 characters) and an English label (max 120 characters)';
      end if;
    end loop;
    if (select count(distinct x ->> 'value') from jsonb_array_elements(new.choices) x) <> jsonb_array_length(new.choices) then
      raise exception 'choice values must be unique';
    end if;
  end if;
  return new;
end;
$$;
revoke all on function public._trg_followup_question_guard() from public, anon, authenticated;
create trigger followup_questions_guard before insert or update or delete on public.followup_questions
  for each row execute function public._trg_followup_question_guard();

-- 5. seed: six example questions per organisation, INACTIVE (the master edits, activates or replaces them) -------------
create or replace function public.seed_followup_questions(p_org_id uuid)
returns void language sql security definer set search_path = public as $$
  insert into public.followup_questions (org_id, code, scope, text_en, text_ta, answer_type, is_required, is_active, sort_order)
  values
    (p_org_id, 'product_working',   'post_service', 'Is the product working properly now?',                      '', 'yes_no', false, false, 1),
    (p_org_id, 'technician_on_time','post_service', 'Was the technician on time?',                               '', 'yes_no', false, false, 2),
    (p_org_id, 'service_rating',    'post_service', 'How would you rate the service?',                           '', 'rating', false, false, 3),
    (p_org_id, 'polite_and_clean',  'post_service', 'Was the technician polite and clean in the work area?',     '', 'yes_no', false, false, 4),
    (p_org_id, 'do_better',         'post_service', 'Anything we can do better?',                                '', 'text',   false, false, 5),
    (p_org_id, 'call_back_wanted',  'post_service', 'Would you like a call back from the office?',              '', 'yes_no', false, false, 6)
  on conflict (org_id, code) do nothing;
$$;
revoke all on function public.seed_followup_questions(uuid) from public, anon, authenticated;
create or replace function public.trg_seed_followup_questions()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.seed_followup_questions(new.id);
  return new;
end;
$$;
revoke all on function public.trg_seed_followup_questions() from public, anon, authenticated;
create trigger seed_followup_questions_on_org after insert on public.organizations
  for each row execute function public.trg_seed_followup_questions();
select public.seed_followup_questions(id) from public.organizations;

-- 6. which questions apply to a ticket type ---------------------------------------------------------------------------
create function public._post_service_questions_for(p_org_id uuid, p_ticket_type text)
returns setof public.followup_questions
language sql stable security definer set search_path = public as $$
  select q.* from public.followup_questions q
  where q.org_id = p_org_id and q.is_active and (q.scope is null or q.scope = 'post_service')
    and (not exists (select 1 from public.followup_question_ticket_types l where l.question_id = q.id)
         or exists (select 1 from public.followup_question_ticket_types l where l.question_id = q.id and l.ticket_type = p_ticket_type))
  order by q.sort_order, q.created_at;
$$;
revoke all on function public._post_service_questions_for(uuid, text) from public, anon, authenticated;
grant execute on function public._post_service_questions_for(uuid, text) to service_role;

create function public.get_post_service_questions(p_followup_id uuid)
returns table (id uuid, text_en text, text_ta text, answer_type text, choices jsonb, is_required boolean, sort_order integer)
language plpgsql stable security definer set search_path = public as $$
declare
  v_f public.lead_followups;
  v_type text;
begin
  if not public.is_sales_staff() then
    raise exception 'not permitted: only master or sales_admin can log a post-service call';
  end if;
  select * into v_f from public.lead_followups where lead_followups.id = p_followup_id and org_id = public.current_org_id();
  if not found or v_f.ticket_id is null then
    raise exception 'post-service follow-up not found';
  end if;
  select t.type::text into v_type from public.service_tickets t where t.id = v_f.ticket_id;
  return query
    select q.id, q.text_en, q.text_ta, q.answer_type, q.choices, q.is_required, q.sort_order
    from public._post_service_questions_for(v_f.org_id, v_type) q;
end;
$$;
revoke all on function public.get_post_service_questions(uuid) from public, anon, authenticated;
grant execute on function public.get_post_service_questions(uuid) to authenticated, service_role;

-- 7. log_post_service_call: answers + follow-up needed -----------------------------------------------------------------
-- SIGNATURE: this is a CHANGED signature (4 -> 6 arguments), so it is a NEW function, not a replacement. create or replace would
-- have left the old 4-argument function in place with its old ACL. The old one is dropped in this same transaction, the new one
-- gets revoke from public, anon, authenticated and an explicit grant to authenticated and service_role. A client that still sends
-- the four old named arguments resolves to the new function through the defaults.
--
-- Interaction of the retry outcome and "follow-up needed": there is ONE follow-up row per ticket (unique index
-- lead_followups_one_per_ticket), so a call can never create a second one. The row is either closed or kept open with a new date:
--   outcome.retry = true                         -> kept open, new date required (as before); followup_needed is stored NULL
--   retry = false and followup_needed = true     -> kept open, new date required; reschedule_reason = 'Follow-up needed'
--   retry = false and followup_needed false/NULL -> closed (done), exactly as before
-- Required questions are enforced here. They are NOT required when the outcome is a retry outcome (customer not reached, asked to
-- call later: not_reachable, call_later) or the code no_answer_needed.
drop function public.log_post_service_call(uuid, uuid, text, timestamptz);
create function public.log_post_service_call(
  p_followup_id uuid,
  p_outcome_id uuid,
  p_note text default null,
  p_next_due_at timestamptz default null,
  p_answers jsonb default null,
  p_followup_needed boolean default null
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_f public.lead_followups;
  v_out public.post_service_outcomes;
  v_q public.followup_questions;
  v_call uuid;
  v_type text;
  v_ticket_name text;
  v_cust_name text;
  v_reopen boolean;
  v_no_answers_needed boolean;
  v_el jsonb;
  v_val jsonb;
  v_qid uuid;
  v_seen uuid[] := '{}';
  v_stored uuid[] := '{}';
  v_b boolean;
  v_i integer;
  v_t text;
  v_saved integer := 0;
  v_missing text;
begin
  if not public.is_sales_staff() then
    raise exception 'not permitted: only master or sales_admin can log a post-service call';
  end if;
  select * into v_f from public.lead_followups where id = p_followup_id and org_id = public.current_org_id() for update;
  if not found or v_f.ticket_id is null then
    raise exception 'post-service follow-up not found';
  end if;
  if v_f.status <> 'open' then
    raise exception 'this follow-up is already %', v_f.status;
  end if;
  select * into v_out from public.post_service_outcomes where id = p_outcome_id and org_id = v_f.org_id and is_active;
  if not found then
    raise exception 'outcome not found or inactive';
  end if;
  if p_note is not null and char_length(p_note) > 2000 then
    raise exception 'the note is too long (max 2000 characters)';
  end if;
  if p_answers is not null and jsonb_typeof(p_answers) not in ('array', 'null') then
    raise exception 'answers must be a list';
  end if;

  v_reopen := v_out.retry or coalesce(p_followup_needed, false);
  if v_reopen then
    perform public._lead_check_due(p_next_due_at);
  end if;

  select t.type::text into v_type from public.service_tickets t where t.id = v_f.ticket_id;

  insert into public.post_service_calls (org_id, followup_id, ticket_id, customer_id, outcome_id, outcome_code, note, followup_needed)
  values (v_f.org_id, v_f.id, v_f.ticket_id, v_f.customer_id, v_out.id, v_out.code, nullif(btrim(coalesce(p_note, '')), ''),
          case when v_out.retry then null else p_followup_needed end)
  returning id into v_call;

  -- answers: any rejection raises, which rolls the whole call back (one transaction)
  for v_el in select * from jsonb_array_elements(case when jsonb_typeof(p_answers) = 'array' then p_answers else '[]'::jsonb end) loop
    if jsonb_typeof(v_el) <> 'object' then
      raise exception 'each answer must be an object with question_id and value';
    end if;
    begin
      v_qid := (v_el ->> 'question_id')::uuid;
    exception when others then
      raise exception 'invalid question_id in answers';
    end;
    if v_qid is null then
      raise exception 'invalid question_id in answers';
    end if;
    if v_qid = any (v_seen) then
      raise exception 'the same question was answered twice';
    end if;
    v_seen := v_seen || v_qid;
    select * into v_q from public._post_service_questions_for(v_f.org_id, v_type) x where x.id = v_qid;
    if not found then
      raise exception 'question % is not active or does not apply to this ticket', v_qid;
    end if;

    v_val := v_el -> 'value';
    v_b := null; v_i := null; v_t := null;
    if v_val is null or jsonb_typeof(v_val) = 'null' then
      continue;                                            -- left blank
    end if;
    if v_q.answer_type = 'yes_no' then
      if jsonb_typeof(v_val) <> 'boolean' then raise exception 'answer type mismatch: question % is yes/no', v_qid; end if;
      v_b := (v_val #>> '{}')::boolean;
    elsif v_q.answer_type = 'rating' then
      if jsonb_typeof(v_val) <> 'number' or (v_val #>> '{}') !~ '^[1-5]$' then
        raise exception 'answer type mismatch: question % needs a whole number from 1 to 5', v_qid;
      end if;
      v_i := (v_val #>> '{}')::integer;
    elsif v_q.answer_type = 'choice' then
      if jsonb_typeof(v_val) <> 'string' then raise exception 'answer type mismatch: question % needs one of its choices', v_qid; end if;
      v_t := v_val #>> '{}';
      if not exists (select 1 from jsonb_array_elements(v_q.choices) c where c ->> 'value' = v_t) then
        raise exception 'answer is not one of the choices of question %', v_qid;
      end if;
    else
      if jsonb_typeof(v_val) <> 'string' then raise exception 'answer type mismatch: question % is free text', v_qid; end if;
      v_t := btrim(v_val #>> '{}');
      if v_t = '' then
        continue;                                          -- blank text is not an answer
      end if;
      if char_length(v_t) > 2000 then
        raise exception 'the answer is too long (max 2000 characters)';
      end if;
    end if;

    insert into public.post_service_call_answers (org_id, call_id, question_id, ticket_id, customer_id, question_text_en, question_text_ta,
                                                  answer_type, question_choices, answer_bool, answer_int, answer_text)
    values (v_f.org_id, v_call, v_q.id, v_f.ticket_id, v_f.customer_id, v_q.text_en, v_q.text_ta,
            v_q.answer_type, v_q.choices, v_b, v_i, v_t);
    v_stored := v_stored || v_q.id;
    v_saved := v_saved + 1;
  end loop;

  -- required questions are enforced here, not only in the screen
  v_no_answers_needed := v_out.retry or v_out.code = 'no_answer_needed';
  if not v_no_answers_needed then
    select q.text_en into v_missing
    from public._post_service_questions_for(v_f.org_id, v_type) q
    where q.is_required and q.id <> all (v_stored)
    order by q.sort_order limit 1;
    if v_missing is not null then
      raise exception 'an answer is required: %', v_missing;
    end if;
  end if;

  if v_reopen then
    update public.lead_followups
       set due_at = p_next_due_at,
           reschedule_reason = case when v_out.retry then v_out.label_en else 'Follow-up needed' end
     where id = v_f.id;
  else
    update public.lead_followups set status = 'done', completed_by = auth.uid(), completed_at = clock_timestamp() where id = v_f.id;
  end if;

  if v_out.alert then
    select t.name_of_complaint, c.name into v_ticket_name, v_cust_name
    from public.service_tickets t left join public.customers c on c.id = v_f.customer_id where t.id = v_f.ticket_id;
    insert into public.notifications (org_id, user_id, type, title, body, ref_id)
    select v_f.org_id, p.id, 'post_service_issue', 'Customer reports a problem after service',
           format('%s: %s%s', coalesce(v_cust_name, 'Customer'), coalesce(v_ticket_name, 'service ticket'),
                  case when nullif(btrim(coalesce(p_note, '')), '') is not null then ' — ' || left(btrim(p_note), 160) else '' end),
           v_f.ticket_id
    from public.profiles p
    where p.org_id = v_f.org_id and p.is_active and p.role in ('master', 'operation_admin');
  end if;

  return jsonb_build_object(
    'call_id', v_call, 'followup_id', v_f.id, 'ticket_id', v_f.ticket_id,
    'status', case when v_reopen then 'open' else 'done' end,
    'next_due_at', case when v_reopen then p_next_due_at end,
    'alerted', v_out.alert,
    'answers_saved', v_saved,
    'followup_needed', case when v_out.retry then null else p_followup_needed end
  );
end;
$$;
revoke all on function public.log_post_service_call(uuid, uuid, text, timestamptz, jsonb, boolean) from public, anon, authenticated;
grant execute on function public.log_post_service_call(uuid, uuid, text, timestamptz, jsonb, boolean) to authenticated, service_role;

-- 8. report: per question, over a date range (IST days), master only, read-only; test customers are left out ------------
create function public.report_followup_question_answers(p_from date, p_to date)
returns table (
  question_id uuid, text_en text, text_ta text, answer_type text, answers integer,
  yes_count integer, no_count integer, rating_avg numeric, rating_counts jsonb, choice_counts jsonb, text_count integer
)
language plpgsql stable security definer set search_path = public as $$
declare
  v_org uuid := public.current_org_id();
begin
  if not public.is_master() then
    raise exception 'not permitted: only the master can view the answers report';
  end if;
  if p_from is null or p_to is null or p_to < p_from then
    raise exception 'invalid date range';
  end if;
  if p_to - p_from > 366 then
    raise exception 'the date range is limited to 366 days';
  end if;
  return query
  with a as (
    select x.*
    from public.post_service_call_answers x
    left join public.customers c on c.id = x.customer_id
    where x.org_id = v_org and coalesce(c.is_test, false) = false
      and (x.created_at at time zone 'Asia/Kolkata')::date between p_from and p_to
  )
  select a.question_id,
         (array_agg(a.question_text_en order by a.created_at desc))[1],
         (array_agg(a.question_text_ta order by a.created_at desc))[1],
         (array_agg(a.answer_type order by a.created_at desc))[1],
         count(*)::integer,
         (count(*) filter (where a.answer_bool is true))::integer,
         (count(*) filter (where a.answer_bool is false))::integer,
         round(avg(a.answer_int) filter (where a.answer_type = 'rating'), 2),
         case when bool_or(a.answer_type = 'rating') then jsonb_build_object(
           '1', count(*) filter (where a.answer_int = 1), '2', count(*) filter (where a.answer_int = 2),
           '3', count(*) filter (where a.answer_int = 3), '4', count(*) filter (where a.answer_int = 4),
           '5', count(*) filter (where a.answer_int = 5)) end,
         (select jsonb_object_agg(s.v, s.n) from (
            select b.answer_text as v, count(*) as n from a b
            where b.question_id = a.question_id and b.answer_type = 'choice' group by b.answer_text) s),
         (count(*) filter (where a.answer_type = 'text'))::integer
  from a
  group by a.question_id
  order by (array_agg(a.question_text_en order by a.created_at desc))[1];
end;
$$;
revoke all on function public.report_followup_question_answers(date, date) from public, anon, authenticated;
grant execute on function public.report_followup_question_answers(date, date) to authenticated, service_role;

notify pgrst, 'reload schema';
$rh0$;
  v_hash := encode(sha256(convert_to(v_text, 'UTF8')), 'hex');
  if v_hash <> '29795b2ebeb1f1569795114ea978e14bd2795af5a2397f61da7e9256932a154c' then
    raise exception 'REHEARSAL_REFUSED: hash mismatch for 20261027100000_followup_questions.sql: %', v_hash;
  end if;
  execute v_text;

  v_text := $rh1$-- Rolled-back DB tests for migration 20261014100000_post_service_followup (batch-17 item 13).
-- One transaction ending in RAISE; read RESULTS in the error. A throwaway __TEST_ organisation is created inside the
-- transaction, so nothing persists and no real lead, ticket or customer row is read or written (the only global reads are
-- the "real data unchanged" fingerprint checks).
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
create function pg_temp.as_pg() returns void language plpgsql as $f$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $f$;
-- complete a ticket (open -> completed) the way every completion path does: a plain status update
create function pg_temp.complete(p_ticket uuid) returns void language plpgsql as $f$
begin update public.service_tickets set status = 'completed' where id = p_ticket; end $f$;

do $t$
declare
  v_org uuid; v_org2 uuid; v_master uuid; v_s1 uuid; v_s2 uuid; v_ops uuid; v_cust uuid; v_cust2 uuid;
  t1 uuid; t2 uuid; t3 uuid; t4 uuid; t5 uuid; f1 uuid; f2 uuid; l1 uuid;
  txt text; b boolean; n int; r jsonb; rec record; v_body text;
  o_sat uuid; o_issue uuid; o_retry uuid; v_due timestamptz; d date;
  fp1 text; fp2 text; fn1 jsonb;
begin
  select md5(string_agg(id::text||'|'||coalesce(name,'')||'|'||created_at::text||'|'||updated_at::text, ',' order by id)) into fp1 from public.leads where name not like '\_\_TEST%';

  insert into organizations (name) values ('__TEST_b17_postservice') returning id into v_org;
  insert into organizations (name) values ('__TEST_b17_postservice_other') returning id into v_org2;
  insert into settings (org_id) values (v_org) on conflict (org_id) do nothing;
  v_master := pg_temp.mkuser('master', v_org);
  v_s1 := pg_temp.mkuser('sales_admin', v_org);
  v_s2 := pg_temp.mkuser('sales_admin', v_org);
  v_ops := pg_temp.mkuser('operation_admin', v_org);
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ Cust A', '9400000001') returning id into v_cust;
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ Cust B', '9400000002') returning id into v_cust2;

  -- ---------- schema ----------
  perform pg_temp.chk('lead_id is nullable now', (select is_nullable from information_schema.columns where table_schema='public' and table_name='lead_followups' and column_name='lead_id')='YES');
  perform pg_temp.chk('every pre-existing follow-up still has a lead (check constraint holds)', not exists (select 1 from lead_followups where lead_id is null and ticket_id is null));
  perform pg_temp.chk('settings defaults: OFF, 2 days, all sales staff, paid/warranty/installation, dedupe 0',
    (select post_service_followup_enabled = false and post_service_followup_days = 2 and post_service_followup_assignee is null
       and post_service_ticket_types = array['paid','warranty','installation'] and post_service_dedupe_days = 0 from settings where org_id = v_org));
  perform pg_temp.chk('new org seeded 5 post-service outcomes (all built-in)', (select count(*) from post_service_outcomes where org_id=v_org)=5 and (select count(*) from post_service_outcomes where org_id=v_org and is_system)=5);
  perform pg_temp.chk('every pre-existing org was seeded too', not exists (select 1 from organizations o where o.id not in (v_org, v_org2) and (select count(*) from post_service_outcomes x where x.org_id=o.id) < 5));
  select id into o_sat from post_service_outcomes where org_id=v_org and code='satisfied';
  select id into o_issue from post_service_outcomes where org_id=v_org and code='issue_remaining';
  select id into o_retry from post_service_outcomes where org_id=v_org and code='not_reachable';

  -- ---------- ACLs ----------
  perform pg_temp.chk('new RPCs: authenticated + service_role yes, anon + PUBLIC no',
    has_function_privilege('authenticated','public.list_post_service_followups(text,text,uuid)','execute')
    and has_function_privilege('authenticated','public.log_post_service_call(uuid,uuid,text,timestamptz,jsonb,boolean)','execute')
    and has_function_privilege('service_role','public.log_post_service_call(uuid,uuid,text,timestamptz,jsonb,boolean)','execute')
    and not has_function_privilege('anon','public.list_post_service_followups(text,text,uuid)','execute')
    and not has_function_privilege('anon','public.log_post_service_call(uuid,uuid,text,timestamptz,jsonb,boolean)','execute')
    and not exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.pronamespace='public'::regnamespace and p.proname in ('list_post_service_followups','log_post_service_call') and a.grantee = 0));
  perform pg_temp.chk('trigger/seed/guard functions are not executable by anon or authenticated',
    not has_function_privilege('anon','public._trg_ticket_post_service_followup()','execute') and not has_function_privilege('authenticated','public._trg_ticket_post_service_followup()','execute')
    and not has_function_privilege('authenticated','public.seed_post_service_outcomes(uuid)','execute') and not has_function_privilege('anon','public.seed_post_service_outcomes(uuid)','execute')
    and not has_function_privilege('authenticated','public.trg_seed_post_service_outcomes()','execute')
    and not has_function_privilege('authenticated','public._trg_post_service_outcome_guard()','execute'));
  perform pg_temp.chk('no duplicate signatures: one of each', (select count(*) from pg_proc where pronamespace='public'::regnamespace and proname='list_post_service_followups')=1
    and (select count(*) from pg_proc where pronamespace='public'::regnamespace and proname='log_post_service_call')=1
    and (select count(*) from pg_proc where pronamespace='public'::regnamespace and proname='list_followups')=1
    and (select count(*) from pg_proc where pronamespace='public'::regnamespace and proname='followup_counts')=1
    and (select count(*) from pg_proc where pronamespace='public'::regnamespace and proname='run_lead_followup_notifications')=1);

  -- ---------- trigger: OFF by default ----------
  insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (v_org, v_cust, 'paid', 'Not cooling') returning id into t1;
  perform pg_temp.complete(t1);
  perform pg_temp.chk('switch OFF: completing a ticket creates nothing', (select count(*) from lead_followups where ticket_id = t1)=0);

  -- ---------- trigger: ON ----------
  update settings set post_service_followup_enabled = true where org_id = v_org;
  insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (v_org, v_cust, 'paid', 'Water leak') returning id into t2;
  perform pg_temp.complete(t2);
  select id, due_at into f1, v_due from lead_followups where ticket_id = t2;
  perform pg_temp.chk('switch ON: completing a paid ticket creates one follow-up', f1 is not null);
  perform pg_temp.chk('row shape: source post_service, type call, status open, customer set, lead null, unassigned',
    (select source='post_service' and type::text='call' and status::text='open' and customer_id=v_cust and lead_id is null and assigned_to is null and ticket_id=t2 from lead_followups where id=f1));
  d := public._lead_ist_date(v_due);
  perform pg_temp.chk('due date = IST today + 2 days, rolled to a working day', d >= public._lead_ist_date(now()) + 2 and public._lead_is_working_day(v_org, d), d::text);
  perform pg_temp.chk('due time = work start + 30 minutes IST', (v_due at time zone 'Asia/Kolkata')::time = (select lead_work_start from settings where org_id=v_org) + interval '30 minutes', ((v_due at time zone 'Asia/Kolkata')::time)::text);

  -- idempotence: reopen + complete again, then complete (no-op update) again
  update service_tickets set status = 'in_progress' where id = t2;
  perform pg_temp.complete(t2);
  update service_tickets set name_of_complaint = 'Water leak (edited)' where id = t2;
  perform pg_temp.chk('idempotent: completed -> reopened -> completed gives still ONE follow-up', (select count(*) from lead_followups where ticket_id = t2)=1);
  begin insert into lead_followups (org_id, ticket_id, customer_id, due_at, source) values (v_org, t2, v_cust, now(), 'post_service'); b := true; exception when unique_violation then b := false; end;
  perform pg_temp.chk('a second follow-up for the same ticket is rejected by the unique index', b = false);
  begin insert into lead_followups (org_id, due_at, source) values (v_org, now(), 'x'); b := true; exception when check_violation then b := false; end;
  perform pg_temp.chk('a follow-up with neither lead nor ticket is rejected', b = false);

  -- skipping rules
  insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (v_org, v_cust2, 'amc', 'Scheduled AMC visit') returning id into t3;
  perform pg_temp.complete(t3);
  perform pg_temp.chk('ticket type not in the master list (amc) is skipped', (select count(*) from lead_followups where ticket_id = t3)=0);
  update settings set post_service_ticket_types = array['paid','amc'] where org_id = v_org;
  insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (v_org, v_cust2, 'amc', 'Scheduled AMC visit 2') returning id into t4;
  perform pg_temp.complete(t4);
  perform pg_temp.chk('adding amc to the master list makes it eligible', (select count(*) from lead_followups where ticket_id = t4)=1);
  update settings set post_service_dedupe_days = 5 where org_id = v_org;
  insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (v_org, v_cust, 'paid', 'Another visit') returning id into t5;
  perform pg_temp.complete(t5);
  perform pg_temp.chk('dedupe window: same customer within N days is skipped', (select count(*) from lead_followups where ticket_id = t5)=0);
  update settings set post_service_dedupe_days = 0 where org_id = v_org;

  -- delay setting and recipient
  update settings set post_service_followup_days = 0, post_service_followup_assignee = v_s1, post_service_ticket_types = array['paid'] where org_id = v_org;
  insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (v_org, v_cust2, 'paid', 'Third visit') returning id into t5;
  perform pg_temp.complete(t5);
  perform pg_temp.chk('delay 0 days: due on the IST completion day (or the next working day)', (select public._lead_ist_date(due_at) from lead_followups where ticket_id=t5) in (public._lead_ist_date(now()), public.lead_next_working_day(v_org, public._lead_ist_date(now()))));
  perform pg_temp.chk('recipient setting: assigned_to is the chosen sales person', (select assigned_to from lead_followups where ticket_id=t5) = v_s1);
  update settings set post_service_followup_days = 2, post_service_followup_assignee = null where org_id = v_org;

  -- a failing trigger must not block completion: a ticket whose customer is gone has no customer -> skipped quietly
  insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (v_org, v_cust, 'warranty', 'No customer later') returning id into t1;
  update settings set post_service_ticket_types = array['paid','warranty'] where org_id = v_org;
  begin perform pg_temp.complete(t1); b := true; exception when others then b := false; end;
  perform pg_temp.chk('completion itself always succeeds', b);

  -- ---------- list_post_service_followups ----------
  -- f1 (t2): unassigned, f(t4): unassigned, f(t5): assigned to s1
  perform pg_temp.as_user(v_master);
  select count(*) into n from list_post_service_followups();
  perform pg_temp.chk('master sees all open post-service follow-ups', n = 3 or n = 4, n::text);
  perform pg_temp.as_user(v_s1);
  select count(*) into n from list_post_service_followups();
  perform pg_temp.chk('sales person (own + unassigned) sees own + unassigned', n = (select count(*) from lead_followups where org_id=v_org and ticket_id is not null and status='open'), n::text);
  perform pg_temp.as_user(v_s2);
  select count(*) into n from list_post_service_followups();
  perform pg_temp.chk('another sales person does NOT see the one assigned to s1', n = (select count(*) from lead_followups where org_id=v_org and ticket_id is not null and status='open' and assigned_to is null), n::text);
  begin perform * from list_post_service_followups('all', 'all'); b := true; exception when others then b := false; end;
  perform pg_temp.chk('sales person cannot ask for the all-scope', b = false);
  select count(*) into n from list_post_service_followups('overdue');
  perform pg_temp.chk('bucket filter works (nothing overdue yet)', n = 0, n::text);
  select * into rec from list_post_service_followups('all') limit 1;
  perform pg_temp.chk('rows carry customer, mobile, complaint, type', rec.customer_name like '__TEST_ Cust%' and rec.mobile like '94000000%' and rec.complaint is not null and rec.ticket_type is not null and rec.attempts = 0);
  perform pg_temp.as_pg();
  perform pg_temp.as_user(v_ops);
  begin perform * from list_post_service_followups(); b := true; exception when others then b := false; end;
  perform pg_temp.as_pg();
  perform pg_temp.chk('operation_admin (not sales staff) cannot list', b = false);
  begin execute 'set local role anon'; perform * from list_post_service_followups(); b := true; exception when others then b := false; end;
  perform pg_temp.as_pg();
  perform pg_temp.chk('anon cannot list', b = false);

  -- ---------- untouched lead side ----------
  insert into leads (org_id, name, mobile) values (v_org, '__TEST_ lead', '9400000010') returning id into l1;
  perform pg_temp.as_user(v_master);
  select count(*) into n from list_followups('all');
  perform pg_temp.chk('list_followups returns only the lead follow-up (no ticket rows)', n = 1 and not exists (select 1 from list_followups('all') x where x.lead_id is null), n::text);
  select count(*) into n from list_leads_without_followup();
  perform pg_temp.chk('No follow-up list unaffected by ticket follow-ups', n = 0, n::text);
  fn1 := get_lead_funnel('2000-01-01'::timestamptz, '2100-01-01'::timestamptz);
  perform pg_temp.as_pg();
  perform pg_temp.chk('leads.next_followup_at is set from the lead follow-up only', (select next_followup_at is not null from leads where id=l1));
  perform pg_temp.chk('ticket follow-ups never touched any lead', (select count(*) from leads where org_id=v_org)=1 and (select postpone_count from leads where id=l1)=0);

  -- ---------- followup_counts ----------
  perform pg_temp.as_user(v_master);
  r := followup_counts('all');
  perform pg_temp.as_pg();
  perform pg_temp.chk('followup_counts (master/all) counts lead + post-service follow-ups', (r->>'total')::int = (select count(*) from lead_followups where org_id=v_org and status='open' and public._lead_ist_date(due_at) <= public._lead_ist_date(now())), r::text);
  -- push the ticket follow-ups due today to prove they are counted
  update lead_followups set due_at = now() where org_id=v_org and ticket_id is not null and status='open';
  perform pg_temp.as_user(v_master);
  r := followup_counts('all');
  perform pg_temp.as_pg();
  perform pg_temp.chk('post-service follow-ups due today are in the badge total', (r->>'today')::int >= (select count(*) from lead_followups where org_id=v_org and ticket_id is not null and status='open'), r::text);
  perform pg_temp.chk('by_person lists the sales person who holds the assigned post-service call', exists (select 1 from jsonb_array_elements(r->'by_person') x where (x->>'id')::uuid = v_s1));
  perform pg_temp.as_user(v_s2);
  r := followup_counts('auto');
  perform pg_temp.as_pg();
  perform pg_temp.chk('sales person badge excludes calls assigned to someone else', (r->>'today')::int = (select count(*) from lead_followups f where f.org_id=v_org and f.status='open' and public._lead_ist_date(f.due_at)=public._lead_ist_date(now()) and ((f.ticket_id is not null and f.assigned_to is null) or (f.lead_id is not null))), r::text);

  -- ---------- log_post_service_call ----------
  select id into f1 from lead_followups where ticket_id = t2;
  perform pg_temp.as_user(v_s2);
  r := log_post_service_call(f1, o_sat, E'Customer happy.\nNothing pending.');
  perform pg_temp.as_pg();
  perform pg_temp.chk('satisfied: follow-up done, call recorded', (select status::text from lead_followups where id=f1)='done' and (select count(*) from post_service_calls where followup_id=f1 and outcome_code='satisfied' and called_by=v_s2)=1 and (r->>'status')='done');
  perform pg_temp.chk('note stored verbatim', (select note from post_service_calls where followup_id=f1)=E'Customer happy.\nNothing pending.');
  perform pg_temp.as_user(v_master);
  select count(*) into n from list_post_service_followups() x where x.followup_id = f1;
  perform pg_temp.chk('a done follow-up is gone from the list', n = 0);
  begin perform log_post_service_call(f1, o_sat); b := true; exception when others then b := false; end;
  perform pg_temp.as_pg();
  perform pg_temp.chk('a done follow-up cannot be logged twice', b = false);

  select id into f2 from lead_followups where ticket_id = t4;
  perform pg_temp.as_user(v_s2);
  begin perform log_post_service_call(f2, o_retry); b := true; exception when others then b := false; end;
  perform pg_temp.chk('retry outcome without a date is refused', b = false);
  r := log_post_service_call(f2, o_retry, 'phone switched off', now() + interval '2 days');
  perform pg_temp.as_pg();
  perform pg_temp.chk('retry outcome: same follow-up stays open with the new date, attempt recorded', (r->>'status')='open' and (select status::text from lead_followups where id=f2)='open' and (select due_at > now() + interval '1 day' from lead_followups where id=f2) and (select count(*) from post_service_calls where followup_id=f2)=1);
  perform pg_temp.chk('retry keeps one follow-up per ticket', (select count(*) from lead_followups where ticket_id=t4)=1);
  perform pg_temp.as_user(v_master);
  select attempts, last_outcome_code into rec from list_post_service_followups() x where x.followup_id = f2;
  perform pg_temp.as_pg();
  perform pg_temp.chk('list shows attempts and last outcome', rec.attempts = 1 and rec.last_outcome_code = 'not_reachable');

  -- alert outcome notifies master + operation_admin, not sales_admin
  perform pg_temp.as_user(v_s1);
  r := log_post_service_call(f2, o_issue, 'Still leaking');
  perform pg_temp.as_pg();
  perform pg_temp.chk('issue outcome: follow-up done and alerted', (r->>'status')='done' and (r->>'alerted')::boolean);
  perform pg_temp.chk('alert went to master and operation_admin only', (select count(*) from notifications where org_id=v_org and type='post_service_issue' and ref_id=t4 and user_id in (v_master, v_ops))=2
    and not exists (select 1 from notifications where org_id=v_org and type='post_service_issue' and user_id in (v_s1, v_s2)));
  perform pg_temp.chk('alert text carries the note', (select body like '%Still leaking%' from notifications where org_id=v_org and type='post_service_issue' and user_id=v_master limit 1));

  -- guards
  select id into f2 from lead_followups where ticket_id = t5;
  perform pg_temp.as_user(v_s2);
  begin perform log_post_service_call(f2, o_sat, repeat('x', 2001)); b := true; exception when others then b := false; end;
  perform pg_temp.chk('2001-character note refused', b = false);
  begin perform log_post_service_call((select id from lead_followups where lead_id = l1 and status='open'), o_sat); b := true; exception when others then b := false; end;
  perform pg_temp.chk('a LEAD follow-up cannot be logged through the post-service RPC', b = false);
  begin perform log_post_service_call(f2, gen_random_uuid()); b := true; exception when others then b := false; end;
  perform pg_temp.chk('unknown outcome refused', b = false);
  perform pg_temp.as_pg();
  update post_service_outcomes set is_active = false where id = o_sat;
  perform pg_temp.as_user(v_s2);
  begin perform log_post_service_call(f2, o_sat); b := true; exception when others then b := false; end;
  perform pg_temp.as_pg();
  perform pg_temp.chk('inactive outcome refused', b = false);
  update post_service_outcomes set is_active = true where id = o_sat;
  perform pg_temp.as_user(pg_temp.mkuser('customer', v_org));
  begin perform log_post_service_call(f2, o_sat); b := true; exception when others then b := false; end;
  perform pg_temp.as_pg();
  perform pg_temp.chk('customer-role user cannot log a call', b = false);
  begin execute 'set local role anon'; perform log_post_service_call(f2, o_sat); b := true; exception when others then b := false; end;
  perform pg_temp.as_pg();
  perform pg_temp.chk('anon cannot log a call', b = false);

  -- master list: RLS + guards
  perform pg_temp.as_user(v_s1);
  begin insert into post_service_outcomes (org_id, code, label_en, label_ta) values (v_org, 'x', 'X', 'X'); b := true; exception when others then b := false; end;
  perform pg_temp.as_pg();
  perform pg_temp.chk('sales person cannot edit the outcome list', b = false);
  perform pg_temp.as_user(v_master);
  insert into post_service_outcomes (org_id, code, label_en, label_ta, retry) values (v_org, 'wants_visit', 'Wants another visit', 'மற்றொரு வருகை', false);
  update post_service_outcomes set label_en = 'Wants another visit!' where org_id=v_org and code='wants_visit';
  begin delete from post_service_outcomes where org_id=v_org and code='satisfied'; get diagnostics n = row_count; b := n > 0; exception when others then b := false; end;
  perform pg_temp.chk('master can add/edit a custom outcome; built-in outcome cannot be deleted', b = false and exists (select 1 from post_service_outcomes where org_id=v_org and code='wants_visit' and label_en='Wants another visit!'));
  begin delete from post_service_outcomes where org_id=v_org and code='wants_visit'; b := true; exception when others then b := false; end;
  perform pg_temp.chk('an unused custom outcome can be deleted', b and not exists (select 1 from post_service_outcomes where org_id=v_org and code='wants_visit'));
  begin update post_service_outcomes set code = 'renamed' where org_id=v_org and code='call_later'; b := true; exception when others then b := false; end;
  perform pg_temp.chk('outcome code cannot change', b = false);
  begin delete from post_service_outcomes where id = o_issue; b := true; exception when others then b := false; end;
  perform pg_temp.as_pg();
  perform pg_temp.chk('an outcome used by a call cannot be deleted (also built-in)', b = false);
  perform pg_temp.as_user(v_s1);
  select count(*) into n from post_service_calls;
  perform pg_temp.as_pg();
  perform pg_temp.chk('staff can read the call history', n >= 3, n::text);
  perform pg_temp.as_user(v_s1);
  begin insert into post_service_calls (org_id, followup_id, ticket_id, outcome_id, outcome_code) values (v_org, f2, t5, o_sat, 'satisfied'); b := true; exception when others then b := false; end;
  perform pg_temp.as_pg();
  perform pg_temp.chk('no client write policy on post_service_calls', b = false);

  -- ---------- digest ----------
  -- fresh org-level state: one lead follow-up due that day + one post-service call due that day
  update lead_followups set due_at = timestamptz '2026-10-13 15:00:00+05:30' where lead_id = l1 and status='open';
  update lead_followups set due_at = timestamptz '2026-10-13 14:00:00+05:30', status='open' where ticket_id = t5;
  update settings set lead_work_days = array[1,2,3,4,5,6], lead_work_start='09:30', lead_work_end='19:00' where org_id = v_org;
  r := run_lead_followup_notifications(timestamptz '2026-10-13 11:00:00+05:30', v_org);
  select n.body into v_body from notifications n where n.org_id=v_org and n.user_id=v_master and n.type='lead_followup_digest';
  perform pg_temp.chk('master digest counts every open post-service call due',
    v_body like format('%% %s post-service call(s) due.%%', (select count(*) from lead_followups where org_id=v_org and ticket_id is not null and status='open' and public._lead_ist_date(due_at) <= date '2026-10-13')), v_body);
  perform pg_temp.chk('digest still has the lead sentence and Daily Follow Up wording', v_body like '1 due today, 0 overdue. Open Daily Follow Up.%', v_body);
  select n.body into v_body from notifications n where n.org_id=v_org and n.user_id=v_s2 and n.type='lead_followup_digest';
  perform pg_temp.chk('a sales person is told only about unassigned calls, not the one assigned to a colleague',
    v_body like format('%% %s post-service call(s) due.%%', (select count(*) from lead_followups where org_id=v_org and ticket_id is not null and status='open' and assigned_to is null and public._lead_ist_date(due_at) <= date '2026-10-13')), coalesce(v_body,'<none>'));
  select n.body into v_body from notifications n where n.org_id=v_org and n.user_id=v_s1 and n.type='lead_followup_digest';
  perform pg_temp.chk('the sales person it is assigned to is told about it plus the unassigned ones',
    v_body like format('%% %s post-service call(s) due.%%', (select count(*) from lead_followups where org_id=v_org and ticket_id is not null and status='open' and (assigned_to is null or assigned_to = v_s1) and public._lead_ist_date(due_at) <= date '2026-10-13')), coalesce(v_body,'<none>'));

  -- digest with ONLY a post-service call due still goes out
  insert into organizations (name) values ('__TEST_b17_postservice_digest_only') returning id into v_org2;
  insert into settings (org_id) values (v_org2) on conflict (org_id) do nothing;
  update settings set post_service_followup_enabled = true, lead_work_days = array[1,2,3,4,5,6] where org_id = v_org2;
  declare m2 uuid; c2 uuid; tk uuid;
  begin
    m2 := pg_temp.mkuser('master', v_org2);
    insert into customers (org_id, name, mobile) values (v_org2, '__TEST_ C', '9400000099') returning id into c2;
    insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (v_org2, c2, 'paid', 'x') returning id into tk;
    perform pg_temp.complete(tk);
    update lead_followups set due_at = timestamptz '2026-10-13 14:00:00+05:30' where ticket_id = tk;
    r := run_lead_followup_notifications(timestamptz '2026-10-13 11:00:00+05:30', v_org2);
    select n.body into v_body from notifications n where n.org_id=v_org2 and n.user_id=m2 and n.type='lead_followup_digest';
    perform pg_temp.chk('digest is sent when the only thing due is a post-service call', v_body like '%1 post-service call(s) due.%', coalesce(v_body,'<none>'));
  end;

  -- ---------- real data untouched ----------
  select md5(string_agg(id::text||'|'||coalesce(name,'')||'|'||created_at::text||'|'||updated_at::text, ',' order by id)) into fp2 from public.leads where name not like '\_\_TEST%';
  perform pg_temp.chk('real leads untouched by everything above (identity + updated_at fingerprint)', fp1 is not distinct from fp2);

  select string_agg(r2.line, E'\n' order by r2.n) into txt from pg_temp.res r2;
  raise exception E'RESULTS\n%', txt;
end $t$;
$rh1$;
  v_hash := encode(sha256(convert_to(v_text, 'UTF8')), 'hex');
  if v_hash <> '086ba1e29fd5a1a43c688315addda53ce4e2e0f007d604a9286f929831802ee4' then
    raise exception 'REHEARSAL_REFUSED: hash mismatch for post_service_followup.test.sql: %', v_hash;
  end if;
  execute v_text;

  raise exception 'REHEARSAL_DID_NOT_RAISE: the test file should have raised RESULTS';
end
$rehearsal$;
