/** Wraps an async handler so a second call while the first is still in
 * flight is a no-op, instead of relying solely on a disabled prop that only
 * takes effect after React's next render.
 *
 * QA smoke test bug #1 (2026-10-29): Manage Categories' "+ Create new
 * category" button already had `disabled={createCategory.isPending}`, but
 * two clicks fired before that render both reached the click handler --
 * the first create succeeded, the second correctly refused as a duplicate,
 * and only the second (losing) request's error ended up on screen, with the
 * input left uncleared. `isPending` and `disabled` only update after a
 * render; `ref.current` is read and written synchronously inside the same
 * call stack, so this closes the window regardless of render timing. Same
 * fix applied to the "+ Create new category" inline inside Log Expense.
 *
 * `ref` must be a mutable ref whose `.current` starts `false`; this
 * function owns setting and clearing it -- callers never touch it directly. */
export function guardReentry(ref: { current: boolean }, fn: () => Promise<void>): Promise<void> {
  if (ref.current) return Promise.resolve()
  ref.current = true
  return fn().finally(() => {
    ref.current = false
  })
}
