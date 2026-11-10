-- Rollback for 20261109100000_huddle_notify_ops_and_task_minute_totals.sql.
-- Refusal check first: refuses if either view has any dependent object (something else now selects from it),
-- since dropping out from under a dependent would break it silently instead of with a clear error.
do $$
begin
  if exists (
    select 1
    from pg_depend d
    join pg_rewrite r on r.oid = d.objid and d.classid = 'pg_rewrite'::regclass
    join pg_class vc on vc.oid = r.ev_class
    where d.refobjid in ('public.task_minute_totals'::regclass, 'public.person_minute_totals'::regclass)
      and vc.relname not in ('task_minute_totals', 'person_minute_totals')
  ) then
    raise exception 'ROLLBACK_REFUSED: another view or object depends on task_minute_totals or person_minute_totals';
  end if;
end $$;

begin;
drop view if exists public.person_minute_totals;
drop view if exists public.task_minute_totals;

-- restores the master-only notify (20261102100000's definition)
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
  where p.org_id = new.org_id and p.role::text = 'master' and p.is_active and p.id is distinct from auth.uid();
  return new;
end;
$$;
revoke all on function public._trg_meeting_issue_notify() from public, anon, authenticated;

notify pgrst, 'reload schema';
commit;
