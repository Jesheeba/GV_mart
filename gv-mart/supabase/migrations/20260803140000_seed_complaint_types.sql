-- The complaint_types master (20260723132000_complaint_types_master.sql) has
-- existed since Build Order STEP 6.4 with full dynamic CRUD (Settings >
-- Masters > Complaint Types — ComplaintTypesTab.tsx for category-wide
-- defaults, ProductComplaintsPanel.tsx for per-product overrides), but the
-- table was never pre-populated — no migration or seed script ever inserted
-- a row into it. Both the admin "New Complaint" and customer "Book Service"
-- "Name of complaint" auto-suggest (NewComplaintPage.tsx,
-- BookServicePage.tsx) filter against this table and silently show an empty
-- dropdown until an admin types entries in by hand.
--
-- This seeds a comprehensive category-wide default list (product_id null —
-- shared by every product in that brand_category, same semantics as
-- 20260729140000_complaint_types_per_product.sql) for all four categories.
-- Nothing here is hardcoded into the app: these are ordinary rows in the
-- existing dynamic master-data table, fully editable/deletable per-org from
-- Settings > Masters > Complaint Types afterward, same as any admin-entered
-- row. NOT EXISTS guards make this idempotent against an admin having
-- already hand-added any of the same (category, label) pairs.
insert into public.complaint_types (org_id, product_category, label)
select o.id, v.category, v.label
from public.organizations o
cross join (
  values
    ('ro'::brand_category, 'No water output'),
    ('ro', 'Low water pressure'),
    ('ro', 'Water leakage'),
    ('ro', 'Water tastes bad / bad odor'),
    ('ro', 'Water looks cloudy or milky'),
    ('ro', 'Purifier not powering on'),
    ('ro', 'Making unusual noise'),
    ('ro', 'Tank not filling'),
    ('ro', 'Continuous dripping even when tank is full'),
    ('ro', 'Auto shut-off not working'),
    ('ro', 'Filter change indicator not working'),
    ('ro', 'TDS / purity not up to standard'),

    ('ac', 'Not cooling'),
    ('ac', 'Water leakage from indoor unit'),
    ('ac', 'AC not turning on'),
    ('ac', 'Unusual noise from unit'),
    ('ac', 'Bad smell / odor'),
    ('ac', 'Remote not working'),
    ('ac', 'AC turns off automatically'),
    ('ac', 'Ice formation on coil'),
    ('ac', 'Outdoor unit not running'),
    ('ac', 'Weak airflow'),
    ('ac', 'High power consumption'),
    ('ac', 'Display / error code shown'),

    ('inverter', 'Not charging'),
    ('inverter', 'No power backup during outage'),
    ('inverter', 'Low backup time'),
    ('inverter', 'Inverter not turning on'),
    ('inverter', 'Continuous beeping / alarm sound'),
    ('inverter', 'Overload trip'),
    ('inverter', 'Display not working'),
    ('inverter', 'Burning smell'),
    ('inverter', 'Not switching to backup automatically'),
    ('inverter', 'Low output voltage'),

    ('battery', 'Not holding charge'),
    ('battery', 'Battery leaking'),
    ('battery', 'Battery swelling / bulging'),
    ('battery', 'Water level low'),
    ('battery', 'Terminal corrosion'),
    ('battery', 'Not charging'),
    ('battery', 'Unusual noise'),
    ('battery', 'Draining too quickly'),
    ('battery', 'Low backup time'),
    ('battery', 'Physical damage / crack')
) as v(category, label)
where not exists (
  select 1 from public.complaint_types ct
  where ct.org_id = o.id and ct.product_category = v.category and ct.label = v.label
);
