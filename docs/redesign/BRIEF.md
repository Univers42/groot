# Website overhaul brief

## Inputs (filled 2026-10-15)

- Product name as users see it: **Prismatica**
- Staging URL the agent may test against: **`https://localhost:4322`**. This is the site served
  by the local stack, with its frontends linked in `direct` mode to the baas grobase over
  Tailscale Funnel at `https://baas.tail10f2ea.ts.net`. The Funnel URL is grobase's API, not the
  site (see DECISIONS.md D-003).
- An inbox you control, for one real end-to-end email check: **not given yet**. It is needed only
  for the Phase 7 manual Titan test.
- Brand rules that must survive the redesign: **none**. The name stays Prismatica; the logo,
  colors and type are open.
- Who the website is for:
  - **Companies** that run on grobase (business to business). They want their data in one place
    and the work between departments orchestrated in one interface, instead of split across
    tools and teams, under honest company policies.
  - **Individuals**, who can also download Prismatica and run it on localhost with a simple
    MongoDB engine, the way people use Obsidian. Code, and a second brain, sit on top.

---

<role>
You are the lead engineer and the design lead on this project. You care equally about craft, evidence and data safety. You work like a senior team. You investigate before you change anything, and you write the plan down before you build. You prove every claim with a screenshot, a test run or a measurement. You leave scripts behind instead of one-off manual steps.
</role>

<context>
Prismatica is a "second brain" app: CRM, notes, a card directory, dashboards, reports and a library, all connected by relations. It runs on Grobase, our backend platform. Grobase has several database engines and its own CLI (`grobase-cli`), which includes a migrator for user data. Confirm all of this in Phase 0. Do not take it on trust.

The public website feels empty and generic. It describes the product in words but never shows it, so it has no personality. The goal is that a first-time visitor understands what the app does, and wants it, within two clicks.

The work has five parts:
1. Redesign the public website so it is distinctive, fast, accessible and animated with purpose.
2. Create a demo account full of realistic, richly related data that exercises every module.
3. Use that account to produce media: JPEG screenshots, animated SVG illustrations and a video tour built with ffmpeg.
4. Make account emails official: email verification and password reset, sent through the Titan mail account already connected in Grobase.
5. Cover all of it with end-to-end tests and measurable quality gates.

You do not know this codebase yet. Before you decide anything, find out everything below that is marked "find out".
</context>

<ground_rules>
- Work in phases. Each phase ends at a gate. At gates marked **STOP**, wait for my approval before continuing.
- Show evidence before claiming success. Never write "done", "fixed" or "passing" without the proof next to it: test output, the path to a Lighthouse report, or the path to a screenshot.
- Turn anything you do twice into a script in the repo. Use the browser MCP tools to explore and iterate. Use committed Playwright scripts for anything repeatable: seeding, capturing, recording and testing.
- Keep a running log in `docs/redesign/DECISIONS.md` of every assumption you make, the option you chose and why. If something is ambiguous but reversible, decide, log it and keep going. If it is irreversible, stop and ask. Irreversible means deleting data, running a production migration, sending email to a real person, or changing DNS.
- Work on a branch named `redesign/<topic>`. Commit after each logical step with a clear message.
- Never weaken, skip or rewrite a test to make it pass. If a test is wrong, explain why in DECISIONS.md before you change it.
- Read secrets from the environment or the Grobase secret store. Never print, log or commit them, and never let them appear in a screenshot. Add only the variable names to `.env.example`.
- Write the tests for each feature in the same phase as the feature. Phase 6 is where the full suite must pass, not where testing starts.
- Repair what you find broken, with a fix that is dynamic and reproducible (derived at runtime or from one source of truth, and committed with a test), never a one-off patch, so the failure cannot come back.
</ground_rules>

<tools>
At the start of Phase 0, check which of these are available and report the result. If one is missing, give the exact install command and wait. Do not silently work around it.

Nothing is installed on the host. Every tool runs from a Docker image the repo owns (`scripts/tools.sh`).

- **Chrome DevTools MCP**: performance traces, Core Web Vitals, network waterfall, console errors, audits.
- **Playwright MCP**: drives the app interactively while you explore and iterate on the design.
- **Playwright test runner** (`@playwright/test`) with `@axe-core/playwright`: committed E2E, accessibility and visual-regression tests.
- **Lighthouse CI** (`@lhci/cli`): scored audits with budgets that fail the build.
- **`frontend-design` skill**: load it before any design work and follow its two-pass process (plan, review the plan against the brief, build, critique).
- **ffmpeg**: assembles and encodes the video. Use **sharp** (or ImageMagick) for image conversion and **SVGO** for SVG.
- **grobase-cli**: schema migrations, the user migrator and seeding.
</tools>

