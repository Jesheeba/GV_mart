# quick-add (F3)

**Purpose:** add a missing master value from inside the form instead of leaving to Masters.

**Architecture**
- `Autocomplete` gains optional `onCreate(text)` + `createLabel`; when the typed text has no exact match, last row shows "+ Add "<text>"".
- Complaint name: creates `complaint_types {label, product_category=resolved category, product_id=null}` then selects it.
- Non-master roles: RLS is master-only. Option A — show button to master only (no DB change). Option B — SECURITY DEFINER RPC `quick_add_complaint_type(p_label, p_category)` allowed for master+operation_admin, trims, max 80 chars, case-insensitive dedupe, org from `current_org_id()`, revoke anon.

**Impact map:** Autocomplete (all callers — prop is optional, default off), NewComplaintPage step 2, complaintTypesHooks cache, ComplaintTypesTab list, ProductComplaintsPanel.

**Edge cases:** blank/whitespace; duplicate label differing in case → select existing; no product resolved → button hidden (no category); network/RLS error → toast, typed text kept as free text; double click → disabled while pending.

**Acceptance:** typing a new name shows "+ Add"; click saves, selects it, and it appears in Masters → Complaint types and next complaint; duplicate never inserted; unauthorised role never sees a failing button.
