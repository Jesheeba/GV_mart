-- Drop the 6-argument generate_enquiry_lead overload.
--
-- The 7-argument form (... , p_visit_id uuid DEFAULT NULL) has the identical body plus the optional visit
-- check, so it already serves every caller; a 6-argument call resolves to it. Keeping both made any
-- 6-argument call ambiguous ("function generate_enquiry_lead(...) is not unique").
-- Callers (checked live 2026-10-07: no function, view, materialised view, policy, trigger or cron job
-- references the function; pg_depend shows none): only src/lib/offline/sync.ts, which always sends p_visit_id.

drop function if exists public.generate_enquiry_lead(uuid, uuid, text, text, public.enquiry_type, text);
