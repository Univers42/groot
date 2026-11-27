# DRAFT. The top bar takes prefix modes (> : / ? @ #) in one combobox; # is a mode only while message search is on

- Status: proposed (draft, unnumbered). devil: PROCEED-WITH-CONDITIONS (PM1–PM17); B1–B3 BLOCKED as first drafted.
- Date: 2026-11-27
- Deciders: devil (ruling); the osionos builder
- Design: `/mnt/storage/dlesieur/scratch/palette-modes/spec.md`
- Full ruling: `/mnt/storage/dlesieur/scratch/palette-modes/verdict.md`


- Context: the top bar becomes the single entry point, with prefix modes. Facts are F1–F12 in the
  full ruling.
- Alternatives considered:
  - (a) Separate hotkeys per mode. Rejected by the spec; it would cost discoverability and
    add more chords.
  - (b) A modal "settings palette". It would duplicate the combobox and its ARIA wiring.
  - (c) Prefix modes in one combobox. Chosen.
- Decision: PROCEED-WITH-CONDITIONS PM1–PM17. B1–B3 are BLOCKED until their conditions
  hold.
- Consequences: a page title that starts with a sigil needs a leading space to be searched.
  "Find in folder" and every other programmatic search must use the literal path.
  Settings that touch the server never enter the inline table without a new ruling.

