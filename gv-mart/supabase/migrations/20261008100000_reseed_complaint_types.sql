-- Re-seed the category-wide default complaint list. Some rows from
-- 20260803140000_seed_complaint_types.sql were later deleted, so this restores
-- them and widens coverage for all four categories (ro, ac, inverter, battery).
-- product_id stays null (shared by every product in the category). Idempotent:
-- NOT EXISTS skips any (org, category, label) already present, so rows an
-- admin added or kept are untouched.
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
    ('ro', 'Water too hot / too cold'),
    ('ro', 'Slow water flow'),
    ('ro', 'Pump not working'),
    ('ro', 'Membrane / filter needs replacement'),
    ('ro', 'Service due / general service'),
    ('ro', 'Display / error code shown'),
    ('ro', 'Tap or tank leakage'),
    ('ro', 'Installation / relocation request'),

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
    ('ac', 'Gas leakage / refilling needed'),
    ('ac', 'Compressor not starting'),
    ('ac', 'Cooling is slow'),
    ('ac', 'Fan not working'),
    ('ac', 'Swing / louver not working'),
    ('ac', 'Tripping the MCB'),
    ('ac', 'General service / deep cleaning'),
    ('ac', 'Installation / uninstallation request'),

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
    ('inverter', 'Fuse blown'),
    ('inverter', 'Overheating'),
    ('inverter', 'Mains / bypass not working'),
    ('inverter', 'Fan noise'),
    ('inverter', 'Wiring / connection issue'),
    ('inverter', 'Installation request'),

    ('battery', 'Not holding charge'),
    ('battery', 'Battery leaking'),
    ('battery', 'Battery swelling / bulging'),
    ('battery', 'Water level low'),
    ('battery', 'Terminal corrosion'),
    ('battery', 'Not charging'),
    ('battery', 'Unusual noise'),
    ('battery', 'Draining too quickly'),
    ('battery', 'Low backup time'),
    ('battery', 'Physical damage / crack'),
    ('battery', 'Overheating'),
    ('battery', 'Distilled water top-up needed'),
    ('battery', 'Loose terminal / connector'),
    ('battery', 'Battery replacement / exchange'),
    ('battery', 'Voltage low on testing')
) as v(category, label)
where not exists (
  select 1 from public.complaint_types ct
  where ct.org_id = o.id and ct.product_category = v.category and ct.label = v.label
);
