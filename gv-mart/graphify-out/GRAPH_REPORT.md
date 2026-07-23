# Graph Report - .  (2026-07-22)

## Corpus Check
- cluster-only mode — file stats not available

## Summary
- 2259 nodes · 5408 edges · 180 communities (148 shown, 32 thin omitted)
- Extraction: 100% EXTRACTED · 0% INFERRED · 0% AMBIGUOUS · INFERRED: 1 edges (avg confidence: 0.5)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `2cf22e1e`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- Community 0
- Community 1
- Community 2
- Community 3
- Community 4
- Community 5
- Community 6
- Community 7
- Community 8
- Community 9
- Community 10
- Community 11
- Community 12
- Community 13
- Community 14
- Community 15
- Community 16
- Community 17
- Community 18
- Community 19
- Community 20
- Community 21
- Community 22
- Community 23
- Community 24
- Community 25
- Community 26
- Community 27
- Community 28
- Community 29
- Community 30
- Community 31
- Community 32
- Community 33
- Community 34
- Community 35
- Community 36
- Community 37
- Community 38
- Community 39
- Community 40
- Community 41
- Community 42
- Community 43
- Community 44
- Community 45
- Community 46
- Community 47
- Community 48
- Community 49
- Community 50
- Community 51
- Community 52
- Community 53
- Community 54
- Community 55
- Community 56
- Community 57
- Community 58
- Community 59
- Community 60
- Community 61
- Community 62
- Community 63
- Community 64
- Community 65
- Community 66
- Community 67
- Community 68
- Community 69
- Community 70
- Community 71
- Community 72
- Community 73
- Community 74
- Community 75
- Community 76
- Community 77
- Community 78
- Community 79
- Community 80
- Community 81
- Community 83
- Community 84
- Community 85
- Community 86
- Community 87
- Community 88
- Community 89
- Community 90
- Community 92
- Community 93
- Community 94
- Community 95
- Community 96
- Community 97
- Community 98
- Community 100
- Community 101
- Community 102
- Community 103
- Community 104
- Community 106
- Community 107
- Community 108
- Community 109
- Community 110
- Community 111
- Community 112
- Community 115
- Community 121
- Community 123
- Community 124
- Community 125
- Community 127
- Community 128
- Community 129
- Community 130
- Community 131
- Community 132
- Community 133
- Community 134
- Community 135
- Community 136
- Community 137
- Community 138
- Community 139
- Community 140
- Community 141
- Community 143
- Community 145
- Community 148
- Community 149
- Community 152
- Community 153
- Community 154
- Community 163

## God Nodes (most connected - your core abstractions)
1. `useProfile()` - 153 edges
2. `cn()` - 149 edges
3. `react` - 99 edges
4. `Button()` - 84 edges
5. `Card()` - 75 edges
6. `formatCurrency()` - 46 edges
7. `Input()` - 43 edges
8. `FullPageLoader()` - 40 edges
9. `FullPageError()` - 36 edges
10. `Enums` - 36 edges

## Surprising Connections (you probably didn't know these)
- `SegButton()` --calls--> `cn()`  [EXTRACTED]
  src/app/admin/amc/AmcWarrantyListPage.tsx → src/lib/utils.ts
- `QuickFilterChip()` --calls--> `cn()`  [EXTRACTED]
  src/app/admin/customers/CustomersListPage.tsx → src/lib/utils.ts
- `AttentionRow()` --calls--> `cn()`  [EXTRACTED]
  src/app/admin/dashboard/OwnerDashboard.tsx → src/lib/utils.ts
- `StepperButton()` --calls--> `cn()`  [EXTRACTED]
  src/app/admin/masters/SettingsTab.tsx → src/lib/utils.ts
- `PnlRow()` --calls--> `cn()`  [EXTRACTED]
  src/app/admin/reports/PnlReportTab.tsx → src/lib/utils.ts

## Import Cycles
- None detected.

## Communities (180 total, 32 thin omitted)

