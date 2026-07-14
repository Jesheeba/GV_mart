-- v2.2 §6.5/§6.7: 4.5-5 star ratings show a "leave a Google review" button
-- (TECH-08 RatingPage / customer app). No Google Business review URL has
-- ever existed anywhere in settings or env — RatingPage.tsx has hardcoded
-- `reviewUrl = null` since it was built, always rendering the button
-- disabled with an explanatory note. This adds the real, admin-editable
-- placeholder so an org can set its own listing's review link (per-org,
-- since each business has a different Google Business Profile — no sane
-- schema-level default exists).
alter table settings add column google_review_url text;
