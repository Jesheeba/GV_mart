-- Independent before/after snapshot (run as two separate Management-API queries, OUTSIDE the
-- rehearsal's own transaction) of every table the customer-link-otp migration's functions can
-- write to, plus the new tables themselves (expected to not exist before the migration, and to
-- exist-but-be-empty-of-real-rows after, since the rehearsal's own transaction never commits).
select
  (select count(*) from public.customers) as customers_count,
  (select count(*) from public.profiles) as profiles_count,
  (select count(*) from public.whatsapp_outbox) as whatsapp_outbox_count,
  (select count(*) from public.audit_log) as audit_log_count,
  (select md5(coalesce(string_agg(x, ',' order by x), '')) from (
    select c.id::text || ':' || c.mobile || ':' || coalesce(c.primary_profile_id::text, '-') || ':' || c.phone_verified::text as x
    from public.customers c where c.name not like '\_\_TEST\_%' escape '\'
  ) r) as customers_real_md5,
  (select md5(coalesce(string_agg(p.id::text, ',' order by p.id), '')) from public.profiles p
    where p.full_name not like '\_\_TEST\_%' escape '\') as profiles_real_md5,
  (select to_regclass('public.customer_link_otp_challenges') is not null) as challenges_table_exists,
  (select to_regclass('public.customer_link_otp_send_log') is not null) as send_log_table_exists,
  (select to_regclass('public.customer_link_otp_settings') is not null) as settings_table_exists;
