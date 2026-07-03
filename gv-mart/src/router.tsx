import { createBrowserRouter, Navigate } from "react-router-dom"
import { LoginPage } from "@/app/auth/LoginPage"
import { AdminShell } from "@/app/admin/AdminShell"
import { DashboardPage } from "@/app/admin/DashboardPage"
import { TechnicianShell } from "@/app/technician/TechnicianShell"
import { TechnicianHomePage } from "@/app/technician/TechnicianHomePage"
import { AttendancePage } from "@/app/technician/AttendancePage"
import { MapPage } from "@/app/technician/MapPage"
import { SearchPage } from "@/app/technician/SearchPage"
import { SpareHandoverPage } from "@/app/technician/SpareHandoverPage"
import { JobDetailPage } from "@/app/technician/JobDetailPage"
import { OnSiteVisitPage } from "@/app/technician/onsite/OnSiteVisitPage"
import { RatingPage } from "@/app/technician/RatingPage"
import { HistoryPage } from "@/app/technician/HistoryPage"
import { HistoryDetailPage } from "@/app/technician/HistoryDetailPage"
import { ProfilePage as TechnicianProfilePage } from "@/app/technician/ProfilePage"
import { CustomerShell } from "@/app/customer/CustomerShell"
import { CustomerHomePage } from "@/app/customer/CustomerHomePage"
import { CustomerProfilePage } from "@/app/customer/CustomerProfilePage"
import { CustomerProductsPage } from "@/app/customer/CustomerProductsPage"
import { CustomerBookingsPage } from "@/app/customer/CustomerBookingsPage"
import { CustomerBookingDetailPage } from "@/app/customer/CustomerBookingDetailPage"
import { CustomerAmcPage } from "@/app/customer/CustomerAmcPage"
import { CustomerProductEnquiryPage } from "@/app/customer/CustomerProductEnquiryPage"
import { CustomerSpareEnquiryPage } from "@/app/customer/CustomerSpareEnquiryPage"
import { BookServicePage } from "@/app/customer/service/BookServicePage"
import { NotFoundPage } from "@/app/NotFoundPage"
import { CustomersListPage } from "@/app/admin/customers/CustomersListPage"
import { CustomerDetailPage } from "@/app/admin/customers/CustomerDetailPage"
import { CustomerFormPage } from "@/app/admin/customers/CustomerFormPage"
import { MastersPage } from "@/app/admin/masters/MastersPage"
import { InventoryPage } from "@/app/admin/inventory/InventoryPage"
import { SuppliersPage } from "@/app/admin/suppliers/SuppliersPage"
import { SalesListPage } from "@/app/admin/sales/SalesListPage"
import { NewSalePage } from "@/app/admin/sales/NewSalePage"
import { InvoicePage } from "@/app/admin/sales/InvoicePage"
import { QuotationsListPage } from "@/app/admin/quotations/QuotationsListPage"
import { QuotationFormPage } from "@/app/admin/quotations/QuotationFormPage"
import { QuotationDetailPage } from "@/app/admin/quotations/QuotationDetailPage"
import { TicketsListPage } from "@/app/admin/service/TicketsListPage"
import { NewComplaintPage } from "@/app/admin/service/NewComplaintPage"
import { TicketDetailPage } from "@/app/admin/service/TicketDetailPage"
import { AppointmentsPage } from "@/app/admin/service/AppointmentsPage"
import { AmcWarrantyListPage } from "@/app/admin/amc/AmcWarrantyListPage"
import { LeadsPage } from "@/app/admin/leads/LeadsPage"
import { AutomationPage } from "@/app/admin/automation/AutomationPage"
import { PurchasePage } from "@/app/admin/purchase/PurchasePage"
import { TechniciansListPage } from "@/app/admin/technicians/TechniciansListPage"
import { TechniciansMapPage } from "@/app/admin/technicians/TechniciansMapPage"
import { TechniciansAttendancePage } from "@/app/admin/technicians/TechniciansAttendancePage"
import { TechniciansSpareHandoverPage } from "@/app/admin/technicians/TechniciansSpareHandoverPage"
import { HrPage } from "@/app/admin/hr/HrPage"
import { ReportsPage } from "@/app/admin/reports/ReportsPage"
import { WorkspacePage } from "@/app/admin/workspace/WorkspacePage"
import { NotificationsPage } from "@/app/admin/notifications/NotificationsPage"
import { ApprovalsPage } from "@/app/admin/approvals/ApprovalsPage"
import { ComplaintsPage } from "@/app/admin/complaints/ComplaintsPage"
import { CampaignsPage } from "@/app/admin/campaigns/CampaignsPage"
import { ReturnsPage } from "@/app/admin/returns/ReturnsPage"
import { AuditLogPage } from "@/app/admin/audit-log/AuditLogPage"
import { DaySheetPage } from "@/app/technician/DaySheetPage"
import { RequireAuth, RequireRole } from "@/lib/guards"
import { STAFF_ROLES } from "@/lib/roles"

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
            element: <AdminShell />,
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
                  { path: "amc", element: <AmcWarrantyListPage /> },
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
            element: <TechnicianShell />,
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
              { path: "jobs/:ticketId/rating", element: <RatingPage /> },
              { path: "day-sheet", element: <DaySheetPage /> },
            ],
          },
          // Full-screen on-site stepper — deliberately outside TechnicianShell
          // so the bottom tab bar doesn't compete with the stepper's own
          // chrome while a technician is mid-job.
          { path: "jobs/:ticketId/visit", element: <OnSiteVisitPage /> },
        ],
      },
      {
        path: "/customer",
        element: <RequireRole roles={["customer"]} />,
        children: [
          {
            element: <CustomerShell />,
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
              { path: "amc", element: <CustomerAmcPage /> },
              { path: "book-service", element: <BookServicePage /> },
              { path: "product-enquiry", element: <CustomerProductEnquiryPage /> },
              { path: "spare-enquiry", element: <CustomerSpareEnquiryPage /> },
            ],
          },
        ],
      },
    ],
  },
  { path: "*", element: <NotFoundPage /> },
])
