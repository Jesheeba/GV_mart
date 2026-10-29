# Nightly backup — plan only, nothing provisioned

Not built. Report for confirmation before anything is created on
production or anywhere else.

## 1. Repository visibility — STOP, runner changed

`Jesheeba/GV_mart` on GitHub is **public**. Per standing instruction, a
`BYPASSRLS` credential that reads every row in this database does not go
into a public repository's secrets, full stop — GitHub Actions is
**not** the runner for this job. `nightly-backup.yml.proposed` is kept
only as a record of the dump/upload logic; it does not get installed as
a workflow and no secret gets added to this repo. The scheduler still
needs to be decided (a cron job on an always-on machine, a self-hosted
runner, a small always-on VM, or a *separate private* repo dedicated to
this one job) — that choice is still open.

## 2. backup_reader role — read plainly before using this credential

**What this credential can do: read every row in every table in the
`public` schema, including every customer record, bypassing Row Level
Security entirely — that is what `BYPASSRLS` means. What it cannot do:
write, update, or delete anything; it has no grants beyond `SELECT`.**
Whoever finds this role in a year should read it as "a credential that
can see all customer data," not as some narrow, harmless backup detail.
It must never be treated as a low-sensitivity credential just because
its only *action* is reading for a backup.

See `supabase/ops/backup_reader_role.sql`. Summary of what was actually
verified (against a disposable container, not production):

- Plain `SELECT` grants are not sufficient — this app's RLS is on nearly
  every table, and `pg_dump` fails outright on the first RLS-enabled
  table without `BYPASSRLS`.
- `BYPASSRLS` + `SELECT` on all `public` tables/sequences is sufficient.
  No table in this schema requires more than that for a successful dump.
- Granting `BYPASSRLS` does not require escalating past what the
  project's own `postgres` role can already do.
- Scope is `public` only. `auth`/`storage` are owned by different
  Supabase-internal roles; out of scope since all of GV Mart's own data
  lives in `public`.

Not run against production. Create this role there only after you
confirm — and wherever its connection string ends up, treat it with the
same care as the main DB credential, not as a lesser one.

## 3. The nightly workflow — Backblaze B2

**Runner:** not GitHub Actions (§1). Still open which always-on
scheduler runs this; the dump/upload/retention logic below is the same
regardless of where it runs.

**Dump command:**
```
pg_dump "$BACKUP_READER_DB_URL" -n public --format=custom --compress=9 \
  -f gv_mart_daily.dump
```
Custom format (`-Fc`) is chosen over plain SQL so `pg_restore` can do
selective/parallel restores later; compression is built into the format,
no separate gzip step needed. At today's live size (187 MB, `audit_log`
alone 138 MB of that) the compressed dump should land well under 100 MB.

**Object storage: Backblaze B2.** Cheapest per-GB at this scale, and its
native versioning + lifecycle rules do the retention work below without
the backup job ever holding delete rights.

**Bucket setup (done once, by you, not by the nightly job):**
- One private bucket, e.g. `gv-mart-backups`.
- **File Lock (B2's Object Lock) enabled** on the bucket, governance
  mode, with a retention period covering the longest copy kept (≥28
  days). This is defense-in-depth on top of the write-only key below: a
  key with no delete capability already can't remove a version, but
  File Lock additionally protects against the bucket's own retention
  settings being loosened or an account-level credential being
  compromised — "existing backups cannot be destroyed by a compromised
  key" is covered twice over, not once.
- **Application key: write-only, scoped to this one bucket.**
  Capability `writeFiles` only — explicitly no `listFiles`, no
  `readFiles`, no `deleteFiles`, no `listBuckets`. A key with this
  capability set can upload new file versions and nothing else; it
  cannot read backups back out, list what's there, or delete anything.
  This is the credential the nightly job actually holds.
- **Fixed filenames, not date-stamped**, so B2's native versioning does
  the retention bookkeeping: `daily/gv_mart.dump` is overwritten every
  night, `weekly/gv_mart.dump` is overwritten only on Sundays. Each
  overwrite doesn't destroy the previous copy — B2 keeps it as a hidden
  prior version until the lifecycle rule below expires it.

**Dump + upload (the nightly job itself, needs only the write-only
key):**
```
pg_dump "$BACKUP_READER_DB_URL" -n public --format=custom --compress=9 -f gv_mart_daily.dump
b2 file upload gv-mart-backups gv_mart_daily.dump daily/gv_mart.dump
if [ "$(date +%u)" = "7" ]; then
  b2 file upload gv-mart-backups gv_mart_daily.dump weekly/gv_mart.dump
fi
```
No prune/delete step exists in the job at all — intentionally, since the
key it runs with cannot delete. Retention is entirely the bucket's own
job, below.

**Retention — 7 daily + 4 weekly, as a B2 lifecycle rule, not a workflow
step:**
```
# Set once on the bucket (by an admin key, not the nightly job's key):
#   prefix "daily/"  — daysFromHidingToDeleting: 7
#   prefix "weekly/" — daysFromHidingToDeleting: 28
# daysFromUploadingToHiding left unset on both: a version only becomes
# "hidden" when the next overwrite supersedes it (normal nightly/weekly
# upload), never just from the passage of time with no new upload. Once
# hidden, B2 deletes it automatically after the day count above —
# roughly 7 trailing daily copies and 4 trailing weekly copies, entirely
# inside B2, outside the reach of the write-only key.
```

**Credentials this job needs, wherever the chosen scheduler stores
secrets:**
- `BACKUP_READER_DB_URL` — the `backup_reader` connection string (not
  `SUPABASE_DB_URL`/the full-privilege one currently in `.env`; this is a
  new, narrower credential created specifically for this job per §2, and
  — per §2 above — still a highly sensitive one, not a harmless one).
- The B2 write-only application key (`writeFiles` only, one bucket, per
  above).
- `SUPABASE_ACCESS_TOKEN` is not involved anywhere in this path — it
  cannot run `pg_dump`.

## 4. Restore verification

Script below. Designed to run once now and then monthly — a backup
nobody has restored is not a backup, per your framing. See
`supabase/ops/verify_restore.sh`.

What it checks, and why each check exists:
- **Schema replay, not dump-restore, builds the target schema.** Tested
  both ways: restoring the dump's own DDL into a bare instance throws on
  RLS policies that reference `auth.uid()` (no `auth` schema exists
  outside a real Supabase project) and on view-ordering. Replaying the
  real migration history first — the same recipe already in use for this
  branch's own testing — produces a correct target, then the dump is
  loaded `--data-only` on top of it. This is the one piece of the
  pipeline that's more involved than "just restore it," and it's the
  reason the verification has to be a maintained script, not a one-liner.
- **Row counts** on the tables that matter most (`customers`, `invoices`,
  `service_tickets`, `salaries`, `audit_log`) compared between source and
  restored instance.
- **Function/trigger existence** for the handful of RPCs the app can't
  run without (`compute_salary`, `compute_incentives`, `audit_master_change`
  actually attached where expected).
- **`supabase_migrations.schema_migrations` version match** against the
  live project, confirming the dump captured the current schema rather
  than a stale one.
- Runs in a disposable container on a disposable volume; discarded after.
  Never touches production.
