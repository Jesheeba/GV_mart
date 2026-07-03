# TODO — before production / before making this repo public

These are known items intentionally deferred during development. **All must be done before going live or making the repo public.**

## Security (hard gate — do all of these)
- [ ] **Rotate the `service_role` key** — Supabase → Project Settings → API → regenerate. (It was surfaced during a dev session.)
- [ ] **Reset the database password** — Supabase → Project Settings → Database. (Surfaced during a dev session.)
- [ ] **Delete the Personal Access Token** — Supabase → Account → Tokens → revoke the `claude-code-cli` token.
- [ ] **Move the seed password out of source** — change `supabase/seed/data.ts` to read `process.env.SEED_PASSWORD` (no hardcoded value); add `SEED_PASSWORD=` to `.env.example`. Change the actual demo password from `GvMart@2026`.
- [ ] Confirm `.env.local` is never tracked; only the anon key (public, RLS-protected) is safe to expose.

## Real integrations to wire (currently stubbed/simulated)
- [ ] **WhatsApp** — currently logs to `whatsapp_outbox` instead of sending. Wire the real WhatsApp Cloud API + complete Meta App Review. Confirm the business number (Section 7 open item).
- [ ] **Payment gateway** — Customer App AMC/online payment needs a real provider (e.g. Razorpay). Staff billing stays manual transaction-ID (no gateway) per v2.2.
- [ ] **Maps / live tracking** — no Maps SDK configured in dev; add a real Maps API key for navigation + technician tracking.

## Client open items (from signed v2.2 §7 — need Ramesh's answers)
- [ ] Confirm the RO consumable's real name (noted as "spun / sponge"). App treats it as an admin-configurable master name — no hardcoded guess.
- [ ] Confirm the WhatsApp business number + owner.

## Final verification before sign-off
- [ ] Live browser smoke test of Technicians / HR / Payroll / Reports / Workspace screens (deferred earlier due to a transient Supabase connectivity/rate-limit issue).
- [ ] Live click-through of the lunch start/end red-flag flow and tap-to-call logging (verified by code review earlier, not a fresh live pass).
- [ ] Full end-to-end smoke test as each of the 5 roles (master / operation_admin / sales_admin / technician / customer), in both English and Tamil.

## Build status reference
- Signed v2.2 scope (11 modules, 5 stages) is functionally complete: Phases 0–11 built and integrated.
- `tsc`, `oxlint`, `vite build` clean; i18n parity at 1449 EN/TA keys.
- No new phases remain in the signed scope — this file is the remaining go-live hardening, not new features.