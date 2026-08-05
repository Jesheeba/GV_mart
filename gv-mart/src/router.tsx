import { lazy, Suspense, type ComponentType } from "react"
import { createBrowserRouter, Navigate } from "react-router-dom"
import { LoginPage } from "@/app/auth/LoginPage"
import { NotFoundPage } from "@/app/NotFoundPage"
import { RouteFallback } from "@/components/shared/RouteFallback"
import { RequireAuth, RequireRole } from "@/lib/guards"
import { STAFF_ROLES } from "@/lib/roles"

/**
 * Admin/technician/customer are logically separate apps that different user
 * types never simultaneously need, but every route component used to be a
 * static import here — one 1.79MB JS chunk downloaded by every user
 * regardless of role. `lazyPage` wraps each route component in
 * `React.lazy(() => import(...))` (all of them are named, not default,
 * exports, hence the `.then(m => ({ default: m[name] }))`), so Vite emits a
 * separate async chunk per component and a technician's phone never
 * downloads the admin bundle (and vice versa). The three shells
 * (AdminShell/TechnicianShell/CustomerShell) are each wrapped in their own
 * <Suspense> below — that single boundary also covers every lazy page
 * rendered through that shell's <Outlet/>, since Suspense catches any
 * suspending descendant, not just its direct child.
 */
function lazyPage<K extends string>(loader: () => Promise<Record<K, ComponentType>>, name: K) {
  return lazy(() => loader().then((m) => ({ default: m[name] })))
}

// --- Admin ---
const AdminShell = lazyPage(() => import("@/app/admin/AdminShell"), "AdminShell")
const DashboardPage = lazyPage(() => import("@/app/admin/DashboardPage"), "DashboardPage")
const CustomersListPage = lazyPage(() => import("@/app/admin/customers/CustomersListPage"), "CustomersListPage")
const CustomerDetailPage = lazyPage(() => import("@/app/admin/customers/CustomerDetailPage"), "CustomerDetailPage")
const CustomerFormPage = lazyPage(() => import("@/app/admin/customers/CustomerFormPage"), "CustomerFormPage")
const MastersPage = lazyPage(() => import("@/app/admin/masters/MastersPage"), "MastersPage")
const InventoryPage = lazyPage(() => import("@/app/admin/inventory/InventoryPage"), "InventoryPage")
const SuppliersPage = lazyPage(() => import("@/app/admin/suppliers/SuppliersPage"), "SuppliersPage")
const SalesListPage = lazyPage(() => import("@/app/admin/sales/SalesListPage"), "SalesListPage")
const NewSalePage = lazyPage(() => import("@/app/admin/sales/NewSalePage"), "NewSalePage")
const InvoicePage = lazyPage(() => import("@/app/admin/sales/InvoicePage"), "InvoicePage")
const QuotationsListPage = lazyPage(() => import("@/app/admin/quotations/QuotationsListPage"), "QuotationsListPage")
const QuotationFormPage = lazyPage(() => import("@/app/admin/quotations/QuotationFormPage"), "QuotationFormPage")
const QuotationDetailPage = lazyPage(() => import("@/app/admin/quotations/QuotationDetailPage"), "QuotationDetailPage")
const TicketsListPage = lazyPage(() => import("@/app/admin/service/TicketsListPage"), "TicketsListPage")
const NewComplaintPage = lazyPage(() => import("@/app/admin/service/NewComplaintPage"), "NewComplaintPage")
const TicketDetailPage = lazyPage(() => import("@/app/admin/service/TicketDetailPage"), "TicketDetailPage")
const AppointmentsPage = lazyPage(() => import("@/app/admin/service/AppointmentsPage"), "AppointmentsPage")
const AmcWarrantyListPage = lazyPage(() => import("@/app/admin/amc/AmcWarrantyListPage"), "AmcWarrantyListPage")
const AmcContractDetailPage = lazyPage(() => import("@/app/admin/amc/AmcContractDetailPage"), "AmcContractDetailPage")
const LeadsPage = lazyPage(() => import("@/app/admin/leads/LeadsPage"), "LeadsPage")
const AutomationPage = lazyPage(() => import("@/app/admin/automation/AutomationPage"), "AutomationPage")
const PurchasePage = lazyPage(() => import("@/app/admin/purchase/PurchasePage"), "PurchasePage")
const TechniciansListPage = lazyPage(() => import("@/app/admin/technicians/TechniciansListPage"), "TechniciansListPage")
const TechnicianDetailPage = lazyPage(() => import("@/app/admin/technicians/TechnicianDetailPage"), "TechnicianDetailPage")
const TechniciansMapPage = lazyPage(() => import("@/app/admin/technicians/TechniciansMapPage"), "TechniciansMapPage")
const TechniciansAttendancePage = lazyPage(() => import("@/app/admin/technicians/TechniciansAttendancePage"), "TechniciansAttendancePage")
const TechniciansSpareHandoverPage = lazyPage(() => import("@/app/admin/technicians/TechniciansSpareHandoverPage"), "TechniciansSpareHandoverPage")
const HrPage = lazyPage(() => import("@/app/admin/hr/HrPage"), "HrPage")
const ReportsPage = lazyPage(() => import("@/app/admin/reports/ReportsPage"), "ReportsPage")
const WorkspacePage = lazyPage(() => import("@/app/admin/workspace/WorkspacePage"), "WorkspacePage")
const NotificationsPage = lazyPage(() => import("@/app/admin/notifications/NotificationsPage"), "NotificationsPage")
const ApprovalsPage = lazyPage(() => import("@/app/admin/approvals/ApprovalsPage"), "ApprovalsPage")
const ComplaintsPage = lazyPage(() => import("@/app/admin/complaints/ComplaintsPage"), "ComplaintsPage")
const CampaignsPage = lazyPage(() => import("@/app/admin/campaigns/CampaignsPage"), "CampaignsPage")
const ReturnsPage = lazyPage(() => import("@/app/admin/returns/ReturnsPage"), "ReturnsPage")
const AuditLogPage = lazyPage(() => import("@/app/admin/audit-log/AuditLogPage"), "AuditLogPage")

