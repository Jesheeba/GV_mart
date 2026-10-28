import { describe, expect, it } from "vitest"
import { mapMonthlyExpensesReport, type MonthlyExpensesReportRpcRow } from "./monthlyExpenses"

// Shapes `salaries` + the technicians(profiles(full_name)) embed actually
// return — see getMonthlyExpensesReport in monthlyExpenses.ts and Unit 7's
// test, supabase/tests/monthly_expenses_report.test.sql.
describe("mapMonthlyExpensesReport", () => {
  it("maps every itemised-expense column and resolves the technician's name", () => {
    const rows: MonthlyExpensesReportRpcRow[] = [
      {
        technician_id: "t1",
        recharge_amount: 300,
        petrol_amount: 450,
        maintenance_amount: 0,
        bike_allowance_amount: 1000,
        technicians: { profiles: { full_name: "Ravi Kumar" } },
      },
    ]
    expect(mapMonthlyExpensesReport(rows)).toEqual([
      {
        technicianId: "t1",
        technicianName: "Ravi Kumar",
        rechargeAmount: 300,
        petrolAmount: 450,
        maintenanceAmount: 0,
        bikeAllowanceAmount: 1000,
      },
    ])
  })

  it("falls back to an em dash when the technician/profile embed is missing", () => {
    const rows: MonthlyExpensesReportRpcRow[] = [
      {
        technician_id: "t2",
        recharge_amount: 0,
        petrol_amount: 0,
        maintenance_amount: 0,
        bike_allowance_amount: 0,
        technicians: null,
      },
    ]
    expect(mapMonthlyExpensesReport(rows)[0].technicianName).toBe("—")
  })

  it("returns an empty array for an empty result set, not a crash", () => {
    expect(mapMonthlyExpensesReport([])).toEqual([])
  })
})
