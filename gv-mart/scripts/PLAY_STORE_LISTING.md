# Play Store listing content

Draft copy for Play Console's Store Listing page. Edit freely before
pasting in — this is based on what the app actually does
(`src/router.tsx`, product categories in `src/lib/i18n/en.json`), not
invented features.

## App name
GV Mart

## Short description (max 80 characters)
RO/water purifier sales, service, AMC & technician dispatch — all in one app.

(79 characters)

## Full description (max 4000 characters)

```
GV Mart is the all-in-one app for a water purifier and home appliance
sales & service business — built for staff, field technicians, and
customers.

For customers:
• Browse RO/water purifier products and compare models
• Book a service visit or raise a complaint
• Track AMC (annual maintenance contract) and warranty status
• Request spare parts or a callback
• Get booking and service updates on WhatsApp

For field technicians:
• See today's assigned jobs and navigate to each one
• Mark attendance and track work hours
• Record job completion with photos, signature, and voice notes
• Manage spare parts handover and expenses
• Request leave and view schedule

For admin & sales staff:
• Manage leads, quotations, and sales end-to-end
• Dispatch and track technicians on a live map
• Run AMC renewals, warranty claims, and returns
• Track accounts, expenses, staff salary, and incentives
• View business reports and daily performance dashboards

GV Mart connects every part of the business — from a customer's first
enquiry to the technician closing the job — in one app.
```

## Category
Business (alternative: Productivity).

## Contact details (Store listing + App content)
- Business name: **GV Mart**
- Address: 4/50, GV Towers, Vignesh Nagar, Kattur, Trichy - 620019
- Phone: +91 81222 22233
- Email: gvmartramesh2001@gmail.com
- Privacy policy URL: `https://gv-mart.vercel.app/privacy-policy`

(Publishing is from Sirah Digital's Play Console account — the public
"Offered by" byline on the store listing will show Sirah Digital
regardless of the contact details above, per the account-ownership
decision already made.)

## Screenshots & graphics — not generated
These need real device/browser screenshots of the running app and
designed graphics:
- At least 2 phone screenshots (Play requires at least 2).
- App icon: 512×512 PNG — export from `resources/icon.png`.
- Feature graphic: 1024×500 PNG/JPG banner — not yet made.

## Data Safety form — answers
(Duplicated from `PLAY_STORE_CHECKLIST.md` step 6 for convenience — keep
both in sync if this changes.)

| Data type | Collected? | Shared with 3rd parties? | Purpose | Optional? |
|---|---|---|---|---|
| Name, phone, email | Yes | No | Account management, app functionality | No |
| Precise location | Yes — technicians only | No | App functionality (job routing) | No, required for technician role |
| Audio (voice notes) | Yes — technicians only | No | App functionality (job documentation) | Yes, device setting can deny mic |
| Customer/service records (address, purchase/service history) | Yes | No | App functionality | No |

- Data encrypted in transit: Yes (HTTPS, Supabase).
- Users can request data deletion: Yes, via the privacy policy contact
  channel (GV Mart's email/phone above).
- Data collection is required for the app to function (most fields), not
  optional user-provided content.
