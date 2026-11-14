import { Link } from "react-router-dom"

/**
 * Public, unauthenticated page — Play Console's Data Safety section requires
 * a live URL it can open without signing in. Must stay reachable at
 * /privacy-policy outside RequireAuth (see router.tsx).
 */
export function PrivacyPolicyPage() {
  return (
    <div className="min-h-screen bg-bg px-6 py-10 text-text">
      <div className="mx-auto max-w-2xl space-y-6">
        <div>
          <h1 className="text-2xl font-bold">Privacy Policy</h1>
          <p className="mt-1 text-sm text-muted-foreground">Last updated: 14 November 2026</p>
        </div>

        <p>
          This policy explains what information the GV Mart app ("we", "us") collects from customers, technicians,
          and staff who use it, and how that information is used.
        </p>

        <Section title="Information we collect">
          <ul className="list-disc space-y-1 pl-5">
            <li>Account details: name, phone number, email, and role (customer, technician, or staff).</li>
            <li>Service details: addresses, appointment and job history, product and warranty records, invoices.</li>
            <li>
              Location: technicians' device location while on duty, used to route jobs and show nearby appointments.
              Not collected from customers.
            </li>
            <li>
              Microphone: technicians may record a voice note while closing out a job; the recording is attached to
              that job's record.
            </li>
            <li>WhatsApp messages: updates about bookings, quotations, and service status sent via WhatsApp.</li>
          </ul>
        </Section>

        <Section title="How we use this information">
          <p>
            To run the service: scheduling jobs, dispatching technicians, generating invoices and quotations,
            processing AMC/warranty claims, and sending status updates. We do not sell this information to third
            parties.
          </p>
        </Section>

        <Section title="Who we share it with">
          <p>
            Service providers we use to operate the app: our database/hosting provider (Supabase), and our WhatsApp
            messaging provider, solely to deliver the service above. We do not share data with anyone else.
          </p>
        </Section>

        <Section title="Data retention">
          <p>
            We keep account and service records for as long as the account is active, and as needed to meet
            accounting and warranty obligations. You can request deletion of your account data by contacting us
            below.
          </p>
        </Section>

        <Section title="Your choices">
          <p>
            Technicians can deny location or microphone access in their device settings; doing so disables the
            features that depend on them (routing and voice notes) without affecting the rest of the app.
          </p>
        </Section>

        <Section title="Contact us">
          <p>
            GV Mart · 4/50, GV Towers, Vignesh Nagar, Kattur, Trichy - 620019 · +91 81222 22233 ·
            gvmartramesh2001@gmail.com
            <br />
            For any question about this policy or to request your data be deleted, contact us using the details
            above.
          </p>
        </Section>

        <Link to="/login" className="inline-block text-sm font-semibold text-accent underline">
          Back to login
        </Link>
      </div>
    </div>
  )
}

function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <section className="space-y-2">
      <h2 className="text-lg font-semibold">{title}</h2>
      {children}
    </section>
  )
}