### Community 0 - "Community 0"
Cohesion: 0.06
Nodes (63): AdminGlobalSearch(), AdminShell(), GlobalSearchResult, DashboardPage(), ADMIN_NAV, AdminNavItem, ALL_STAFF, NotificationsPage() (+55 more)

### Community 1 - "Community 1"
Cohesion: 0.03
Nodes (65): AdminShell, AmcContractDetailPage, AmcWarrantyListPage, AppointmentsPage, ApprovalsPage, AttendancePage, AuditLogPage, AutomationPage (+57 more)

### Community 2 - "Community 2"
Cohesion: 0.06
Nodes (44): ComplaintsPage(), currentMonthIso(), IncentivesTab(), money(), monthToPeriodDate(), CATEGORIES, currentMonthIso(), monthToPeriodDate() (+36 more)

### Community 3 - "Community 3"
Cohesion: 0.04
Nodes (52): addresses, amc_contracts, amc_plans, appointments, approvals, attendance, audit_log, automation_flows (+44 more)

### Community 4 - "Community 4"
Cohesion: 0.11
Nodes (34): AmcPlanCoveredSparesPanel(), AmcPlansTab(), displayPricePerYear(), inclusionsToText(), resolvePricing(), textToInclusions(), BrandsTab(), CATEGORIES (+26 more)

### Community 5 - "Community 5"
Cohesion: 0.06
Nodes (34): enqueue(), AppointmentRow, AttendanceRow, cacheVisitSignature(), CreateServiceInvoiceInput, CustomerHistoryEntry, getTodaysJobCounts(), isWindowOpenAt() (+26 more)

### Community 6 - "Community 6"
Cohesion: 0.09
Nodes (39): SignaturePad(), OnSiteVisitPage(), SopStep, STEP_KEYS, useVisitTimer(), VisitDraftData, SelectedSpare, RatingPage() (+31 more)

### Community 7 - "Community 7"
Cohesion: 0.05
Nodes (10): BrandRow, ComplaintTypeRow, fromCoveredSpares(), IncentiveRuleRow, listAmcPlanCoveredSpareIds(), ModelRow, ProductRow, setAmcPlanCoveredSpares() (+2 more)

### Community 8 - "Community 8"
Cohesion: 0.11
Nodes (33): DateRangeFilter(), FeedbackReportTab(), AVATAR_COLORS, firstFixTone(), formatCompletionMinutes(), formatProductivity(), initials(), PerformanceReportTab() (+25 more)

### Community 9 - "Community 9"
Cohesion: 0.06
Nodes (21): AddressRow, CustomerFilterCounts, CustomerInvoiceRow, CustomerLifetimeSummary, CustomerListFilters, CustomerNextAmcAction, CustomerProductRow, CustomerRow (+13 more)

### Community 10 - "Community 10"
Cohesion: 0.05
Nodes (14): AmcContractRow, AmcPlanRow, AppointmentRow, CustomerExemptionWindowRow, CustomerRow, InvoiceRow, LeadRow, ProductRow (+6 more)

### Community 11 - "Community 11"
Cohesion: 0.12
Nodes (26): MastersPage(), LegendDot(), DataTable(), initials(), CardFooter(), DropdownMenu(), DropdownMenuCheckboxItem(), DropdownMenuContent() (+18 more)

### Community 12 - "Community 12"
Cohesion: 0.11
Nodes (25): TaskItem(), todayIso(), WorkspacePage(), WorkspaceTask, useCompletedWorkspaceTasks(), useCreateTask(), useMarkAppointmentConfirmed(), useMyNotificationsFeed() (+17 more)

### Community 13 - "Community 13"
Cohesion: 0.09
Nodes (25): StuckJobsPanel(), SyncStatusChip(), CardAction(), CardContent(), CardDescription(), CardHeader(), CardTitle(), useOnlineStatus() (+17 more)

### Community 14 - "Community 14"
Cohesion: 0.06
Nodes (13): AppointmentMode, AppointmentRow, AppointmentStatus, OwnedEquipment, ServiceTicketRow, ServiceVisitRow, SettingsWithSla, TechnicianOption (+5 more)

