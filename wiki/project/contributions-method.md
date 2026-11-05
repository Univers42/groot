# How the contribution counts are made

The README's [Features](../../README.md#-features-and-who-built-them) and [Who committed
where](../../README.md#who-committed-where) count commits one way, described
here with the identity joins it rests on.

## The method

Non-merge commits reachable from the commit groot `main` pins for each
repository, read through the root [`.mailmap`](../../.mailmap), with bots and
AI-agent identities left out:

```sh
# for the root repository, use origin/main itself as the pin
pin=$(git ls-tree origin/main apps/osionos/app | awk '{print $3}')
git -C apps/osionos/app -c mailmap.file="$PWD/.mailmap" \
  log --no-merges --format='%aN' "$pin" -- <paths> |
  grep -viE 'bot|AI agent' | sort | uniq -c | sort -rn
```

Counted on 2026-11-05, groot `main` = `0bef3cb3`. Repositories: groot, osionos,
grobase, opposite-osiris (prismatica), hydrawn, mail, calendar, QA, monkey-bot.

Caveat: a commit count is not effort. One large commit and one typo fix weigh
the same; pairing, review and work committed by someone else do not show; a
commit that touches several features counts once for each. Work that is not on a
pinned commit (an open branch, an unmerged pull request) is not counted.

`scripts/contributors.sh` counts all refs (`--all`), not the pins. Until a clone
drops the refs from before the 2026-11-04 history rewrite, `--all` counts each
rewritten commit twice.

## Left out of the counts

At the pins, on 2026-11-05:

- `Space Bunny` (also `bunny` and `builder`): an AI-agent identity. Its
  addresses are local (for example `bunny@local`, `builder@bunny`,
  `bunny@drawnosaurus.local`) and hydrawn `BUNNY.md` describes a team of agents.
  Who ran it is not identified. 68 hydrawn commits.
- `opencode`: an AI-agent identity committing under its own name. Who ran it is
  not identified. 1 root and 5 osionos commits.
- Bots: `dependabot[bot]` 8 root; `coderabbitai[bot]` 3 root and 4 osionos;
  `Grok CI Bot` 2 root; `copilot-swe-agent[bot]` 9 opposite-osiris.

## How the identities are joined

The evidence for each join is in [`.mailmap`](../../.mailmap).

- Each member committed under several addresses, including GitHub's `noreply`
  ones; `.mailmap` joins them.
- `settes <ioanaroxana.st@…>` is **`rstancu`** (Roxana Stancu): the address
  belongs to GitHub account [@esettes](https://github.com/esettes), listed for
  `rstancu` on the original roster
  ([`archive/wiki-2026-09/CONTRIBUTORS.md`](../../archive/wiki-2026-09/CONTRIBUTORS.md)).
  The osionos commits (2026-04-10 → 2026-05-02) touch mostly the Playwright
  browser tests (`tests/browser`), their CI job and committed build assets.
  `rstancu` is a former member (README, Team Information).
- `La Cebolla <smhashem545@…>` is **`shashemi`**: opposite-osiris commit
  `93e6b65` carries `Signed-off-by: Seyed Mostafa Hashemian`.
- `SMOSTAFAH1 <SMOSTAFAH1@users.noreply.github.com>` is **`shashemi`**: it is
  the GitHub login [@SMOSTAFAH1](https://github.com/SMOSTAFAH1) of the team
  table, without the numeric id `.mailmap` already maps (2 osionos commits at
  the pin).
- Two groups of grobase commits pair one member's name with another's address.
  They are attributed by inference, not by proof:
  - `LESdylan <vjannieto@…>` (3 commits on grobase's pinned commit, 5 on all
    branches, 2026-09-21 → 2026-11-02) goes to `dlesieur`: the author name is
    `LESdylan`, and `b4c1d33f` landed through grobase PR #89, opened by
    `LESdylan`.
  - `dlesieur <daniel17dev@…>` (5 commits, 2026-03-20/21) goes to `danfern3`:
    they sit inside `danielfdez17`'s own Docker and Kubernetes series of the
    same two days.
- `opencode` and `Space Bunny` are AI-agent identities, shown under their own
  names and left out of the member counts (list above).
- `qwO-Owp` (born2root, 2026-10-08/09) is unidentified: no address, sign-off or
  pull request ties it to anyone.
- `Alex Caceres` (vendor/scripts, 2026-01-26) is a former member (team answer,
  2026-11-05).
- Neither born2root nor vendor/scripts is counted.
- On 2026-11-04 the history of groot, osionos and grobase was rewritten to
  remove `Co-authored-by` trailers; trees, authors, dates and subjects are
  unchanged, and every commit from the first rewritten one onward has a new SHA.
  148 root commits on `main` have a one-word subject (147 `dlesieur`, 1
  `vjan-nie`, 2026-05-01 → 2026-10-09); the [`Commit
  subjects`](../../.github/workflows/commit-subjects.yml) check refuses new
  ones.