// --- Technician ---
const TechnicianShell = lazyPage(() => import("@/app/technician/TechnicianShell"), "TechnicianShell")
const TechnicianHomePage = lazyPage(() => import("@/app/technician/TechnicianHomePage"), "TechnicianHomePage")
const AttendancePage = lazyPage(() => import("@/app/technician/AttendancePage"), "AttendancePage")
const MapPage = lazyPage(() => import("@/app/technician/MapPage"), "MapPage")
const SearchPage = lazyPage(() => import("@/app/technician/SearchPage"), "SearchPage")
const SpareHandoverPage = lazyPage(() => import("@/app/technician/SpareHandoverPage"), "SpareHandoverPage")
const JobDetailPage = lazyPage(() => import("@/app/technician/JobDetailPage"), "JobDetailPage")
const JobRoutePage = lazyPage(() => import("@/app/technician/JobRoutePage"), "JobRoutePage")
const OnSiteVisitPage = lazyPage(() => import("@/app/technician/onsite/OnSiteVisitPage"), "OnSiteVisitPage")
const RatingPage = lazyPage(() => import("@/app/technician/RatingPage"), "RatingPage")
const HistoryPage = lazyPage(() => import("@/app/technician/HistoryPage"), "HistoryPage")
const HistoryDetailPage = lazyPage(() => import("@/app/technician/HistoryDetailPage"), "HistoryDetailPage")
const TechnicianProfilePage = lazyPage(() => import("@/app/technician/ProfilePage"), "ProfilePage")
const DaySheetPage = lazyPage(() => import("@/app/technician/DaySheetPage"), "DaySheetPage")
const TechnicianNotificationsPage = lazyPage(() => import("@/app/technician/NotificationsPage"), "NotificationsPage")

