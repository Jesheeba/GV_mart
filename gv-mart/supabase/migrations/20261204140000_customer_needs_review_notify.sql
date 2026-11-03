-- Item 5(c) (urgent task list, owner guardrails 2026-11-03): when customer_auto_onboard()
-- or the phone-OTP merge-on-verify RPC flags a newly-created customers row needs_review = true
-- (a sign-in matched more than one existing record, or one already linked elsewhere, and the
-- system deliberately did not guess), staff need to find out and act on it. Today nothing does
-- that -- needs_review is only visible via a badge if a master happens to browse the admin
-- Customers list (CustomersListPage.tsx) and filters for it.
--
-- This migration adds exactly one thing: a trigger on public.customers that, the moment a row's
-- needs_review transitions from false/absent to true, creates ONE "Customer needs account
-- review" task (assigned to one active master) and ONE in-app notification (broadcast to all
-- active masters, same role-targeted-notification convention as every other
-- `insert into public.notifications (org_id, role, ...)` call in this project -- see e.g.
-- 20260702100100_sales_phase5_functions.sql:230-234).
--
-- GUARDRAILS (owner, 2026-11-03), all satisfied by this migration:
--   (1) FAIL-SAFE: the only two statements that can genuinely fail (the dedup/flood reads are
--       read-only; the two inserts are the real risk -- no active master, a tasks/notifications
--       constraint violation, anything else) are wrapped in their own BEGIN/EXCEPTION block.
--       ANY error inside it is caught, logged via RAISE WARNING (visible in the Postgres logs,
--       never propagated), and the function falls through to `return new` regardless -- the
--       customer INSERT/UPDATE this trigger is attached to always succeeds, even if this
--       trigger's own bookkeeping fails outright. This is checked by rehearsal with a forced
--       tasks-insert failure and with zero active masters in the org, not just asserted.
--   (2) Deduplicated: the dedup check mirrors the established convention
--       (20261204100000_sync_outstanding_tasks.sql:87-90 -- `where ref_type = X and ref_id = Y
--       and status = 'open'`) -- an open task already exists for this customer -> skip, so a
--       repeat sign-in (which re-runs customer_auto_onboard's idempotent short-circuit and
--       never re-flags an already-flagged row anyway, but belt-and-suspenders) never creates a
--       second task. One task per customer, not one per event.
--       Assigned to ONE master (oldest active master in the org, same
--       "no explicit assignee -> fall back to the oldest active master" shape as
--       20261204100000_sync_outstanding_tasks.sql:40-46's v_owner resolution) -- not all of
--       them, so there's a single clear owner. The notification goes to all active masters
--       (role-broadcast), so no master is left unaware even though only one is assigned the work.
--   (2b) FLOOD CAP: today only two call sites can ever set needs_review=true
--       (customer_auto_onboard_rpc.sql, customer_link_otp_merge_on_verify.sql), and both act on
--       exactly one customers row per call (one sign-in event), so there is no existing path
--       that could flag many rows in a single statement. As defense-in-depth against a future
--       bulk tool or a mistake, this trigger caps itself: if 20 or more
--       'customer_needs_review' tasks have already been created for this org in the last
--       minute, it stops creating individual per-customer tasks/notifications and instead
--       ensures exactly ONE open "Multiple customers need account review" summary task (+ one
--       matching notification) exists, deduplicated the same way, rather than flooding the
--       masters with hundreds of identical-shaped items.
--   (3) Nothing is ever sent to the customer: this trigger touches only public.tasks and
--       public.notifications -- no WhatsApp/SMS/email, no row in wa_outbox or any
--       customer-facing table. wa_test_mode_enabled is untouched.
--   (4) No trigger that touches money tables or writes beyond the notification and task rows:
--       this function's only writes, in either the per-customer or the flood-summary path, are
--       the same two inserts (tasks, notifications) -- nothing else is read-write (the master
--       lookup, the dedup check and the flood-rate check are all read-only selects).
--
-- Trigger fires on the SAME WHEN condition this project already uses to detect a boolean flag's
-- false->true transition on customers (`customers_is_test_cascade`, 20261016110000:
-- `after insert or update of is_test, mobile`) -- here, `after insert or update of needs_review`,
-- scoped further by a `when (new.needs_review)` clause so the trigger function is never even
-- invoked on the (overwhelmingly common) non-flagged path.
create or replace function public._notify_customer_needs_review()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_assignee uuid;
  v_already_open boolean;
  v_recent_count int;
  v_flood_already_open boolean;
begin
  -- Only a real transition into needs_review=true -- an UPDATE that re-saves an already-true
  -- row (e.g. a later, unrelated column edit) must not re-fire. Pure boolean logic, nothing
  -- that can fail -- kept outside the exception-guarded block below on purpose.
  if tg_op = 'UPDATE' and old.needs_review then
    return new;
  end if;

  -- GUARDRAIL (1), FAIL-SAFE: everything below this point writes data and is wrapped so that
  -- no failure here can ever block or roll back the customer INSERT/UPDATE this trigger is
  -- attached to.
  begin
    -- GUARDRAIL (2b), FLOOD CAP: more than 20 'customer_needs_review' tasks already created
    -- for this org in the last minute -- switch to a single summary task/notification instead
    -- of one more per-customer pair.
    select count(*) into v_recent_count
    from public.tasks
    where org_id = new.org_id and ref_type = 'customer_needs_review' and created_at > now() - interval '1 minute';

    if v_recent_count >= 20 then
      select exists(
        select 1 from public.tasks
        where org_id = new.org_id and ref_type = 'customer_needs_review_flood' and status = 'open'
          and created_at > now() - interval '1 hour'
      ) into v_flood_already_open;

      if not v_flood_already_open then
        select id into v_assignee
        from public.profiles
        where org_id = new.org_id and role = 'master' and is_active
        order by created_at asc
        limit 1;

        if v_assignee is not null then
          insert into public.tasks (org_id, assignee_id, title, source, ref_type)
          values (
            new.org_id, v_assignee,
            'Multiple customers need account review -- check Customers list filtered by Needs Review',
            'system', 'customer_needs_review_flood'
          );
        end if;

        insert into public.notifications (org_id, role, type, title, body)
        values (
          new.org_id, 'master', 'customer_needs_review_flood', 'Multiple customers need account review',
          'Several new sign-ins matched existing records in a short time. Check the Customers list filtered by Needs Review.'
        );
      end if;

      return new;
    end if;

    -- Normal, per-customer path.
    select exists(
      select 1 from public.tasks
      where ref_type = 'customer_needs_review' and ref_id = new.id and status = 'open'
    ) into v_already_open;
    if v_already_open then
      return new;
    end if;

    select id into v_assignee
    from public.profiles
    where org_id = new.org_id and role = 'master' and is_active
    order by created_at asc
    limit 1;

    if v_assignee is not null then
      insert into public.tasks (org_id, assignee_id, title, source, ref_type, ref_id)
      values (new.org_id, v_assignee, 'Customer needs account review', 'system', 'customer_needs_review', new.id);
    end if;

    insert into public.notifications (org_id, role, type, title, body, ref_id)
    values (
      new.org_id, 'master', 'customer_needs_review', 'Customer needs account review',
      'A new sign-in matched existing records and needs a master to review.', new.id
    );
  exception when others then
    raise warning 'customer_needs_review trigger: failed to create task/notification for customer % (org %): % (sqlstate %)', new.id, new.org_id, sqlerrm, sqlstate;
  end;

  return new;
end;
$function$;

create trigger customers_needs_review_notify
after insert or update of needs_review on public.customers
for each row
when (new.needs_review)
execute function public._notify_customer_needs_review();

revoke all on function public._notify_customer_needs_review() from public, anon, authenticated;
