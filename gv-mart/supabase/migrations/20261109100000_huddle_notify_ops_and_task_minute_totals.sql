-- Window P, Step 3 verification follow-up (client items 3 and 5).
--
--   1. _trg_meeting_issue_notify (20261102100000) notified the master only when a huddle problem was raised,
--      a solution given, or an issue solved. The acceptance criterion is master AND operation_admin. Fixes the
--      role filter from = 'master' to in ('master', 'operation_admin').
--   2. task_minute_totals / person_minute_totals: plain views over task_logs so a screen can show total time
--      logged per task and cumulative per person, without pulling every log row client-side. These are views,
--      not functions, and carry no privilege of their own to leak: WITH (security_invoker = true) makes
--      Postgres evaluate task_logs' and tasks' row security as the CALLING role, not the view owner (the
--      migration runs as postgres, which bypasses RLS — without security_invoker a view created here would
--      silently show every organisation's data to every caller. PG15+, which this project runs on Supabase).
--
-- Rollback: supabase/rollbacks/20261109100000_huddle_notify_ops_and_task_minute_totals.rollback.sql

-- 1. the master AND operation_admin are told --------------------------------------------------------------------------
create or replace function public._trg_meeting_issue_notify()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_type text;
  v_title text;
  v_who text;
begin
  if tg_op = 'INSERT' then
    v_type := 'huddle_problem_raised';
    v_title := 'Problem raised in the huddle';
  elsif new.status = 'solved' and old.status is distinct from 'solved' then
    v_type := 'huddle_issue_solved';
    v_title := 'Huddle problem marked solved';
  elsif new.solution is distinct from old.solution and btrim(coalesce(new.solution, '')) <> '' then
    v_type := 'huddle_solution_given';
    v_title := 'Solution given for a huddle problem';
  else
    return new;
  end if;

  select full_name into v_who from public.profiles where id = auth.uid();
  insert into public.notifications (org_id, user_id, type, title, body, ref_id)
  select new.org_id, p.id, v_type, v_title,
         left(new.description, 140) || case when v_who is not null then ' (' || v_who || ')' else '' end,
         new.id
  from public.profiles p
  where p.org_id = new.org_id and p.role::text in ('master', 'operation_admin') and p.is_active and p.id is distinct from auth.uid();
  return new;
end;
$$;
revoke all on function public._trg_meeting_issue_notify() from public, anon, authenticated;

-- 2. time totals --------------------------------------------------------------------------------------------------------
create view public.task_minute_totals
  with (security_invoker = true)
as
  select task_id, sum(minutes_spent) as total_minutes
  from public.task_logs
  where minutes_spent is not null
  group by task_id;
revoke all on public.task_minute_totals from public, anon, authenticated;
grant select on public.task_minute_totals to authenticated;

create view public.person_minute_totals
  with (security_invoker = true)
as
  select t.assignee_id as profile_id, sum(l.minutes_spent) as total_minutes
  from public.task_logs l
  join public.tasks t on t.id = l.task_id
  where l.minutes_spent is not null and t.assignee_id is not null
  group by t.assignee_id;
revoke all on public.person_minute_totals from public, anon, authenticated;
grant select on public.person_minute_totals to authenticated;

notify pgrst, 'reload schema';
