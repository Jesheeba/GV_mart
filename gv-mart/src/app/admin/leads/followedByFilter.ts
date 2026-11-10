export type LeadActorPair = { leadId: string; actorId: string }

/** actorId -> distinct set of lead ids they've logged at least one follow-up activity on. */
export function groupLeadIdsByActor(pairs: LeadActorPair[]): Map<string, Set<string>> {
  const byActor = new Map<string, Set<string>>()
  for (const { leadId, actorId } of pairs) {
    if (!byActor.has(actorId)) byActor.set(actorId, new Set())
    byActor.get(actorId)!.add(leadId)
  }
  return byActor
}

/** actorId -> count of DISTINCT leads followed up on — never the number of activity rows (spec §7.4). */
export function distinctLeadCountByActor(pairs: LeadActorPair[]): Map<string, number> {
  const byActor = groupLeadIdsByActor(pairs)
  return new Map([...byActor.entries()].map(([actorId, leadIds]) => [actorId, leadIds.size]))
}
