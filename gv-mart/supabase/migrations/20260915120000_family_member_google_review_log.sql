-- Item D4: no real Google review API integration is feasible here (reviewer
-- identity Google exposes — a bare display name, blank entirely if
-- anonymous — can't be reliably matched back to a specific customer/family
-- member; see session notes). Manual staff logging instead: which family
-- member left a review, and what star rating they gave.
alter table public.customer_members add column if not exists google_review_stars smallint;
alter table public.customer_members add column if not exists google_review_logged_at timestamptz;
alter table public.customer_members add constraint customer_members_google_review_stars_range
  check (google_review_stars is null or (google_review_stars between 1 and 5));
