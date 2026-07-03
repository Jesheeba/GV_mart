import { NavLink } from "react-router-dom"
import type { LucideIcon } from "lucide-react"
import { cn } from "@/lib/utils"

export type BottomTab = {
  key: string
  label: string
  path: string
  icon: LucideIcon
  end?: boolean
}

export function BottomTabBar({ tabs }: { tabs: BottomTab[] }) {
  return (
    <nav className="fixed inset-x-0 bottom-0 z-40 border-t border-border bg-surface pb-[env(safe-area-inset-bottom)]">
      <ul className="mx-auto flex max-w-md items-stretch justify-around">
        {tabs.map((tab) => {
          const Icon = tab.icon
          return (
            <li key={tab.key} className="flex-1">
              <NavLink
                to={tab.path}
                end={tab.end}
                className={({ isActive }) =>
                  cn(
                    "flex flex-col items-center gap-1 py-2.5 text-xs font-medium transition-colors",
                    isActive ? "text-accent" : "text-text-muted"
                  )
                }
              >
                <Icon className="size-5" />
                {tab.label}
              </NavLink>
            </li>
          )
        })}
      </ul>
    </nav>
  )
}