// --- Customer ---
const CustomerShell = lazyPage(() => import("@/app/customer/CustomerShell"), "CustomerShell")
const CustomerHomePage = lazyPage(() => import("@/app/customer/CustomerHomePage"), "CustomerHomePage")
const CustomerProfilePage = lazyPage(() => import("@/app/customer/CustomerProfilePage"), "CustomerProfilePage")
const CustomerProductsPage = lazyPage(() => import("@/app/customer/CustomerProductsPage"), "CustomerProductsPage")
const CustomerBookingsPage = lazyPage(() => import("@/app/customer/CustomerBookingsPage"), "CustomerBookingsPage")
const CustomerBookingDetailPage = lazyPage(() => import("@/app/customer/CustomerBookingDetailPage"), "CustomerBookingDetailPage")
const CustomerAmcPage = lazyPage(() => import("@/app/customer/CustomerAmcPage"), "CustomerAmcPage")
const CustomerAmcProductDetailPage = lazyPage(
  () => import("@/app/customer/CustomerAmcProductDetailPage"),
  "CustomerAmcProductDetailPage"
)
const CustomerProductEnquiryPage = lazyPage(() => import("@/app/customer/CustomerProductEnquiryPage"), "CustomerProductEnquiryPage")
const CustomerProductDetailPage = lazyPage(() => import("@/app/customer/CustomerProductDetailPage"), "CustomerProductDetailPage")
const CustomerRequestCallbackPage = lazyPage(() => import("@/app/customer/CustomerRequestCallbackPage"), "CustomerRequestCallbackPage")
const CustomerCompareProductsPage = lazyPage(() => import("@/app/customer/CustomerCompareProductsPage"), "CustomerCompareProductsPage")
const CustomerSpareEnquiryPage = lazyPage(() => import("@/app/customer/CustomerSpareEnquiryPage"), "CustomerSpareEnquiryPage")
const BookServicePage = lazyPage(() => import("@/app/customer/service/BookServicePage"), "BookServicePage")
const CustomerNotificationsPage = lazyPage(() => import("@/app/customer/NotificationsPage"), "NotificationsPage")

const SALES_ROLES = ["master", "sales_admin"] as const
const OPS_ROLES = ["master", "operation_admin"] as const
const MASTER_ONLY = ["master"] as const

