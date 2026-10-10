-- Rollback for 20261012120000_log_outcome_followup_choice.sql: back to the live 9-argument function.
-- Follow-ups already skipped with "No" stay skipped (those leads simply have no open follow-up).
drop function if exists public.log_lead_outcome(uuid, uuid, text, text, timestamp with time zone, public.lead_followup_type, text, boolean, text, boolean);

CREATE OR REPLACE FUNCTION public.log_lead_outcome(p_lead_id uuid, p_outcome_id uuid, p_note text DEFAULT NULL::text, p_channel text DEFAULT 'call'::text, p_next_due_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_next_type lead_followup_type DEFAULT NULL::lead_followup_type, p_next_note text DEFAULT NULL::text, p_next_is_exact boolean DEFAULT false, p_lost_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_lead public.leads;
  v_out public.lead_outcomes;
  v_activity_id uuid;
  v_followup_id uuid;
  v_closing boolean;
  v_reason text;
  v_postpone integer;
  v_open_id uuid;
begin
  v_lead := public._lead_lock(p_lead_id);
  perform set_config('app.lead_stage_source', 'outcome', true);

  if v_lead.status in ('won', 'lost') then
    raise exception 'this lead is already %; reopen it first', v_lead.status;
  end if;
  if p_channel not in ('call', 'whatsapp', 'visit', 'meeting') then
    raise exception 'invalid channel %', p_channel;
  end if;

  select * into v_out from public.lead_outcomes where id = p_outcome_id and org_id = v_lead.org_id and is_active;
  if not found then
    raise exception 'outcome % not found or inactive', p_outcome_id;
  end if;

  v_closing := v_out.stage_effect in ('won', 'lost');

  if v_out.stage_effect = 'lost' then
    v_reason := nullif(btrim(coalesce(p_lost_reason, v_out.lost_reason_hint, '')), '');
    if v_reason is null then
      raise exception 'a reason is required to mark a lead lost';
    end if;
  end if;

  if not v_closing and v_out.requires_followup then
    perform public._lead_check_due(p_next_due_at);
  end if;

  insert into public.lead_activities (org_id, lead_id, type, note, at, outcome_id)
  values (v_lead.org_id, v_lead.id, p_channel, nullif(btrim(coalesce(p_note, '')), ''), clock_timestamp(), v_out.id)
  returning id into v_activity_id;

  -- The contact itself completes the open task, even if it was not due yet.
  update public.lead_followups
    set status = 'done', completed_by = auth.uid(), completed_at = clock_timestamp(), completing_activity_id = v_activity_id
    where lead_id = v_lead.id and status = 'open'
    returning id into v_open_id;

  v_postpone := case when v_out.counts_as_postpone then v_lead.postpone_count + 1 else 0 end;

  if v_out.stage_effect = 'won' then
    perform public._lead_apply_status(v_lead, 'won', null);
  elsif v_out.stage_effect = 'lost' then
    perform public._lead_apply_status(v_lead, 'lost', v_reason);
  elsif v_out.stage_effect is not null and public._lead_stage_rank(v_out.stage_effect) > public._lead_stage_rank(v_lead.status) then
    perform public._lead_apply_status(v_lead, v_out.stage_effect, null);
  end if;

  update public.leads set postpone_count = v_postpone where id = v_lead.id;

  if not v_closing and v_out.requires_followup then
    insert into public.lead_followups (org_id, lead_id, due_at, type, is_exact_time, note, source, created_at)
    values (
      v_lead.org_id, v_lead.id, p_next_due_at, coalesce(p_next_type, v_out.default_followup_type),
      coalesce(p_next_is_exact, false) or v_out.followup_mode = 'exact_time',
      nullif(btrim(coalesce(p_next_note, '')), ''), 'outcome', clock_timestamp()
    )
    returning id into v_followup_id;
  end if;

  return jsonb_build_object(
    'activity_id', v_activity_id,
    'followup_id', v_followup_id,
    'completed_followup_id', v_open_id,
    'next_due_at', case when v_followup_id is not null then p_next_due_at end,
    'status', (select status from public.leads where id = v_lead.id),
    'postpone_count', v_postpone
  );
end;
$function$;
revoke all on function public.log_lead_outcome(uuid, uuid, text, text, timestamp with time zone, public.lead_followup_type, text, boolean, text) from public, anon, authenticated;
grant execute on function public.log_lead_outcome(uuid, uuid, text, text, timestamp with time zone, public.lead_followup_type, text, boolean, text) to authenticated, service_role;

notify pgrst, 'reload schema';
