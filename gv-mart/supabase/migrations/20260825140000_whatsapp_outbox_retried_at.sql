-- wa-milestone-dispatch's marker column. The three milestone triggers
-- (_milestone_ticket_notify, _milestone_visit_notify, _milestone_invoice_
-- notify) insert directly into whatsapp_outbox, bypassing sendMessage()
-- entirely — this is how the poller marks a stuck trigger-written row as
-- "already pushed through sendMessage() once" so it isn't picked up again
-- on the next 5-minute run. Explicit column over overloading wa_message_id
-- with a sentinel string, consistent with how this codebase already
-- prefers a named, queryable flag over an overloaded value (e.g.
-- RouteResult.suppressReply).
alter table public.whatsapp_outbox
  add column if not exists retried_at timestamptz;