export const router = createBrowserRouter([
  { path: "/", element: <Navigate to="/login" replace /> },
  { path: "/login", element: <LoginPage /> },
  {
    element: <RequireAuth />,
    children: [
      {
        path: "/admin",
        element: <RequireRole roles={[...STAFF_ROLES]} />,
        children: [
          {
            element: (
              <Suspense fallback={<RouteFallback />}>
                <AdminShell />
              </Suspense>
            ),
            children: [
              { index: true, element: <DashboardPage /> },
              {
                element: <RequireRole roles={[...SALES_ROLES]} />,
                children: [
                  {
                    path: "customers",
                    children: [
                      { index: true, element: <CustomersListPage /> },
                      { path: "new", element: <CustomerFormPage /> },
                      { path: ":id", element: <CustomerDetailPage /> },
                      { path: ":id/edit", element: <CustomerFormPage /> },
                    ],
                  },
                  {
                    path: "sales",
                    children: [
                      { index: true, element: <SalesListPage /> },
                      { path: "new", element: <NewSalePage /> },
                      { path: "invoices/:id", element: <InvoicePage /> },
                    ],
                  },
                  {
                    path: "quotations",
                    children: [
                      { index: true, element: <QuotationsListPage /> },
                      { path: "new", element: <QuotationFormPage /> },
                      { path: ":id", element: <QuotationDetailPage /> },
                    ],
                  },
                  { path: "leads", element: <LeadsPage /> },
                  { path: "automation", element: <AutomationPage /> },
                ],
              },
              {
                element: <RequireRole roles={[...OPS_ROLES]} />,
                children: [
                  {
                    path: "service",
                    children: [
                      { index: true, element: <TicketsListPage /> },
                      { path: "new", element: <NewComplaintPage /> },
                      { path: "appointments", element: <AppointmentsPage /> },
                      { path: ":id", element: <TicketDetailPage /> },
                    ],
                  },
                  {
                    path: "technicians",
                    children: [
                      { index: true, element: <TechniciansListPage /> },
                      { path: "map", element: <TechniciansMapPage /> },
                      { path: "attendance", element: <TechniciansAttendancePage /> },
                      { path: "spares", element: <TechniciansSpareHandoverPage /> },
                      { path: ":id", element: <TechnicianDetailPage /> },
                    ],
                  },
                  { path: "inventory", element: <InventoryPage /> },
                  { path: "suppliers", element: <SuppliersPage /> },
                  { path: "purchase", element: <PurchasePage /> },
                  { path: "complaints", element: <ComplaintsPage /> },
                  { path: "returns", element: <ReturnsPage /> },
                ],
              },
              {
                element: <RequireRole roles={[...MASTER_ONLY]} />,
                children: [
                  {
                    path: "amc",
                    children: [
                      { index: true, element: <AmcWarrantyListPage /> },
                      { path: ":id", element: <AmcContractDetailPage /> },
                    ],
                  },
                  { path: "hr", element: <HrPage /> },
                  { path: "reports", element: <ReportsPage /> },
                  { path: "masters", element: <MastersPage /> },
                  { path: "approvals", element: <ApprovalsPage /> },
                  { path: "audit-log", element: <AuditLogPage /> },
                ],
              },
              {
                element: <RequireRole roles={[...STAFF_ROLES]} />,
                children: [
                  { path: "workspace", element: <WorkspacePage /> },
                  { path: "notifications", element: <NotificationsPage /> },
                ],
              },
              {
                element: <RequireRole roles={[...SALES_ROLES]} />,
                children: [{ path: "campaigns", element: <CampaignsPage /> }],
              },
            ],
          },
        ],
      },
      {
        path: "/technician",
        element: <RequireRole roles={["technician"]} />,
        children: [
          {
            element: (
              <Suspense fallback={<RouteFallback />}>
                <TechnicianShell />
              </Suspense>
            ),
            children: [
              { index: true, element: <TechnicianHomePage /> },
              { path: "map", element: <MapPage /> },
              { path: "attendance", element: <AttendancePage /> },
              { path: "history", element: <HistoryPage /> },
              { path: "history/:visitId", element: <HistoryDetailPage /> },
              { path: "profile", element: <TechnicianProfilePage /> },
              { path: "spares", element: <SpareHandoverPage /> },
              { path: "search", element: <SearchPage /> },
              { path: "jobs/:ticketId", element: <JobDetailPage /> },
              { path: "jobs/:ticketId/route", element: <JobRoutePage /> },
              { path: "jobs/:ticketId/rating", element: <RatingPage /> },
              { path: "day-sheet", element: <DaySheetPage /> },
              { path: "notifications", element: <TechnicianNotificationsPage /> },
            ],
          },
          // Full-screen on-site stepper — deliberately outside TechnicianShell
          // so the bottom tab bar doesn't compete with the stepper's own
          // chrome while a technician is mid-job. Not a descendant of the
          // shell's <Suspense> above (it's a sibling route), so it needs its
          // own boundary.
          {
            path: "jobs/:ticketId/visit",
            element: (
              <Suspense fallback={<RouteFallback />}>
                <OnSiteVisitPage />
              </Suspense>
            ),
          },
        ],
      },
      {
        path: "/customer",
        element: <RequireRole roles={["customer"]} />,
        children: [
          {
            element: (
              <Suspense fallback={<RouteFallback />}>
                <CustomerShell />
              </Suspense>
            ),
            children: [
              { index: true, element: <CustomerHomePage /> },
              { path: "products", element: <CustomerProductsPage /> },
              {
                path: "bookings",
                children: [
                  { index: true, element: <CustomerBookingsPage /> },
                  { path: ":id", element: <CustomerBookingDetailPage /> },
                ],
              },
              { path: "profile", element: <CustomerProfilePage /> },
              {
                path: "amc",
                children: [
                  { index: true, element: <CustomerAmcPage /> },
                  { path: ":productId", element: <CustomerAmcProductDetailPage /> },
                ],
              },
              { path: "book-service", element: <BookServicePage /> },
              {
                path: "product-enquiry",
                children: [
                  { index: true, element: <CustomerProductEnquiryPage /> },
                  { path: "catalog/:productId", element: <CustomerProductDetailPage /> },
                  { path: "callback", element: <CustomerRequestCallbackPage /> },
                  { path: "compare", element: <CustomerCompareProductsPage /> },
                ],
              },
              { path: "spare-enquiry", element: <CustomerSpareEnquiryPage /> },
              { path: "notifications", element: <CustomerNotificationsPage /> },
            ],
          },
        ],
      },
    ],
  },
  { path: "*", element: <NotFoundPage /> },
])
