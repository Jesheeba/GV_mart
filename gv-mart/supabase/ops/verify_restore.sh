#!/bin/bash
# Restore-verification drill. Run on demand now, and monthly after —
# a backup nobody has restored is not a backup.
#
# What it does: spins up a disposable Postgres 17 container, replays the
# real migration history onto it (same recipe used for this branch's own
# migration testing), loads the most recent nightly dump --data-only on
# top of that correct schema, then checks row counts / critical
# functions-and-triggers / migration-version parity against the source.
# Tears the container down at the end either way. Never touches
# production — everything here is local to the disposable container.
#
# Requires: DUMP_PATH (path to the dump to verify) and SOURCE_DB_URL (a
# read-only connection to production, to pull comparison counts/version —
# backup_reader's connection string is sufficient and is all this should
# ever use).
set -euo pipefail

DUMP_PATH="${1:?usage: verify_restore.sh <path-to-dump>}"
SOURCE_DB_URL="${SOURCE_DB_URL:?set SOURCE_DB_URL to a read-only (backup_reader) connection string}"
MIGRATIONS_DIR="$(cd "$(dirname "$0")/../migrations" && pwd)"
CONTAINER=verify_restore_$$
IMAGE=public.ecr.aws/supabase/postgres:17.6.1.127

cleanup() { docker rm -f "$CONTAINER" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "== starting disposable container =="
docker run -d --name "$CONTAINER" -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=postgres "$IMAGE" >/dev/null
for i in $(seq 1 30); do
  docker exec "$CONTAINER" pg_isready -U postgres >/dev/null 2>&1 && break
  sleep 1
done
docker exec "$CONTAINER" psql -U postgres -c "create extension if not exists btree_gist;" >/dev/null

echo "== replaying real migration history (schema only) =="
# Minimal harness prereqs a bare image lacks that a real Supabase project
# already has: storage.buckets/objects + storage.foldername(), and
# auth.uid()/auth.role() reading the GUC form this project's own tests use.
docker exec -i "$CONTAINER" psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 <<'SQL'
create table if not exists storage.buckets (
  id text primary key, name text not null, owner uuid, public boolean default false,
  file_size_limit bigint, allowed_mime_types text[],
  created_at timestamptz default now(), updated_at timestamptz default now()
);
create table if not exists storage.objects (
  id uuid primary key default gen_random_uuid(), bucket_id text references storage.buckets(id),
  name text, owner uuid, metadata jsonb,
  path_tokens text[] generated always as (string_to_array(name, '/')) stored,
  created_at timestamptz default now(), updated_at timestamptz default now()
);
grant select, insert, update, delete on storage.buckets, storage.objects to authenticated, anon, service_role;
alter table storage.objects enable row level security;
alter table storage.buckets enable row level security;
create or replace function storage.foldername(name text) returns text[]
language sql immutable as $f$ select string_to_array(name, '/'); $f$;

create or replace function auth.uid() returns uuid language sql stable as $f$
  select coalesce(
    nullif(current_setting('request.jwt.claim.sub', true), '')::uuid,
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')::uuid
  );
$f$;
create or replace function auth.role() returns text language sql stable as $f$
  select coalesce(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role')
  );
$f$;
SQL

docker cp "$MIGRATIONS_DIR" "$CONTAINER":/tmp/migrations_src >/dev/null
docker exec "$CONTAINER" bash -c '
  cd /tmp/migrations_src
  for f in $(ls *.sql | sort); do
    psql -U postgres -v ON_ERROR_STOP=1 -f "$f" >>/tmp/replay.log 2>&1 || { echo "SCHEMA REPLAY FAILED at $f"; tail -30 /tmp/replay.log; exit 1; }
  done
'
echo "schema replay OK"

echo "== loading dump (data-only) =="
docker cp "$DUMP_PATH" "$CONTAINER":/tmp/restore.dump >/dev/null
# session_replication_role=replica during the data load only: this is the
# exact bypass this project's audit triggers (audit_master_change,
# salary_period_locks' guard_locked_salary_period, audit_log's own
# append-only guard) warn about — legitimate here because this is a
# disposable verification instance being loaded with historical data, not
# production being mutated.
docker exec "$CONTAINER" bash -c "
  psql -U postgres -c \"select 'set_session_replication_role_replica';\" >/dev/null
  PGOPTIONS='-c session_replication_role=replica' pg_restore -U postgres -h localhost -d postgres --data-only /tmp/restore.dump > /tmp/restore.log 2>&1
  echo RESTORE_EXIT=\$?
  grep -c '^pg_restore: error' /tmp/restore.log || true
"

echo "== row-count comparison (source vs restored) =="
FAIL=0
for t in customers invoices service_tickets salaries audit_log; do
  SRC=$(psql "$SOURCE_DB_URL" -tAc "select count(*) from public.$t")
  DST=$(docker exec "$CONTAINER" psql -U postgres -tAc "select count(*) from public.$t")
  if [ "$SRC" != "$DST" ]; then
    echo "MISMATCH $t: source=$SRC restored=$DST"
    FAIL=1
  else
    echo "OK $t: $SRC rows, matches"
  fi
done

echo "== critical function/trigger presence =="
for fn in compute_salary compute_incentives audit_master_change; do
  EXISTS=$(docker exec "$CONTAINER" psql -U postgres -tAc "select exists(select 1 from pg_proc where proname='$fn')")
  [ "$EXISTS" = "t" ] && echo "OK function $fn exists" || { echo "MISSING function $fn"; FAIL=1; }
done
TRIGGER_COUNT=$(docker exec "$CONTAINER" psql -U postgres -tAc "
  select count(*) from pg_trigger t join pg_proc p on p.oid=t.tgfoid
  where p.proname='audit_master_change' and not t.tgisinternal")
echo "audit_master_change attached to $TRIGGER_COUNT tables (restored instance)"

echo "== migration version parity =="
SRC_VER=$(psql "$SOURCE_DB_URL" -tAc "select version from supabase_migrations.schema_migrations order by version desc limit 1" 2>/dev/null || echo "N/A")
DST_VER=$(docker exec "$CONTAINER" psql -U postgres -tAc "select version from supabase_migrations.schema_migrations order by version desc limit 1" 2>/dev/null || echo "N/A")
echo "source latest migration: $SRC_VER"
echo "restored latest migration: $DST_VER"
[ "$SRC_VER" = "$DST_VER" ] || { echo "MISMATCH migration version"; FAIL=1; }

if [ "$FAIL" -eq 0 ]; then
  echo "== RESTORE VERIFICATION PASSED =="
else
  echo "== RESTORE VERIFICATION FAILED — see MISMATCH/MISSING lines above =="
  exit 1
fi
