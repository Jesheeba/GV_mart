-- Rental Plans: dynamic yearly-to-monthly calculation.
-- monthly_rate becomes a generated column derived from yearly_rate, so it is
-- always in sync at the DB level regardless of write path. duration_years is
-- metadata only (display/future contract-term use) and does not affect the
-- monthly calculation.

alter table public.rental_plans
  add column duration_years integer not null default 1,
  add column yearly_rate numeric;

update public.rental_plans
set yearly_rate = round(monthly_rate * 12, 2)
where yearly_rate is null;

alter table public.rental_plans
  alter column yearly_rate set not null,
  add constraint rental_plans_yearly_rate_check check (yearly_rate >= 0),
  add constraint rental_plans_duration_years_check check (duration_years >= 1);

alter table public.rental_plans drop column monthly_rate;

alter table public.rental_plans
  add column monthly_rate numeric generated always as (round(yearly_rate / 12, 2)) stored;
