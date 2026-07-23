# GV Mart - Technician Module Discussion Notes

> **Source:** Technician Dashboard Discussion (Conversation Notes)

---

## Bugs & Fixes

### Bug 1
**Issue:** Attendance button requires multiple clicks before marking attendance.  
**Fix:** Attendance should be marked with a single click and the button should be disabled while the request is processing.

---

### Bug 2
**Issue:** Dashboard jobs are not sorted based on business priority.  
**Fix:** Sort jobs as **Overdue → Very Urgent → High → Medium → Low → Upcoming**.

---

### Bug 3
**Issue:** Overdue jobs are displayed as normal jobs.  
**Fix:** Highlight overdue jobs with a red card, warning icon, overdue badge, and overdue duration.

---

### Bug 4
**Issue:** Technician can search every customer in the system.  
**Fix:** Restrict customer search to assigned customers and previously serviced customers only.

---

### Bug 5
**Issue:** "I've Arrived" button works even when the technician is far from the customer.  
**Fix:** Enable the arrival button only after entering the customer geofence (200–300 meters).

---

### Bug 6
**Issue:** Productivity timer starts without validating technician arrival.  
**Fix:** Start the timer only after GPS validation and successful arrival confirmation.

---

### Bug 7
**Issue:** Technician evidence is scattered and difficult to track.  
**Fix:** Create a centralized Evidence Dashboard with photos, GPS, signatures, checklist, invoice, and attachments.

---

## Requirements

### Requirement 1
Customer Timeline should display the complete service history.

### Requirement 2
Technician Timeline should display attendance, jobs, GPS, ratings, and work history.

### Requirement 3
Every completed job must permanently store before and after photos with timestamps.

### Requirement 4
Every completed job must store GPS location and attendance records.

### Requirement 5
Every completed job must store customer and technician signatures.

### Requirement 6
Dashboard should display Today's Jobs, Pending, Completed, Cancelled, and Overdue counts.

### Requirement 7
Attendance History screen should display check-in, check-out, GPS, and working hours.

### Requirement 8
Technician Performance Dashboard should display ratings, jobs completed, completion time, and productivity.

### Requirement 9
Customer profile should display previous services, AMC, warranty, invoices, and service history.

### Requirement 10
Every customer should have a chronological service timeline.

### Requirement 11
Every technician should have a complete work history timeline.

### Requirement 12
Evidence uploaded during service should never be overwritten or deleted.

### Requirement 13
GPS history should be maintained from job acceptance until completion.

### Requirement 14
Dashboard refresh should not reset the technician workflow or lose data.

---

## Business Logic

### Logic 1
Repeat customers should be assigned to the previous technician if the previous rating is **4 stars or above**.

### Logic 2
If a technician receives a customer rating of **3 stars or below**, the next service should be assigned to the highest-rated technician.

### Logic 3
Overdue status should be calculated using **Assigned Date + SLA based on priority**.

### Logic 4
Technician access must be limited to assigned jobs and assigned customers only.

### Logic 5
Arrival must always be validated using GPS before the service workflow starts.

---

## UI Suggestions

### UI Suggestion 1
Dashboard should display clear priority colours and overdue indicators.

### UI Suggestion 2
Dashboard should include better counters and status cards.

### UI Suggestion 3
Improve loading states during attendance marking.

### UI Suggestion 4
Organize technician evidence into a dedicated screen instead of multiple locations.

---

## Workflow

### Technician Flow

```text
Login
↓
Attendance
↓
Dashboard
↓
Assigned Jobs
↓
Navigation
↓
Arrived
↓
Inspection
↓
Service
↓
Evidence
↓
Invoice
↓
Payment
↓
Signature
↓
Completion
```

---

## Pending Discussion

- Review whether the Evidence Dashboard already exists.
- If it exists, tune and improve it.
- If it does not exist, redesign the entire Evidence Dashboard flow.
```