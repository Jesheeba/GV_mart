-- Idempotence proof for migrations/20261015145000_reseed_complaint_types.sql, all rolled back (one transaction).
-- Runner order: _1_setup, the migration, _2_first, the migration again, _3_second (ends in RAISE).
-- A throwaway organisation: the migration must add the full default list once and nothing the second time.
create temp table rs_ctx(org uuid, n_real_before int, n_org_before int);
with o as (insert into organizations(name) values ('__TEST_reseed_idem') returning id)
insert into rs_ctx select o.id, (select count(*) from complaint_types ct join organizations r on r.id = ct.org_id where r.name not like '\_\_TEST\_%' escape '\'), 0 from o;
update rs_ctx set n_org_before = (select count(*) from complaint_types where org_id = rs_ctx.org);
create temp table rs_run(step text, n_org int, n_real int);
