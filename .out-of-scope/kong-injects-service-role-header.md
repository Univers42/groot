# Kong injects X-Baas-Role: service_role

Rejected 2026-10-17 (devil, ADR 0006 TM2): it would open a second path to the most powerful role.
Revisit only if a product caller needs admin over the public edge and cannot reach the
orchestrator's internal :3026.
