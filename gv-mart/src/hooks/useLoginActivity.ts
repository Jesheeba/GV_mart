import { useQuery } from "@tanstack/react-query"
import { listLoginActivity, loginActivityParamsSchema, type LoginActivityParams } from "@/services/loginActivity"

export function useLoginActivity(params: LoginActivityParams) {
  const valid = loginActivityParamsSchema.safeParse(params).success
  return {
    valid,
    ...useQuery({
      queryKey: ["hr", "loginActivity", params],
      queryFn: () => listLoginActivity(params),
      enabled: valid,
      placeholderData: (prev) => prev,
    }),
  }
}
