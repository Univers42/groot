# A prefix mode whose backend a flag switches off is out of scope

- Decided: 2026-11-27 · by devil (ruling `/mnt/storage/dlesieur/scratch/palette-modes/verdict.md`, draft `docs/adr/DRAFT-palette-modes-ruling.md`)
- Holds while: unified message search sits behind a flag that is off by default


- Rejected: a prefix mode (`#`) whose backend is switched off by a flag.
- Why: it takes a whole class of real searches and returns only an "is off" row.
- What would change the answer: unified message search becomes on by default with no flag,
  or the bar stops reserving the prefix whenever the flag is off.

## Prior requests

- 2026-11-27 (builder draft): `#` always a messages mode. Refused; `#` is a mode only while the flag is on (PM3).
