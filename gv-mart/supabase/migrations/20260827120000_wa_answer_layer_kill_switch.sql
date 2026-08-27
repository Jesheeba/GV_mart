-- Answer Layer kill switch — independent of whatsapp_bot_enabled (the
-- whole-bot switch), per the user's explicit rollout requirement: a way to
-- disable just the Answer Layer during early review without a redeploy and
-- without silencing the rest of the bot (journeys keep working). Defaults
-- FALSE — stays inert even after this migration ships, until someone
-- deliberately turns it on post-review, same reasoning as
-- 20260827100000_wa_answer_layer_log.sql shipping before any live wiring.
alter table public.settings
  add column wa_answer_layer_enabled boolean not null default false;
