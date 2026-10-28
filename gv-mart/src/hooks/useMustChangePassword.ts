import { useQuery } from "@tanstack/react-query"
import { supabase } from "@/lib/supabase"
import { useAuth } from "@/hooks/useAuth"

/**
 * Whether the signed-in person must choose a new password before using the app (new staff, or after a master's reset).
 *
 * Read in its OWN small query, not from the profile row, so that a failure here can never lock people out: if the query errors
 * (for example the front end is deployed before the migration that adds the column), the error is logged and the flag is treated
 * as false. Deploy order is migration, Edge Functions, then front end; this is the safety net, not the plan.
 */
export function useMustChangePassword() {
  const { session } = useAuth()
  const userId = session?.user.id
  return useQuery({
    queryKey: ["profile", "mustChange", userId],
    enabled: !!userId,
    staleTime: 60_000,
    queryFn: async (): Promise<boolean> => {
      const { data, error } = await supabase.from("profiles").select("must_change_password").eq("id", userId!).maybeSingle()
      if (error) {
        console.error("must_change_password could not be read; treating it as false:", error.code ?? "", error.message)
        return false
      }
      return data?.must_change_password === true
    },
  })
}
