# quick-add (F3)

**Purpose:** add a missing master value from inside the form instead of leaving to Masters.

**Architecture**
- `Autocomplete` gains optional `onCreate(text)` + `createLabel`; when the typed text has no exact match, last row shows "+ Add "<text>"".
- Complaint name: creates `complaint_types {label, product_category=resolved category, product_id=null}` then selects it.
- Non-master roles: RLS is master-only. Option A — show button to master only (no DB change). Option B — SECURITY DEFINER RPC `quick_add_complaint_type(p_label, p_category)` allowed for master+operation_admin, trims, max 80 chars, case-insensitive dedupe, org from `current_org_id()`, revoke anon.

**Impact map:** Autocomplete (all callers — prop is optional, default off), NewComplaintPage step 2, complaintTypesHooks cache, ComplaintTypesTab list, ProductComplaintsPanel.

**Edge cases:** blank/whitespace; duplicate label differing in case → select existing; no product resolved → button hidden (no category); network/RLS error → toast, typed text kept as free text; double click → disabled while pending.

**Acceptance:** typing a new name shows "+ Add"; click saves, selects it, and it appears in Masters → Complaint types and next complaint; duplicate never inserted; unauthorised role never sees a failing button.

## F3b: other forms (2026-11-26)
- **Built:**
  - New Lead: Source, Product type, Kind.
  - Edit Lead: Source (unless it is a referral), Product type.
  - Purchase order and Bill entry: Supplier.
- **Shared parts:**
  - `QuickAddInline` ("+ Add new" link → inline box, Enter/Escape, error inline).
  - `LeadOptionQuickAdd`, `SupplierQuickAdd`.
  - `findByLabel` helper.
- **Lead lists:** new RPC `quick_add_lead_option(p_list, p_label)` (master + sales_admin via `is_sales_staff()`, list whitelisted, same key rule as Masters, existing key/label returned, archived option raises `archived` rather than re-enabling). Migration `20261226120000`: **built, not applied**.
- **Suppliers:** a direct insert; RLS `is_ops_staff` already matches the Purchase page roles. Name only; an existing name is selected instead of a duplicate.
- **Already had an add option (left as is):** Accounts → expense category ("create new"), New Sale → "Add a new customer".
- **Excluded on purpose:**
  - Products, spares, AMC/rental plans, gifts: they carry prices and stock.
  - Lead outcomes and post-service outcomes: they drive follow-up logic.
  - Customer-app complaint types: customers must not add to masters.
  - Brands/models: they live inside Masters → Products already.
