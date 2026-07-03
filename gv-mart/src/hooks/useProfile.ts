import { useQuery } from "@tanstack/react-query"
import { fetchProfile } from "@/services/auth"
import { useAuth } from "@/hooks/useAuth"

export function useProfile() {
  const { session } = useAuth()
  const userId = session?.user.id

  return useQuery({
    queryKey: ["profile", userId],
    queryFn: () => fetchProfile(userId!),
    enabled: !!userId,
    staleTime: 5 * 60_000,
  })
}
