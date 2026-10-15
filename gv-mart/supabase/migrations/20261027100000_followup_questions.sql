-- Master-defined questions for follow-up calls (post-service calls first). Design: gv-mart/docs/design-followup-questions.md
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
