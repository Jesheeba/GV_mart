-- REHEARSAL (NOT RUN; for the owner's approval of this exact text): followup questions: migration 20261027100000 + its tests
-- One request, one DO block. It: (1) refuses to run before 18:00 IST (the clock is read from clock_timestamp()), (2) recomputes
-- the sha256 of every embedded file and refuses on any mismatch with the pinned value, (3) executes the migration text(s) and then the
-- test file in order, (4) always ends in an unconditional RAISE EXCEPTION, so nothing is ever committed.
-- No top-level begin / commit / savepoint / rollback. No schema_migrations row is written. Never concatenated with test code outside
-- this wrapper. Expected error text starts with RESULTS (or TIMING); anything else is a failure and also rolls back.
-- Pinned (sha256 of the LF blob at the commit this wrapper was generated from):
--   29795b2ebeb1f1569795114ea978e14bd2795af5a2397f61da7e9256932a154c  gv-mart/supabase/migrations/20261027100000_followup_questions.sql
--   fdb556bb4d56b493ab23290e36cdfa9b723bf1fae1133aa3a096e32553fec6c7  gv-mart/supabase/tests/followup_questions.test.sql

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

  v_text := $rh1$-- Rolled-back DB tests for 20261027100000_followup_questions.
-- NOT RUN (written for review). Run only through the rehearsal wrapper the owner approves: the wrapper applies the migration and
-- then this file in ONE request; this file ends in an unconditional RAISE, so nothing is committed. Throwaway __TEST_
-- organisations only; nothing is sent; no real customer, ticket or number is touched.
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
-- a completed paid/amc ticket gives a post-service follow-up through the real trigger
create function pg_temp.ticket(p_org uuid, p_cust uuid, p_type text) returns uuid language plpgsql as $f$
declare t uuid; f uuid;
begin
  insert into public.service_tickets (org_id, customer_id, type, name_of_complaint) values (p_org, p_cust, p_type::public.ticket_type, '__TEST_ complaint') returning id into t;
  update public.service_tickets set status = 'completed' where id = t;
  select id into f from public.lead_followups where ticket_id = t;
  return f;
end $f$;

do $t$
declare
  v_org uuid; v_org2 uuid; v_master uuid; v_master2 uuid; v_sales uuid; v_ops uuid; v_custrole uuid;
  v_c1 uuid; v_c_test uuid;
  q_yn uuid; q_rate uuid; q_txt uuid; q_ch uuid; q_req uuid; q_amc uuid; q_other uuid;
  o_sat uuid; o_issue uuid; o_retry uuid; o_later uuid; o_noneed uuid;
  f1 uuid; f2 uuid; f3 uuid; f4 uuid; f5 uuid; f6 uuid; f7 uuid; f_amc uuid;
  r jsonb; s text; n int; rec record; v_due timestamptz := now() + interval '3 days'; v_call uuid;
  v_ratings_before int; v_ratings_after int; v_reviews_before int;
  v_org3 uuid; v_c3 uuid; v_q3 uuid; v_f3 uuid; v_o3 uuid; v_m3 uuid; v_s3 uuid; v_ok boolean; v_err text; v_list text; v_call3 uuid;
begin
  -- ---------- schema, seeds, grants ----------
  perform pg_temp.chk('the three new tables exist with RLS on',
    (select count(*) from pg_class c where c.relnamespace = 'public'::regnamespace and c.relrowsecurity
       and c.relname in ('followup_questions', 'followup_question_ticket_types', 'post_service_call_answers')) = 3);
  perform pg_temp.chk('post_service_calls.followup_needed is a nullable boolean',
    (select data_type || '/' || is_nullable from information_schema.columns
      where table_schema = 'public' and table_name = 'post_service_calls' and column_name = 'followup_needed') = 'boolean/YES');
  perform pg_temp.chk('anon has no privilege on the new tables; authenticated cannot write answers or delete questions',
    not exists (select 1 from unnest(array['followup_questions', 'followup_question_ticket_types', 'post_service_call_answers']) t,
                     unnest(array['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE']) pr where has_table_privilege('anon', 'public.' || t, pr))
    and not has_table_privilege('authenticated', 'public.post_service_call_answers', 'INSERT')
    and not has_table_privilege('authenticated', 'public.post_service_call_answers', 'UPDATE')
    and not has_table_privilege('authenticated', 'public.post_service_call_answers', 'DELETE')
    and not has_table_privilege('authenticated', 'public.followup_questions', 'DELETE')
    and has_table_privilege('authenticated', 'public.post_service_call_answers', 'SELECT'));
  perform pg_temp.chk('functions: the old 4-argument log_post_service_call is gone, the 6-argument one exists, one of each',
    to_regprocedure('public.log_post_service_call(uuid,uuid,text,timestamptz)') is null
    and to_regprocedure('public.log_post_service_call(uuid,uuid,text,timestamptz,jsonb,boolean)') is not null
    and (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname = 'log_post_service_call') = 1);
  perform pg_temp.chk('log_post_service_call grants: authenticated and service_role yes, anon and PUBLIC no',
    has_function_privilege('authenticated', 'public.log_post_service_call(uuid,uuid,text,timestamptz,jsonb,boolean)', 'execute')
    and has_function_privilege('service_role', 'public.log_post_service_call(uuid,uuid,text,timestamptz,jsonb,boolean)', 'execute')
    and not has_function_privilege('anon', 'public.log_post_service_call(uuid,uuid,text,timestamptz,jsonb,boolean)', 'execute')
    and not exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                     where p.pronamespace = 'public'::regnamespace and a.grantee = 0
                       and p.proname in ('log_post_service_call', 'get_post_service_questions', 'report_followup_question_answers',
                                         '_post_service_questions_for', 'seed_followup_questions', 'trg_seed_followup_questions',
                                         '_trg_followup_question_guard')));
  perform pg_temp.chk('read functions: authenticated yes, anon no; internal helpers not callable by clients',
    has_function_privilege('authenticated', 'public.get_post_service_questions(uuid)', 'execute')
    and has_function_privilege('authenticated', 'public.report_followup_question_answers(date,date)', 'execute')
    and not has_function_privilege('anon', 'public.get_post_service_questions(uuid)', 'execute')
    and not has_function_privilege('anon', 'public.report_followup_question_answers(date,date)', 'execute')
    and not has_function_privilege('authenticated', 'public._post_service_questions_for(uuid,text)', 'execute')
    and not has_function_privilege('authenticated', 'public.seed_followup_questions(uuid)', 'execute')
    and not has_function_privilege('authenticated', 'public._trg_followup_question_guard()', 'execute'));
  perform pg_temp.chk('definer functions have a fixed search_path',
    not exists (select 1 from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prosecdef
                 and p.proname in ('log_post_service_call', 'get_post_service_questions', 'report_followup_question_answers',
                                   '_post_service_questions_for', 'seed_followup_questions', 'trg_seed_followup_questions', '_trg_followup_question_guard')
                 and not coalesce(p.proconfig::text like '%search_path=%', false)));
  perform pg_temp.chk('no foreign key from the new tables to ratings or any review table',
    not exists (select 1 from pg_constraint c where c.contype = 'f'
                 and c.conrelid in ('public.followup_questions'::regclass, 'public.followup_question_ticket_types'::regclass, 'public.post_service_call_answers'::regclass)
                 and c.confrelid = 'public.ratings'::regclass));
  perform pg_temp.chk('every pre-existing organisation was seeded with 6 inactive example questions',
    not exists (select 1 from organizations o where o.name not like '\_\_TEST\_%'
                 and (select count(*) from public.followup_questions q where q.org_id = o.id and not q.is_active and q.scope = 'post_service') <> 6));

  insert into organizations (name) values ('__TEST_followupq') returning id into v_org;
  insert into organizations (name) values ('__TEST_followupq_other') returning id into v_org2;
  insert into settings (org_id) values (v_org) on conflict (org_id) do nothing;
  insert into settings (org_id) values (v_org2) on conflict (org_id) do nothing;
  v_master := pg_temp.mkuser('master', v_org);
  v_master2 := pg_temp.mkuser('master', v_org2);
  v_sales := pg_temp.mkuser('sales_admin', v_org);
  v_ops := pg_temp.mkuser('operation_admin', v_org);
  v_custrole := pg_temp.mkuser('customer', v_org);
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ c1', '9400000091') returning id into v_c1;
  insert into customers (org_id, name, mobile, is_test) values (v_org, '__TEST_ flagged', '9400000092', true) returning id into v_c_test;
  update settings set post_service_followup_enabled = true, post_service_ticket_types = array['paid', 'warranty', 'amc'] where org_id = v_org;
  select id into o_sat from post_service_outcomes where org_id = v_org and code = 'satisfied';
  select id into o_issue from post_service_outcomes where org_id = v_org and code = 'issue_remaining';
  select id into o_retry from post_service_outcomes where org_id = v_org and code = 'not_reachable';
  select id into o_later from post_service_outcomes where org_id = v_org and code = 'call_later';
  select id into o_noneed from post_service_outcomes where org_id = v_org and code = 'no_answer_needed';

  perform pg_temp.chk('new organisation: 6 example questions, all inactive, scope post_service, Tamil blank, none required',
    (select count(*) from followup_questions where org_id = v_org) = 6
    and not exists (select 1 from followup_questions where org_id = v_org and (is_active or is_required or scope is distinct from 'post_service' or text_ta <> '')));
  perform pg_temp.chk('seed types: 4 yes/no, 1 rating, 1 free text',
    (select count(*) from followup_questions where org_id = v_org and answer_type = 'yes_no') = 4
    and (select count(*) from followup_questions where org_id = v_org and answer_type = 'rating') = 1
    and (select count(*) from followup_questions where org_id = v_org and answer_type = 'text') = 1);

  -- ---------- RLS and master-only writes ----------
  perform pg_temp.as_user(v_sales);
  select count(*) into n from followup_questions;
  perform pg_temp.chk('sales_admin can read the questions of its own organisation only', n = 6, n::text);
  s := pg_temp.raises(format($q$insert into followup_questions (org_id, text_en, answer_type) values (%L, 'x', 'yes_no')$q$, v_org));
  perform pg_temp.chk('sales_admin cannot write questions', s is not null, coalesce(s, 'accepted'));
  perform pg_temp.as_user(v_custrole);
  select count(*) into n from followup_questions;
  perform pg_temp.chk('a customer-role user sees no questions', n = 0, n::text);
  perform pg_temp.as_user(v_master2);
  select count(*) into n from followup_questions where org_id = v_org;
  perform pg_temp.chk('another organisation''s master cannot see these questions', n = 0, n::text);
  perform pg_temp.as_anon();
  s := pg_temp.raises('select count(*) from public.followup_questions');
  perform pg_temp.chk('anon is refused', s like '%permission denied%', coalesce(s, 'accepted'));

  perform pg_temp.as_user(v_master);
  insert into followup_questions (org_id, text_en, answer_type, is_required, sort_order) values (v_org, 'Working?', 'yes_no', false, 10) returning id into q_yn;
  insert into followup_questions (org_id, text_en, answer_type, sort_order) values (v_org, 'Rate', 'rating', 11) returning id into q_rate;
  insert into followup_questions (org_id, text_en, answer_type, sort_order) values (v_org, 'Comments', 'text', 12) returning id into q_txt;
  insert into followup_questions (org_id, text_en, answer_type, choices, sort_order)
    values (v_org, 'Which day suits?', 'choice', '[{"value":"am","label_en":"Morning"},{"value":"pm","label_en":"Afternoon","label_ta":""}]'::jsonb, 13) returning id into q_ch;
  insert into followup_questions (org_id, text_en, answer_type, is_required, sort_order) values (v_org, 'Must answer', 'yes_no', true, 14) returning id into q_req;
  perform pg_temp.chk('master can create questions of all four types', q_yn is not null and q_rate is not null and q_txt is not null and q_ch is not null and q_req is not null);
  s := pg_temp.raises(format($q$delete from followup_questions where id = %L$q$, q_yn));
  perform pg_temp.chk('a question cannot be deleted (soft delete only)', s is not null, coalesce(s, 'deleted'));
  s := pg_temp.raises(format($q$update followup_questions set answer_type = 'text' where id = %L$q$, q_yn));
  perform pg_temp.chk('answer_type is fixed after creation', s like '%answer_type cannot be changed%', coalesce(s, 'accepted'));
  s := pg_temp.raises(format($q$insert into followup_questions (org_id, text_en, answer_type, choices) values (%L, 'c', 'choice', '[{"value":"a","label_en":"A"}]'::jsonb)$q$, v_org));
  perform pg_temp.chk('a choice question needs at least two choices', s is not null, coalesce(s, 'accepted'));
  s := pg_temp.raises(format($q$insert into followup_questions (org_id, text_en, answer_type, choices) values (%L, 'c', 'choice', '[{"value":"a","label_en":"A"},{"value":"a","label_en":"B"}]'::jsonb)$q$, v_org));
  perform pg_temp.chk('choice values must be unique', s like '%unique%', coalesce(s, 'accepted'));
  s := pg_temp.raises(format($q$insert into followup_questions (org_id, text_en, answer_type, choices) values (%L, 'c', 'yes_no', '[]'::jsonb)$q$, v_org));
  perform pg_temp.chk('a non-choice question cannot carry choices', s is not null, coalesce(s, 'accepted'));
  update followup_questions set is_active = true where id in (q_yn, q_rate, q_txt, q_ch, q_req);
  perform pg_temp.chk('master can activate questions', (select count(*) from followup_questions where org_id = v_org and is_active) = 5);
  perform pg_temp.as_pg();
  perform pg_temp.chk('question edits are audited', exists (select 1 from audit_log where org_id = v_org and table_name = 'followup_questions'));

  -- ---------- which questions a call shows ----------
  f1 := pg_temp.ticket(v_org, v_c1, 'paid');
  perform pg_temp.as_user(v_sales);
  select count(*) into n from get_post_service_questions(f1);
  perform pg_temp.chk('an empty link table means all ticket types: the 5 active questions are offered', n = 5, n::text);
  perform pg_temp.as_pg();
  insert into followup_questions (org_id, text_en, answer_type, sort_order) values (v_org, 'AMC only', 'yes_no', 20) returning id into q_amc;
  insert into followup_question_ticket_types (org_id, question_id, ticket_type) values (v_org, q_amc, 'amc');
  f_amc := pg_temp.ticket(v_org, v_c1, 'amc');
  perform pg_temp.as_user(v_sales);
  select count(*) into n from get_post_service_questions(f1);
  perform pg_temp.chk('a question restricted to amc is NOT offered on a paid ticket', n = 5 and not exists (select 1 from get_post_service_questions(f1) where id = q_amc), n::text);
  select count(*) into n from get_post_service_questions(f_amc);
  perform pg_temp.chk('and IS offered on an amc ticket', n = 6 and exists (select 1 from get_post_service_questions(f_amc) where id = q_amc), n::text);
  perform pg_temp.as_pg();
  update followup_questions set scope = 'lead_call' where id = q_txt;
  perform pg_temp.as_user(v_sales);
  perform pg_temp.chk('a question with another scope is not offered on a post-service call',
    not exists (select 1 from get_post_service_questions(f1) where id = q_txt));
  perform pg_temp.as_pg();
  update followup_questions set scope = null where id = q_txt;
  perform pg_temp.as_user(v_sales);
  perform pg_temp.chk('a NULL scope is treated as post_service', exists (select 1 from get_post_service_questions(f1) where id = q_txt));
  perform pg_temp.as_pg();
  update followup_questions set is_active = false where id = q_amc;
  perform pg_temp.as_user(v_ops);
  s := pg_temp.raises(format($q$select * from get_post_service_questions(%L)$q$, f1));
  perform pg_temp.chk('operation_admin cannot fetch the call-sheet questions (sheet is for sales staff)', s like '%not permitted%', coalesce(s, 'accepted'));
  perform pg_temp.as_pg();

  -- ---------- backward compatibility: no answers, behaves as before ----------
  select count(*) into v_ratings_before from public.ratings where org_id = v_org;
  select count(*) into v_reviews_before from public.ratings where org_id = v_org and google_review_clicked;
  f2 := pg_temp.ticket(v_org, v_c1, 'paid');
  update followup_questions set is_required = false where id = q_req;
  perform pg_temp.as_user(v_sales);
  r := public.log_post_service_call(f2, o_sat);
  perform pg_temp.as_pg();
  perform pg_temp.chk('4-argument style call (positional two arguments) works and closes the follow-up',
    r ->> 'status' = 'done' and (r ->> 'answers_saved')::int = 0
    and (select status::text from lead_followups where id = f2) = 'done'
    and (select count(*) from post_service_calls where followup_id = f2) = 1
    and (select followup_needed from post_service_calls where followup_id = f2) is null);
  perform pg_temp.chk('no answer rows were written', (select count(*) from post_service_call_answers where ticket_id = (select ticket_id from lead_followups where id = f2)) = 0);

  -- ---------- answers: saved in one transaction with the call ----------
  update followup_questions set is_required = true where id = q_req;
  f3 := pg_temp.ticket(v_org, v_c1, 'paid');
  perform pg_temp.as_user(v_sales);
  r := public.log_post_service_call(f3, o_sat, 'all fine', null,
         jsonb_build_array(jsonb_build_object('question_id', q_yn, 'value', true),
                           jsonb_build_object('question_id', q_rate, 'value', 5),
                           jsonb_build_object('question_id', q_txt, 'value', '  Good work  '),
                           jsonb_build_object('question_id', q_ch, 'value', 'pm'),
                           jsonb_build_object('question_id', q_req, 'value', false)));
  perform pg_temp.as_pg();
  v_call := (r ->> 'call_id')::uuid;
  perform pg_temp.chk('five answers saved against the call, the ticket, the customer and the org',
    (r ->> 'answers_saved')::int = 5
    and (select count(*) from post_service_call_answers where call_id = v_call and org_id = v_org and customer_id = v_c1
          and ticket_id = (select ticket_id from lead_followups where id = f3)) = 5);
  perform pg_temp.chk('typed value columns: yes/no bool, rating int, text trimmed, choice code',
    (select answer_bool from post_service_call_answers where call_id = v_call and question_id = q_yn) is true
    and (select answer_int from post_service_call_answers where call_id = v_call and question_id = q_rate) = 5
    and (select answer_text from post_service_call_answers where call_id = v_call and question_id = q_txt) = 'Good work'
    and (select answer_text from post_service_call_answers where call_id = v_call and question_id = q_ch) = 'pm');
  perform pg_temp.chk('snapshot of question text, type and choices stored with the answer',
    (select question_text_en || '/' || answer_type from post_service_call_answers where call_id = v_call and question_id = q_ch) = 'Which day suits?/choice'
    and (select jsonb_array_length(question_choices) from post_service_call_answers where call_id = v_call and question_id = q_ch) = 2);
  -- a later edit of the question does not rewrite history
  update followup_questions set text_en = 'Which day suits you best?', is_active = false where id = q_ch;
  perform pg_temp.chk('editing or deactivating a question leaves the stored snapshot unchanged',
    (select question_text_en from post_service_call_answers where call_id = v_call and question_id = q_ch) = 'Which day suits?');
  update followup_questions set is_active = true where id = q_ch;
  perform pg_temp.chk('the unique index (call_id, question_id) exists',
    exists (select 1 from pg_indexes where tablename = 'post_service_call_answers' and indexdef like '%UNIQUE%' and indexdef like '%(call_id, question_id)%'));
  s := pg_temp.raises(format($q$insert into post_service_call_answers (org_id, call_id, question_id, ticket_id, question_text_en, answer_type, answer_bool)
        values (%L, %L, %L, (select ticket_id from post_service_calls where id = %L), 'dup', 'yes_no', true)$q$, v_org, v_call, q_yn, v_call));
  perform pg_temp.chk('a second answer for the same question on the same call is rejected', s like '%duplicate key%', coalesce(s, 'accepted'));
  s := pg_temp.raises(format($q$insert into post_service_call_answers (org_id, call_id, question_id, ticket_id, question_text_en, answer_type, answer_int)
        values (%L, %L, %L, (select ticket_id from post_service_calls where id = %L), 'bad', 'yes_no', 3)$q$, v_org, v_call, q_req, v_call));
  perform pg_temp.chk('the table itself rejects a value that does not match the snapshot type', s like '%value_matches_type%', coalesce(s, 'accepted'));

  -- ---------- the rating question never touches the Google-review flow ----------
  select count(*) into v_ratings_after from public.ratings where org_id = v_org;
  perform pg_temp.chk('ratings table untouched by a call with a rating answer', v_ratings_after = v_ratings_before and
    (select count(*) from public.ratings where org_id = v_org and google_review_clicked) = v_reviews_before);

  -- ---------- validation ----------
  f4 := pg_temp.ticket(v_org, v_c1, 'paid');
  perform pg_temp.as_user(v_sales);
  s := pg_temp.raises(format($q$select public.log_post_service_call(%L, %L, null, null, %L::jsonb)$q$, f4, o_sat,
        jsonb_build_array(jsonb_build_object('question_id', q_yn, 'value', 'yes'), jsonb_build_object('question_id', q_req, 'value', true))::text));
  perform pg_temp.chk('a yes/no question answered with a string is rejected (type mismatch)', s like '%type mismatch%', coalesce(s, 'accepted'));
  s := pg_temp.raises(format($q$select public.log_post_service_call(%L, %L, null, null, %L::jsonb)$q$, f4, o_sat,
        jsonb_build_array(jsonb_build_object('question_id', q_rate, 'value', 6), jsonb_build_object('question_id', q_req, 'value', true))::text));
  perform pg_temp.chk('a rating of 6 is rejected', s like '%1 to 5%', coalesce(s, 'accepted'));
  s := pg_temp.raises(format($q$select public.log_post_service_call(%L, %L, null, null, %L::jsonb)$q$, f4, o_sat,
        jsonb_build_array(jsonb_build_object('question_id', q_ch, 'value', 'evening'), jsonb_build_object('question_id', q_req, 'value', true))::text));
  perform pg_temp.chk('a value that is not one of the choices is rejected', s like '%not one of the choices%', coalesce(s, 'accepted'));
  s := pg_temp.raises(format($q$select public.log_post_service_call(%L, %L, null, null, %L::jsonb)$q$, f4, o_sat,
        jsonb_build_array(jsonb_build_object('question_id', q_req, 'value', true), jsonb_build_object('question_id', q_req, 'value', false))::text));
  perform pg_temp.chk('the same question twice is rejected', s like '%twice%', coalesce(s, 'accepted'));
  s := pg_temp.raises(format($q$select public.log_post_service_call(%L, %L, null, null, %L::jsonb)$q$, f4, o_sat,
        jsonb_build_array(jsonb_build_object('question_id', gen_random_uuid(), 'value', true), jsonb_build_object('question_id', q_req, 'value', true))::text));
  perform pg_temp.chk('an unknown question id is rejected', s like '%not active or does not apply%', coalesce(s, 'accepted'));
  s := pg_temp.raises(format($q$select public.log_post_service_call(%L, %L, null, null, %L::jsonb)$q$, f4, o_sat,
        jsonb_build_array(jsonb_build_object('question_id', q_amc, 'value', true), jsonb_build_object('question_id', q_req, 'value', true))::text));
  perform pg_temp.chk('an inactive (or non-applicable) question id is rejected', s like '%not active or does not apply%', coalesce(s, 'accepted'));
  s := pg_temp.raises(format($q$select public.log_post_service_call(%L, %L, null, null, '{"a":1}'::jsonb)$q$, f4, o_sat));
  perform pg_temp.chk('answers that are not a list are rejected', s like '%must be a list%', coalesce(s, 'accepted'));
  perform pg_temp.as_pg();
  perform pg_temp.chk('every rejection left no call row and the follow-up still open (one transaction)',
    (select count(*) from post_service_calls where followup_id = f4) = 0 and (select status::text from lead_followups where id = f4) = 'open');

  -- ---------- required questions: enforced server-side ----------
  f5 := pg_temp.ticket(v_org, v_c1, 'paid');
  perform pg_temp.as_user(v_sales);
  s := pg_temp.raises(format($q$select public.log_post_service_call(%L, %L)$q$, f4, o_sat));
  perform pg_temp.chk('a required question with no answer is refused', s like '%an answer is required: Must answer%', coalesce(s, 'accepted'));
  s := pg_temp.raises(format($q$select public.log_post_service_call(%L, %L, null, null, %L::jsonb)$q$, f4, o_sat,
        jsonb_build_array(jsonb_build_object('question_id', q_req, 'value', null))::text));
  perform pg_temp.chk('a null value counts as no answer', s like '%an answer is required%', coalesce(s, 'accepted'));
  r := public.log_post_service_call(f4, o_noneed);
  perform pg_temp.chk('outcome no_answer_needed does not require answers', r ->> 'status' = 'done', r::text);
  r := public.log_post_service_call(f5, o_retry, null, v_due);
  perform pg_temp.chk('outcome not_reachable does not require answers and keeps the follow-up open',
    r ->> 'status' = 'open' and (select due_at from lead_followups where id = f5) = v_due, r::text);
  perform pg_temp.as_pg();
  perform pg_temp.chk('a required-answers refusal for sales still allows the call to be logged once answered',
    exists (select 1 from post_service_calls where followup_id = f5));

  -- ---------- follow-up needed and retry: one task, never two ----------
  f6 := pg_temp.ticket(v_org, v_c1, 'paid');
  update followup_questions set is_required = false where id = q_req;
  perform pg_temp.as_user(v_sales);
  s := pg_temp.raises(format($q$select public.log_post_service_call(%L, %L, null, null, null, true)$q$, f6, o_sat));
  perform pg_temp.chk('follow-up needed = true without a new date is refused', s is not null, coalesce(s, 'accepted'));
  r := public.log_post_service_call(f6, o_sat, 'needs a visit', v_due, null, true);
  perform pg_temp.as_pg();
  perform pg_temp.chk('follow-up needed = true keeps the SAME follow-up open at the new date; the call stores true',
    r ->> 'status' = 'open' and (r ->> 'followup_needed')::boolean is true
    and (select status::text || '/' || due_at::text from lead_followups where id = f6) = 'open/' || v_due::text
    and (select followup_needed from post_service_calls where followup_id = f6) is true
    and (select reschedule_reason from lead_followups where id = f6) = 'Follow-up needed');
  perform pg_temp.chk('still exactly one follow-up row for that ticket',
    (select count(*) from lead_followups where ticket_id = (select ticket_id from lead_followups where id = f6)) = 1);
  f7 := pg_temp.ticket(v_org, v_c1, 'paid');
  perform pg_temp.as_user(v_sales);
  r := public.log_post_service_call(f7, o_sat, null, null, null, false);
  perform pg_temp.as_pg();
  perform pg_temp.chk('follow-up needed = false closes the task and stores false',
    r ->> 'status' = 'done' and (select followup_needed from post_service_calls where followup_id = f7) is false);
  -- a retry outcome with followup_needed = true is still ONE reschedule, and the stored column is NULL
  f1 := pg_temp.ticket(v_org, v_c1, 'paid');
  perform pg_temp.as_user(v_sales);
  r := public.log_post_service_call(f1, o_later, null, v_due, null, true);
  perform pg_temp.as_pg();
  perform pg_temp.chk('retry outcome plus follow-up needed: one reschedule, one follow-up row, column stored NULL',
    r ->> 'status' = 'open' and (select count(*) from lead_followups where ticket_id = (select ticket_id from lead_followups where id = f1)) = 1
    and (select followup_needed from post_service_calls where followup_id = f1) is null);

  -- ---------- alert outcome unchanged ----------
  f2 := pg_temp.ticket(v_org, v_c1, 'paid');
  perform pg_temp.as_user(v_sales);
  r := public.log_post_service_call(f2, o_issue, 'still leaking');
  perform pg_temp.as_pg();
  perform pg_temp.chk('an alert outcome still notifies master and operations', (r ->> 'alerted')::boolean
    and exists (select 1 from notifications where org_id = v_org and type = 'post_service_issue' and user_id = v_master));

  -- ---------- answers are not writable by clients ----------
  perform pg_temp.as_user(v_master);
  s := pg_temp.raises(format($q$insert into post_service_call_answers (org_id, call_id, question_id, ticket_id, question_text_en, answer_type, answer_bool)
        values (%L, %L, %L, (select ticket_id from post_service_calls where id = %L), 'x', 'yes_no', true)$q$, v_org, v_call, q_yn, v_call));
  perform pg_temp.chk('even a master cannot insert an answer directly', s like '%permission denied%', coalesce(s, 'accepted'));
  s := pg_temp.raises(format($q$update post_service_call_answers set answer_bool = false where call_id = %L$q$, v_call));
  perform pg_temp.chk('even a master cannot edit an answer directly', s like '%permission denied%', coalesce(s, 'accepted'));
  s := pg_temp.raises(format($q$delete from post_service_call_answers where call_id = %L$q$, v_call));
  perform pg_temp.chk('even a master cannot delete an answer directly', s like '%permission denied%', coalesce(s, 'accepted'));
  perform pg_temp.as_pg();

  -- ---------- readers ----------
  perform pg_temp.as_user(v_ops);
  select count(*) into n from post_service_call_answers where customer_id = v_c1;
  perform pg_temp.chk('operation_admin can read answers (customer and ticket cards)', n >= 5, n::text);
  perform pg_temp.as_user(v_custrole);
  select count(*) into n from post_service_call_answers;
  perform pg_temp.chk('a customer-role user cannot read answers', n = 0, n::text);
  perform pg_temp.as_user(v_master2);
  select count(*) into n from post_service_call_answers where org_id = v_org;
  perform pg_temp.chk('another organisation cannot read these answers', n = 0, n::text);
  perform pg_temp.as_pg();

  -- ---------- report ----------
  -- one answer from a flagged test customer must be left out
  update followup_questions set is_required = false where id = q_req;
  f3 := pg_temp.ticket(v_org, v_c_test, 'paid');
  perform pg_temp.as_user(v_sales);
  perform public.log_post_service_call(f3, o_sat, null, null, jsonb_build_array(jsonb_build_object('question_id', q_rate, 'value', 1)));
  perform pg_temp.as_user(v_master);
  select * into rec from report_followup_question_answers(current_date - 1, current_date + 1) where question_id = q_rate;
  perform pg_temp.chk('report: rating question has 1 real answer (the test customer''s is excluded), average 5.00',
    rec.answers = 1 and rec.rating_avg = 5.00 and (rec.rating_counts ->> '5')::int = 1 and (rec.rating_counts ->> '1')::int = 0,
    coalesce(rec.answers::text, 'no row') || '/' || coalesce(rec.rating_avg::text, '-'));
  select * into rec from report_followup_question_answers(current_date - 1, current_date + 1) where question_id = q_yn;
  perform pg_temp.chk('report: yes/no counts', rec.yes_count = 1 and rec.no_count = 0, coalesce(rec.yes_count::text, 'no row'));
  select * into rec from report_followup_question_answers(current_date - 1, current_date + 1) where question_id = q_ch;
  perform pg_temp.chk('report: choice counts use the stored codes', (rec.choice_counts ->> 'pm')::int = 1, coalesce(rec.choice_counts::text, 'no row'));
  select * into rec from report_followup_question_answers(current_date - 1, current_date + 1) where question_id = q_txt;
  perform pg_temp.chk('report: free-text questions report a count, never the text', rec.text_count = 1 and rec.choice_counts is null);
  select count(*) into n from report_followup_question_answers(current_date + 5, current_date + 6);
  perform pg_temp.chk('report: an empty range returns no rows', n = 0, n::text);
  s := pg_temp.raises($q$select * from report_followup_question_answers(current_date, current_date - 1)$q$);
  perform pg_temp.chk('report: reversed range refused', s like '%invalid date range%', coalesce(s, 'accepted'));
  s := pg_temp.raises($q$select * from report_followup_question_answers(current_date - 400, current_date)$q$);
  perform pg_temp.chk('report: range over 366 days refused', s like '%limited to 366%', coalesce(s, 'accepted'));
  perform pg_temp.as_user(v_sales);
  s := pg_temp.raises($q$select * from report_followup_question_answers(current_date - 1, current_date)$q$);
  perform pg_temp.chk('report: master only (sales_admin refused)', s like '%only the master%', coalesce(s, 'accepted'));
  perform pg_temp.as_user(v_master2);
  select count(*) into n from report_followup_question_answers(current_date - 1, current_date + 1);
  perform pg_temp.chk('report: another organisation''s master sees nothing of this organisation', n = 0, n::text);
  perform pg_temp.as_anon();
  s := pg_temp.raises($q$select * from public.report_followup_question_answers(current_date - 1, current_date)$q$);
  perform pg_temp.chk('report: anon refused', s like '%permission denied%', coalesce(s, 'accepted'));
  perform pg_temp.as_pg();

  -- ---------- a new organisation gets the seeds; nothing real is changed ----------
  perform pg_temp.chk('the second throwaway organisation was seeded too',
    (select count(*) from followup_questions where org_id = v_org2) = 6);
  perform pg_temp.chk('wa_dispatch_v2_enabled untouched; nothing queued to the outbox',
    not coalesce((select wa_dispatch_v2_enabled from settings where org_id = v_org), false)
    and not exists (select 1 from whatsapp_outbox where org_id = v_org));

  -- ---------- (d) one function, no overload ambiguity for a caller that sends the four old named arguments ----------
  f6 := pg_temp.ticket(v_org, v_c1, 'paid');
  update followup_questions set is_required = false where id = q_req;
  perform pg_temp.as_user(v_sales);
  r := public.log_post_service_call(p_followup_id => f6, p_outcome_id => o_sat, p_note => 'named', p_next_due_at => null);
  perform pg_temp.as_pg();
  perform pg_temp.chk('a caller using the four old NAMED arguments resolves to the single new function',
    r ->> 'status' = 'done' and (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname = 'log_post_service_call') = 1);
  perform pg_temp.chk('no other overload of the new read functions either',
    (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname in ('get_post_service_questions', 'report_followup_question_answers')) = 2);

  -- ---------- (c) seed trigger and backfill ----------
  select count(*) into n from followup_questions where org_id = v_org;
  perform public.seed_followup_questions(v_org);
  perform pg_temp.chk('seed function is idempotent: a second run adds nothing',
    (select count(*) from followup_questions where org_id = v_org) = n, n::text);
  update followup_questions set text_en = 'Edited wording', is_active = true where org_id = v_org and code = 'do_better';
  perform public.seed_followup_questions(v_org);
  perform pg_temp.chk('re-running the seed leaves an edited, activated seed question as the master left it',
    (select text_en || '/' || is_active::text from followup_questions where org_id = v_org and code = 'do_better') = 'Edited wording/true');
  perform pg_temp.chk('the seed trigger is one AFTER INSERT row trigger on organizations',
    (select count(*) from pg_trigger t where t.tgrelid = 'public.organizations'::regclass and t.tgname = 'seed_followup_questions_on_org'
       and (t.tgtype & 4) = 4 and (t.tgtype & 1) = 1 and (t.tgtype & 2) = 0) = 1);

  -- ---------- (b) the guard bypass flag is reachable by no client-callable function ----------
  select string_agg(p.oid::regprocedure::text, ', ') into v_list
  from pg_proc p
  where p.pronamespace = 'public'::regnamespace and p.prokind = 'f' and p.prosrc ilike '%set_config%lead_lists_cleanup%';
  perform pg_temp.chk('the only public function that SETS app.lead_lists_cleanup is purge_test_organisation',
    coalesce(v_list, '') = 'purge_test_organisation(uuid)', coalesce(v_list, 'none'));
  perform pg_temp.chk('purge_test_organisation is executable by neither anon, authenticated nor service_role',
    not has_function_privilege('anon', 'public.purge_test_organisation(uuid)', 'execute')
    and not has_function_privilege('authenticated', 'public.purge_test_organisation(uuid)', 'execute')
    and not has_function_privilege('service_role', 'public.purge_test_organisation(uuid)', 'execute'));
  select string_agg(p.oid::regprocedure::text, ', ' order by p.proname) into v_list
  from pg_proc p
  where p.pronamespace = 'public'::regnamespace and p.prokind = 'f' and p.prosrc ilike '%set_config(%'
    and (has_function_privilege('authenticated', p.oid, 'execute') or has_function_privilege('anon', p.oid, 'execute'));
  perform pg_temp.chk('client-callable public functions that call set_config (listed for review; none sets lead_lists_cleanup)',
    not exists (select 1 from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prosrc ilike '%set_config%lead_lists_cleanup%'
                  and (has_function_privilege('authenticated', p.oid, 'execute') or has_function_privilege('anon', p.oid, 'execute'))),
    coalesce(v_list, 'none'));
  perform pg_temp.as_user(v_master);
  s := pg_temp.raises(format($q$delete from followup_questions where id = %L$q$, q_ch));
  perform pg_temp.as_pg();
  perform pg_temp.chk('a master cannot delete a question that has answers', s is not null and exists (select 1 from followup_questions where id = q_ch), coalesce(s, 'deleted'));

  -- ---------- (a) purge_test_organisation: an organisation with questions, links, calls and answers ----------
  insert into organizations (name) values ('__TEST_followupq_purge') returning id into v_org3;
  insert into settings (org_id) values (v_org3) on conflict (org_id) do nothing;
  update settings set post_service_followup_enabled = true where org_id = v_org3;
  v_m3 := pg_temp.mkuser('master', v_org3);
  v_s3 := pg_temp.mkuser('sales_admin', v_org3);
  insert into customers (org_id, name, mobile) values (v_org3, '__TEST_ purge customer', '9400000093') returning id into v_c3;
  select id into v_q3 from followup_questions where org_id = v_org3 and code = 'service_rating';
  update followup_questions set is_active = true, is_required = true where id = v_q3;
  insert into followup_question_ticket_types (org_id, question_id, ticket_type) values (v_org3, v_q3, 'paid');
  select id into v_o3 from post_service_outcomes where org_id = v_org3 and code = 'satisfied';
  v_f3 := pg_temp.ticket(v_org3, v_c3, 'paid');
  perform pg_temp.as_user(v_s3);
  r := public.log_post_service_call(v_f3, v_o3, null, null, jsonb_build_array(jsonb_build_object('question_id', v_q3, 'value', 4)));
  perform pg_temp.as_pg();
  v_call3 := (r ->> 'call_id')::uuid;
  perform pg_temp.chk('purge fixture: the organisation has questions, a link, a call and an answer',
    (select count(*) from followup_questions where org_id = v_org3) = 6
    and (select count(*) from followup_question_ticket_types where org_id = v_org3) = 1
    and (select count(*) from post_service_call_answers where call_id = v_call3) = 1);
  s := pg_temp.raises(format($q$delete from followup_questions where org_id = %L$q$, v_org3));
  perform pg_temp.chk('without app.lead_lists_cleanup the guard refuses deleting the questions', s like '%never deleted%', coalesce(s, 'deleted'));
  -- with the flag but answers still present, the deferred foreign key refuses when it is checked
  v_ok := false;
  begin
    perform set_config('app.lead_lists_cleanup', 'on', true);
    delete from followup_questions where id = v_q3;
    set constraints all immediate;
  exception when foreign_key_violation then
    v_ok := true;
  end;
  perform set_config('app.lead_lists_cleanup', '', true);
  perform pg_temp.chk('even with the flag set, a question that still has answers is refused by the foreign key', v_ok);
  perform pg_temp.chk('the question and the answer are intact after that refusal',
    exists (select 1 from followup_questions where id = v_q3) and exists (select 1 from post_service_call_answers where call_id = v_call3));
  -- the supported route: purge_test_organisation sets both flags itself and removes the organisation
  v_ok := false; v_err := null;
  begin
    perform public.purge_test_organisation(v_org3);
    set constraints all immediate;
    v_ok := not exists (select 1 from organizations where id = v_org3)
        and not exists (select 1 from followup_questions where org_id = v_org3)
        and not exists (select 1 from followup_question_ticket_types where org_id = v_org3)
        and not exists (select 1 from post_service_calls where org_id = v_org3)
        and not exists (select 1 from post_service_call_answers where org_id = v_org3);
  exception when others then
    v_ok := false; v_err := sqlerrm;
  end;
  perform pg_temp.chk('purge_test_organisation removes an organisation with questions, links, calls and answers', v_ok, coalesce(v_err, ''));
  perform pg_temp.chk('and leaves both flags cleared',
    coalesce(current_setting('app.lead_lists_cleanup', true), '') = '' and coalesce(current_setting('app.audit_purge_ok', true), '') = '');

  raise exception 'RESULTS%', E'\n' || (select string_agg(r2.line, E'\n' order by r2.n) from pg_temp.res r2);
end $t$;
$rh1$;
  v_hash := encode(sha256(convert_to(v_text, 'UTF8')), 'hex');
  if v_hash <> 'fdb556bb4d56b493ab23290e36cdfa9b723bf1fae1133aa3a096e32553fec6c7' then
    raise exception 'REHEARSAL_REFUSED: hash mismatch for followup_questions.test.sql: %', v_hash;
  end if;
  execute v_text;

  raise exception 'REHEARSAL_DID_NOT_RAISE: the test file should have raised RESULTS';
end
$rehearsal$;
