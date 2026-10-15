-- Rollback for 20261027100000_followup_questions.sql
-- Restores the 4-argument log_post_service_call exactly as 20261014100000 defined it and removes the question feature.
-- REFUSES to run while any answer rows or any followup_needed value exist: that data would be destroyed. Export it first, then
-- delete the rows on purpose:
--   select * from post_service_call_answers;  select id, followup_needed from post_service_calls where followup_needed is not null;
begin;
do $g$
begin
  if exists (select 1 from public.post_service_call_answers) then
    raise exception 'rollback refused: post_service_call_answers has rows (export them, then delete them deliberately)';
  end if;
  if exists (select 1 from public.post_service_calls where followup_needed is not null) then
    raise exception 'rollback refused: post_service_calls.followup_needed has values (export, then set to null deliberately)';
  end if;
end $g$;

drop function if exists public.log_post_service_call(uuid, uuid, text, timestamptz, jsonb, boolean);
create function public.log_post_service_call(
  p_followup_id uuid,
  p_outcome_id uuid,
  p_note text default null,
  p_next_due_at timestamptz default null
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_f public.lead_followups;
  v_out public.post_service_outcomes;
  v_call uuid;
  v_ticket_name text;
  v_cust_name text;
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
  if v_out.retry then
    perform public._lead_check_due(p_next_due_at);
  end if;

  insert into public.post_service_calls (org_id, followup_id, ticket_id, customer_id, outcome_id, outcome_code, note)
  values (v_f.org_id, v_f.id, v_f.ticket_id, v_f.customer_id, v_out.id, v_out.code, nullif(btrim(coalesce(p_note, '')), ''))
  returning id into v_call;

  if v_out.retry then
    update public.lead_followups set due_at = p_next_due_at, reschedule_reason = v_out.label_en where id = v_f.id;
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
    'status', case when v_out.retry then 'open' else 'done' end,
    'next_due_at', case when v_out.retry then p_next_due_at end,
    'alerted', v_out.alert
  );
end;
$$;
revoke all on function public.log_post_service_call(uuid, uuid, text, timestamptz) from public, anon, authenticated;
grant execute on function public.log_post_service_call(uuid, uuid, text, timestamptz) to authenticated, service_role;

drop function if exists public.report_followup_question_answers(date, date);
drop function if exists public.get_post_service_questions(uuid);
drop function if exists public._post_service_questions_for(uuid, text);

drop trigger if exists seed_followup_questions_on_org on public.organizations;
drop function if exists public.trg_seed_followup_questions();
drop function if exists public.seed_followup_questions(uuid);

drop table if exists public.post_service_call_answers;
drop table if exists public.followup_question_ticket_types;
drop table if exists public.followup_questions;
drop function if exists public._trg_followup_question_guard();
alter table public.post_service_calls drop column if exists followup_needed;

notify pgrst, 'reload schema';
commit;
