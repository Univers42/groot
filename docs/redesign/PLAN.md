# Phase 1 plan — the Prismatica website, demo account, media and email

Written 2026-10-15 for [BRIEF.md](BRIEF.md), on the evidence in [AUDIT.md](AUDIT.md). Every
assumption is logged in [DECISIONS.md](DECISIONS.md) (D-015 onwards). **Nothing in this plan is
built yet.** Phase 2 starts only after approval of this plan, with the devil's conditions in §9.

---

## 1. The story

> Most companies do not lack data; they keep five copies of it. Sales has the customer in a CRM,
> finance has them in invoices, operations in a spreadsheet, and what the team learned sits in
> someone's notes. Each department is right about its own copy, and nobody sees the whole.
> Prismatica keeps pages, databases and the links between them in one workspace. A customer, their
> deal, the invoice and the note that changed a decision become one linked record that every
> department reads. Teams run it on grobase; one person can run it on their own machine. The site
> follows one real week of one operations director, lets you watch it, then lets you start your
> own.

(113 words.)

**The two-click path.**

| Step | What the visitor sees or does | What it proves |
|---|---|---|
| Arrival | `h1` "One workspace for every department." A one-line subhead names the four things it links. The real Home dashboard of the demo account sits under it, as a flat 1:1 capture. One primary button ("Watch the 75-second tour") and one text link ("Create a workspace") are shown. | The product is real and the claim is specific. |
| Click 1 | The tour opens in a `<dialog>`: the video, with captions on and a chapter list beside it. The file is fetched only on this click (`preload="none"`). Under the player: "Create your workspace". | It shows the whole week in 75 seconds, without sign-up. |
| Click 2 | "Create your workspace" opens sign-up (§7). After email verification it lands in osionos. | It converts. |

**Every section earns its place in the story**, or it is cut:

| # | Section | Story beat | Replaces |
|---|---|---|---|
| 1 | Hero | The claim, and the product as proof | `HeroNew`, `LogoStrip` (invented logos, R8) |
| 2 | "One customer, five copies" | The problem: the silo, drawn (SVG V2) | `FeatureTrio` |
| 3 | "One record every department reads" | A contact page, with relations to deals, invoices and notes (capture S2 and SVG V3) | `CanvasWindowsSection` |
| 4 | "Views, not copies" | One dataset shown as a table, a board, a calendar and a chart (S4–S7) | — |
| 5 | "What you learn, next to the work" | An academy note linked to the decision it informed, plus the graph view (S8, S9) | — |
| 6 | "Run it where you work" | Hosted on grobase for teams, or local for one person, with honest requirements (§9 Q1) | `BackendArchitecture`, `Pricing` (unbacked claims, R8) |
| 7 | "What it is, plainly" | Open source, the engines, and what is **not** done yet | `FaqSection` (unbacked claims), `SocialProof` (invented testimonials, R8) |
| 8 | Final call to action and footer | Click 2 again | `FinalCta`, `FooterNew` |

Removed outright: `MascotDock` and `mascot.ts` (506 lines on every page), the `premium.ts`
tilt and magnetic effects, the scroll-reveal fade-ups (the blank-below-the-fold defect), the
cookie banner (§9 Q5), and the `DocsTeaser` card. Docs stay in the header and footer.

---

## 2. Design direction

### 2.1 Palette

Six named values per theme. Contrast was computed with the WCAG 2.x formula
(`scripts/tools.sh node`; the numbers are reproduced in D-017). Light is the default, and dark
follows `prefers-color-scheme` or the toggle. The full palette is defined on `:root`; dark
overrides only these tokens.

| Token | Role | Light | Dark | Contrast (light / dark) |
|---|---|---|---|---|
| `--paper` | Page ground | `#F6F5F1` | `#111114` | — |
| `--raised` | Cards, the dialog, captures' frame fill | `#FFFFFF` | `#1A1A1F` | — |
| `--ink` | Text, primary button fill | `#15151A` | `#ECEAE4` | 16.7 / 15.7 on paper |
| `--graphite` | Secondary text, **form-field borders** | `#56565F` | `#A3A2AB` | 6.7 / 7.5 on paper |
| `--rule` | Hairlines and section dividers (decorative only) | `#DCDAD2` | `#2C2C33` | 1.3 / 1.4: never a control boundary |
| `--signal` | Links on hover, the focus ring, the converged beam | `#B93A0C` | `#FF8A4C` | 5.2 / 8.1 on paper |

The text colour on a `--signal` fill is `--paper` in both themes (5.2 / 8.1). Rule 1.4.11 asks
3:1 for control boundaries, so inputs take `--graphite`, never `--rule`.

**The spectrum ramp** is an illustration-only ramp of six hues, one per department, that exists
only inside the hero's convergence SVG (V1) and the silo SVG (V2). It is never text, never a
state, and never a background. It is defined in the SVGs, not as site tokens, so it cannot leak
into UI.

### 2.2 Type

| Role | Face | Source | Sizes (fluid `clamp`) |
|---|---|---|---|
| Display: `h1`, `h2` | Instrument Serif, regular (italic for one emphasised word, at most once per page) | Already self-hosted (`public/fonts/instrument-serif.woff2`, 21 KB), subset to Latin, **the only preloaded face** | `h1` 2.75 → 5.25 rem, `h2` 2 → 3.25 rem |
| Text and UI | The system UI stack (`system-ui, -apple-system, "Segoe UI", Roboto, sans-serif`) | No download | 1.0625 rem body, 1.25 rem lead, 0.875 rem small |
| Data and labels | `ui-monospace, "SF Mono", Menlo, Consolas, monospace` | No download | 0.8125 rem, uppercase never |

The current site loads 84 KB of fonts on every page: Space Grotesk and Instrument Serif are both
preloaded (`Layout.astro:85-86`), plus JetBrains Mono. The plan loads one subset face of about
12–15 KB. Caveat, Special Elite and Architects Daughter (141 KB on disk) leave the site with the
mascot.

The body measure is 62ch, with line height 1.55 for body and 1.05 for display. The scale has
three steps per section: display, lead and body.

### 2.3 Layout concept

- **Grid:** the content column is 68 rem max with a 12-column grid inside it. Captures may break
  out to 80 rem. The side gutter is `max(1rem, 4vw)`. The spacing scale is 4/8/12/16/24/32/48/64/96/128
  px, and nothing sits off it.
- **Captures are the hero, and they are flat:** shown 1:1 in a `--raised` frame with a hairline
  border, never tilted, never glowing. Every capture has width and height attributes, AVIF and
  WebP sources with a JPEG fallback, `srcset` at 1×/2×, and alt text that says what is on screen.
- **Alternation:** text and capture alternate left and right from section 3 to section 5 at
  ≥ 64 rem, and stack text-then-capture below it.

**Hero (1440 and 390):**

```
1440 ───────────────────────────────────────────────────────────────────────────────────────────
 Prismatica        Product  Docs  Run locally                          Sign in  [Create workspace]
───────────────────────────────────────────────────────────────────────────────────────────────
        ╲  ╲  ╲                                                                                    
          ╲  ╲  ╲  ╲      One workspace for                                                         
  ════════════════════►   every department.                       (h1, Instrument Serif)           
          ╱  ╱  ╱  ╱                                                                                
        ╱  ╱  ╱           Customers, orders, invoices and what your team learns —                  
   (V1: six department     linked in one place instead of copied across five tools.               
    lines converge)                                                                                 
                          [▶ Watch the 75-second tour]   Create a workspace →                     
        ┌──────────────────────────────────────────────────────────────────────────┐              
        │  (S1) Home dashboard — Inès's Monday: sales, stock, invoices, coursework │  ← the beam  
        │  real capture, 1:1, hairline frame, fetchpriority=high                   │    ends here 
        └──────────────────────────────────────────────────────────────────────────┘              

390 ──────────────────────────────
 Prismatica             [≡]  [Sign in]
──────────────────────────────────
 One workspace for
 every department.

 Customers, orders, invoices and
 what your team learns — linked in
 one place.

 [▶ Watch the 75-second tour]
 Create a workspace →
 ┌────────────────────────────┐
 │ (S1-mobile) Home, 390 crop │
 └────────────────────────────┘
```

