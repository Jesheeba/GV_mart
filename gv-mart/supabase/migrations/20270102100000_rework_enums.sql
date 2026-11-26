-- Rework (build-docs/features/rework.md), step 0 of 2.
-- Postgres cannot USE a new enum value in the transaction that adds it, so these two values are
-- their own migration and must be COMMITTED before 20270102100100_rework_core.sql is rehearsed or applied.
-- Additive only. Enum values cannot be dropped, so there is no rollback file; unused values are harmless.
alter type public.ticket_type add value if not exists 'rework';
alter type public.approval_type add value if not exists 'rework';
