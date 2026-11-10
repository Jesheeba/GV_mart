// The master login is a shared office account, not an individual staff
// member, so its dashboard greeting shows the org name instead of a
// person's name. operation_admin/sales_admin are real individual staff and
// keep their own first name. `orgName` is undefined while the org is still
// loading or for non-master roles that never fetch it — falls back to the
// first name so the greeting is never blank.
export function resolveGreetingName(profile: { role: string; full_name: string }, orgName: string | undefined): string {
  const firstName = profile.full_name.split(" ")[0]
  if (profile.role === "master" && orgName) return orgName
  return firstName
}
