# graph-studio contract

What osionos relies on from graph_render's `<graph-studio>`, pinned at groot's `apps/graph_render`
gitlink. CI: `.github/workflows/graph-studio-contract.yml`.

| File | What it does |
|---|---|
| `extract.mjs` | reads the contract out of graph_render's sources: tag, attributes, `HOST_API`/`ABI_VERSION`, host members, events, the `loadGraph` rejection name, the ingest schema and its refusals. Every leaf is `{ value, at: "path:line" }` |
| `contract.json` | its output at the gitlink. Generated, never edited by hand |
| `check.sh` | regenerates and compares: `VALUES CHANGED` (the contract moved) or `CITATIONS ONLY` (the code moved). Either kind of diff fails |
| `static.bats` | `check.sh` at the gitlink, plus negative controls that must bite |
| `fetch-pack.sh` | pulls the pack `app.Dockerfile` pins, by digest, without docker, and checks every byte and `source_rev` |
| `../e2e/graph-studio/` | the runtime half: the pack in Chromium, with expectations read from `contract.json` |

Run them locally (graph_render clone at `$GR_SRC`):

    GR_SRC=~/recon/graph_render bats tests/graph-studio-contract
    tests/graph-studio-contract/fetch-pack.sh /tmp/gs-pack
    cd tests/e2e && GS_PACK_DIR=/tmp/gs-pack GS_PIN=$(git ls-tree HEAD ../../apps/graph_render | awk '{print $3}') \
      npx playwright test -c graph-studio.config.ts

## Bumping the pin

In the same commit as the new gitlink and `GRAPH_STUDIO_PACK`, regenerate the contract:

    node tests/graph-studio-contract/extract.mjs --git $GR_SRC --rev <new sha> > tests/graph-studio-contract/contract.json

Read the diff first. If `check.sh` said `CITATIONS ONLY`, the bump is free. If it said `VALUES
CHANGED`, the osionos adapter has work to do.

To see what a branch would change without bumping, run a drift report (exit 3 marks a rule that
matched nothing):

    tests/graph-studio-contract/check.sh --git $GR_SRC --rev origin/develop
    node tests/graph-studio-contract/extract.mjs --lenient --git $GR_SRC --rev origin/develop

The extractor uses line regexes, not a parser. A contract spelled in a new way makes it exit 2 and
name the rule that broke; it never reports a quietly different value. When that happens, fix the
rule and regenerate.
