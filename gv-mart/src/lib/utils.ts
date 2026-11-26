import { clsx, type ClassValue } from "clsx"
import { twMerge } from "tailwind-merge"

export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs))
}

/** Moves focus (and so scroll) to a choice control that blocked a save: the element itself when it is a
 * form control (a <select>), otherwise the first button inside it (a SegButton group). */
export function focusChoice(id: string) {
  const el = document.getElementById(id)
  const target = el?.matches("select, input, button") ? el : el?.querySelector<HTMLElement>("button, select, input")
  target?.focus()
}
