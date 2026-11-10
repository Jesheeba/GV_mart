# OPEN_DECISIONS.md — payroll-fixes2

Items the connection-map audit and this follow-up surfaced that need a client/
owner decision before any code changes — explicitly out of scope for this
task's 3 fixes (F-01/F-02/F-05), per instruction.

1. **Sales-income bonus scope** — `sales_income` incentive currently fires for
   whoever's `invoices.sold_by` happens to also have a `technicians` row,
   regardless of whether that person is primarily a technician or a sales/
   master account moonlighting as a seller. No rule exists either way. Needs
   an owner call: is a technician-flagged master/sales_admin allowed to earn
   this personally, or is that a conflict of interest to exclude?
2. **Rating consequences** — a rating below 4.5 stars currently has ZERO
   financial consequence anywhere in the code (confirmed by the connection-map
   audit). If a penalty or review-trigger is wanted, that's a new mechanism
   needing its own design, not a fix to an existing one.
3. **Huddle issues/solutions** — confirmed no incentive linkage exists at all.
   If raising/resolving huddle issues should ever affect pay, that's new
   scope.
4. **Spares usage/hand-over** — inventory tracking only; no incentive tied to
   quantity or timeliness. Same as above — new scope if wanted.
5. **F-03 (carried over from connection_map.md)** — `leads.owner_id` referral
   attribution remains a soft, optional, human-typed-or-picked link even
   after H-02's dedupe and this task's F-05 warning-on-miss fix. Nothing
   forces every qualifying sale to capture a referrer. Not a bug — a design
   question about how strict attribution should be.
6. **F-04 (carried over)** — the Employee-of-the-Month `rewards` table has no
   amount column at all. "Connected for identity, not connected for payout."
   Needs an owner decision on whether a cash/voucher amount should exist.
7. **Independent-reviewer non-blocking finding** — `renew_amc_plan`'s
   notification body contains mojibake (`â€”` instead of a real em dash),
   pre-existing and unrelated to this task's 3 fixes, left untouched by design
   (not in scope); flagging for a future cleanup pass.
8. **Independent-reviewer non-blocking finding** — recommend a one-off live
   check of `information_schema.routine_privileges` for `renew_amc_plan`
   post-deploy, given this project's documented history of default-privileges
   auto-granting EXECUTE to anon on new functions. The apply script for this
   migration already checks this explicitly (`has_function_privilege('anon',
   ...)`) and it came back false, but a periodic sweep across the whole
   schema (not just this one function) is a good standing habit, not a
   one-time fix.