<phase_0_discovery>
This phase is read-only: change no code.

Write `docs/redesign/AUDIT.md` covering the following. Run independent areas (website, Grobase and data, auth and email) as parallel subagents.

- **Stack** (find out): framework, rendering mode (SSR, SSG or SPA), styling system, existing design tokens, component library, motion libraries, build tool, hosting and CI.
- **Website** (find out): every public route, what job it does, its current copy, and what is broken, generic or missing.
- **Grobase** (find out):
  - which database engines are available;
  - how volumes and databases owned by a user are namespaced;
  - how ownership and sharing permissions work;
  - how `grobase-cli` migrations and the user migrator work;
  - what seed scripts already exist;
  - which users and volumes already exist, because you must not touch them.
- **Auth** (find out):
  - how signup, login and sessions work;
  - the current state of email verification and password reset;
  - where the Titan mail connection is configured and how the app reaches it.
- **Baseline measurements**, for every public page on both mobile and desktop:
  - all four Lighthouse category scores;
  - LCP, CLS and INP/TBT;
  - JS, CSS, image and font weight;
  - console errors and axe violations.

  Save the raw reports in `docs/redesign/baseline/`.
- **"Before" screenshots** of every public page at 390, 768 and 1440 px wide.

Gate: AUDIT.md is complete.
</phase_0_discovery>

<phase_1_plan>
Write `docs/redesign/PLAN.md` with these sections:

1. **The story.** In at most 120 words, describe the narrative the site tells. Then define the two-click path:
   - what a visitor sees on arrival;
   - what the first click reveals (for example, the video tour or a live product walkthrough);
   - what the second click does (sign up, or try the demo).

   Every section of the site must earn its place in this story.
2. **Design direction**, following the `frontend-design` skill's two passes:
   - palette: 4–6 named hex values, for both light and dark themes;
   - typefaces, their roles and the type scale;
   - a layout concept, with ASCII wireframes for the hero and two key sections;
   - principles, and the one memorable element.

   Then write the self-review: what looked generic and what you changed.
3. **Motion plan.** List every animation with its trigger, purpose, duration, easing and reduced-motion fallback. Use one orchestrated moment on page load. Everything else should either respond to the user or follow scroll position with a clear purpose. Scattered fade-ups on every section read as templated, so avoid them.
4. **What the best product sites do well.** Pick 4–6 current product websites known for craft. Inspect them with the browser tools and write down the principles they share. Examples of principles: the product is shown rather than described; real UI is the hero; motion explains state; there is restraint everywhere except one place. Borrow principles only. Do not borrow layouts, assets, code or copy.
5. **Demo persona and data model.** See `<demo_account>`.
6. **Media plan:**
   - a shot list that gives the screen, the state and the story beat for each shot;
   - a list of the animated SVG illustrations;
   - a video storyboard with timings.
7. **Email plan.** See `<email>`.
8. **Test plan and quality budgets.** See `<testing_and_quality_gates>`.
9. **Risks and open questions**, each with your recommended answer.

**STOP.** Wait for my approval before Phase 2.
</phase_1_plan>

<demo_account>
**Persona.** Choose one coherent person whose week touches every module, so that the screenshots read as a story rather than a feature list. Propose two personas in PLAN.md.

For example: the founder of a small specialty-coffee roastery who is also finishing a certificate at an academy. Wholesale clients and suppliers fill the CRM. The roastery fills the business dashboard. The coursework fills the academy notes. The founder's reading fills the library.

**Modules and volumes.** Adjust these to what the app actually supports. Never put features in the data that the app cannot display.

- **Home:** a personal dashboard that pulls from every module below.
- **CRM:**
  - about 60 companies, about 220 contacts, about 80 deals across every pipeline stage (including won and lost), and about 700 interactions (calls, emails and meetings) with notes;
  - contacts link to companies many-to-many, each link with a role;
  - deals link to contacts, companies, notes and tasks.
- **Card directory:** card-based views over the data, with filters, facets, sorting and saved views. Include several card formats or templates: person, company, lecture note, case study and flashcard.
- **Academy notes:**
  - about 120 notes across 5–6 subjects, each signed and attributed to its subject and course;
  - backlinks to library items, to contacts (for example, guest lecturers) and to the business decisions each note informed.
- **Business:**
  - 18 months of operations ending today: orders, invoices, products, inventory and expenses;
  - believable seasonality, including a couple of bad months;
  - KPIs that reconcile, meaning dashboard totals equal the sum of the underlying records.
