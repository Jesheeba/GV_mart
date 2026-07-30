import { supabase } from "@/lib/supabase"

export async function signInWithPassword(email: string, password: string) {
  const { data, error } = await supabase.auth.signInWithPassword({ email, password })
  if (error) throw error
  return data
}

/** Redirects to Google, then back to /login — the session lands via the URL fragment (supabase-js handles it automatically). */
export async function signInWithGoogle() {
  const { error } = await supabase.auth.signInWithOAuth({
    provider: "google",
    options: { redirectTo: `${window.location.origin}/login` },
  })
  if (error) throw error
}

/**
 * First-time Google sign-in has a Supabase auth user but no `profiles` row —
 * admin-created customers (create_customer_with_details) never get one, see
 * 20260729130000_customer_google_link.sql. This links the new auth user to
 * their existing customer record by mobile number and creates that profile.
 */
export async function linkCustomerGoogleAccount(mobile: string) {
  const { error } = await supabase.rpc("link_customer_google_account", { p_mobile: mobile })
  if (error) throw error
}

export async function signOut() {
  const { error } = await supabase.auth.signOut()
  if (error) throw error
}

export async function fetchProfile(userId: string) {
  const { data, error } = await supabase.from("profiles").select("*").eq("id", userId).single()
  if (error) throw error
  return data
}