**Section 3, "One record every department reads":**

```
┌────────────────────────────────┐   ┌──────────────────────────────────────────────┐
│ One record every               │   │ (S2) Contact page: Marc Delorme, buyer        │
│ department reads.              │   │   ├─ Company: Hôtel Varenne  (role: buyer)    │
│                                │   │   ├─ Deals: 3 (1 won, 1 open, 1 lost)        │
│ Sales sees the deal. Finance   │   │   ├─ Invoices: 7                             │
│ sees the invoice. Operations   │   │   └─ Notes: "Switch supplier" — informed by  │
│ sees the order. It is the same │   │        lecture note "Dual sourcing"          │
│ record, so nobody re-types it. │   └──────────────────────────────────────────────┘
│                                │          ↑ V3 relation lines reveal with scroll
│ ● 3.1 links per record on      │
│   average in this demo         │   (the number is computed by seed:demo:verify,
│   (measured, not claimed)      │    never typed into the copy)
└────────────────────────────────┘
```

**Section 4, "Views, not copies":**

```
                 Views, not copies.
   The same 80 deals, four ways. Pick one: nothing is exported or re-entered.

   ┌ Table ┐┌ Board ┐┌ Calendar ┐┌ Chart ┐         ← real tabs (role=tablist), arrow keys move
   └───────┘└───────┘└──────────┘└───────┘
   ┌──────────────────────────────────────────────────────────────────────────┐
   │ (S5 / S4 / S6 / S7) the selected view, swapped with a View Transition    │
   └──────────────────────────────────────────────────────────────────────────┘
   Saved view: "Open deals over €5k, by owner", with filter chips shown in the capture
```

### 2.4 Principles

1. **Show, then say.** Every claim sits next to the capture that proves it. A claim with no
   capture is cut.
2. **One primary action per viewport.** The other action is a text link (§4: Raycast,
   Obsidian and Things keep 0–2 filled controls in the first viewport; Stripe and Attio keep 5–6).
3. **Restraint everywhere except one place:** colour and motion are spent on the convergence,
   and nowhere else.
4. **Numbers come from the data:** any figure in the copy is computed by `seed:demo:verify` and
   injected at build time, or it is not printed.
5. **Nothing waits for JavaScript to be seen.** The page is complete with JS off and with
   reduced motion; JS adds the dialog, the view switcher and the theme toggle.

### 2.5 The one memorable element

**The convergence.** Six thin lines, one per department colour, enter from the left edge, bend
through a point and leave as one `--signal` beam that ends on the hero capture's frame. It is
the name (a prism, run backwards) and the story (separate departments, one record) in one image.
It plays once on load and never loops. It is inline SVG under 4 KB, animated with `transform`
only, and with reduced motion it is the finished drawing.

### 2.6 Self-review — the two passes

**Pass 1 draft, and what read as generic:**

| Pass 1 had | Why it is generic (evidence) | Pass 2 changed it to |
|---|---|---|
| Near-black ground, violet accent, Inter everywhere | 4 of the 6 reference sites ship exactly this (dark ground; Inter or a close grotesk; measured fonts in `references.json`) | A light paper ground first (dark is an equal theme, not the identity), a serif display, and a vermilion signal used only for interaction |
| A tilted screenshot with a glow behind it | Decoration that hides the UI at the size where it should be read | Flat 1:1 captures in a hairline frame |
| Three icon cards ("Fast / Secure / Open") | Describes, and shows nothing | Each section is built on one capture and one story beat |
| A logo strip and a quote carousel | There is no proof yet; the brief forbids inventing it | Deleted. Section 7 says plainly what exists and what does not |
| Fade-up on every section | Scattered motion reads as a template (brief); it already blanks the page today (AUDIT §3) | One orchestrated moment, plus two scroll-linked diagrams that explain something |

**Pass 2, through the design-review lenses:**

- **Hierarchy:** the hero had two filled buttons (tour, sign up), so the second became a text
  link. The header keeps one filled button.
- **Rhythm:** section padding was 120/80 px in the draft, which is off the scale. It is now
  128/96 at ≥ 64 rem and 64/48 below.
- **Type:** the draft used five sizes in the hero; it now uses three.
- **States** that the draft did not have:
  - the video fails to load → the poster stays, with "Download MP4" and "Read the transcript"
    links;
  - JS is off → the tour button is a plain link to the MP4 page (`/tour`);
  - a slow network → the capture reserves its box (`aspect-ratio`) and shows the AVIF progressively;
  - the view switcher with JS off → all four captures stack, labelled.
- **Consistency:** one frame style for every capture; three button styles (primary filled,
  secondary outline, text link); sentence case everywhere.
- **Removed as decoration:** the eyebrow numerals ("01 — …") on every section.

---

## 3. Motion plan

The rules:
- Only `transform` and `opacity` are animated. Hover colour changes are an overlay's opacity,
  never a `color` transition.
- Each animation checks `prefers-reduced-motion`, and CSS-only animations sit inside
  `@media (prefers-reduced-motion: no-preference)`.
- **No motion library.** The site has none today (AUDIT §2), and nothing below needs one.

| # | Animation | Trigger | Purpose | Duration | Easing | Fallback without support | Reduced motion |
|---|---|---|---|---|---|---|---|
| M1 | **The convergence** (the one orchestrated moment) | Page load, once | The name and the story in one image | 900 ms total, lines staggered 60 ms, then the beam 240 ms | `cubic-bezier(.2,.7,0,1)` | — (CSS animation is universal) | The finished drawing, static |
| M2 | Silo merge (SVG V2): four department copies of one contact card slide together into one | Scroll position, `animation-timeline: view()`, range `entry 20%` → `cover 55%` | Shows the problem and the fix as one motion | Bound to scroll | linear (scroll is the easing) | Without `animation-timeline` support (`@supports`): the merged state plus a static "before" thumbnail | Before and after side by side, static |
| M3 | Relation lines (SVG V3) reveal along the contact page capture (`scaleX` from the origin card) | Scroll position, as M2 | Shows which records the contact links to | Bound to scroll | linear | All lines drawn | All lines drawn |
| M4 | View switcher swap | Click or arrow key on a tab | Shows that the data stays and only the view changes | 220 ms | `ease-out` | Instant swap (no `startViewTransition`) | Instant swap |
| M5 | Tour dialog open and close | Click | Ties the player to the button that opened it | 160 ms open, 120 ms close | `ease-out` / `ease-in` | Instant | Opacity only, 0 ms |
| M6 | Buttons and linked cards: an overlay at 0 → 0.08 opacity; cards `translateY(-2px)` | Hover, never focus | Affordance | 120 ms | `ease-out` | — | Overlay only, no movement |
| M7 | Theme change crossfade | Toggle | Avoids a flash between themes | 200 ms | `ease-out` | Instant | Instant |
| M8 | Tour loop (8–10 s, silent) in section 4's aside, **not in the hero** | Autoplays only while ≥ 50 % visible; a visible pause button (WCAG 2.2.2) | Shows motion in the product itself | Loop | — | The poster still | Poster only, never autoplays |

Focus is never animated: the ring appears instantly at 2 px `--signal` with a 2 px offset.

---

## 4. What the best product sites do well