- **Reports and dashboards:** about 10 saved reports and at least 6 dashboards or views (table, board, gallery, calendar, timeline and chart) that look good in screenshots.
- **Library:** about 250 books, articles, papers and files, tagged and linked to notes.
- **Relations:** an average of at least 3 links per record, no unintended orphans, and a few "hub" records that make the relations view striking.

**Rules:**
- The data is fictional but realistic. Use no real person's personal data and no real company's confidential data. Use email addresses on `example.com`, `.test` or our own domain, and phone numbers in fictional ranges.
- The seed is deterministic: use a seeded random generator with a fixed seed. Make dates relative to the run date so the data never looks stale.
- Use each Grobase database engine where it naturally fits the data. In PLAN.md, map each dataset to an engine and give the reason. Do not force data into an engine just to use it.
- **Isolation.**
  - Namespace every volume and database for the demo user to that user, so nothing collides with existing ones.
  - Only the owner can read them, unless something is shared through the app's permission system.
  - Include one item shared with a second demo user, to show permissions in action, and test it.
- **Migrations go through `grobase-cli` and its user migrator only.**
  - Migrations are versioned, checksummed and reversible (up and down).
  - Schema changes are kept separate from seed data.
  - Do a dry run first and show the diff.
  - Run against local or staging. Run against production only after my explicit approval.
- **The seed is idempotent:** running it twice changes nothing. Provide three commands:
  - `seed:demo` creates the data.
  - `seed:demo:verify` checks counts, referential integrity, KPI reconciliation and isolation.
  - `seed:demo:reset` removes only the demo users' data. Before it deletes anything, it must list exactly what it will delete.
- Create the demo user already verified. Keep its credentials in the environment, not in code.
</demo_account>

<website>
- **Show the product; don't describe it.** The hero and key sections use real captures from the demo account (made in Phase 4), not stock images or abstract blobs.
- **Copy.** Write plain, specific copy in sentence case, for the audience above. Do not invent testimonials, customer logos, user counts or press quotes. If there is no social proof yet, leave it out.
- **Motion.**
  - Use CSS and the Web Animations API first.
  - Use View Transitions and scroll-driven animations (`animation-timeline`), with graceful fallbacks for browsers that lack them.
  - Add a motion library only if it clearly earns its bytes. If the project already uses one, use that one.
  - Animate only `transform` and `opacity`.
  - Every animation respects `prefers-reduced-motion`.
- **Performance.**
  - Fonts are self-hosted and subset, and the critical face is preloaded.
  - Images are responsive: AVIF or WebP with a JPEG fallback, `srcset` and `sizes`, and explicit width and height.
  - Video is lazy-loaded with a poster and `preload="none"`. A hero loop, if used, is at most 1.5 MB.
  - Fonts, images and embeds cause no layout shift.
  - Keep third-party scripts to a minimum.
- **Accessibility.**
  - Use semantic landmarks, exactly one `h1`, visible focus and full keyboard navigation.
  - Meet AA contrast in both themes.
  - Video has captions.
  - Alt text says what each screenshot shows.
- **SEO.**
  - Every page has a title, a meta description and a canonical URL.
  - Open Graph and Twitter images are generated from the captures.
  - Include a sitemap, `robots.txt`, and `SoftwareApplication` and `VideoObject` structured data.
- **Iteration loop.** After each section:
  1. Take screenshots at 390, 768 and 1440 px, in both light and dark themes.
  2. Compare them against PLAN.md and write a three-line critique.
  3. Fix what the critique found.

  Repeat at least twice. Before you call a section done, remove one decorative element that isn't earning its place.
</website>

<media>
**Screenshots**
- `scripts/media/capture.ts` (Playwright) logs in as the demo user and walks the shot list.
- Captures are deterministic:
  - the clock is frozen with `page.clock`;
  - viewports are fixed: 1440×900 at deviceScaleFactor 2, plus 390×844 for mobile;
  - fonts are loaded and the network is idle before each capture;
  - animations are disabled for stills;
  - no cursor, scrollbars, devtools or toasts appear;
  - no secrets or real email addresses are visible.
- Save the masters as JPEG at quality 85 in `media/screenshots/`, in light and dark. Generate AVIF and WebP versions for the site.

**Animated SVG**
- Hand-build illustrations that tell part of the story. Examples: relation lines drawing between a contact, a deal and a note; a card filtering into a saved view.
- Animate with CSS or SMIL and optimize with SVGO, to at most 40 KB each.
- Each has a static fallback frame for reduced motion, plus a `<title>` and a `<desc>`.

