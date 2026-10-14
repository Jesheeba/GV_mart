# Dispatcher functions: what is deployed, and who deploys next (read-only check, 2026-10-14 ~11:00 UTC)

Method: each of the five functions was downloaded through the Management API into an empty scratch directory (never into a working tree) and every extracted source file was compared, line endings normalised, with the blob at several commits. A bundle carries no commit id, so "built from" means "byte-identical to the files of". The CLI refused to extract one non-function file (`src/lib/i18n/en.json`), which is therefore not compared. No secrets, numbers or wamids are recorded here.

## Live versions and what they match

| Function | Live version | Deployed (UTC) | Files compared | Identical to `feat/dispatcher-v2` tip `17fd6ec` | Identical to `origin/main` `a08819b` |
|---|---|---|---|---|---|
| wa-dispatch-now | v15 | 2026-10-12 14:54:37 | 12 | all 12 | all 12 |
| wa-milestone-dispatch | v17 | 2026-10-12 14:54:55 | 12 | all 12 | all 12 |
| wa-scheduled-tasks | v26 | 2026-10-12 14:54:15 | 14 | all 14 | all 14 |
| wasi-webhook | v50 | 2026-10-13 11:08:35 | 17 | 16 of 17 | all 17 |
| whatsapp-webhook | v57 | 2026-10-13 11:09:01 | 17 | 16 of 17 | all 17 |

`verify_jwt` unchanged on all five (`wa-dispatch-now` true, the other four false).

## The one difference
`_shared/whatsapp-handle-message.ts` in the two webhooks contains the opt-out keyword hook (`handleOptOutKeyword` from `_shared/wa-opt-out.ts`, run before the supplier branch and the kill switch), commit `fa96718` "opt-out keyword check runs before the supplier branch", from `feat/automation-phase3a` (merged to `origin/main` as `a410a3f`). `feat/dispatcher-v2` does not have it. The same bundle also carries the later START reply (`7c0f70a`). So the webhooks were redeployed on 2026-10-13 by a session other than the dispatcher tab, from a tree equal to `origin/main`; that is the automation Phase 3 Stage A change (STOP recognised), not a dispatcher change. Everything else in the two webhooks is the dispatcher v2 code.

Conclusion: nothing deployed is unexpected relative to `origin/main`; three functions are exactly the intended dispatcher v2 tip; two webhooks are dispatcher v2 plus the Phase 3A opt-out hook.

## State that goes with it (unchanged by this check)
`settings.wa_dispatch_v2_enabled` OFF, `wa_dispatch_v2_scope` `numbers`, one number on the list (the canary), test mode off. Migrations applied through `20261021100000`; `20261016300000-330000` and `20261016500000` are live.

## Who deploys from here
* The dispatcher (`wa-dispatch-now`, `wa-milestone-dispatch`, `wa-scheduled-tasks`, and the dispatcher parts of the two webhooks) is owned by the dispatcher tab, worktree `GV_mart_dispatcher2`, branch `feat/dispatcher-v2`. No other tab should deploy these three functions.
* The webhook handler's opt-out logic belongs to the automation tab (`feat/automation-phase3a` / `3b`). Any redeploy of `wasi-webhook` or `whatsapp-webhook` must be built from a tree that contains BOTH, i.e. from `origin/main` at or after `a08819b`, never from `feat/dispatcher-v2` alone (that would silently remove STOP handling) and never from `feat/dispatcher-fix`.
* Flag ON, template mappings and any send stay owner-approved, one step at a time. No deploy is needed to turn the flag on.
* Rollback and preflight for deploys are in `dispatcher-live-state-handoff.md` and `plan-dispatcher-fix-deploy.md` section 7 (run `supabase projects list` first).