**How measured.** `scripts/reference-sites.mjs` ran in `groot-tools` Chromium on 2026-10-15
against six sites, at 1440×900 and 390×844, with and without reduced motion. It recorded the `h1`,
the first-viewport media, the filled controls, the fonts, the bytes by type over the first 8 s,
and `document.getAnimations()` before and after a scroll. The measurements are in
[`references.json`](references.json). The screenshots stayed in a git-ignored folder, because
they are third-party assets. Principles only were taken; no layout, asset, code or copy.

| Site | First viewport | Filled controls (1440) | JS KB | Animations (scrolled / reduced) | What it does well |
|---|---|---|---|---|---|
| Linear | Its own issue view, in app chrome, under a two-line `h1` | 1 (Sign up) | 1537 | 522 / 101 | The real UI is the hero, with live-looking data in it |
| Obsidian | The app itself: note, graph and phone, under a 3-word `h1` | 1 (platform-detected: "for Linux (AppImage)") | 169 | 0 / 0 | One action, tailored to the visitor; zero motion; the product does the talking |
| Things | The app icon, one paragraph, "Watch Introduction Video" | 0 | 63 | 0 / 0 | **The first click is a video.** The calmest page in the set, and the lightest |
| Raycast | A 4-word `h1` and one sentence, then "Download for Mac", with the system requirement printed in mono under it | 2 | 1321 | 55 / 55 | Honesty at the point of action: what you need, said before you click |
| Stripe | A long `h1` over its gradient; real customer logos | 5 (+ cookie banner) | 1342 | 90 / 1 | One memorable element (the gradient), and the best reduced-motion handling in the set (90 → 1) |
| Attio | **Blank for 8 s:** the hero waits for JS; the cookie banner covers the UI | 6 | 3509 | 24 / 1 | The counter-example: a JS-gated hero is an empty page to anything that does not run it |

**The shared principles we take:**
1. **Real UI is the hero.** Linear and Obsidian put the product, with believable data, in the
   first viewport. Mockups and illustrations sit around it, not in place of it.
2. **One primary action, specific to the visitor.** Obsidian names your platform, and Raycast
   prints the requirement under the button. Our version: "Watch the 75-second tour" says the
   length.
3. **Video as the first click** (Things): the calmest way to show a whole workflow without asking
   for anything.
4. **One memorable element, restraint everywhere else** (Stripe's gradient; Obsidian's graph).
5. **Calm is cheap.** The two sites with zero animations are also the two lightest (63 and 169 KB
   of JS). The two heaviest run 24–522 animations.
6. **Reduced motion is a real mode** (Stripe drops 90 animations to 1). Linear still runs 101 of
   522, and we hold the stricter line.
7. **Never gate the first paint on JavaScript.** This is Attio's measured blank hero, and the
   same failure as our own opacity-0 sections (AUDIT §3).

---

## 5. Demo persona and data model

### 5.1 What the app can actually hold and show

This section extends AUDIT §4.4. It was found by a read-only subagent, and the claims cite osionos
fabe846b. **NDS** is the `notion-database-sys` submodule; **GB** is grobase.

| Fact | Evidence | Consequence for the seed |
|---|---|---|
| A user object database is **one JSONB blob** (schema, views and every row). The bridge caps a write at 6 MiB, with a 2.5 s PostgREST timeout. The client also mirrors it in localStorage, whose shared quota is about 2.62 M characters; past it the user sees "Browser storage is full" | `bridge-api.mjs:93,96,3243-3268`; `knownDatabaseStorage.ts:13-50` | Object databases hold **small** sets only (≤ ~300 short rows each, ≤ 1.5 MB in total across the demo). 18 months of orders cannot live there |
| **Database blocks can display a grobase mount:** `baas:<dbId>:<table>` through the query-router; postgres, mysql and mongodb are seeded today. A mount is linked to a workspace by a `osionos_workspace_databases` row, and created only through `/admin/v1/databases` (no UI) | `DataSourcePicker.tsx:12-17`; `bridge-api.mjs:2512-2519,2795-2930`; GB `osionos-extra-engines.sh:115-125` | Volume data goes in mounts, one engine per natural fit. **Unproven:** which view types (board, calendar, chart) and which relations a mount-backed block supports. Phase 2 opens with a spike (§5.4) |
| Views store filters, sorts, grouping and visible properties. Gallery cards can show a cover, properties or content, at chosen sizes | NDS `contract-types/src/index.ts:481-486,562-574`; `GalleryView.tsx:57-133` | Saved views and the card formats are real |
| **Two-way relations are not maintained;** the reverse side is never written | NDS `RelationEditorPanel.tsx:52-59` | The seed writes both sides |
| **Backlinks** come from `[[page:<uuid>]]` in blocks (trigger → `osionos_page_links`). The **graph** draws page parents, `relation` page properties and tags; **not** inline links, **not** object-database rows | `models/osionos-page-links-migration.sql`; `bridge-graph.mjs:88-121` | Notes and decisions are **pages**, with relation properties between them for the graph and `[[page:]]` links for the backlinks |
| **Sharing:** a page is shared through `visibility` plus `collaborators[{userId, role}]`, owner-only, and the sharee must be a workspace member. **No UI writes `collaborators`**; the Share popover writes `osionos_share_rules`, which nothing enforces. There is no "Shared with me" view | `bridge-page-read.mjs:25-81`; `bridge-api.mjs:794,816-826,948-995`; `pageStore.actions.ts:274…614`; `shareApi.ts` | The shared item can be seeded, but the share **dialog** cannot be shown as working today. That is a repair (§9 Q4) |
| There is **no bulk import** on the bridge: `POST /api/pages` creates one page, and `POST /api/object-databases` upserts one database | `bridge-api.mjs:3091-3102,3268` | The seed calls the bridge once per page (about 160 calls) |
| **The local edition is Postgres-only.** `apps/osionos-electron` (v0.5.4, AppImage/deb/exe) and `apps/osionos-desktop` (Tauri) exist; their design doc says "no Mongo" | `osionos-electron/local-edition/NATIVE-EDITION-DESIGN.md:12` | The site must not claim a MongoDB download (§9 Q1) |

### 5.2 Two personas

**A — Inès Caradec, operations director at Arlet Équipement (recommended).**
- Arlet is a fictional 38-person distributor of professional kitchen equipment, selling to
  restaurants, hotels and caterers around Lyon. It has four departments: sales, warehouse,
  finance and service.
- Inès is finishing an executive certificate in operations management. Her course notes changed
  two decisions this year: dual-sourcing a supplier, and a new stock-reorder rule.
- Wholesale clients and suppliers fill the CRM, and Arlet's trading fills the business data. The
  coursework fills the academy notes, and her reading fills the library.
- **Jules Marchand** (finance controller) is the second demo user. He is a viewer member of a
  second workspace of Inès's that links no mount, and she shares one page with him there (§5.4).
- It is the brief's B2B story: one record read by every department.

