-- Lead follow-up Phase 2, gap 1: reopen with a required reason + pre-closing
-- stage, block won<->lost in update_lead_status, stage-change source on every RPC.
--
-- BACKWARD COMPATIBILITY: the deployed frontend still calls the 5-argument
-- reopen_lead(p_lead_id, p_next_due_at, p_type, p_note, p_is_exact). That
-- overload is KEPT (it still reopens to 'contacted', no reason). The new
-- overload takes a required p_reason and returns the lead to its pre-closing
-- stage. The old overload is dropped in a LATER migration, once the new
-- frontend is live.
--
-- Note: create_sale (converting a quotation) can still move a lost lead to
-- won on purpose - that is a real sale, and it is logged in lead_stage_log.
-- Only update_lead_status (the stage buttons) refuses closed-lead changes.

-- ── the stage trigger consumes (and clears) the context it was given ─────
create or replace function public._trg_lead_status_history()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_source text := coalesce(nullif(current_setting('app.lead_stage_source', true), ''), 'other');
  v_reason text := nullif(btrim(coalesce(current_setting('app.lead_stage_reason', true), '')), '');
begin
  if v_source not in ('outcome', 'stage_button', 'reopen') then
    v_source := 'other';
  end if;
  -- one-shot: a later unrelated update in the same transaction must not inherit it
  perform set_config('app.lead_stage_source', '', true);
  perform set_config('app.lead_stage_reason', '', true);

  insert into public.lead_activities (org_id, lead_id, type, note, at, from_status, to_status)
  values (
    new.org_id, new.id, 'status_change',
    case
      when v_source = 'reopen' then v_reason
      when new.status = 'lost' then new.lost_reason
      else new.status::text
    end,
    clock_timestamp(), old.status, new.status
  );

  insert into public.lead_stage_log (org_id, lead_id, from_status, to_status, changed_by, reason, source)
  values (
    new.org_id, new.id, old.status, new.status, auth.uid(),
    case when new.status = 'lost' then coalesce(new.lost_reason, v_reason) else v_reason end,
    v_source
  );
  return null;
end;
$$;
revoke execute on function public._trg_lead_status_history() from public, anon, authenticated;

-- ── log_lead_outcome: same body as before + source outcome ─────────────
create or replace function public.log_lead_outcome(
  p_lead_id uuid,
  p_outcome_id uuid,
  p_note text default null,
  p_channel text default 'call',
  p_next_due_at timestamptz default null,
  p_next_type public.lead_followup_type default null,
  p_next_note text default null,
  p_next_is_exact boolean default false,
  p_lost_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
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
$$;

-- ── old reopen_lead overload: same behaviour, now tagged source reopen ──
create or replace function public.reopen_lead(
  p_lead_id uuid,
  p_next_due_at timestamptz,
  p_type public.lead_followup_type default 'call',
  p_note text default null,
  p_is_exact boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_lead public.leads;
  v_id uuid;
begin
  v_lead := public._lead_lock(p_lead_id);
  perform set_config('app.lead_stage_source', 'reopen', true);
  perform set_config('app.lead_stage_reason', '', true);
  if v_lead.status not in ('won', 'lost') then
    raise exception 'only a won or lost lead can be reopened';
  end if;
  perform public._lead_check_due(p_next_due_at);

  -- Follow-up first: the reopen guard trigger requires one to exist.
  insert into public.lead_followups (org_id, lead_id, due_at, type, is_exact_time, note, source)
  values (v_lead.org_id, v_lead.id, p_next_due_at, coalesce(p_type, 'call'), coalesce(p_is_exact, false), nullif(btrim(coalesce(p_note, '')), ''), 'reopen')
  returning id into v_id;

  update public.leads set status = 'contacted', lost_reason = null, postpone_count = 0 where id = v_lead.id;

  return jsonb_build_object('followup_id', v_id, 'next_due_at', p_next_due_at, 'status', 'contacted');
end;
$$;

-- ── new reopen_lead overload: required reason, pre-closing stage ─────────
create or replace function public.reopen_lead(
  p_lead_id uuid,
  p_next_due_at timestamptz,
  p_reason text,
  p_type public.lead_followup_type default 'call',
  p_note text default null,
  p_is_exact boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_lead public.leads;
  v_id uuid;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_prev public.lead_status;
  v_stage public.lead_status;
begin
  v_lead := public._lead_lock(p_lead_id);
  if v_lead.status not in ('won', 'lost') then
    raise exception 'only a won or lost lead can be reopened';
  end if;
  if char_length(v_reason) < 3 then
    raise exception 'a reason (at least 3 characters) is required to reopen a lead';
  end if;
  perform public._lead_check_due(p_next_due_at);

  v_prev := public._lead_pre_close_stage(v_lead.id);
  v_stage := coalesce(v_prev, 'contacted');

  -- Follow-up first: the reopen guard trigger requires one to exist.
  insert into public.lead_followups (org_id, lead_id, due_at, type, is_exact_time, note, source)
  values (v_lead.org_id, v_lead.id, p_next_due_at, coalesce(p_type, 'call'), coalesce(p_is_exact, false), nullif(btrim(coalesce(p_note, '')), ''), 'reopen')
  returning id into v_id;

  perform set_config('app.lead_stage_source', 'reopen', true);
  perform set_config('app.lead_stage_reason', v_reason, true);
  update public.leads set status = v_stage, lost_reason = null, postpone_count = 0 where id = v_lead.id;

  return jsonb_build_object('followup_id', v_id, 'next_due_at', p_next_due_at, 'status', v_stage, 'stage_was_known', v_prev is not null);
end;
$$;

-- ── update_lead_status: closed leads change only through reopen_lead ─────
create or replace function public.update_lead_status(p_lead_id uuid, p_status public.lead_status, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_lead public.leads;
begin
  v_lead := public._lead_lock(p_lead_id);

  if p_status = 'lost' and trim(coalesce(p_reason, '')) = '' then
    raise exception 'update_lead_status: a reason is required to mark a lead lost';
  end if;
  if v_lead.status in ('won', 'lost') then
    raise exception 'update_lead_status: this lead is already %; use Reopen to change a closed lead', v_lead.status;
  end if;
  if v_lead.status = p_status then
    return;
  end if;

  perform set_config('app.lead_stage_source', 'stage_button', true);
  perform public._lead_apply_status(v_lead, p_status, nullif(btrim(coalesce(p_reason, '')), ''));
end;
$$;

-- ── grants (CREATE OR REPLACE keeps existing ones; the new overload needs its own) ──
revoke execute on function public.reopen_lead(uuid, timestamptz, text, public.lead_followup_type, text, boolean) from public, anon;
grant execute on function public.reopen_lead(uuid, timestamptz, text, public.lead_followup_type, text, boolean) to authenticated;
revoke execute on function public.reopen_lead(uuid, timestamptz, public.lead_followup_type, text, boolean) from public, anon;
grant execute on function public.reopen_lead(uuid, timestamptz, public.lead_followup_type, text, boolean) to authenticated;
revoke execute on function public.log_lead_outcome(uuid, uuid, text, text, timestamptz, public.lead_followup_type, text, boolean, text) from public, anon;
grant execute on function public.log_lead_outcome(uuid, uuid, text, text, timestamptz, public.lead_followup_type, text, boolean, text) to authenticated;
revoke execute on function public.update_lead_status(uuid, public.lead_status, text) from public, anon;
grant execute on function public.update_lead_status(uuid, public.lead_status, text) to authenticated;