### Community 15 - "Community 15"
Cohesion: 0.08
Nodes (27): SlaCountdown(), PRIORITY_BG_CLASS, PRIORITY_COLOR_CLASS, PriorityBadge(), PriorityText(), TicketTypeBadge(), TYPE_BADGE_CLASS, CardStatusBadge() (+19 more)

### Community 16 - "Community 16"
Cohesion: 0.07
Nodes (11): adminSignSpareHandover(), createSpareHandover(), EligibleProfile, rpc(), SpareHandoverItemInsert, SpareHandoverItemRow, SpareHandoverRow, SpareOption (+3 more)

### Community 17 - "Community 17"
Cohesion: 0.11
Nodes (25): AttendanceCell, AttendanceTab(), AVAILABILITY_STATUS_OPTIONS, AvailabilityTab(), buildMonthCells(), CurrentJobTab(), DayDetailPanel(), fmtDate() (+17 more)

### Community 18 - "Community 18"
Cohesion: 0.17
Nodes (20): AMC_STATUS_TONE, CATEGORY_STYLE, CustomerDetailPage(), fmtDate(), FamilyMembersPanel(), useAddMember(), useCustomer(), useCustomerExemptionWindows() (+12 more)

### Community 19 - "Community 19"
Cohesion: 0.15
Nodes (26): CustomerAmcPage(), formatCurrency(), AddressBar(), NextServiceBanner(), StatusCards(), CustomerProductsPage(), RegisterProductForm(), BookServicePage() (+18 more)

### Community 20 - "Community 20"
Cohesion: 0.07
Nodes (5): LastBillEntry, LeadActivityRow, LeadRow, PoItemRow, PurchaseOrderRow

### Community 21 - "Community 21"
Cohesion: 0.07
Nodes (27): oxlint, devDependencies, oxlint, playwright, tailwindcss, @tailwindcss/vite, tsx, @types/google.maps (+19 more)

### Community 22 - "Community 22"
Cohesion: 0.17
Nodes (21): ItemsStep(), NewSaleDraftData, NewSalePage(), STEP_KEYS, SaleSummaryPanel(), amcSubtotal(), CartAmc, cartIsEmpty() (+13 more)

### Community 23 - "Community 23"
Cohesion: 0.11
Nodes (23): LiveTracking(), ControlButton(), dotIconUrl(), FINEXY_MAP_STYLE, loadGoogleMaps(), Map(), MapContext, MapContextValue (+15 more)

### Community 24 - "Community 24"
Cohesion: 0.12
Nodes (24): AddressesSection(), CustomerProfilePage(), MembersSection(), ProfessionField(), ReferralWalletCard(), useAddMyAddress(), useAddMyMember(), useDeleteMyAddress() (+16 more)

### Community 25 - "Community 25"
Cohesion: 0.11
Nodes (23): Database, BRANDS, CHENNAI_AREAS, CUSTOMERS, MODELS, ORG, PRODUCT_STOCK, PRODUCTS (+15 more)

### Community 26 - "Community 26"
Cohesion: 0.08
Nodes (25): DOM, google.maps, src, vite/client, compilerOptions, allowArbitraryExtensions, allowImportingTsExtensions, erasableSyntaxOnly (+17 more)

### Community 27 - "Community 27"
Cohesion: 0.19
Nodes (14): react, ENQUIRY_TYPES, KINDS, SOURCES, BookServiceDraftData, CATEGORIES, ProductView, SpareSelectStep() (+6 more)

### Community 28 - "Community 28"
Cohesion: 0.08
Nodes (3): ApprovalRow, NotificationRow, ReturnRow

### Community 29 - "Community 29"
Cohesion: 0.09
Nodes (23): @base-ui/react, @fontsource-variable/plus-jakarta-sans, @hookform/resolvers, i18next, i18next-browser-languagedetector, dependencies, @base-ui/react, @fontsource-variable/plus-jakarta-sans (+15 more)

### Community 30 - "Community 30"
Cohesion: 0.14
Nodes (16): AMC_STATUS_TONE, AmcContractDetailPage(), fmt(), TICKET_STATUS_TONE, AddTechnicianPanel(), FilterChip(), initialsOf(), STATUS_DOT_CLASS (+8 more)