**B — Tomás Reyes, a solo specialty-coffee roaster** (the brief's example).
- He runs Prismatica on the local edition, and studies at a roasting academy.
- He tells the second-brain story well, but a one-person business has no departments: the CRM
  and business sections would carry the weight of a story the site no longer tells.

The recommendation is **A**. B can come back as one scene of the tour ("or on your own machine")
once the local edition is downloadable.

### 5.3 Datasets, where each lives, and why

Volumes follow the brief and are scaled to what each store holds. Every name is fictional,
emails use `@arlet.example.com`, `@<client>.example.com` or `.test`, and phone numbers are in the
`+33 6 39 98 xx xx` fiction range (D-024).

| Dataset | Volume | Lives in | Engine | Why this engine |
|---|---|---|---|---|
| Companies, contacts, company↔contact links with a role, deals, deal↔contact links | 60 / 220 / ~300 / 80 / ~200 | Mount `demo_<uid>_crm` | **PostgreSQL** | Many-to-many with attributes (the role) and foreign keys are relational by nature. KPI rollups are SQL |
| Interactions (calls, emails, meetings) with notes | ~700 | Mount `demo_<uid>_activity` | **MongoDB** | The shape varies by kind (a call has a duration, an email a subject and thread, a meeting attendees). It is append-only and read newest first. A document per event fits without nullable columns |
| Products, orders, order lines, invoices, stock movements, expenses (18 months to the anchor date) | 120 / ~1 800 / ~5 000 / ~1 800 / ~3 000 / ~600 | Mount `demo_<uid>_crm`, tables `trade_*` in `public` (introspection reads `public` only, `schema.rs:120`) | **PostgreSQL** | "Totals equal the sum of the records" is a SQL `GROUP BY`. One database keeps orders joined to companies |
| Reports (≈10): revenue by month, margin by category, top clients, late invoices, stock below reorder point… | 10 SQL views | Same mount | PostgreSQL | Views over the same rows, so a report cannot drift from its records |
| Library: books, articles, papers, files | ~250 | Mount `demo_<uid>_activity`, collection `library` | **MongoDB** | The metadata differs per kind (ISBN, DOI, URL, file); tags are arrays |
| Academy notes, signed and attributed to a subject and course | ~120 across 6 subjects | **osionos pages** | (platform postgres, via the bridge) | Only pages get backlinks and graph edges (§5.1) |
| Decision log (the hubs) | ~15 | osionos pages | same | Each note links to the decision it informed, which makes the graph's hubs |
| Home dashboard | 1 page | osionos page with `home_views` and database blocks over the mounts | same | It pulls from every module |
| Card directory: flashcards and case studies | ~80 / ~12 | **User object databases** | (JSONB blob) | Small, card-shaped, owned by Inès. Well inside the 1.5 MB envelope |
| Person and company cards | views | Gallery views over the CRM mount, **if** the spike shows mount-backed gallery views; otherwise dropped | — | No copies of CRM data are made just to get a card |

**Not used, and why:**
- **MySQL:** nothing here is more natural in it than in Postgres. A second relational engine
  would be forced.
- **Redis:** no dataset is a cache or a counter.
- **SQLite, MSSQL and DynamoDB:** they exist only when the router is compiled with them (GB
  `osionos-extra-engines.sh:14-32`).

The site's "what it is, plainly" section can list the engines the demo uses, and say that the
others exist.

**Relations target:**
- at least 3 links per record on average, counting foreign keys, the role links, interaction →
  contact/deal, note → decision/library item/contact, and the reverse sides written explicitly;
- three hubs: the "Supplier switch" decision, Hôtel Varenne (the largest client) and the fictional book
  *The Two-Supplier Rule*;
- `seed:demo:verify` computes the average and lists every orphan; zero unintended orphans are
  allowed.

### 5.4 How the seed works (re-submitted to the devil after BLOCK, §9)

The first ruling was **BLOCK** ([verdict](verdicts/phase1-devil.md), Decision A). It found four
problems:
- the bridge reads every mount with **one** tenant key;
- its mount check ignores the member's role;
- a reset that deletes "the demo tenant" would delete the tenant every osionos mount lives in;
- a local backend is not free.

This version answers L1–L5 and folds in conditions 1–11.

**Isolation, stated as it is (L2).**
- The demo mounts live in the **bridge's tenant** (`agency` locally: the bridge holds one tenant
  key, `bridge-api.mjs:166,174`; the data plane refuses any other tenant's key,
  `helpers.rs:199`).
- **Per-user isolation of mount data is the bridge's ACL alone:** only a workspace that links a
  mount can reach it.
- **The data plane separates tenants, not users.** Anyone holding the bridge's tenant key could
  read every mount in that tenant. Only the bridge holds it. This is a platform limit, written
  down rather than claimed away.
- `dm2` has two parts:
  - **(a)** an outsider gets 403 from the bridge for every manifest mount id, on list, get,
    insert, update, delete, upsert, batch, ddl, sql-ro and txn;
  - **(b)** another tenant's key is refused by the query-router for the same ids.

**Jules (L3).**
- Inès owns two workspaces: **"Arlet — Operations"**, which links the mounts, and **"Arlet —
  Finance review"**, which links none.
- Jules is a viewer member of the second one only. The shared page, "Q4 supplier review", lives
  there, with `collaborators` naming him.
- `dm2` asserts 403 for Jules on every demo mount id and op, and the page opens for him.
- The role-blind mount ACL (`bridge-api.mjs:2591-2601,3055-3065`) is repair **R17**, handed to
  osionos.

**Reset cannot delete what it did not create (L4).**
- It deletes **no tenant**.
- It drops a database only when all three hold: its name matches
  `^demo_[0-9a-f]{8}_(crm|activity)$`, it is in the manifest, and its `tenant_databases.name`
  matches.
- It deletes GoTrue users only by manifest id **and** only with an `@arlet.example.com` email.
- osionos rows are deleted only when `owner_id ∈ {Inès, Jules}` and they are in the manifest.
- **Teardown order (G1):** pages and object databases, then the `osionos_workspace_databases`
  links, then the mount registration, then the physical database, then its login role. Role
  names get the same triple match as databases.
- A hard deny-list (`agency`, `postgres`, `template*`, `mini_baas*`, every name not matching the
  pattern) is checked before anything else.
- `reset --dry-run` prints the full list; deletion needs `--yes`.
- A bats test plants each forbidden entry in a manifest and expects `--dry-run` to exit non-zero.
  It is mutation-tested: remove the guard, and the test must fail.

**Every write and its credential (L5).**

| Write | Path | Credential |
|---|---|---|
| Physical databases `demo_<uid8>_crm` (PostgreSQL) and `demo_<uid8>_activity` (MongoDB), each with a login role limited to itself | `docker exec` into the engine container, locally; on baas, a human-run step | The engine's superuser, used only for this bootstrap and never stored |
| Mount registration (`tenant_databases`) | `POST /admin/v1/databases` | service_role (tailnet only on baas) |
| Mount schema (migrations) | `grobase db migrate` → `/admin/v1/migrate` | service_role |
| Mount rows | `/query/v1` `upsert` batches (≤ 1 MB, ≤ 300/min, honouring 429 `Retry-After`) | The tenant API key |
| GoTrue users (created confirmed) | GoTrue admin API | service_role |
| The two workspaces, Jules's membership and the `osionos_workspace_databases` link rows | `/rest/v1` (service_role only, `osionos-workspace-databases-migration.sql:34-41`) | service_role |
| `directory_opt_out` for both users | The bridge as each user if it exposes the setting (the spike checks), otherwise `/rest/v1` | The user's session, or service_role |
| Pages, page links and object databases | Bridge, as Inès | Inès's session |

"No service role" applies only to pages and object databases. Mount DSNs never use `postgres` or
`sa`: connected as the mount's own role, `pg_authid` must fail (condition 8, G2).

**Schema.**
- Every mount table is in `public`, because introspection reads only `public`
  (`schema.rs:120`). Trade tables are prefixed `trade_`.
- Migrations are `scripts/demo/migrations/NNNN_name.{up,down}.sql`.
- The runner has these rules:
  - each application gets a unique server name, `<NNNN_name>.<up|down>.<seq>`;
  - the groot ledger row (version, file, sha256, direction, seq) is the last statement of the
    **same** `/admin/v1/migrate` request, so it commits in the server's transaction
    (`schema.rs:62-100`);
  - it never writes `_baas_migrations`;
  - it refuses an applied file whose sha256 changed;
  - `--dry-run` refuses non-transactional DDL (`CONCURRENTLY`, `CREATE DATABASE`, `VACUUM`) and
    prints the SQL with the schema diff;
  - each request is ≤ 256 KB.
- Runner tests:
  - up → down → up gives the schema diffs X, ∅, X;
  - an edited applied file is refused;
  - a failing last statement leaves **no** ledger row in either table.
