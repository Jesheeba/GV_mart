# Migration-numbering survey, 2026-10-24

Full picture of every Supabase migration filename at or above the live schema ceiling
(`20261024100000`), across every local branch — so nobody has to re-derive this. Triggered by a
real collision: `pkg5/standard-minutes-and-efficiency` originally claimed `20261024110000`, which
`fix/amc-renewal-financial-trail` already held (committed the day before). pkg5 moved to
`20261024120000`.

## Flag first: the one collision a filename-only check would miss

**`20261103100000`** is claimed by both `feat/p3-task-log-visibility` and
`pkg3/task-logs-colours-workspace-merge`, under the **identical filename**
(`task_logs_and_visibility.sql`) — but the two files differ by a 198-line diff. Every cheap
check (file exists? name matches?) passes here; only a content diff catches it. Any tooling that
dedupes migrations by filename alone will silently pick one and drop real work from the other.

## Method

Worktrees of this repo share one object store, so `refs/heads` is visible identically from any of
them — this was run from `GV_mart_pkg5` (one of the active worktrees), but the result is the same
from any checkout. For each local branch, list every tracked file under
`gv-mart/supabase/migrations/`, extract the filenames at or above the ceiling, and group by
timestamp:

```bash
# from the repo root (parent of gv-mart/) — any worktree's root works, refs are shared
git for-each-ref --format='%(refname:short)' refs/heads \
  | while read -r b; do
      git ls-tree -r --name-only "$b" -- gv-mart/supabase/migrations 2>/dev/null \
        | while read -r f; do echo "$b|$f"; done
    done > all_migrations.txt

# keep filenames whose leading 14-digit timestamp is >= 20261024100000
awk -F'|' '{
  n=$2; sub(/^.*migrations\//, "", n); split(n, a, "_"); ts = a[1]
  if (ts ~ /^[0-9]{14}$/ && ts+0 >= 20261024100000) print $1 "|" n
}' all_migrations.txt | sort -t'|' -k2,2 -k1,1
```

~90 local branches, ~31,200 (branch, file) pairs scanned. To check whether two branches claiming
the same filename actually hold the same content (a collision a name match alone won't show):

```bash
diff <(git show <branch-a>:gv-mart/supabase/migrations/<file>) \
     <(git show <branch-b>:gv-mart/supabase/migrations/<file>)
```

## Collision table (same timestamp, different content)

| Timestamp | Branch | File | Note |
|---|---|---|---|
| `20261103100000` | `feat/p3-task-log-visibility` | `task_logs_and_visibility.sql` | **same filename on both sides — flagged above** |
| `20261103100000` | `pkg3/task-logs-colours-workspace-merge` | `task_logs_and_visibility.sql` | 198-line diff from the other |
| `20261101100000` | `feat/p1-task-security`, `feat/p3-task-log-visibility` | `task_completion_rule.sql` | |
| `20261101100000` | `pkg1/task-completion-rule` | `task_status_guard.sql` | different filename, same slot |
| `20261101110000` | `feat/p1-task-security`, `feat/p3-task-log-visibility` | `current_technician_id_active.sql` | |
| `20261101110000` | `pkg1/task-completion-rule` | `current_technician_id_active_only.sql` | different filename, same slot |
| `20261102100000` | `feat/p2-staff-profile-huddle`, `feat/p3-task-log-visibility` | `p2_staff_profile_and_huddle.sql` | |
| `20261102100000` | `pkg2/staff-huddle-profile` | `staff_profile_fields_and_huddle_attribution.sql` | different filename, same slot |
| `20261024110000` | `fix/amc-renewal-financial-trail` | `amc_sale_financial_trail.sql` | AMC had the slot first (committed 2026-10-23) |
| `20261024110000` | ~~`pkg5/standard-minutes-and-efficiency`~~ | ~~`standard_minutes_and_efficiency.sql`~~ | **resolved 2026-10-24 → moved to `20261024120000`** |

The `pkg1`/`pkg2`/`pkg3` vs `feat/p1`/`feat/p2`/`feat/p3` rows are the "Window P supersedes
pkg1-3" situation — see `docs/pkg1-3-supersession-2026-10-24.md` for the full functional
comparison and what (if anything) pkg1-3 built that the P-series doesn't cover.

## Same timestamp, same content (shared ancestry — not a collision)

- `20261024100000` (`close_public_and_anon_function_execute.sql`) — `fix/close-public-anon-function-execute`, `release/b17-batch8`, `ui-ux-improvements`. This one is live.
- `20261024100100`–`20261024100600` (`technician_vehicles.sql` … `compute_salary_itemised_expenses.sql`) — `feat/monthly-expenses`, `feat/salary-finalization`, `main`, `throwaway/parallel-session-wip-2026-10-23`, `wip/finalization-transfer`. All five branches inherit these from a common point; confirmed 0-diff.

## Everything else ≥ ceiling, one branch each (no collision)

| Timestamp(s) | Branch |
|---|---|
| `20261024100700`–`20261024100900` | `feat/salary-finalization` |
| `20261024200000`–`20261024210000` | `feat/master-time-slots` |
| `20261025100000` | `feat/amc-release-path`, `release/b17-batch8` (same file) |
| `20261025200000` | `feat/initiated-send-gate` |
| `20261026100000`–`20261026110000` | `feat/automation-item-added-cooldown`, `feat/automation-no-customer-record`, `feat/automation-phase3b` (shared) |
| `20261027100000` | `feat/followup-questions` |
| `20261028100000` | `feat/enquiry-video-resolver` |
| `20261029100000`–`20261029130000` | `feat/automation-phase3b` |
| `20261030100000` | `feat/technician-table` |
| `20261104100000`–`20261104110000` | `pkg4/item-code` |
| `20261024120000` | `pkg5/standard-minutes-and-efficiency` (current slot, confirmed free against every branch above) |

## Next free slot

As of this survey, `20261024120000` was free and is now pkg5's slot. Anyone claiming a new
timestamp in the `202610xx`–`202611xx` range should re-run the method above first — this table
is a snapshot, not a lock.
