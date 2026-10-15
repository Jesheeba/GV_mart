# Enquiry-video resolver (queue item 3): what is built, what waits for Stage B

Status: BUILT on `feat/enquiry-video-resolver`, NOT applied. Migration `20261028100000_enquiry_video_resolver`.
Cut from `origin/main`. Spec: `docs/automations-flows-design.md` sections 2.3, 7 and 9.

## Built here (stands on origin/main, read-only)
Two functions, no table, no column, no trigger, no new state:

- `_automation_enquiry_video(org, product_id, spare_id, language, max_url_length)` returns one video link plus the cleaned item name.
- `_automation_lead_enquiry_video(org, lead_id, item_key, language, max_url_length)` starts from a lead; an `item_key`
  (the `enquiry.item_added` event's added item, item 1) overrides the lead's own first item.

Owner decisions applied: first item only (3); no video means a skip, never a topic-video fallback, so `video_library` is not read (2);
language order = the customer's language, then a language-neutral (NULL) row, then English, never skipped for a missing Tamil
video (9, 11); an English customer is never sent a Tamil-only video. Within a language: lowest `sort_order`, then oldest.
The link must be https, trimmed, free of whitespace and at most 60 characters (parameter; the spec says "about 60"). A link that fails
is not used; if that leaves nothing the reason is `url_unusable`, distinct from `no_video`, so the master can tell them apart.
Everything is org-scoped. EXECUTE: service_role only.

## NOT built here, and why
The hand-off (`automation_handoff_due`, `automation_handoff_ref_types`, the queue/audit state CHECK lists) exists only on
`feat/automation-phase3b` (unapplied). Any migration touching those would have to redefine objects Stage B also redefines, so it
cannot be written against origin/main without clobbering or being clobbered. Part 2 is therefore authored AFTER Stage B is renumbered
and rebased on items 1 and 2:

1. `lead` row in `automation_handoff_ref_types`; a lead branch in the dispatcher's `resolveEventContext`.
2. New queue state and audit decision `skipped_no_video`, added to every counted-state list (use one helper, section 8.4) so a
   missing video neither blocks the item for 30 days nor burns a daily-cap slot.
3. In the hand-off: call `_automation_lead_enquiry_video(org, subject lead, queue.item_key, queue.language)`; `ok = false` ends the
   row as `skipped_no_video` (detail carries the reason) and writes the master in-app note ("no video for X"; "no Tamil video,
   English sent" when `language_fallback`); `ok = true` puts `video_url` and `item_name` in the context copied to the outbox payload.
4. `wa-automation-vars.ts`: variables `video_url` and `item_name` (the template calls them `video_link` and `item_name`).
5. The in-app note to the sales person (decision 10).

## Estimate
Resolver (this branch): built, 0.5 day including tests and wrapper. Part 2: 1.5 to 2 days after Stage B is rebased.

## Open question
Link length: 60 characters is the spec's "about 60". A YouTube watch link with extra parameters can exceed it; say if 100 is preferred
(one argument default, no schema change).
