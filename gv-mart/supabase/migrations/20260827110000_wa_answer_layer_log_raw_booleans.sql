-- Audit-log precision follow-up (same day, same build) — found while
-- verifying the fully_addresses_question fix: the model doesn't cleanly
-- keep can_answer and fully_addresses_question separate in practice (it
-- tends to report can_answer:false for a genuinely incomplete-but-partially-
-- grounded case, rather than using fully_addresses_question for that). The
-- derived `reason` string (can_answer_false vs. partial_coverage_only) is
-- therefore a best-effort label, not fully reliable. These two columns
-- store the RAW booleans exactly as the model set them in round 2, so
-- future review of this log isn't dependent on the model's own labeling
-- discipline. Nullable — null whenever round 2 was never reached at all
-- (cannot_answer in round 1, a tool execution error, or an API/timeout
-- failure before round 2 started).
alter table public.wa_answer_layer_log
  add column model_can_answer boolean,
  add column model_fully_addresses_question boolean;