- Mongo has no DDL. Its collections and indexes are an idempotent `ensure` step, listed in the
  dry run.

**Idempotency.**
- Mount rows have UUIDv5 keys from a seeded PRNG and use the `upsert` op (`DO UPDATE`,
  `crud_build.rs:202`). Seeded tables have no `now()` update column, so the row checksum is
  equal after run 2.
- Page ids are minted by the server (`bridge-api.mjs:728-748`). Each page therefore carries a
  deterministic `seed_key` property, and the manifest maps each seed key to its server id.
  **A second `make seed-demo` issues 0 `POST /api/pages`**, and the verify fingerprint is
  identical (bats).
- Dates are offsets from an anchor date stored in the manifest. Re-running keeps the anchor;
  reset followed by a seed re-anchors to today.

**Manifests.**
- There is **one manifest per target**, keyed by Kong URL and tenant id, at
  `scripts/demo/manifests/<target>.json`. It is git-ignored, holds ids only, and is covered by
  `make secrets-scan`.
- `verify` and `reset` refuse when the manifest's target is not the current one.
- "Demo-tagged" means `owner_id ∈ {Inès, Jules}` for osionos rows, and the L4 name pattern for
  mounts. `verify` lists any demo-tagged row that is not in the manifest.

**Order of work.**
1. **The spike** (condition 1): one record per §5.3 mapping on the local grobase, plus one table
   outside `public` and one SQL view. Every view type the shot list needs is rendered and
   screenshotted under `docs/redesign/spike/`.
2. Each fallback becomes a DECISIONS entry **before** any bulk generator runs.
3. Generate, then `verify`:
   - counts;
   - referential integrity;
   - KPI reconciliation: SQL views versus the sum of rows;
   - the average of ≥ 3 links per record, and orphans;
   - the isolation probes;
   - **non-demo invariance** (before and after counts of `auth.users`, `tenants`,
     `tenant_databases`, `osionos_pages` and `osionos_workspace_members` are equal across seed and
     reset).

**Commands:** `make seed-demo`, `make seed-demo-verify` and `make seed-demo-reset` (the brief's
`seed:demo`, `seed:demo:verify` and `seed:demo:reset`).

**Where it runs (L1, §9 Q2).**
- Phase 2 needs an **exclusive window for a local grobase**: `backend-up` refuses while the link
  relay runs (`grobase.mk:64`), and the container names are fixed.
- The running stack is shared with the session in `/goinfre/dlesieur/wt-groot-e2e`.
- Done-when for the window:
  - it is recorded in DECISIONS with its date;
  - `make all SKIP_SYNC=1` runs from this worktree, with its own submodule checkout at the same
    pins;
  - after Phase 2 the link stack is restored, and `make link-verify` passes.
- **baas** is a human-run step, in this order:
  1. the Appendix A inventory shows the bridge's tenant, no existing `demo_*` names and a Mongo
     engine mounted;
  2. `--dry-run`;
  3. you review the diff;
  4. `--yes --target baas`, outside ADR 0002's backup and gc windows.

---

## 6. Media plan

### 6.1 Shot list

`scripts/media/capture.ts`:
- logs in as the demo user (credentials from the environment, through `scripts/lib/demo-login.sh`'s
  contract);
- freezes the clock with `page.clock`, at the seed's "today";
- shoots 1440×900 @2x and 390×844 @2x, in light and dark;
- writes JPEG q85 masters to `media/screenshots/`.

AVIF and WebP for the site come from `scripts/tools.sh vips`.

| # | Screen | State | Story beat | Used in |
|---|---|---|---|---|
| S1 | Home dashboard | Monday 09:10: the week's meetings, open deals, low-stock items, unpaid invoices, this week's coursework | "Everything in one place" | Hero (1440 and 390), OG image |
| S2 | Contact page: Marc Delorme | Relations open: company with role, 3 deals, 7 invoices, call notes, one linked lecture note | "One record every department reads" | Section 3 |
| S3 | Company page: Hôtel Varenne | 4 contacts, each with a role; deals rollup | Many-to-many with roles | Section 3 (second, smaller) |
| S4 | Deals, board | Every pipeline stage populated, including won and lost | "Views, not copies" | Section 4 tab |
| S5 | Deals, table | A saved view with two filter chips and a sort | Same | Section 4 tab (default) |
| S6 | Interactions, calendar | The current month, meetings and calls | Same | Section 4 tab |
| S7 | Business dashboard, chart | 18 months of revenue with the two bad months visible | Same; also "reports" | Section 4 tab |
| S8 | Academy note: "Dual sourcing" | Backlinks panel: the book, the guest lecturer (a contact), the decision page | "What you learn, next to the work" | Section 5 |
| S9 | Graph view | Centred on a hub record (the "Supplier switch" decision) | Same | Section 5 |
| S10 | Library, gallery | Books and papers as cards with tags | Same | Section 5 (small) |
| S11 | Jules's view | Signed in as Jules (finance): the one page Inès shared, "Q4 supplier review", and none of her other pages or databases. The Share dialog is shot only if the §9 Q4 repair lands | Permissions in action | Section 6 |
| S12 | The tour poster | S1 with the play glyph | Click 1 | Tour dialog |

Every shot is checked: no real address, no token in the URL bar (no chrome is captured), no
toast, cursor or scrollbar.

### 6.2 Animated SVG

Each is built by hand, run through SVGO (`scripts/tools.sh svgo`), at most 40 KB, with
`<title>` and `<desc>`. A static frame is the reduced-motion fallback.

