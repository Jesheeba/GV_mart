-- Phase 7 (TECH-07): the on-site stepper's technician + customer signature
-- capture had nowhere to persist server-side — service_visits never gained
-- signature columns (unlike spare_handovers.tech_sign_url/admin_sign_url,
-- which already existed). The build agent correctly avoided inventing a
-- migration itself (out of its authorized scope) and cached signatures in
-- the local Dexie store instead so nothing is lost — this closes that gap
-- so they actually sync to the server, matching the DoD's "signatures ...
-- complete on-device" (which implies they end up recorded, not just local).
alter table service_visits
  add column tech_sign_url text,
  add column customer_sign_url text;