### Community 31 - "Community 31"
Cohesion: 0.10
Nodes (21): InboundTestTab(), useSimulateInboundWhatsapp(), useWhatsappOutbox(), AutomationFlowInput, automationFlowSchema, BillEntryInput, billEntrySchema, CreatePurchaseOrderInput (+13 more)

### Community 32 - "Community 32"
Cohesion: 0.18
Nodes (17): barHeights(), lastNMonths(), thisMonthRange(), todayRange(), APPT_STATUS_TONE, OpsDashboard(), AttentionRow(), OwnerDashboard() (+9 more)

### Community 33 - "Community 33"
Cohesion: 0.18
Nodes (18): GEO_ERROR_KEYS, googleMapsUrl(), MapPage(), useDirectionsDistance(), classifyGeoError(), distanceKm(), expectedMinutes(), GeoErrorKind (+10 more)

### Community 34 - "Community 34"
Cohesion: 0.09
Nodes (21): aliases, components, hooks, lib, ui, utils, iconLibrary, menuAccent (+13 more)

### Community 35 - "Community 35"
Cohesion: 0.16
Nodes (19): CustomerFormPage(), MemberFieldRow(), useAreaAutocomplete(), useCreateCustomer(), useMobileDuplicateCheck(), usePincodeLookup(), useUpdateCustomerProfession(), useUpsertPrimaryAddress() (+11 more)

### Community 36 - "Community 36"
Cohesion: 0.12
Nodes (18): NewComplaintDraftData, PRIORITIES, Stepper(), StepperStep, DraftEnvelope, useLocalDraft(), ComplaintAppointmentStepInput, complaintAppointmentStepSchema (+10 more)

### Community 37 - "Community 37"
Cohesion: 0.15
Nodes (18): AttendancePage(), formatWorkedDuration(), GEO_ERROR_KEYS, geoErrorKey(), Tick, TICK_ORDER, PhotoCapture(), useCheckOut() (+10 more)

### Community 38 - "Community 38"
Cohesion: 0.17
Nodes (18): JobTypeBadge(), OverdueBadge(), PRIORITY_CLASS, PriorityBadge(), TYPE_VARIANT, HistoryDetailPage(), minutesBetween(), formatDateTime() (+10 more)

### Community 39 - "Community 39"
Cohesion: 0.10
Nodes (19): vite.config.ts, compilerOptions, allowImportingTsExtensions, erasableSyntaxOnly, lib, module, moduleDetection, noEmit (+11 more)

### Community 40 - "Community 40"
Cohesion: 0.15
Nodes (17): AMC_STATUS_TONE, AmcTable(), AmcWarrantyListPage(), fmt(), formatCompact(), SegButton(), TIER_COLORS, WARRANTY_STATUS_TONE (+9 more)

### Community 41 - "Community 41"
Cohesion: 0.18
Nodes (17): ACTIONS, AutomationFlowsTab(), TRIGGERS, TOPICS, VideoLibraryTab(), useAutomationFlows(), useCreateAutomationFlow(), useCreateVideoLibraryEntry() (+9 more)

### Community 42 - "Community 42"
Cohesion: 0.20
Nodes (14): InventoryPage(), InventoryTable(), STATUS_STYLE, StatusKey, stockLevelPct(), stockStatus(), useAdjustStock(), useInventoryList() (+6 more)

### Community 43 - "Community 43"
Cohesion: 0.16
Nodes (15): DiscountGiftCard(), formatPct(), hhmm(), SettingsTab(), StepperButton(), lunchMinutes(), TechniciansAttendancePage(), todayIso() (+7 more)

### Community 44 - "Community 44"
Cohesion: 0.18
Nodes (17): initialsOf(), TechnicianDetailPage(), TechniciansListPage(), DraftLine, TechniciansSpareHandoverPage(), todayIso(), useAdminSignSpareHandover(), useCreateSpareHandover() (+9 more)

