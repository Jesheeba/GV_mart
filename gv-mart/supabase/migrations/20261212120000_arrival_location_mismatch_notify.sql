-- Arrival Location Mismatch Alerts (build-docs/features/arrival-location-mismatch-alerts.md).
--
-- technician_arrival_blocks (20260915170000) already records every time a technician is stuck
-- >5 min outside the arrival geofence for a job (MapPage.tsx's arrival state machine) -- but
-- nothing has ever read that table. A wrong/stale customer pin never surfaces to anyone and
-- stays wrong indefinitely. This migration adds exactly one thing: a trigger on
-- public.technician_arrival_blocks that, on every insert, creates ONE "address needs a recheck"
-- task (assigned to one active operation_admin) and ONE in-app notification (broadcast to all
-- active operation_admins) -- same role-targeted-notification convention as every other
-- `insert into public.notifications (org_id, role, ...)` call in this project, and the exact
-- same guardrail shape as 20261204140000_customer_needs_review_notify.sql's trigger (fail-safe,
-- deduplicated, flood-capped).
--
-- GUARDRAILS, all satisfied by this migration:
--   (1) FAIL-SAFE: every write below is wrapped in its own BEGIN/EXCEPTION block. Any error is
--       caught, logged via RAISE WARNING, and the function falls through to `return new`
--       regardless -- the technician_arrival_blocks insert this trigger is attached to (itself
--       a best-effort visibility log, see technician.ts's queueArrivalBlock comment) always
--       succeeds even if this trigger's own bookkeeping fails outright.
--   (2) Deduplicated: one open task per CUSTOMER (ref_type = 'arrival_location_mismatch',
--       ref_id = customer_id), not one per block row -- a technician stuck at the same wrong
--       address on several visits in a row must not spam several open tasks. Assigned to ONE
--       operation_admin (oldest active one in the org, falling back to the oldest active
--       master if none -- same fallback shape as _sync_outstanding_tasks_for_org's v_owner
--       resolution, 20261204100000). The notification goes to all active operation_admins
--       (role-broadcast), matching submit_rating's low-rating notification target
--       (20260702120000) -- this is a service-ops concern, not accounts/sales.
--   (2b) FLOOD CAP: if 20 or more 'arrival_location_mismatch' tasks have already been created
--       for this org in the last minute, this trigger stops creating individual per-customer
--       tasks/notifications and instead ensures exactly ONE open "Multiple addresses need a
--       recheck" summary task (+ one matching notification) exists, deduplicated the same way.
--   (3) Nothing is ever sent to the customer: this trigger touches only public.tasks and
--       public.notifications -- no WhatsApp/SMS/email, no row in wa_outbox.
--   (4) No trigger that touches money tables or writes beyond the notification and task rows.
create or replace function public._notify_arrival_block()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_customer_id uuid;
  v_customer_name text;
  v_address_text text;
  v_assignee uuid;
  v_already_open boolean;
  v_recent_count int;
  v_flood_already_open boolean;
begin
  -- GUARDRAIL (1), FAIL-SAFE: everything below this point writes data and is wrapped so that no
  -- failure here can ever block or roll back the technician_arrival_blocks insert itself.
  begin
    select t.customer_id, c.name, coalesce(a.full_address, a.area)
      into v_customer_id, v_customer_name, v_address_text
    from public.service_tickets t
    join public.customers c on c.id = t.customer_id
    left join public.addresses a on a.id = t.address_id
    where t.id = new.ticket_id;

    if v_customer_id is null then
      return new; -- ticket/customer vanished or never resolved; nothing sensible to flag
    end if;

    -- GUARDRAIL (2b), FLOOD CAP.
    select count(*) into v_recent_count
    from public.tasks
    where org_id = new.org_id and ref_type = 'arrival_location_mismatch' and created_at > now() - interval '1 minute';

    if v_recent_count >= 20 then
      select exists(
        select 1 from public.tasks
        where org_id = new.org_id and ref_type = 'arrival_location_mismatch_flood' and status = 'open'
          and created_at > now() - interval '1 hour'
      ) into v_flood_already_open;

      if not v_flood_already_open then
        select id into v_assignee
        from public.profiles
        where org_id = new.org_id and role = 'operation_admin' and is_active
        order by created_at asc
        limit 1;
        if v_assignee is null then
          select id into v_assignee
          from public.profiles
          where org_id = new.org_id and role = 'master' and is_active
          order by created_at asc
          limit 1;
        end if;

        if v_assignee is not null then
          insert into public.tasks (org_id, assignee_id, title, source, ref_type)
          values (
            new.org_id, v_assignee,
            'Multiple addresses need a recheck -- technicians keep arriving outside the pinned location',
            'system', 'arrival_location_mismatch_flood'
          );
        end if;

        insert into public.notifications (org_id, role, type, title, body)
        values (
          new.org_id, 'operation_admin', 'arrival_location_mismatch_flood', 'Multiple addresses need a recheck',
          'Several technicians arrived outside the pinned location in a short time. Check Tasks for details.'
        );
      end if;

      return new;
    end if;

    -- Normal, per-customer path.
    select exists(
      select 1 from public.tasks
      where ref_type = 'arrival_location_mismatch' and ref_id = v_customer_id and status = 'open'
    ) into v_already_open;
    if v_already_open then
      return new;
    end if;

    select id into v_assignee
    from public.profiles
    where org_id = new.org_id and role = 'operation_admin' and is_active
    order by created_at asc
    limit 1;
    if v_assignee is null then
      select id into v_assignee
      from public.profiles
      where org_id = new.org_id and role = 'master' and is_active
      order by created_at asc
      limit 1;
    end if;

    if v_assignee is not null then
      insert into public.tasks (org_id, assignee_id, title, source, ref_type, ref_id)
      values (
        new.org_id, v_assignee,
        format('Check %s''s address -- technician arrived %s m from the pinned location', coalesce(v_customer_name, 'customer'), round(new.distance_m)),
        'system', 'arrival_location_mismatch', v_customer_id
      );
    end if;

    insert into public.notifications (org_id, role, type, title, body, ref_id)
    values (
      new.org_id, 'operation_admin', 'arrival_location_mismatch', 'Address may need a recheck',
      format(
        '%s was %s m from the pinned address (allowed %s m)%s. The pin may be wrong or stale.',
        coalesce(v_customer_name, 'A customer'), round(new.distance_m), new.radius_m,
        case when v_address_text is not null then format(' -- "%s"', v_address_text) else '' end
      ),
      v_customer_id
    );
  exception when others then
    raise warning 'arrival_location_mismatch trigger: failed for block % (ticket %, org %): % (sqlstate %)', new.id, new.ticket_id, new.org_id, sqlerrm, sqlstate;
  end;

  return new;
end;
$function$;

create trigger technician_arrival_blocks_notify
after insert on public.technician_arrival_blocks
for each row
execute function public._notify_arrival_block();

revoke all on function public._notify_arrival_block() from public, anon, authenticated;