| # | Illustration | Motion | Budget |
|---|---|---|---|
| V1 | The convergence: six department lines merge into one beam | M1, on load | ≤ 4 KB, inline |
| V2 | One customer, five copies: the same contact card in Sales, Finance, Ops and Notes columns merges into one record with four relation stubs | M2, scroll | ≤ 20 KB |
| V3 | Relation lines: contact → deal → invoice → note, overlaid on S2's layout | M3, scroll | ≤ 12 KB |
| V4 | A card filtering into a saved view (the brief's example), beside the section 4 tabs | Plays once when ≥ 50 % visible | ≤ 16 KB |

### 6.3 Video storyboard (75 s)

The tour is recorded with Playwright `recordVideo` at a human pace (actions 600–900 ms apart, and
typing at 12 characters per second). It is assembled by `scripts/media/build-video.sh` with
400 ms crossfades. The title cards are 2.5 s, in Instrument Serif on `--paper`. It is silent:
there is no licensed music (D-020).

| Time | Scene | One idea | On screen | Caption (summary) |
|---|---|---|---|---|
| 0:00–0:04 | Title card | — | "Prismatica — one week of one operations director" | — |
| 0:04–0:16 | 1. Monday | Everything starts in one place | Home (S1); hovering this week's numbers | "Inès opens Prismatica on Monday. Sales, stock, invoices and her coursework are on one page." |
| 0:16–0:30 | 2. One customer | One record, every department | Open Marc Delorme (S2), follow the deal → invoice → call note | "A customer is one record. Sales, finance and operations read the same one." |
| 0:30–0:43 | 3. Views | Views, not copies | Deals: table → board → calendar → chart (S5 → S4 → S6 → S7) | "The same deals, four views. Nothing is exported." |
| 0:43–0:55 | 4. Learning | Notes inform decisions | The lecture note (S8), then backlinks, then the graph (S9) | "Her course notes link to the decision they changed." |
| 0:55–1:05 | 5. Sharing | Permissions | Inès shares "Q4 supplier review" with Jules (the dialog only after the Q4 repair); cut to Jules's view (S11) | "She shares one page with finance. Nothing else is visible to them." |
| 1:05–1:15 | 6. Where it runs | Hosted or local | Card: grobase for teams, localhost for one person; end card "Create your workspace" and the URL | "Run it for a team, or on your own machine." |

Exports: MP4 (H.264, yuv420p, `+faststart`) at 1080p; WebM (VP9); a poster JPEG; an 8–10 s
silent loop cut from scene 3 (M8, ≤ 1.5 MB); WebVTT captions; a chapters `.vtt`; a plain-text
transcript. A `VideoObject` JSON-LD names the transcript.

---

## 7. Email plan

**Where things stand** (AUDIT §5):
- The confirm and reset pages cannot reach GoTrue (R3), and the reset link carries the wrong
  token (R4).
- The site's mail path reads different SMTP keys from grobase and defaults to Mailpit (R5).
- Recover leaks timing and has no per-target cap (R10).
- Logout and reset revoke nothing (R11).

**What grobase's GoTrue gives us** (src, `apps/grobase` 8b9321a6):
- Supabase Auth **v2.188.1**, built from source (`infra/docker/services/gotrue/Dockerfile:35`).
- No compose file sets `GOTRUE_MAILER_OTP_EXP`, so every email token (signup and recovery alike)
  lives GoTrue's default 24 h, unless the optional `.env.gotrue` sets it
  (`auth-api.yml:12-16`). baas's `.env.gotrue` has not been read. That is one platform-wide knob
  for every app on grobase.
- SMTP comes from `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASS` and `EMAIL_FROM`
  (`orchestrators/compose/base/auth-api.yml:27-33`).

### 7.1 Design: GoTrue owns the tokens, and the gateway owns the policy

The devil ruled **PROCEED-WITH-CONDITIONS** ([verdict](verdicts/phase1-devil.md), Decision B).
Its conditions are the C1–C14 references below. The rejected alternative, a gateway-owned token
table, stays rejected: GoTrue is still the only party that can confirm, set a password or revoke
sessions, so a second token store would add code without removing that dependency.

The browser never calls GoTrue. Every link the gateway mails is **signed by the gateway**, and the
token travels in the **URL fragment**, so no server log or `Referer` header ever holds it.

```
signup ─► POST /api/auth/register ─► GoTrue admin generate_link(signup) ─► queued mail ─► Mailpit|Titan
link   ─► /auth/confirm#token_hash=…&type=signup&exp=…&sig=HMAC(AUTH_LINK_SIGNING_KEY; token_hash,type,exp)
page   ─► POST /api/auth/verify {token_hash,type,exp,sig}
          ─► bad sig or exp past: 410, GoTrue not called (C1) ─► else GoTrue POST /verify ─► 200

forgot ─► POST /api/auth/recover {email} ─► per-address bucket ─► 202 at once, one body ─► (bounded queue) generate_link(recovery) + mail
link   ─► /auth/reset-password#token_hash=…&exp=now+3600&sig=…
page   ─► POST /api/auth/reset-password {…, password}
          ─► sig/exp check (C1) ─► GoTrue /verify(recovery) ─► [TOTP user: aal2 step, C4] ─► PUT /user {password}
          ─► POST /logout?scope=global ─► sessions_valid_after = now (bridge) ─► 200 "sign in again"
```

| Brief requirement | How it is met | Proven by |
|---|---|---|
| Random, single-use, stored hashed | GoTrue `generate_link`: random token, hash in `one_time_tokens`, consumed by `/verify` | pr2: a reused link is refused |
| Verification ≤ 24 h, reset ≤ 60 min, checked **before** consumption | The gateway's signed `exp` is 86 400 s / 3 600 s. A past `exp` or a bad signature is refused with 410 **without calling GoTrue** (C1). GoTrue's own lifetime is the outer bound. A preflight fails if the effective `GOTRUE_MAILER_OTP_EXP` (compose plus `.env.gotrue`) is set below 86 400 (C14); on baas it is in Appendix A's human-run inventory | Unit tests: the GoTrue mock gets 0 calls for an expired or tampered link. pr2: an expired link on a stack started with `AUTH_RESET_TOKEN_TTL_SEC=5` |
| Token never in a URL a server sees | Fragment, plus `Referrer-Policy: no-referrer` on both pages (C2) | After pr1 and pr2, a grep of the nginx and web access logs finds no token value |
| A new request kills the old link | GoTrue overwrites on `generate_link` (UNKNOWN for v2.188.1, so it is tested) | pr2 |
| Resend keeps the password | (C3) | pr1: sign up, resend, confirm with the **second** link, sign in with the sign-up password |
| Reset signs out all other sessions | `logout?scope=global` revokes every GoTrue refresh token. The bridge refuses an `osionos_v1` token issued before the user's `sessions_valid_after`. That column comes from a **groot `models/` migration**, service_role-only (`make models-grants-verify`). The check sits inside the one verifier (`bridge-api.mjs:425`), so all 27 bridge modules inherit it (C8). Tokens get a millisecond issue time, because 1 s precision cannot separate "1 ms before" from "1 ms after" | Unit tests at ±1 ms; the behaviour on a failed lookup is chosen and tested; pr2: the other browser's refresh gets 4xx and the bridge gets 401 |
| **Residual, stated (C9)** | Other sessions' GoTrue **access** JWTs stay valid for up to 3 600 s at services that check only the signature. That is GoTrue's `JWT_EXP`. The plan revokes the refresh tokens and the bridge, and says so | pr2 asserts exactly what is revoked |
| MFA users can reset (C4) | A user with a verified TOTP factor either completes the reset, or the page asks for the code and reaches aal2 before `PUT /user` | pr2 MFA variant. If v2.188.1 refuses both, that becomes a user decision in DECISIONS |
| No account enumeration, **stated honestly** (C5) | `/recover` and `/resend-verification` answer 202 with one body before any lookup. **Three other surfaces exist:** `/login` waits for a failed-login alert sent only when a profile exists (`auth-gateway.mjs:923`), so that send moves after the response; `/register` answers 409 for a taken email (`:851`); `/availability` says so outright, rate-limited to 30/min. Keeping the last two is your decision (§9 Q6) | pr3 covers `/recover`, `/resend` and `/login`: same status and body, median timing difference under 50 ms over 20 tries |
| Rate limit per IP and per account | Per IP: the existing `rateLimit()`. Per address: one bucket shared by `/recover` and `/resend-verification`, keyed `keyHash(lowercased trimmed email)`, taken before any lookup, 3 per hour, silently dropped over the cap (C7). Residual, in DECISIONS: an attacker can spend a victim's 3 per hour | pr4 alternates the two endpoints; the 4th request sends no mail and gets the same answer |
| Work after the 202 cannot crash or flood (C6) | One queue with a maximum length, at most 2 concurrent SMTP sessions, overflow dropped and audited, every rejection caught. `Caveat:` work queued at a gateway restart is lost; the user asks again | Tests: the GoTrue mock throws after the 202 and the next request is still served; 10 000 requests do not grow the queue past its maximum |
| Logout revokes (R11, C10) | `POST /api/auth/logout` revokes the refresh token server-side using **the cookie alone**, so it works after a reload with no access token in memory | Replaying the old cookie on `/api/auth/refresh` gets 401 |
| Fixes R3 and R4 | The pages no longer call `/api/auth/v1/*`, and the link never uses `action_link` | pr1 and pr2 run through real links in Mailpit |

### 7.2 Configuration: one vocabulary (R5), and Titan unreachable from tests

- **The defect is the key names, not the interpolation.** groot compose already interpolates
  `SMTP_HOST` (`docker-compose.yml:524`).
- The gateway moves to **grobase's names**: `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASS`
  and `EMAIL_FROM`. `SMTP_SECURE` is derived from the port when it is unset.
- The real risk is that `.env.local` can be filled from vault42 (`docker.mk:12`,
  `grobase-link.mk:36`), and the local `apps/grobase/.env` already points GoTrue at Titan. So:
  - **`tests/e2e/run.sh` refuses `pr*`/`dm*`** unless the running gateway's effective `SMTP_HOST`,
    and for a local backend `mini-baas-gotrue`'s `GOTRUE_SMTP_HOST`, is the Mailpit service (C11).
  - A bats test plants `SMTP_HOST=smtp.titan.email` in a temporary `.env.local` and expects the
    refusal. It is mutation-tested.
  - `pr*` also refuses to run while the link relay points at a remote backend. Test users use a
    reserved `.test` domain and are deleted at teardown, so OD1's leak does not repeat (C12).
- The `EHLO` name and the `Message-ID` domain are derived from `EMAIL_FROM`'s domain, not from
  the hard-coded `prismatica.local` (`auth-gateway.mjs:548,664`).
- `AUTH_REQUIRE_EMAIL_VERIFICATION` defaults to **true** locally. It lands **in the same change**
  that moves `ac1-new-account` through Mailpit, announced to the session that shares the stack
  (C13). The demo seed creates its users already confirmed.
- New keys in `.env.example`, by name only: `AUTH_LINK_SIGNING_KEY`, `AUTH_RESET_TOKEN_TTL_SEC`
  and `AUTH_VERIFY_TOKEN_TTL_SEC`.

### 7.3 Templates

- Three messages:
  - "Confirm your email";
  - "Reset your password";
  - "Your password was changed" (a security notice, sent after a reset).
- Each is table-based HTML, inlined CSS under 30 KB, plus a plain-text part. They use the site
  palette (`--paper`, `--ink`, `--signal`) with system fonts; web fonts are unreliable in mail
  clients.
- From is `Prismatica <no-reply@{domain}>`. Links are built from `PUBLIC_SITE_URL`, never from the
  request's `Host` header.
- The templates are rendered from one source file per message by the gateway's renderer, and
  snapshot-tested in vitest (HTML and text).

### 7.4 Deliverability

- Once the sending domain is known (§9 Q3), `scripts/tools.sh dig` checks SPF, DKIM and DMARC.
  `bind-tools` will be added to `groot-tools`.
- The result goes in REPORT.md: the exact missing records, the selector and the policy. **No
  DNS change is made.**
- The one real Titan send happens at the end of Phase 7, to `TEST_INBOX`, and only after your
  approval.

---

## 8. Test plan and quality budgets

### 8.1 End-to-end specs (Playwright, `tests/e2e/specs/`)

| Spec | Covers | Needs |
|---|---|---|
| `pr1-signup-verify` | Sign up → mail in Mailpit → open the link → verified → sign in → osionos. Resend: the **second** link confirms, the first dies, and the sign-up password still works (C3) | Local stack, Mailpit |
| `pr2-reset` | Request → mail → the new password works and the old one fails. In a second browser, the GoTrue refresh gets 4xx and the bridge answers 401 (C8, C9). A reused link is refused; an older link dies once a new one is sent; an expired link is refused (on a stack started with `AUTH_RESET_TOKEN_TTL_SEC=5`). **TOTP variant** (C4). Logout with the cookie alone revokes it (C10). Afterwards, no token appears in the access logs (C2) | Local stack, Mailpit |
| `pr3-no-enumeration` | `/recover`, `/resend-verification` and `/login`: known and unknown addresses get the same status and body, and a median timing difference under 50 ms over 20 tries (C5). `Caveat:` a timing test on a shared machine can false-fail under load; it retries once and reports both medians | Local stack |
| `pr4-recover-cap` | `/recover` and `/resend` alternate; the 4th request in an hour sends no mail and answers the same (C7) | Local stack, Mailpit |
| `dm1-demo-screens` | The key screens S1–S11 render with the seeded data (counts asserted against `seed:demo:verify`'s output) | Local stack, seed |
| `dm2-demo-isolation` | (a) an outsider, and Jules, get 403 from the bridge for every manifest mount id, on list, get, insert, update, delete, upsert, batch, ddl, sql-ro and txn, and for every demo page and object database. (b) A key of another tenant is refused by the query-router for those ids (L2, L3) | Local stack, seed |
| `dm3-share-revoke` | The page opens for Jules once its `collaborators` name him, and gives 403 once they no longer do. If the §9 Q4 repair lands, this goes through the Share dialog | Local stack, seed |
| `st1-two-click` | Header navigation; the tour opens; the video plays and its captions track has cues; "Create your workspace" opens sign-up | Site only |
| `st2-reduced-motion` | With `reducedMotion: 'reduce'`, `document.getAnimations()` is empty after load and after a scroll, and every section is visible (no opacity-0 content) | Site only |
| `st3-routes` | Every route in `routes.txt`, both themes: no console errors, axe 0 serious or critical, `overflowPx` 0 at 390/768/1440 | Site only |
| `st4-visual` | `toHaveScreenshot` per section at 3 widths × 2 themes, with the clock frozen and media masked until Phase 4 | Site only |

`tests/e2e/run.sh` refuses `pr*`/`dm*` unless the gateway and the local GoTrue point at Mailpit,
and refuses while the link relay points at a remote backend (§7.2, C11/C12). The dm2 (b) fixture
creates a second tenant and its key, deletes both at teardown, and refuses to run against baas
(G3).

Seed tests are bats plus the verify script:
- `seed:demo` twice → **0** `POST /api/pages` on run 2, and an identical verify fingerprint
  (counts plus a row checksum);
- the migration runner gives the schema diffs X, ∅, X for up → down → up; it refuses an edited
  applied file; a failing last statement leaves no ledger row in either table;
- `seed:demo:reset --dry-run` lists exactly the manifest, and **exits non-zero for each planted
  forbidden entry** (`agency`, `postgres`, `template1`, a non-pattern name, a non-`@arlet` user).
  This is mutation-tested (L4);
- non-demo row counts are equal before and after seed and reset;
- least privilege, probed **with the mount's own login role**, not through the bridge's sql-ro
  route (which is off unless `OSIONOS_SQL_RO=1`): `pg_authid` fails on Postgres, and reading
  another database fails on Mongo. A probe that cannot run is SKIP, and SKIP fails verify (G2);
- after a reset, no `tenant_databases` row remains under a demo name, and a fresh seed registers
  the mounts with 201, not 409 (G1).

**Where they run:**
- The **site-only** specs (st1–st4) run in CI against the built static site served by the
  site's own nginx image, with no backend.
- The **stack** specs (pr*, dm*) run locally through `make e2e`. In CI they run in groot's
  `fresh-machine` job, which already brings the whole stack up on `main`. Today that job does
  not run e2e; adding it is §9 Q7.

### 8.2 Budgets (Lighthouse CI, `lhci assert`, mobile default throttling unless stated)

| Metric | Baseline (`/`, mobile) | Budget | Note |
|---|---|---|---|
| Performance | 96 | ≥ 90 mobile, ≥ 95 desktop | |
| Accessibility | 100 (legal 93–95) | 100 | |
| Best Practices | 100 | 100 | |
| SEO | 100 (noindex routes 66) | 100 on **indexable** pages | Noindex routes are excluded from this one assertion only, because Lighthouse docks `noindex` by design (AUDIT §6). All other budgets still apply to them |
| LCP | **2.53 s** | ≤ 2.5 s (aim 2.0 s) | Already over the limit with no media. The plan to recover: fonts 84 → ~15 KB, one preloaded subset face, JS removed (mascot, premium), a hero AVIF ≤ 60 KB at 390 px with `fetchpriority=high` |
| CLS | 0.000 (auth pages 0.044) | ≤ 0.05 | Every image and video has dimensions; the auth pages' 0.04 shift is fixed by reserving the status box |
| TBT | 0 ms | ≤ 200 ms | |
| **Initial JS on `/`** | 33 KB | **≤ 30 KB** transfer, target 20 KB | Set below the baseline as a ratchet: the auth dialog and `@grobase/js` load on click, never at start |
| Fonts on `/` | 84 KB | ≤ 20 KB | |
| Images on `/` before interaction | 0 KB | ≤ 250 KB mobile | The captures below the fold are `loading=lazy` |
| Horizontal overflow | 6 of 11 routes | 0 px on every route at every width | Asserted by st3 |

`scripts/site-audit.sh after` measures the redesign on this machine, so the before and after
tables in REPORT.md compare like with like (its `Caveat:`). The `lhci assert` step joins the
script, and the site's CI.

---

## 9. Risks and open questions

### 9.1 The gate

| Decision | Devil's ruling | What it needs from you |
|---|---|---|
| A — the Phase 2 demo seed | **BLOCK on L1 alone.** The re-ruling found L2–L5 and conditions 1–11 met. Once L1 is recorded it becomes **PROCEED-WITH-CONDITIONS**, with no new hearing, adding gaps G1–G3, now in §5.4 and §8.1 ([verdict](verdicts/phase1-devil.md)) | L1, which is Q2 below |
| B — Phase 5 verification and reset | **PROCEED-WITH-CONDITIONS** (C1–C14, now in §7–§8) | Q6 below; and the MFA outcome if GoTrue refuses both paths (Q12) |

### 9.2 Open questions, each with a recommended answer

| # | Question | Recommended answer | Why |
|---|---|---|---|
| Q1 | What does section 6 ("Run it where you work") promise for local use? You described a download with a simple MongoDB engine | Promise only what ships: **"Desktop app for Linux (AppImage, .deb), local, Postgres"**, linked to the latest release, and "self-host with Docker" for everyone else. Leave out MongoDB until a local edition uses it. Cut a release from the current source (v0.5.4) before launch | The local edition is Postgres-only (`NATIVE-EDITION-DESIGN.md:12`). The only public release is `osionos-v0.5.2-local`, Linux assets only (GitHub API, 2026-10-15), two versions behind `package.json`. The brief forbids claims the product does not back |
| Q2 | **(L1)** When can Phase 2 and the stack tests have an exclusive local grobase? | Name a window once the `wt-groot-e2e` session (branch `fix/e2e-drift-funnel`) is finished, or a time it can pause. I record it in DECISIONS, run `make all SKIP_SYNC=1` from this worktree, and restore the link stack with `make link-verify` green afterwards | `backend-up` refuses while the link relay runs, and the container names are fixed (`grobase.mk:64`). Phase 3 (site) and Phase 4 media prep do not need the window and can start first |
| Q3 | What are the production domain, the host (Vercel or the nginx image) and the sending domain? | Give me the domain. Until then canonical URLs, the sitemap and `From` come from one `PUBLIC_SITE_URL`, and the SPF/DKIM/DMARC report waits | Unknown in AUDIT §9. `robots.txt` points at `localhost` today |
| Q4 | Repair osionos sharing, so the Share dialog writes the `collaborators` it enforces, and either enforce `osionos_share_rules` or remove them? Repair R17 (the role-blind mount ACL) too? | **Yes, both**, in the osionos repo, with tests, as their own commits (D-009). Until then the site shows Jules's view, not the dialog | Today the dialog stores rules nothing reads (§5.1). A viewer gets CRUD on linked mounts (verdict A4). Showing either as "permissions" would be false |
| Q5 | Remove the cookie banner? | **Yes.** Update `/legal/cookies` to list the only cookie (`prismatica_refresh`, strictly necessary) and the theme key in localStorage | It stores analytics and marketing choices, but the site loads no analytics or marketing script (grep: 0 hits). It covers the hero at every width |
| Q6 | `/register` answers 409 for a taken email, and `/availability` says whether an address is registered. Keep them? | **Change both.** Register answers 202 "check your inbox" either way, and mails "you already have an account — sign in or reset" to a taken address. Remove `/availability` | They are the two enumeration surfaces left after C5. The verdict makes keeping them your dated decision |
| Q7 | Run the stack specs (pr*, dm*) in CI? | Yes, in `fresh-machine` on `main` only (it already runs `make all`). Site specs on every PR of the site | The brief requires local **and** CI. The full stack is too heavy for every PR |
| Q8 | Is `/docs/` held to the budgets (mobile LCP 20.7 s, 5.2 MB of images)? | Yes, for performance only. `build-vault.mjs` emits AVIF/WebP, lazy loading and dimensions, and splits the 3.8 MB fragment. Its design is out of scope | "Every public page", and the fix is a build step, so it is reproducible |
| Q9 | Collapse the five themes (swiss, aurora, solar, ember, forest) into one design with light and dark? | **Yes** | One palette to keep at AA in both modes; the other four would need the same audit for nothing the story uses |
| Q10 | Persona A (Inès, B2B operations) or B (Tomás, solo roaster)? | **A** | §5.2 |
| Q11 | No user migrator exists. Accept the groot runner over `grobase db migrate`, and hand R13 (server-side checksum, down and dry-run) to grobase? | **Yes.** The runner meets the brief's rules today. The permanent home is grobase's `/admin/v1/migrate`, logged as a hand-off | AUDIT §4.5; verdict A, assumption 2 |
| Q12 | If GoTrue v2.188.1 lets a TOTP user neither reset nor step up to aal2, what happens? | They reset after an aal2 step on the reset page. If GoTrue forbids even that, an admin-assisted reset documented in the runbook, rather than bypassing MFA | C4. Bypassing a second factor on reset would defeat it |
| Q13 | Commit the visual-regression baselines (8 sections × 3 widths × 2 themes, about 48 PNGs)? | Yes, element shots per section under `tests/e2e`, about 5–8 MB, refreshed only by an explicit `--update-snapshots` commit | The brief asks for snapshots; element shots keep them small |
| Q14 | `TEST_INBOX` | Needed only in Phase 7, for the one Titan send you approve | D-010 |

### 9.3 Risks

| Risk | Likelihood · impact | Mitigation |
|---|---|---|
| **Mobile LCP already fails** (2.53 s) before any media is added | High · a budget breach | Fonts 84 → ~15 KB, JS cut, hero AVIF ≤ 60 KB at 390 px with `fetchpriority=high`. Measured after Phase 3 before any media lands. If it still fails: the hero capture moves below the `h1` block on mobile |
| Mount-backed blocks may not support board, calendar or chart views | Medium · the shot list shrinks | The spike runs first (§5.4); fallbacks become DECISIONS entries; no data is invented to fill a view the app cannot show |
| Per-user isolation of mount data is the bridge's ACL alone (a platform limit) | Certain · it is stated, not hidden | dm2 (a) and (b); R17; the site never claims row-level isolation for mounts |
| A Titan send from a test | Low after C11 · a mail to a real inbox | `run.sh` refuses unless SMTP is Mailpit, mutation-tested |
| Deleting shared data on baas | Low after L4 · irreversible | Reset deletes no tenant; triple-matched names; deny-list; human-run with a dry run first |
| GoTrue behaviour the plan depends on is UNKNOWN (no source in the tree) | Medium · a redesign of §7 | Each assumption is a test (pr1–pr4) that runs before merge |
| The work spans four repos (opposite-osiris, osionos, groot, and grobase hand-offs) | Certain · coordination | Each submodule change is committed there first, then pinned in groot (CLAUDE.md) |
| The stack is shared with another session | Certain · collisions | Q2; this session never switches or commits in the main checkout |
| Residual access-token lifetime after a reset (3 600 s at signature-only services) | Certain · bounded | Stated in §7.1 (C9) |
| An attacker can spend a victim's 3 reset mails per hour | Low · an annoyance, not a takeover | Stated in DECISIONS (C7) |

**STOP.** Phase 2 waits for your approval of this plan, your answers to Q1–Q14 (or acceptance of
the recommendations), and L1's window.