### Community 45 - "Community 45"
Cohesion: 0.11
Nodes (13): getCustomerInvoices(), getCustomerTimeline(), getInvoice(), InvoiceDetail, InvoiceItemRow, InvoiceListItem, InvoiceRow, itemNameLookup() (+5 more)

### Community 46 - "Community 46"
Cohesion: 0.21
Nodes (15): BillEntryTab(), PoItemRows(), PurchaseOrdersTab(), STATUS_TONE, Button(), buttonVariants, useCreateBillEntry(), useCreatePurchaseOrder() (+7 more)

### Community 47 - "Community 47"
Cohesion: 0.18
Nodes (14): SellAmcPanel(), QuotationFormPage(), QuotationNavState, QuoteLine, Autocomplete(), useRoProducts(), useSellAmcPlan(), useCustomerAutocomplete() (+6 more)

### Community 48 - "Community 48"
Cohesion: 0.16
Nodes (14): QuotationsListPage(), INVOICE_TYPE_BADGE_CLASS, InvoiceTypeBadge(), PAYMENT_STATUS_BADGE_CLASS, PaymentStatusBadge(), FilterChip(), PAYMENT_METHOD_KEY, SalesListPage() (+6 more)

### Community 49 - "Community 49"
Cohesion: 0.19
Nodes (10): AddressMapPicker(), Coords, DEFAULT_CENTER, newSessionToken(), useAutocomplete(), useGeocodeAddress(), useMapApiKey(), usePlaceDetails() (+2 more)

### Community 50 - "Community 50"
Cohesion: 0.13
Nodes (6): ItemType, SupplierProductRow, PublicSchema, Tables, TablesInsert, TablesUpdate