**Video tour**
- Write the storyboard in PLAN.md first: 60–90 seconds, 5–7 scenes that follow the story, one idea per scene.
- Record each scene with Playwright, using `recordVideo`, or a frame-sequence capture if you need smoother motion. Script the interactions at a human pace.
- Assemble the video with ffmpeg in `scripts/media/build-video.sh`: join the scenes with short crossfades, add title cards and keep the pacing consistent.
- Export:
  - MP4 (H.264, yuv420p, `-movflags +faststart`) at 1080p;
  - WebM (VP9 or AV1);
  - a poster JPEG;
  - an 8–10-second silent loop for the hero;
  - WebVTT captions;
  - a chapters file;
  - a plain-text transcript.

  The captions, chapters and transcript let people and research or AI tools read the tour, not only watch it.
- Use music only if it is royalty-free, and record the license in DECISIONS.md. Otherwise, keep the video silent.
</media>

<email>
Titan mail is already connected in Grobase. Use it to make account emails official.

- Build email verification on signup, and password reset (forgot password, then email, then set a new password).
- Read SMTP settings and credentials from the existing Grobase config or the environment. Titan's SMTP host is usually `smtp.titan.email` on port 465 (SSL) or 587 (STARTTLS), but confirm this against the existing config rather than assuming it.
- **Tokens.**
  - Tokens are cryptographically random, single-use and stored hashed.
  - Verification tokens expire after 24 hours and reset tokens after 30–60 minutes.
  - Tokens are invalidated once used.
  - A password reset signs out all other sessions.
- **No account enumeration.** Return the same response, in similar time, whether or not the email exists. Rate-limit requests per IP address and per account.
- **Templates.** Branded HTML templates that match the new design, each with a plain-text version. The From name and address use the product domain. Build links from the configured app URL.
- **Deliverability.** Check SPF, DKIM and DMARC for the sending domain. Report anything missing with the exact DNS records needed. Do not change DNS yourself.
- **Testing.** Tests send to a local mail catcher such as Mailpit, never through Titan. At the very end, and only with my approval, send one manual test through Titan to the test inbox above.
</email>

<testing_and_quality_gates>
**E2E tests (Playwright).** They must run both locally and in CI.

- **Signup:** sign up, receive the verification email, verify, log in.
- **Password reset:**
  - request a reset and receive the email;
  - the new password works and the old one fails;
  - old sessions are signed out;
  - expired and reused tokens are rejected.
- **Demo account:**
  - key screens render with the seeded data;
  - a second user cannot read any demo volume;
  - a shared item becomes visible after sharing and disappears after access is revoked.
- **Seed:** running it twice changes nothing, the verify script passes, and reset removes only demo data.
- **Website:**
  - navigation and the two-click path work;
  - the video plays with captions;
  - reduced motion turns off non-essential animation;
  - there are no console errors;
  - axe reports zero serious or critical violations;
  - visual-regression snapshots exist for every section at all three widths.

**Budgets.** Lighthouse CI enforces these on every public page, using mobile default throttling unless stated otherwise:

| Metric | Budget |
| --- | --- |
| Performance | ≥ 90 on mobile, ≥ 95 on desktop |
| Accessibility | 100 |
| Best Practices | 100 |
| SEO | 100 |
| LCP | ≤ 2.5 s on mobile (aim for 2.0 s) |
| CLS | ≤ 0.05 |
| TBT | ≤ 200 ms |
| Initial JS on the landing page | set in PLAN.md from the baseline (target ≤ 150 KB gzipped), then enforced |

If a budget cannot be met, say which one, why, and what you would trade to meet it. Do not quietly lower it.
</testing_and_quality_gates>

<phase_sequence>
- **Phase 0:** Discovery and baseline. Read-only. Ends when AUDIT.md is complete.
- **Phase 1:** Plan. **STOP** for approval.
- **Phase 2:** Demo account and data: migrations, seed, verify and reset, with their tests. Run against local or staging only.
- **Phase 3:** Design system and site structure. Build the tokens, type, layout and sections, using placeholder frames where media will go. This phase can run in parallel with Phase 2.
- **Phase 4:** Media. Produce the screenshots, SVG and video from the demo account, then put them into the site and finish the motion work.
- **Phase 5:** Email flows: verification, reset and templates, with tests against the mail catcher. This phase can run in parallel with Phases 2–4.
- **Phase 6:** Quality gate. The full E2E suite passes, Lighthouse CI meets every budget, and axe is clean.
- **Phase 7:** Report. **STOP** before the production migration and before the real Titan email test.
</phase_sequence>

<final_report>
Write `docs/redesign/REPORT.md`, and keep it short. Include:
- a before-and-after table for every metric;
- before-and-after screenshots side by side;
- what changed;
- the commands that reproduce everything (seed, capture, video and tests);
- what is left, and the recommended next steps.
</final_report>
