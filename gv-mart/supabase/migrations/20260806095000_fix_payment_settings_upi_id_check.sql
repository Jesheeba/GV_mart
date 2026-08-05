-- Fix: 20260806091000_payment_settings.sql's upi_id CHECK used {2,256} for
-- the VPA local-part length — Postgres's bundled regex engine caps interval
-- repetition counts at 255 (RE_DUP_MAX), so any save hit "invalid regular
-- expression: invalid repetition count(s)" server-side. Lowered to {2,64},
-- which is more than enough for a real UPI handle and mirrors the existing
-- bound already used for the bank/domain part.
alter table public.payment_settings drop constraint if exists payment_settings_upi_id_check;
alter table public.payment_settings add constraint payment_settings_upi_id_check
  check (upi_id = '' or upi_id ~ '^[\w.-]{2,64}@[a-zA-Z]{2,64}$');