### Community 51 - "Community 51"
Cohesion: 0.12
Nodes (16): ../../src/types/database.ts, **/*.ts, compilerOptions, lib, module, moduleResolution, noEmit, resolveJsonModule (+8 more)

### Community 52 - "Community 52"
Cohesion: 0.20
Nodes (12): ApprovalRow(), STATUS_TONE, STATUS_TONE, CustomerBookingDetailPage(), formatCurrency(), PAYMENT_STATUS_TONE, STATUS_TONE, DOT_TONE_CLASS (+4 more)

### Community 53 - "Community 53"
Cohesion: 0.17
Nodes (14): CampaignsPage(), CHANNEL_OPTIONS, STATUS_TONE, useCampaigns(), useCreateCampaign(), useDeleteCampaign(), useUpdateCampaignStatus(), CreateCampaignFormInput (+6 more)

### Community 54 - "Community 54"
Cohesion: 0.30
Nodes (13): LinkedRow, SupplierItemsPanel(), SuppliersPage(), useCatalogForLinking(), useCreateSupplier(), useDeleteSupplier(), useLinkSupplierItem(), useSupplierProducts() (+5 more)

### Community 55 - "Community 55"
Cohesion: 0.19
Nodes (15): CHENNAI_CENTER, computeIdleMinutes(), statusColor(), statusTone(), TechnicianMarker(), TechnicianRow(), TechniciansMapPage(), TrackingStatus (+7 more)

### Community 56 - "Community 56"
Cohesion: 0.26
Nodes (10): QuotationDetailPage(), STATUS_TONE, HistoryPage(), TYPE_FILTERS, useMarkQuotationLost(), useQuotation(), useMyHistory(), billBreakdown() (+2 more)

### Community 57 - "Community 57"
Cohesion: 0.22
Nodes (13): NEXT_STATUS, ReturnsPage(), STATUS_TONE, useCreateReturn(), useInvoicesForPicker(), useReturns(), useUpdateReturnStatus(), AuditLogFilters (+5 more)

### Community 58 - "Community 58"
Cohesion: 0.21
Nodes (11): CustomerProductEnquiryPage(), TOPICS, CustomerSpareEnquiryPage(), VideoCard(), useSubmitEnquiry(), useVideoLibrary(), EnquiryInput, enquirySchema (+3 more)

### Community 59 - "Community 59"
Cohesion: 0.16
Nodes (8): ErrorBoundary, ErrorBoundaryProps, ErrorBoundaryState, ToastProvider(), AuthProvider(), I18nProvider(), queryClient, router

### Community 60 - "Community 60"
Cohesion: 0.18
Nodes (9): AutocompletePrediction, extractComponents(), GeocodeRequest, GeocodeResult, GoogleAddressComponent, LatLng, toGeocodeResult(), corsHeaders (+1 more)

### Community 61 - "Community 61"
Cohesion: 0.16
Nodes (6): invoices_milestone_notify, public._milestone_invoice_notify(), public._milestone_ticket_notify(), public._milestone_visit_notify(), service_tickets_milestone_notify, service_visits_milestone_notify

### Community 62 - "Community 62"
Cohesion: 0.23
Nodes (11): barColor(), LogExpensePanel(), PnlReportTab(), PnlRow(), useCreateExpense(), CreateExpenseFormInput, CreateExpenseOutput, createExpenseSchema (+3 more)

### Community 63 - "Community 63"
Cohesion: 0.27
Nodes (12): compareScheduledAt(), CountCell(), formatOverdueDuration(), formatTime(), JobListItem(), priorityBucket(), sortJobsByPriority(), TechnicianHomePage() (+4 more)

### Community 64 - "Community 64"
Cohesion: 0.15
Nodes (5): AmcContractDetail, AmcContractRow, AmcContractVisit, AmcStatus, WarrantyRow

### Community 65 - "Community 65"
Cohesion: 0.20
Nodes (10): COLUMNS, LeadsKanban(), KIND_OPTIONS, LeadsPage(), SOURCE_OPTIONS, TOPIC_OPTIONS, NewLeadForm(), KpiCard() (+2 more)

### Community 66 - "Community 66"
Cohesion: 0.23
Nodes (10): backoffDelayMs(), flushOutbox(), Listener, listeners, runJob(), setState(), startSyncEngine(), state (+2 more)

### Community 67 - "Community 67"
Cohesion: 0.18
Nodes (8): getQuotation(), itemNameLookup(), QuotationCartItem, QuotationDetail, QuotationItemRow, QuotationListItem, QuotationRow, Enums

### Community 69 - "Community 69"
Cohesion: 0.25
Nodes (9): AMC_STATUS_TONE, CustomersListPage(), fmtDate(), QuickFilter, QuickFilterChip(), useCustomerFilterCounts(), useCustomerListEnrichment(), useCustomersList() (+1 more)

### Community 70 - "Community 70"
Cohesion: 0.24
Nodes (8): NewComplaintPage(), todayInput(), useCreateComplaintTicket(), useDetectTicketType(), useOwnedEquipment(), useSlaSettings(), CreateComplaintInput, TicketFiltersInput

### Community 71 - "Community 71"
Cohesion: 0.18
Nodes (10): amc_contracts, audit_amc_contracts, audit_invoices, audit_quotations, audit_service_tickets, audit_warranties, products, service_tickets (+2 more)

### Community 72 - "Community 72"
Cohesion: 0.29
Nodes (8): ToastApi, ToastContext, ToastContextValue, ToastRecord, ToastVariant, Toaster(), VARIANT_ICON, VARIANT_ICON_CLASS

### Community 73 - "Community 73"
Cohesion: 0.44
Nodes (8): fitsJob(), FreeWindowResult, isBookableDate(), isNarrowWindow(), largestFreeWindow(), mergedBlocks(), toHHMM(), toMinutes()

### Community 74 - "Community 74"
Cohesion: 0.38
Nodes (9): audit_amc_plans, audit_brands, audit_gifts, audit_incentive_rules, audit_models, audit_products, audit_settings, audit_spares (+1 more)

### Community 75 - "Community 75"
Cohesion: 0.22
Nodes (8): plugins, rules, react/only-export-components, react/rules-of-hooks, $schema, oxc, typescript, warn

### Community 76 - "Community 76"
Cohesion: 0.33
Nodes (8): ApprovalsPage(), STATUS_OPTIONS, TYPE_OPTIONS, useToast(), useApprovals(), useApprovePurchaseOrder(), useDecideApproval(), ApprovalListItem

### Community 77 - "Community 77"
Cohesion: 0.33
Nodes (8): ACTIVITY_TYPES, LeadDetailPanel(), STATUSES, useAwardReferralPoints(), useLeadActivities(), useLogLeadActivity(), useUpdateLeadStatus(), LeadStatus

### Community 78 - "Community 78"
Cohesion: 0.39
Nodes (7): minutesBetween(), TicketDetailPage(), useAssignTicketTechnician(), useCustomerAddresses(), useTicket(), useTicketEvidence(), useUpdateTicketAddress()

### Community 79 - "Community 79"
Cohesion: 0.25
Nodes (8): scripts, build, dev, lint, preview, seed, test, test:watch

### Community 80 - "Community 80"
Cohesion: 0.43
Nodes (7): AppointmentsPage(), toDateInput(), useAppointmentsRange(), useAutoAssignTicket(), useTechnicians(), useUnassignAppointment(), AppointmentListItem

### Community 81 - "Community 81"
Cohesion: 0.46
Nodes (7): appointments, ratings, ro_checklists, service_sop_steps, service_spares_used, service_tickets, service_visits

### Community 83 - "Community 83"
Cohesion: 0.32
Nodes (6): public.appointment_unavailable_windows, public.appointments, public._customer_exemption_blocks(), public.customer_exemption_windows, public.settings, set_updated_at

### Community 84 - "Community 84"
Cohesion: 0.43
Nodes (5): PlanTierCard(), isAmcRenewalOpen(), pricePerYearOf(), daysFromNow(), NOW

### Community 85 - "Community 85"
Cohesion: 0.38
Nodes (4): AuditLogPage(), useAuditLog(), useAuditLogTableNames(), AuditLogRow

### Community 86 - "Community 86"
Cohesion: 0.43
Nodes (6): DAYS, ExemptionWindowsPanel(), useAddExemptionWindow(), useRemoveExemptionWindow(), useSetExemptionWindowActive(), ExemptionWindowRow

### Community 87 - "Community 87"
Cohesion: 0.33
Nodes (5): getInitialTheme(), Theme, ThemeContext, ThemeContextValue, ThemeProvider()

### Community 88 - "Community 88"
Cohesion: 0.43
Nodes (6): brands, inventory, inventory_movements, models, products, spares

### Community 89 - "Community 89"
Cohesion: 0.52
Nodes (6): gift_logs, gifts, invoice_items, invoices, quotation_items, quotations

### Community 90 - "Community 90"
Cohesion: 0.33
Nodes (6): automation_flows, lead_activities, leads, quotations, referral_points, video_library

### Community 93 - "Community 93"
Cohesion: 0.40
Nodes (4): CustomerBookingsPage(), STATUS_TONE, TicketRow, useMyTickets()

### Community 94 - "Community 94"
Cohesion: 0.33
Nodes (5): SpareHandoverFormInput, spareHandoverFormSchema, spareHandoverItemSchema, TechnicianEditInput, technicianEditSchema

### Community 95 - "Community 95"
Cohesion: 0.67
Nodes (5): po_items, purchase_bills, purchase_orders, supplier_products, suppliers

### Community 96 - "Community 96"
Cohesion: 0.40
Nodes (5): expenses, incentive_rules, incentives_earned, rewards, salaries

### Community 97 - "Community 97"
Cohesion: 0.33
Nodes (5): approvals, audit_log, notifications, settings, tasks

### Community 98 - "Community 98"
Cohesion: 0.33
Nodes (5): audit_appointments, audit_ro_checklists, audit_service_spares_used, audit_service_visits, settings

### Community 102 - "Community 102"
Cohesion: 0.33
Nodes (4): public.addresses, public.service_tickets, public.settings, public.technicians

### Community 103 - "Community 103"
Cohesion: 0.40
Nodes (4): name, private, type, version

### Community 104 - "Community 104"
Cohesion: 0.50
Nodes (4): attendance, spare_handover_items, spare_handovers, technician_locations

### Community 106 - "Community 106"
Cohesion: 0.60
Nodes (3): public.amc_plan_covered_spares, public.amc_plans, public.sell_amc_plan()

### Community 108 - "Community 108"
Cohesion: 0.40
Nodes (4): compilerOptions, paths, files, references

### Community 109 - "Community 109"
Cohesion: 0.50
Nodes (3): LogRewardFormInput, logRewardSchema, periodMonthSchema

### Community 110 - "Community 110"
Cohesion: 1.00
Nodes (3): organizations, profiles, technicians

### Community 111 - "Community 111"
Cohesion: 0.83
Nodes (3): addresses, customer_members, customers

### Community 112 - "Community 112"
Cohesion: 0.67
Nodes (3): amc_contracts, amc_plans, warranties

### Community 115 - "Community 115"
Cohesion: 0.50
Nodes (3): public.purchase_order_items, public.settings, public.whatsapp_outbox

## Knowledge Gaps
- **616 isolated node(s):** `$schema`, `typescript`, `oxc`, `react/rules-of-hooks`, `warn` (+611 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **32 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `react` connect `Community 27` to `Community 0`, `Community 1`, `Community 2`, `Community 4`, `Community 6`, `Community 8`, `Community 11`, `Community 12`, `Community 13`, `Community 15`, `Community 17`, `Community 18`, `Community 19`, `Community 22`, `Community 23`, `Community 24`, `Community 30`, `Community 33`, `Community 35`, `Community 36`, `Community 37`, `Community 38`, `Community 40`, `Community 42`, `Community 43`, `Community 44`, `Community 46`, `Community 47`, `Community 48`, `Community 49`, `Community 52`, `Community 53`, `Community 54`, `Community 55`, `Community 56`, `Community 57`, `Community 58`, `Community 59`, `Community 62`, `Community 65`, `Community 69`, `Community 72`, `Community 75`, `Community 76`, `Community 77`, `Community 78`, `Community 80`, `Community 85`, `Community 86`, `Community 87`?**
  _High betweenness centrality (0.095) - this node is a cross-community bridge._
- **Why does `useProfile()` connect `Community 0` to `Community 2`, `Community 4`, `Community 6`, `Community 8`, `Community 11`, `Community 12`, `Community 15`, `Community 17`, `Community 18`, `Community 19`, `Community 22`, `Community 24`, `Community 27`, `Community 30`, `Community 31`, `Community 33`, `Community 35`, `Community 36`, `Community 37`, `Community 38`, `Community 40`, `Community 41`, `Community 42`, `Community 43`, `Community 44`, `Community 46`, `Community 47`, `Community 48`, `Community 52`, `Community 53`, `Community 54`, `Community 55`, `Community 56`, `Community 57`, `Community 62`, `Community 63`, `Community 65`, `Community 69`, `Community 70`, `Community 76`, `Community 77`, `Community 80`, `Community 85`?**
  _High betweenness centrality (0.092) - this node is a cross-community bridge._
- **Why does `cn()` connect `Community 11` to `Community 0`, `Community 2`, `Community 4`, `Community 6`, `Community 8`, `Community 12`, `Community 13`, `Community 15`, `Community 17`, `Community 18`, `Community 23`, `Community 27`, `Community 30`, `Community 32`, `Community 33`, `Community 36`, `Community 37`, `Community 40`, `Community 42`, `Community 43`, `Community 46`, `Community 47`, `Community 48`, `Community 49`, `Community 52`, `Community 55`, `Community 62`, `Community 63`, `Community 65`, `Community 69`, `Community 72`, `Community 84`?**
  _High betweenness centrality (0.053) - this node is a cross-community bridge._
- **What connects `$schema`, `typescript`, `oxc` to the rest of the system?**
  _616 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Community 0` be split into smaller, more focused modules?**
  _Cohesion score 0.06128702757916241 - nodes in this community are weakly interconnected._
- **Should `Community 1` be split into smaller, more focused modules?**
  _Cohesion score 0.029850746268656716 - nodes in this community are weakly interconnected._
- **Should `Community 2` be split into smaller, more focused modules?**
  _Cohesion score 0.06349206349206349 - nodes in this community are weakly interconnected._