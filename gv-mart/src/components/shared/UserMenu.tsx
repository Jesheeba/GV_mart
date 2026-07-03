import { ChevronDown, LogOut } from "lucide-react"
import { useTranslation } from "react-i18next"
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuGroup,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu"
import { signOut } from "@/services/auth"
import type { UserRole } from "@/lib/roles"

function initials(name: string) {
  const parts = name.trim().split(/\s+/)
  return ((parts[0]?.[0] ?? "") + (parts[1]?.[0] ?? "")).toUpperCase()
}

export function UserMenu({ fullName, role }: { fullName: string; role: UserRole }) {
  const { t } = useTranslation()

  return (
    <DropdownMenu>
      <DropdownMenuTrigger className="flex items-center gap-2 rounded-full py-1 pr-2 pl-1 outline-none hover:bg-surface-alt">
        <span className="flex size-8 items-center justify-center rounded-full bg-ink text-xs font-semibold text-white">
          {initials(fullName)}
        </span>
        <span className="hidden text-left sm:block">
          <span className="block text-sm font-medium leading-tight text-text">{fullName}</span>
          <span className="block text-xs leading-tight text-text-muted">{t(`roles.${role}`)}</span>
        </span>
        <ChevronDown className="size-4 text-text-muted" />
      </DropdownMenuTrigger>
      <DropdownMenuContent align="end" className="w-48">
        <DropdownMenuGroup>
          <DropdownMenuLabel>
            <span className="block text-sm font-medium text-text">{fullName}</span>
            <span className="block text-xs font-normal text-text-muted">{t(`roles.${role}`)}</span>
          </DropdownMenuLabel>
        </DropdownMenuGroup>
        <DropdownMenuSeparator />
        <DropdownMenuItem variant="destructive" onClick={() => signOut()}>
          <LogOut className="size-4" />
          {t("shell.signOut")}
        </DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
  )
}
