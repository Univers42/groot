# The gate system

> **Status:** Verified · 2026-09-15
> **Evidence:** batteries, the numbering caveats and the vacuous-pass rule are all stated in the
> backend document
> **Sources:** `apps/grobase/CLAUDE.md` §Verify gates (the unit of "done") · `scripts/verify/`

**Verify gates are the unit of "done".** Not "it compiles", not "the tests pass" — a numbered,
self-contained script that exercises the behaviour against a running system.

There are about **160** of them in `scripts/verify/`.

---

## The one rule

> *A gate that passes vacuously (no-op) is not a gate — gates have to exercise real behaviour.*

That is the repository's own wording, and it is the most important sentence in this wiki. It
means a green result is not evidence until you know the script did something.

It exists because of the failure mode in [platform/07-isolation](../platform/07-isolation.md): a
fault in owner scoping raises no error, it returns someone else's rows. No exception to catch,
no alert. The gates are the only sensor, so a gate that quietly does nothing is worse than none
— it manufactures confidence.

Apply the same suspicion to your own work. An empty result, a green log or a "seems fine" is not
confirmation until you have checked the tool looked at the right thing.

---

## Running them

```sh
bash scripts/verify/run-gate-battery.sh --fast         # per-PR set
bash scripts/verify/run-gate-battery.sh --enterprise   # nightly, includes flag-gated features
make conformance                                       # alias for m27, the engine battery
make conformance-<engine>                              # one engine
```

The `--enterprise` battery exists because most enterprise features are flag-gated off: the fast
set runs the default configuration, the nightly one raises flags and exercises what they unlock.
→ [operations/02-flags](../operations/02-flags.md)

---

## Two practical warnings

**Numbers are not contiguous, and some are reused.** There are two `m101` scripts, and
duplicates at `m23`, `m24`, `m102`, `m146` and `m154`. **Invoke gates by full name, never by
number** — you will run the wrong one.

**The scripts are the source of truth; the Makefile targets are thin wrappers.** When a result
does not make sense, read the script. It is self-contained by design, so it is readable in one
sitting.

---

## What a gate looks like conceptually

Each one stands alone: set up its own fixtures against the running stack, perform the operation,
assert the observable outcome, clean up. No shared harness, no framework to learn. That is why
they can be read individually and why they survive refactors of the code they test.

The assertions are deliberately blunt — zero rows, a 404, a byte-equal signature, an exact
capability set. Blunt assertions are hard to pass accidentally, which is the whole point given
the rule above.

---

## Beyond the numbered gates

Three other layers carry weight and are easy to overlook:

**`engine-conformance`** is a crate of the data-plane workspace, not an external test suite —
cross-engine parity is treated as part of the product.
→ [platform/03-data-plane](../platform/03-data-plane.md)

**`capability_honesty`** asserts that what each engine advertises matches what its dispatch
actually implements, so the capability catalogue cannot drift into a lie.

**Go fuzz tests** on the identity path feed arbitrary input rather than chosen cases, and prove
both that a forged header cannot be accepted and that a flag defaulting to off changes nothing
for *any* input. → [security/02-proofs](../security/02-proofs.md)

---

## For the evaluation

"How do you know it works?" is a question this project answers unusually well. The answer is not
"we tested it" — it is a named gate per claim, and the discipline of refusing vacuous passes.
The eight that matter most are on the next page.

---

See also: [02-key-gates](02-key-gates.md) · [security/02-proofs](../security/02-proofs.md)
