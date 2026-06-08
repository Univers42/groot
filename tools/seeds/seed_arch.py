#!/usr/bin/env python3
"""Architecture wing for dylan's CS Academy: ~50 NEW notes that showcase EVERY
editor block component in original, themed layouts — so the renderer can be
critiqued component-by-component. INSERTs folders + notes into dylan's workspace
3f009d03 with parent hierarchy + relation cross-links (graph stays connected)."""
import base64, json, sys, uuid

WS = "3f009d03-d954-5e35-85b8-db5c37aa859f"
OWNER = "ff284cf3-ab7d-4756-ade3-369257e36b2a"   # dylan@gmail.com
ROOT_TITLE = "Architecture Atlas"

# ---- block toolkit (matches entities/block ReadOnlyBlock exactly) -----------
_bid = 0
def bid():
    global _bid; _bid += 1; return f"a-{_bid}"
def B(t, content="", **x): return {"id": bid(), "type": t, "content": content, **x}
def h1(t): return B("heading_1", t)
def h2(t): return B("heading_2", t)
def h3(t): return B("heading_3", t)
def h4(t): return B("heading_4", t)
def h5(t): return B("heading_5", t)
def h6(t): return B("heading_6", t)
def p(t): return B("paragraph", t)
def bullet(t, kids=None): return B("bulleted_list", t, **({"children": kids} if kids else {}))
def numbered(t, kids=None): return B("numbered_list", t, **({"children": kids} if kids else {}))
def todo(t, done=False): return B("to_do", t, checked=done)
def quote(t, level=None): return B("quote", t, **({"headingLevel": level} if level else {}))
def divider(): return B("divider")
def equation(latex): return B("equation", latex)
def callout(icon, t, kids=None, level=None):
    b = B("callout", t, color=icon)
    if kids: b["children"] = kids
    if level: b["headingLevel"] = level
    return b
def code(lang, src, fname=None, theme="dark"):
    b = B("code", src, language=lang, lineNumbers=True, codeTheme=theme)
    if fname: b["fileName"] = fname
    return b
def toggle(t, kids, level=None, collapsed=True):
    b = B("toggle", t, children=kids, collapsed=collapsed)
    if level: b["headingLevel"] = level
    return b
def columns(*cols):  # cols = (widthRatio, [blocks])
    return B("column_list", children=[B("column", widthRatio=r, children=bl) for r, bl in cols])
def table(headers, rows, aligns=None, header_col=False):
    cfg = {"headerRow": True, "showBorders": True, "stripedRows": True, "headerColumn": header_col}
    if aligns: cfg["columnAlignments"] = aligns
    return B("table_block", tableData=[list(map(str, headers))] + [list(map(str, r)) for r in rows],
             tableConfig=cfg)

# ---- shared fragments -------------------------------------------------------
def meta_bar(t):
    domain = t.get("sub", "Architecture")
    return columns(
        (1, [callout("📌", f"**Domain**\n{domain}")]),
        (1, [callout("⭐", f"**Pattern**\n{t.get('pattern', t['title'])}")]),
        (1, [callout("🎯", f"**Use it for**\n{t.get('usefor', 'system design')}")]),
    )
def related_block(related):
    if not related: return []
    return [divider(), h3("🔗 Related"), *[bullet(f"→ {r}") for r in related]]
def eq_block(t):
    if "eq" not in t: return []
    latex, cap = t["eq"]
    return [callout("🧮", f"**Key relation** — {cap}"), equation(latex)]
def code_block(t):
    if "code" not in t: return []
    lang, src, fname, theme = (t["code"] + ("dark",))[:4]
    return [h2("💻 In code"), code(lang, src, fname, theme)]
def table_block(t, title="📊 At a glance"):
    if "table" not in t: return []
    headers, rows = t["table"][0], t["table"][1]
    aligns = t["table"][2] if len(t["table"]) > 2 else None
    return [h2(title), table(headers, rows, aligns)]

# ---- 9 original presentation archetypes ------------------------------------
def hero_dashboard(t):
    body = [h1(t["title"]), callout("🎯", f"**TL;DR** — {t['tldr']}", level=3), meta_bar(t)]
    if t.get("points"):
        body += [h2("🧠 How it works"), *[numbered(s) for s in t["points"]]]
    body += eq_block(t) + code_block(t) + table_block(t)
    return body + related_block(t.get("related"))

def comparison(t):
    a_lbl, a_pts = t["a"]; b_lbl, b_pts = t["b"]
    body = [h1(t["title"]), p(t["tldr"]),
            columns(
                (1, [callout("✅", f"**{a_lbl}**", kids=[bullet(x) for x in a_pts], level=3)]),
                (1, [callout("❌", f"**{b_lbl}**", kids=[bullet(x) for x in b_pts], level=3)]),
            )]
    body += table_block(t, "⚔️ Head to head")
    if t.get("verdict"): body += [callout("🔥", f"**Verdict** — {t['verdict']}")]
    return body + eq_block(t) + related_block(t.get("related"))

def decision_flow(t):
    body = [h1(t["title"]), callout("📌", f"**When you reach for this** — {t['tldr']}")]
    if t.get("steps"):
        body += [h2("🪜 Decision steps")]
        for title, subs in t["steps"]:
            body += [numbered(title, kids=[bullet(s) for s in subs] if subs else None)]
    if t.get("qa"):
        body += [h2("🌿 Branches")]
        for q, a in t["qa"]:
            body += [toggle(f"▸ {q}", [callout("ℹ️", a)])]
    if t.get("pitfalls"):
        body += [callout("⚠️", "**Rule of thumb**", kids=[bullet(x) for x in t["pitfalls"]])]
    return body + code_block(t) + related_block(t.get("related"))

def anatomy(t):
    body = [h1(t["title"]), p(t["tldr"])]
    parts = t.get("parts", [])
    if parts:
        cols = []
        for name, icon, desc, bl in parts:
            cols.append((1, [h3(f"{icon} {name}"), callout("💬", desc),
                             *[bullet(x) for x in bl]]))
        body += [h2("🧩 Anatomy"), columns(*cols)]
    body += code_block(t)
    if "table" in t: body += table_block(t, "🔧 Components")
    return body + eq_block(t) + related_block(t.get("related"))

def cheatsheet(t):
    body = [h1(t["title"]), callout("💬", f"**Cheat sheet** — {t['tldr']}")]
    body += table_block(t, "📋 Reference")
    if t.get("snippets"):
        cols = [(1, [h4(lbl), code(lang, src, None, theme)])
                for lbl, lang, src, theme in t["snippets"]]
        body += [h2("✂️ Snippets"), columns(*cols)]
    body += eq_block(t)
    if t.get("tips"):
        body += [h2("⭐ Quick tips"), *[todo(x) for x in t["tips"]]]
    return body + related_block(t.get("related"))

def socratic(t):
    body = [h1(t["title"]), quote(t["tldr"], level=2)]
    for q, a in t.get("qa", []):
        body += [toggle(f"❓ {q}", [callout("📝", a)], level=3)]
    if t.get("takeaway"): body += [callout("🎯", f"**Key takeaway** — {t['takeaway']}")]
    return body + eq_block(t) + related_block(t.get("related"))

def timeline(t):
    body = [h1(t["title"]), p(t["tldr"])]
    if t.get("milestones"):
        body += [h2("🕰️ How it unfolds")]
        for era, text, subs in t["milestones"]:
            body += [numbered(f"**{era}** — {text}", kids=[bullet(s) for s in subs] if subs else None)]
    if t.get("quote"): body += [quote(t["quote"], level=3)]
    body += code_block(t) + table_block(t)
    return body + related_block(t.get("related"))

def deep_dive(t):
    body = [h1(t["title"]), callout("🎯", f"**TL;DR** — {t['tldr']}", level=3)]
    if t.get("points"): body += [h2("🧠 The idea"), *[bullet(x) for x in t["points"]]]
    body += eq_block(t) + code_block(t)
    if t.get("deep"):
        body += [toggle("🔬 Deep dive", [p(x) if isinstance(x, str) else x for x in t["deep"]])]
    cards = []
    if t.get("pitfalls"):
        cards.append((1, [callout("❌", "**Pitfalls**", kids=[bullet(x) for x in t["pitfalls"]], level=4)]))
    if t.get("when"):
        cards.append((1, [callout("✅", "**Use it when**", kids=[bullet(x) for x in t["when"]], level=4)]))
    if cards: body += [columns(*cards)]
    body += table_block(t)
    return body + related_block(t.get("related"))

def component_gallery(t):
    """Deliberately exercises EVERY block type with labels, to critique the renderer."""
    body = [h1(t["title"]),
        callout("🎨", "This page renders **every block type** the editor supports. "
                "Scroll and critique each component: spacing, colour, wrapping, nesting."),
        h2("1 · Heading scale (H1–H6)"), h1("H1 — display"), h2("H2 — section"),
        h3("H3 — subsection"), h4("H4 — minor"), h5("H5 — label"), h6("H6 — overline"),
        h2("2 · Inline markdown (paragraph)"),
        p("Paragraph with **bold**, *italic*, `inline code`, ~~strike~~ and a "
          "[link](https://example.com). Long line to test wrapping: " + ("lorem ipsum " * 12)),
        h2("3 · Callout colours (every tint)"),
        columns(
            (1, [callout("💡", "yellow — tip"), callout("📌", "blue — pinned"),
                 callout("✅", "green — success"), callout("🔥", "orange — hot")]),
            (1, [callout("❗", "purple — important"), callout("❌", "red — danger"),
                 callout("💬", "gray — note"), callout("🎯", "blue — goal")]),
        ),
        h2("4 · Callout with children (collapsible card)"),
        callout("📝", "**Expandable card** — click the chevron", kids=[
            p("A callout can nest arbitrary blocks:"), bullet("a bullet"),
            code("bash", "echo 'nested code inside a callout'"), todo("a nested to-do", True)]),
        h2("5 · Columns (2-col and 3-col)"),
        columns((1, [callout("📌", "Left")]), (1, [callout("📌", "Middle")]), (1, [callout("📌", "Right")])),
        columns((2, [p("Wide column (ratio 2): " + "text " * 10)]),
                (1, [callout("ℹ️", "Narrow column (ratio 1)")])),
        h2("6 · Lists & nesting (markers change by depth)"),
        bullet("Level 1 (disc)", kids=[bullet("Level 2 (circle)", kids=[bullet("Level 3 (square)")])]),
        numbered("First", kids=[numbered("Nested 1"), numbered("Nested 2")]), numbered("Second"),
        todo("done", True), todo("not done", False),
        h2("7 · Quote (plain + heading-level pull quote)"),
        quote("A small attributed quote."),
        quote("A LARGE pull-quote rendered at heading size.", level=1),
        h2("8 · Code (dark, light, filename, line numbers)"),
        code("python", "def hello(name: str) -> str:\n    return f'hi {name}'\n\nprint(hello('osionos'))",
             "hello.py", "dark"),
        code("rust", "fn main() {\n    println!(\"light theme + filename\");\n}", "main.rs", "light"),
        h2("9 · Table (alignments + header row/col)"),
        table(["left", "center", "right"], [["a", "b", "c"], ["1000", "20", "3"]],
              aligns=["left", "center", "right"]),
        h2("10 · Equation (KaTeX)"),
        equation(r"f(n) = \Theta\!\left(n^{\log_b a}\right) \quad\text{(Master Theorem)}"),
        equation(r"S(N) = \dfrac{1}{(1-p) + \dfrac{p}{N}}"),
        h2("11 · Toggle (nested, with heading level)"),
        toggle("▸ A toggle (click me)", [p("Hidden until expanded."),
            toggle("▸ A nested toggle", [callout("✅", "Nesting works.")])], level=2),
        h2("12 · Divider"), divider(),
        h2("13 · Media (image / file from a direct URL)"),
        callout("ℹ️", "Media renders from a **direct URL** in `block.asset` — `http(s):`, `data:` or "
                "`blob:` (optionally `url:`-prefixed). No special asset blob is required."),
        B("image", "An inline SVG via a `data:` URL — renders offline, no network.",
          asset="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='640' height='200'%3E%3Crect width='640' height='200' fill='%232383e2'/%3E%3Ccircle cx='320' cy='100' r='62' fill='white' fill-opacity='0.28'/%3E%3Ctext x='320' y='112' font-size='26' fill='white' text-anchor='middle' font-family='sans-serif'%3Edata%3A URL image%3C/text%3E%3C/svg%3E"),
        B("image", "A remote image via `https` (needs network + a CSP `img-src` allow).",
          asset="https://picsum.photos/seed/osionos/640/220"),
        B("file", "A file link via `https`.",
          asset="https://www.w3.org/TR/2003/REC-PNG-20031110/iso_8859-1.txt"),
        callout("🔥", "**Now critique it:** what looks off? colours, spacing, wrapping, nesting, media?"),
    ]
    return body + related_block(t.get("related"))

ARCH = {"hero": hero_dashboard, "compare": comparison, "flow": decision_flow,
        "anatomy": anatomy, "cheat": cheatsheet, "socratic": socratic,
        "timeline": timeline, "deep": deep_dive, "gallery": component_gallery}

def layout_playground(t):
    tint = ["💡","📌","✅","🔥","❗","❌","💬","🎯","⭐","ℹ️","📝"]
    return [h1(t["title"]),
        callout("🌈","A sandbox for **layout & colour**: column ratios, every callout tint, "
                "aligned tables, and equations. Resize the window and critique the reflow."),
        h2("Column ratios"),
        columns((1,[callout("📌","ratio 1")]),(1,[callout("📌","ratio 1")]),(1,[callout("📌","ratio 1")])),
        columns((3,[callout("ℹ️","ratio 3 — wide column with more text to test wrapping behaviour")]),(1,[callout("ℹ️","ratio 1")])),
        columns((1,[callout("✅","1")]),(2,[callout("✅","2 — wider")]),(1,[callout("✅","1")])),
        h2("Every callout tint"),
        *[callout(ic, f"`{ic}` tint — **bold**, *italic*, `code` inside a coloured card") for ic in tint],
        h2("Nested colour cards"),
        callout("🔥","**Orange card** wrapping a 2-col of cards", kids=[
            columns((1,[callout("✅","green inside")]),(1,[callout("❌","red inside")]))]),
        h2("Tables with alignment"),
        table(["left","center","right","metric"],
              [["alpha","mid","end","12.5"],["beta","middle","right","1000"],["gamma","x","y","3"]],
              aligns=["left","center","right","right"]),
        h2("Equations beside prose"),
        p("Throughput follows a Little's-Law rearrangement:"), equation(r"X = \dfrac{N}{R}"),
        p("Availability compounds across independent components:"),
        equation(r"A_{\text{total}} = \prod_{i=1}^{n} A_i"),
        h2("Code in two themes, side by side"),
        columns((1,[code("python","print('dark theme')","dark.py","dark")]),
                (1,[code("python","print('light theme')","light.py","light")])),
        callout("🎯","**Critique:** do ratios reflow? do tints have contrast? do equations align with text?"),
    ] + related_block(t.get("related"))

ARCH["playground"] = layout_playground

# code snippets (kept short + real; varied langs/themes to test the code renderer) ----
C = {
 "balancer": ("go", "type Backend struct{ URL string; Active int; Alive bool }\n\nfunc (p *Pool) RoundRobin() *Backend {\n    p.i = (p.i + 1) % len(p.b)\n    return p.b[p.i]\n}\n\nfunc (p *Pool) LeastConn() *Backend {\n    best := p.b[0]\n    for _, b := range p.b {\n        if b.Alive && b.Active < best.Active { best = b }\n    }\n    best.Active++\n    return best\n}", "balancer.go", "dark"),
 "cdn": ("nginx", "location /static/ {\n    add_header Cache-Control \"public, max-age=31536000, immutable\";\n    etag on;\n}\nlocation / {\n    add_header Cache-Control \"public, max-age=60, stale-while-revalidate=300\";\n}", "cdn.conf", "light"),
 "shard": ("python", "import hashlib\n\ndef shard_for(key: str, shards: int) -> int:\n    h = int(hashlib.md5(key.encode()).hexdigest(), 16)\n    return h % shards\n\ndef route(key, conns):\n    return conns[shard_for(key, len(conns))]", "shard_router.py", "dark"),
 "queue": ("go", "func produce(q chan<- Job, jobs []Job) {\n    for _, j := range jobs { q <- j }  // blocks when full -> backpressure\n}\n\nfunc consume(q <-chan Job, ack func(Job)) {\n    for j := range q {\n        if err := handle(j); err != nil { retry(j); continue }\n        ack(j)\n    }\n}", "queue.go", "dark"),
 "gateway": ("yaml", "routes:\n  - path: /api/users\n    service: users-svc\n    plugins: [jwt, rate-limit: { rps: 100 }]\n  - path: /api/orders\n    service: orders-svc\n    canary: { service: orders-v2, weight: 5 }", "gateway.yaml", "light"),
 "bucket": ("python", "import time\n\nclass TokenBucket:\n    def __init__(self, rate, size):\n        self.rate, self.size = rate, size\n        self.tokens, self.ts = size, time.monotonic()\n\n    def allow(self, n=1):\n        now = time.monotonic()\n        self.tokens = min(self.size, self.tokens + (now - self.ts) * self.rate)\n        self.ts = now\n        if self.tokens >= n:\n            self.tokens -= n\n            return True\n        return False", "token_bucket.py", "dark"),
 "raft": ("rust", "fn handle_request_vote(&mut self, req: VoteReq) -> VoteResp {\n    if req.term < self.term {\n        return VoteResp { term: self.term, granted: false };\n    }\n    if req.term > self.term { self.become_follower(req.term); }\n    let up_to_date = (req.last_term, req.last_index) >= (self.last_term(), self.last_index());\n    let granted = self.voted_for.map_or(true, |c| c == req.candidate) && up_to_date;\n    if granted { self.voted_for = Some(req.candidate); }\n    VoteResp { term: self.term, granted }\n}", "raft.rs", "dark"),
 "vclock": ("typescript", "type VC = Record<string, number>;\n\nfunction compare(a: VC, b: VC): \"before\"|\"after\"|\"concurrent\"|\"equal\" {\n  let lt = false, gt = false;\n  for (const k of new Set([...Object.keys(a), ...Object.keys(b)])) {\n    const x = a[k] ?? 0, y = b[k] ?? 0;\n    if (x < y) lt = true;\n    if (x > y) gt = true;\n  }\n  if (lt && gt) return \"concurrent\";\n  if (lt) return \"before\";\n  if (gt) return \"after\";\n  return \"equal\";\n}", "vclock.ts", "dark"),
 "dlock": ("go", "func Acquire(c *Client, key string, ttl time.Duration) (token int64, ok bool) {\n    // SET key uuid NX PX ttl -> returns a monotonic fencing token\n    return c.SetNX(key, ttl)\n}\n\nfunc Write(s *Store, key string, val, token int64) error {\n    if token <= s.LastToken(key) {\n        return ErrStaleLock // a newer holder exists; reject\n    }\n    return s.Put(key, val, token)\n}", "dlock.go", "dark"),
 "idem": ("typescript", "async function withIdempotency(key: string, fn: () => Promise<Result>) {\n  const cached = await store.get(key);\n  if (cached) return cached;                 // replay -> same answer\n  const lock = await store.lockOrWait(key);  // guard concurrent first-tries\n  try {\n    const result = await fn();\n    await store.put(key, result, { ttl: \"24h\" });\n    return result;\n  } finally { lock.release(); }\n}", "idempotency.ts", "dark"),
 "wal": ("python", "def append(log, record):\n    log.write(serialize(record))\n    log.flush(); os.fsync(log.fileno())   # durable BEFORE applying\n\ndef apply(db, record):\n    db[record.key] = record.value\n\ndef recover(log, db):\n    for record in read_all(log):          # replay committed entries\n        apply(db, record)", "wal.py", "dark"),
 "lsm": ("rust", "fn put(&mut self, k: Key, v: Val) {\n    self.wal.append(&k, &v);        // durability first\n    self.memtable.insert(k, v);     // sorted, in-memory\n    if self.memtable.size() > self.threshold {\n        self.flush_to_sstable();    // immutable sorted file\n    }\n}\n\nfn get(&self, k: &Key) -> Option<Val> {\n    self.memtable.get(k).cloned()\n        .or_else(|| self.sstables.iter().rev().find_map(|s| s.get(k)))\n}", "lsm.rs", "dark"),
 "ring": ("go", "func (r *Ring) Add(node string, vnodes int) {\n    for i := 0; i < vnodes; i++ {\n        h := hash(fmt.Sprintf(\"%s#%d\", node, i))\n        r.points = append(r.points, h); r.owner[h] = node\n    }\n    sort.Slice(r.points, func(i, j int) bool { return r.points[i] < r.points[j] })\n}\n\nfunc (r *Ring) Get(key string) string {\n    h := hash(key)\n    i := sort.Search(len(r.points), func(i int) bool { return r.points[i] >= h })\n    return r.owner[r.points[i%len(r.points)]]  // next clockwise\n}", "hashring.go", "dark"),
 "breaker": ("typescript", "class CircuitBreaker {\n  private fails = 0; private openedAt = 0;\n  constructor(private max = 5, private cooldown = 10_000) {}\n\n  async call<T>(fn: () => Promise<T>): Promise<T> {\n    if (this.state() === \"open\") throw new Error(\"circuit open\");\n    try { const r = await fn(); this.fails = 0; return r; }\n    catch (e) {\n      if (++this.fails >= this.max) this.openedAt = Date.now();\n      throw e;\n    }\n  }\n  state() {\n    if (this.fails < this.max) return \"closed\";\n    return Date.now() - this.openedAt > this.cooldown ? \"half-open\" : \"open\";\n  }\n}", "breaker.ts", "dark"),
 "cqrs": ("typescript", "// Command side: validate + emit an event\nfunction placeOrder(cmd: PlaceOrder, bus: EventBus) {\n  if (cmd.qty <= 0) throw new Error(\"bad qty\");\n  bus.emit({ type: \"OrderPlaced\", id: cmd.id, qty: cmd.qty });\n}\n\n// Read side: a denormalized projection updated from events\nfunction onOrderPlaced(e: OrderPlaced, view: OrderView) {\n  view.upsert({ id: e.id, qty: e.qty, status: \"placed\" });\n}", "cqrs.ts", "dark"),
 "es": ("python", "def apply(state, event):\n    if event.type == \"OrderPlaced\":  state = {**state, \"status\": \"placed\", \"qty\": event.qty}\n    if event.type == \"ItemShipped\":  state = {**state, \"status\": \"shipped\"}\n    return state\n\ndef current(events):                 # state = fold over the log\n    return reduce(apply, events, {})", "es.py", "dark"),
 "pubsub": ("go", "func (b *Broker) Subscribe(topic string) <-chan Msg {\n    ch := make(chan Msg, 16)\n    b.subs[topic] = append(b.subs[topic], ch)\n    return ch\n}\n\nfunc (b *Broker) Publish(topic string, m Msg) {\n    for _, ch := range b.subs[topic] { ch <- m }  // fan-out to all\n}", "pubsub.go", "dark"),
}

def topic(sub, title, icon, arch, related, **kw):
    d = {"sub": sub, "title": title, "icon": icon, "arch": arch, "related": related}
    d.update(kw)
    if "codekey" in kw: d["code"] = C[kw["codekey"]]
    return d

TOPICS = [
 # ---- System Design ----
 topic("System Design","Load Balancing","🔀","hero",
   ["Rate Limiting","API Gateway","Health Checks","Consistent Hashing"],
   pattern="Traffic distribution", usefor="horizontal scale + HA",
   tldr="Spread requests across identical servers so no node is a bottleneck or a single point of failure.",
   points=["A balancer (L4 or L7) fronts a pool of identical backends.","It picks a backend per request via an algorithm.","Health checks evict dead nodes so traffic only hits live ones.","Sticky sessions or a shared session store handle state."],
   table=(["Algorithm","How it picks","Best for"],[["Round-robin","next in rotation","uniform backends"],["Least-connections","fewest active conns","uneven / long-lived load"],["IP / consistent hash","hash(key) → node","cache affinity"],["Weighted","by capacity score","mixed instance sizes"]]),
   codekey="balancer"),
 topic("System Design","Caching Strategies","🗃️","compare",
   ["CDN","Read Replicas & Fan-out","Consistency Models","Consistent Hashing"],
   tldr="Caching trades freshness for speed; the pattern decides who fills the cache and who eats stale data.",
   a=("Cache-aside (lazy)",["App reads cache; on miss loads DB then populates it.","Only requested data is cached → memory-efficient.","Stale until TTL; first hit is a slow cold miss."]),
   b=("Write-through / write-back",["Writes flow through the cache to the store (sync) or async (back).","Cache stays warm; reads fast + consistent (through).","Write-back risks loss on crash before flush."]),
   table=(["Pattern","Read","Write","Risk"],[["Cache-aside","app fills on miss","direct to DB","stale until TTL"],["Read-through","cache fills on miss","direct to DB","lib coupling"],["Write-through","fast","cache→DB sync","write latency"],["Write-back","fast","cache→DB async","loss on crash"]]),
   verdict="Default to cache-aside + short TTL; reach for write-through when reads must never be stale."),
 topic("System Design","Content Delivery Network (CDN)","🛰️","anatomy",
   ["Caching Strategies","Load Balancing","Read Replicas & Fan-out"],
   tldr="A CDN pushes copies of content to edge POPs near users, cutting latency and shielding the origin.",
   parts=[("Edge POP","🛰️","Caches content near users",["Hits served in <20ms","Honors Cache-Control / ETag"]),("Origin","🏠","Source of truth",["Hit only on a miss","Protected by an origin shield"]),("Invalidation","🧹","Purges stale copies",["Purge by URL or tag","Or version the asset path"])],
   table=(["Concept","Meaning"],[["TTL","how long an edge keeps a copy"],["Hit ratio","% served from the edge"],["Origin shield","mid-tier cache protecting origin"],["SWR","serve stale, refresh in background"]]),
   codekey="cdn"),
 topic("System Design","Database Sharding","🪓","deep",
   ["Consistent Hashing","Database Replication","Consistency Models","Quorums"],
   tldr="Split one dataset across many DBs by a shard key; the price is cross-shard queries and rebalancing.",
   points=["Pick a shard key with high cardinality + even access (e.g. user_id).","Hash sharding spreads evenly but kills range scans; range keeps order but risks hotspots.","A routing layer maps key → shard, consistently for reads + writes.","Resharding is the hard part — consistent hashing minimizes movement."],
   eq=(r"\text{keys per node} \approx \dfrac{K}{N}","K keys over N shards"),
   codekey="shard",
   pitfalls=["Cross-shard joins/transactions are costly or impossible.","A bad key creates a hotspot shard.","Resharding without consistent hashing moves almost everything."],
   when=["A single DB can't hold the data or write rate.","Access partitions naturally by a key."],
   table=(["Strategy","Pro","Con"],[["Hash","even spread","no range scans"],["Range","range scans","hotspots"],["Directory","flexible","lookup is a SPOF"]])),
 topic("System Design","Database Replication","🧬","compare",
   ["Database Sharding","Quorums","Read Replicas & Fan-out","Consistency Models"],
   tldr="Keep copies on multiple nodes for read scale + failover; the sync model sets your consistency/latency trade.",
   a=("Synchronous",["Primary waits for replica ack before commit.","No data loss on primary failure.","Higher write latency; a slow replica stalls writes."]),
   b=("Asynchronous",["Primary commits, replicates in the background.","Low write latency, scales reads.","Replica lag → stale reads + a loss window on failover."]),
   table=(["Topology","Reads","Writes","Failover"],[["Primary-replica","scale on replicas","primary only","promote a replica"],["Multi-primary","anywhere","conflict-prone","needs resolution"],["Quorum","R replicas","W replicas","R+W>N"]]),
   verdict="Async primary-replica for read scale; sync or quorum when you can't lose a committed write."),
 topic("System Design","CAP Theorem","🎲","socratic",
   ["Consistency Models","Quorums","Database Replication","Consensus & Raft"],
   tldr="In a network partition a store must choose: stay Consistent (reject) or stay Available (serve maybe-stale).",
   qa=[("What do C, A, P mean?","Consistency = every read sees the latest write; Availability = every request gets a non-error response; Partition tolerance = the system keeps working despite dropped messages between nodes."),("If P is unavoidable, why 'pick 2'?","Because partitions WILL happen, P is mandatory — so the real choice DURING a partition is C vs A. With no partition you can have both."),("Is CAP the whole story?","No — PACELC adds: Else (no partition) you still trade Latency vs Consistency."),("CP vs AP example?","CP: a strongly-consistent store rejects writes during a partition. AP: Dynamo-style stores serve and reconcile later.")],
   takeaway="Decide per operation whether stale-but-up or correct-but-down is the lesser evil."),
 topic("System Design","Consistency Models","🪞","cheat",
   ["CAP Theorem","Vector Clocks","Quorums","Database Replication"],
   tldr="A spectrum from 'reads always see the latest write' down to 'reads see something, eventually'.",
   table=(["Model","Guarantee","Example"],[["Linearizable","latest + real-time order","etcd, Spanner"],["Sequential","one global order","some DBs"],["Causal","cause precedes effect","collab editors"],["Read-your-writes","see your own writes","sticky session"],["Eventual","converges if writes stop","Dynamo, DNS"]]),
   tips=["Pick the weakest model the UX tolerates — it's cheaper + faster.","Session guarantees fix most 'it looked stale' bugs.","Strong consistency usually means a consensus round-trip."]),
 topic("System Design","Message Queues","📨","anatomy",
   ["Pub/Sub","Backpressure","Saga Pattern","Idempotency"],
   tldr="A queue decouples producers from consumers, absorbs bursts, and lets work be retried.",
   parts=[("Producer","📤","Publishes messages",["Fire-and-forget or await ack","Sets routing key / topic"]),("Broker","🏤","Stores + routes",["Durable log or queue","Delivery guarantees"]),("Consumer","📥","Processes + acks",["Ack on success, nack to retry","Scale by adding consumers"])],
   table=(["Concept","Meaning"],[["Ack","consumer confirms processing"],["DLQ","dead-letter for poison messages"],["Backpressure","slow consumer signals producer"],["Ordering","per-partition / per-key only"]]),
   codekey="queue"),
 topic("System Design","API Gateway","🚪","anatomy",
   ["Load Balancing","Rate Limiting","Microservices vs Monolith","Service Mesh"],
   tldr="A single entry point fronting your services: routing, auth, rate-limiting, aggregation in one tier.",
   parts=[("Routing","🚪","Path/host → service",["Versioned routes","Canary splits"]),("Cross-cutting","🛡️","Auth, TLS, limits",["JWT / OAuth verify","Rate limit + WAF"]),("Aggregation","🧩","Fan-out + combine",["BFF per client","Response shaping"])],
   table=(["Does","Why"],[["AuthN/Z","one place to enforce"],["Rate limit","protect backends"],["Routing","decouple clients from topology"],["Aggregation","fewer client round-trips"]]),
   codekey="gateway"),
 topic("System Design","Rate Limiting","🚦","deep",
   ["Load Balancing","API Gateway","Backpressure","Circuit Breaker"],
   tldr="Cap how fast a client can hit you to protect capacity + ensure fairness; the algorithm sets burst behaviour.",
   points=["Token bucket allows bursts up to bucket size, refilling steadily.","Leaky bucket smooths output to a constant rate.","Fixed window is simple but spikes at boundaries; sliding window fixes that.","Enforce per-key in a shared store so the limit is global."],
   codekey="bucket",
   pitfalls=["Fixed-window doubles the allowed rate at the edge.","Per-instance limits don't sum to a global limit.","Return 429 + Retry-After so clients back off."],
   when=["Public APIs, login endpoints, expensive ops.","Protecting a capacity-limited downstream."],
   table=(["Algorithm","Bursts?","Smoothness"],[["Token bucket","yes (≤ size)","good"],["Leaky bucket","no","constant"],["Fixed window","spiky","poor"],["Sliding log","precise","memory-heavy"]])),
 # ---- Distributed Systems ----
 topic("Distributed Systems","Consensus & Raft","🗳️","deep",
   ["Paxos","Leader Election","Quorums","Two-Phase Commit"],
   tldr="Raft makes a cluster agree on one ordered log despite failures, via a leader replicating to a majority.",
   points=["Roles: follower, candidate, leader; terms act as a logical clock.","A candidate wins with a majority of votes for its term.","The leader commits an entry once a majority has replicated it.","On leader loss, an election timeout starts a new term + vote."],
   eq=(r"\text{majority} = \left\lfloor \tfrac{N}{2} \right\rfloor + 1","a strict majority is needed to commit"),
   codekey="raft",
   deep=["Log matching: if two logs share an entry at the same index+term, all prior entries match — the safety backbone.","Leader completeness: a committed entry survives all future leaders, because elections require an up-to-date log."],
   pitfalls=["Even N gives no extra fault tolerance — use odd N.","Split votes waste terms; randomized timeouts reduce them."],
   when=["Leader election, config stores, replicated state machines.","Any single agreed order with crash tolerance."]),
 topic("Distributed Systems","Paxos","🏛️","socratic",
   ["Consensus & Raft","Quorums","Two-Phase Commit","Leader Election"],
   tldr="Paxos proves unreliable nodes can agree on a single value — famously correct, famously hard to follow.",
   qa=[("What are the roles?","Proposers propose, acceptors vote, learners learn the chosen value; one node often plays several roles."),("How is a value chosen?","Phase 1 (prepare): pick number n, ask a majority to promise not to accept lower. Phase 2 (accept): if promised, ask them to accept your value; a value a majority accepts is final."),("Why is it safe?","A higher-numbered proposal must adopt any value already accepted by a majority, so once chosen the value can't change."),("Why use Raft instead?","Raft packages the same guarantees in an understandable leader+log model; Multi-Paxos is Paxos with a stable leader.")],
   takeaway="Consensus works because any two majorities intersect — so at most one value is chosen."),
 topic("Distributed Systems","Leader Election","👑","flow",
   ["Consensus & Raft","Distributed Locks","Quorums","Paxos"],
   tldr="Pick exactly one coordinator among peers, and re-pick fast when it dies.",
   steps=[("Detect there is no live leader (lease/heartbeat expired).",["Each node tracks a leader lease/TTL"]),("Nominate yourself and request votes (or grab a lock).",["Bump term / use a fencing token"]),("Win with a majority (or acquire the lock).",["Majority prevents two leaders"]),("Announce + start heartbeats.",["Renew the lease before expiry"])],
   qa=[("What stops split-brain?","A majority quorum or a lease + fencing token; a minority partition simply can't elect a leader."),("Lock-based vs consensus-based?","A lock (etcd/ZK/Redis) is simple but needs fencing tokens to be safe; consensus (Raft) bakes election in.")],
   pitfalls=["Split-brain if you elect from a minority.","Clock skew breaks naive leases — use monotonic clocks + fencing."]),
 topic("Distributed Systems","Vector Clocks","⏱️","deep",
   ["Consistency Models","CAP Theorem","Gossip Protocol","Database Replication"],
   tldr="A per-node version vector captures causality so you can tell 'happened-before' from 'concurrent' without synced clocks.",
   points=["Each node keeps a counter per node; bump your own on each event.","On send attach your vector; on receive take element-wise max then bump self.","A ≤ B element-wise means A happened-before B; else they're concurrent.","Concurrent events = a conflict to merge (siblings)."],
   eq=(r"A \to B \iff \forall i:\; V_A[i] \le V_B[i] \;\wedge\; V_A \ne V_B","happened-before via vector comparison"),
   codekey="vclock",
   pitfalls=["Vectors grow with writers — prune with dotted version vectors.","They detect conflicts, not resolve them — you still need merge logic."],
   when=["Eventually-consistent stores, CRDTs, collaborative editing.","Detecting concurrent updates."]),
 topic("Distributed Systems","Gossip Protocol","🗣️","anatomy",
   ["Vector Clocks","Consistency Models","Database Replication","Quorums"],
   tldr="Nodes periodically swap state with a few random peers; info spreads epidemically in O(log N) rounds.",
   parts=[("Peer sampling","🎲","Pick random partners",["Avoids hotspots","Robust to churn"]),("State merge","🔀","Anti-entropy",["Take newest per key","Version vectors / CRDTs"]),("Failure detect","💀","SWIM / phi-accrual",["Suspect then confirm","Spreads membership"])],
   eq=(r"\text{rounds to converge} \approx O(\log N)","epidemic spread over N nodes"),
   table=(["Use","Example"],[["Membership","Cassandra, Serf"],["Failure detection","SWIM"],["Config spread","service meshes"]])),
 topic("Distributed Systems","Quorums","🔢","cheat",
   ["Database Replication","Consistency Models","CAP Theorem","Consensus & Raft"],
   tldr="Read/write to overlapping subsets so any read intersects the latest write: R + W > N.",
   table=(["Term","Meaning"],[["N","replicas per key"],["W","acks to commit a write"],["R","replicas read"],["R+W>N","read set overlaps write set"],["W>N/2","prevents conflicting writes"]]),
   eq=(r"R + W > N","the quorum overlap condition"),
   tips=["W=N, R=1 → fast reads, fragile writes.","R=N, W=1 → fast writes, slow reads.","R=W=⌈(N+1)/2⌉ balances both."]),
 topic("Distributed Systems","Two-Phase Commit","🤝","timeline",
   ["Saga Pattern","Consensus & Raft","Distributed Locks","Idempotency"],
   tldr="A coordinator gets all participants to PREPARE then COMMIT — atomic across nodes, but it blocks if the coordinator dies.",
   milestones=[("Phase 1 · Prepare","coordinator asks everyone 'can you commit?'",["Each votes yes (durably prepared) or no"]),("Decision","all yes → commit, else → abort",["Decision is logged by the coordinator"]),("Phase 2 · Finish","coordinator broadcasts the outcome",["Participants finalize + ack"]),("The flaw","coordinator crash after prepare → participants block",["3PC reduces blocking; consensus is preferred"])],
   quote="2PC is atomic but not available: a dead coordinator leaves prepared participants stuck holding locks."),
 topic("Distributed Systems","Saga Pattern","🧵","flow",
   ["Two-Phase Commit","Idempotency","Message Queues","Event Sourcing"],
   tldr="Replace one distributed transaction with a sequence of local transactions + compensations on failure.",
   steps=[("Break the workflow into local steps, each with a compensation.",["reserve → charge → ship; refund/cancel as compensations"]),("Run steps forward; persist progress.",["Each step commits locally"]),("On failure, run compensations in reverse for completed steps.",["Undo, don't rollback"]),("Make every step + compensation idempotent.",["Retries must be safe"])],
   qa=[("Orchestration vs choreography?","Orchestration: a central coordinator drives steps (easier to reason about). Choreography: services react to events (looser, harder to trace)."),("Why not 2PC?","2PC blocks and doesn't scale across heterogeneous services; sagas trade atomicity for availability + eventual consistency.")],
   pitfalls=["Compensations aren't perfect rollbacks (money moved → refund).","Without idempotency, retries double-apply steps."]),
 topic("Distributed Systems","Distributed Locks","🔒","deep",
   ["Leader Election","Idempotency","Quorums","Consensus & Raft"],
   tldr="Coordinate exclusive access across machines — but a lock without fencing is a foot-gun under GC pauses + partitions.",
   points=["A lock service grants a lease with a TTL.","The holder must renew before expiry or lose the lock.","A fencing token (monotonic number) makes stale holders' writes rejectable.","Redlock spreads the lock over N nodes for majority safety (debated)."],
   codekey="dlock",
   pitfalls=["A GC pause can silently lose the lock → fence writes by token.","Clock-based TTLs + skew = two holders.","Locks reduce availability; prefer idempotency/partitioning."],
   when=["Single-writer invariants (leader, cron, migration).","Guarding a non-idempotent external side effect."]),
 topic("Distributed Systems","Idempotency","🔁","deep",
   ["Saga Pattern","Message Queues","Rate Limiting","Distributed Locks"],
   tldr="An operation you can safely retry: doing it twice equals doing it once — the antidote to at-least-once delivery.",
   points=["Clients send an idempotency key; the server records key → result.","A repeat with the same key returns the stored result, no second effect.","PUT/DELETE/set-to-X are naturally idempotent; 'charge $10' is not.","Pair with dedup windows / unique constraints."],
   codekey="idem",
   pitfalls=["Storing only the key (not the response) → retries get a different answer.","Concurrent first-tries race — guard with a unique index.","Scope + expire keys to bound storage."],
   when=["Payment/order APIs, webhooks, queue consumers.","Any at-least-once delivery."]),
 # ---- Scalability & Performance ----
 topic("Scalability & Performance","Horizontal vs Vertical Scaling","📐","compare",
   ["Load Balancing","Database Sharding","Universal Scalability Law","Connection Pooling"],
   tldr="Scale up (bigger box) or scale out (more boxes) — they fail differently and cost differently.",
   a=("Vertical (scale up)",["Add CPU/RAM to one machine.","Simple — no distribution, no code changes.","Hard ceiling + a SPOF; pricey at the top."]),
   b=("Horizontal (scale out)",["Add machines behind a balancer.","Near-linear capacity + redundancy.","Needs statelessness, sharding, coordination."]),
   table=(["Dimension","Vertical","Horizontal"],[["Ceiling","hardware limit","~unbounded"],["Failure","SPOF","degrades gracefully"],["Complexity","low","high"],["Cost curve","superlinear","~linear"]]),
   verdict="Scale up until it's cheaper/safer to scale out; design stateless so 'out' stays an option."),
 topic("Scalability & Performance","Amdahl's Law","⚖️","hero",
   ["Universal Scalability Law","Little's Law","Horizontal vs Vertical Scaling","Backpressure"],
   pattern="Parallel speedup ceiling", usefor="capacity planning",
   tldr="The serial fraction of a program caps its speedup — more cores give diminishing, bounded returns.",
   points=["If fraction p is parallelizable, N cores give speedup S(N).","As N→∞, speedup → 1/(1−p): the serial part dominates.","10% serial ⇒ max 10×, no matter the core count.","Optimize the serial bottleneck, not just core count."],
   eq=(r"S(N) = \dfrac{1}{(1-p) + \dfrac{p}{N}} \;\xrightarrow{N\to\infty}\; \dfrac{1}{1-p}","speedup with parallel fraction p"),
   table=(["Serial part","Max speedup"],[["1%","100×"],["5%","20×"],["10%","10×"],["25%","4×"]])),
 topic("Scalability & Performance","Little's Law","📊","hero",
   ["Connection Pooling","Backpressure","Universal Scalability Law","Rate Limiting"],
   pattern="Queueing identity", usefor="sizing pools + queues",
   tldr="In any stable system, average items in system = arrival rate × time in system: L = λW.",
   points=["L = items in system, λ = arrival rate, W = time in system.","It's distribution-free — holds for any stable queue.","Rearrange for any term: W=L/λ, λ=L/W.","Use it to size pools, queues, and concurrency."],
   eq=(r"L = \lambda W","average concurrency = throughput × latency"),
   table=(["Solve for","Formula"],[["concurrency L","λ × W"],["latency W","L / λ"],["throughput λ","L / W"]])),
 topic("Scalability & Performance","Universal Scalability Law","📉","deep",
   ["Amdahl's Law","Little's Law","Horizontal vs Vertical Scaling","Connection Pooling"],
   tldr="Real systems don't scale linearly: contention and crosstalk eventually make adding nodes HURT.",
   points=["Linear scaling is cut by α (contention: serialized resources).","And by β (coherency: nodes coordinating, growing as N²).","Past a knee, throughput peaks then DECLINES with more nodes.","Find the knee; don't add capacity past it."],
   eq=(r"C(N) = \dfrac{N}{1 + \alpha (N-1) + \beta N (N-1)}","capacity vs concurrency; α=contention, β=coherency"),
   pitfalls=["β>0 means a retrograde region — more nodes, less throughput.","Chasing linear scaling ignores coordination cost."],
   when=["Modeling DB / connection scaling.","Explaining why 2× nodes ≠ 2× throughput."]),
 topic("Scalability & Performance","Connection Pooling","🏊","anatomy",
   ["Little's Law","Database Replication","Backpressure","Universal Scalability Law"],
   tldr="Reuse a bounded set of expensive connections instead of one per request — bounded, predictable load.",
   parts=[("Pool","🏊","Holds live connections",["Min/idle + max size","Validates on borrow"]),("Borrow/return","🔁","Lease per request",["Block or fail-fast when empty","Return promptly (try/finally)"]),("Eviction","🧹","Reaps stale conns",["Idle + max-lifetime","Avoids server-side timeouts"])],
   eq=(r"\text{pool size} \approx \lambda \times W","size from throughput × hold time (Little's Law)"),
   table=(["Knob","Effect"],[["maxSize","caps DB concurrency"],["acquireTimeout","fail vs queue"],["maxLifetime","recycle stale conns"],["idleTimeout","shrink when quiet"]])),
 topic("Scalability & Performance","Write-Ahead Log (WAL)","📓","deep",
   ["LSM Trees","Database Replication","Event Sourcing","Consensus & Raft"],
   tldr="Append the intent to a durable log BEFORE mutating data, so a crash can replay to a consistent state.",
   points=["Log the change + fsync; only then apply to pages.","Recovery replays committed entries and rolls back uncommitted ones.","Sequential log writes beat random page writes.","Checkpoints bound startup replay."],
   codekey="wal",
   deep=["WAL underpins durability (the D in ACID) and powers replication: ship the log to replicas.","Group commit batches many fsyncs into one for throughput."],
   pitfalls=["Skipping fsync = fast but not durable.","No checkpoints = slow recovery."],
   when=["Databases, brokers, any durable store.","Crash consistency + log-based replication."]),
 topic("Scalability & Performance","LSM Trees","🌲","deep",
   ["Write-Ahead Log (WAL)","Bloom Filter","Database Sharding","Caching Strategies"],
   tldr="Log-Structured Merge trees turn random writes into sequential ones via a memtable flushed to sorted files.",
   points=["Writes hit an in-memory memtable (sorted) + the WAL.","A full memtable flushes to an immutable sorted file (SSTable).","Reads check memtable then SSTables newest→oldest; Bloom filters skip misses.","Compaction merges SSTables, dropping tombstones/old versions."],
   codekey="lsm",
   deep=["Write amplification (compaction) vs read amplification (many SSTables) is the core tension — leveled vs size-tiered picks a side.","A Bloom filter per SSTable makes negative lookups O(1)."],
   pitfalls=["Compaction can stall writes if under-provisioned.","Range scans touch many files."],
   when=["Write-heavy stores (Cassandra, RocksDB).","SSD-backed high-ingest workloads."],
   table=(["vs B-Tree","LSM","B-Tree"],[["Writes","sequential","random"],["Reads","amplified","direct"],["Space","compaction churn","in-place"]])),
 topic("Scalability & Performance","Consistent Hashing","🧮","hero",
   ["Database Sharding","Load Balancing","Caching Strategies","Quorums"],
   pattern="Partitioning", usefor="rebalancing-friendly sharding",
   tldr="Map keys and nodes onto a ring so adding/removing a node moves only ~K/N keys, not the whole keyspace.",
   points=["Hash nodes + keys onto the same circular space.","A key belongs to the next node clockwise.","Add/remove a node → only its arc of keys moves.","Virtual nodes (many points per server) even out load."],
   eq=(r"\text{keys moved on change} \approx \dfrac{K}{N}","vs K under naive mod-N hashing"),
   codekey="ring",
   table=(["","With vnodes","Without"],[["Load spread","even","lumpy"],["Rebalance cost","~K/N","large"]])),
 topic("Scalability & Performance","Backpressure","🌊","flow",
   ["Message Queues","Rate Limiting","Little's Law","Circuit Breaker"],
   tldr="When a consumer can't keep up, push the slowdown UPSTREAM instead of buffering until you OOM.",
   steps=[("Measure the lag (queue depth / inflight vs capacity).",["Bounded queues make lag visible"]),("Signal upstream to slow or stop.",["Pause reads, return 429, reactive request(n)"]),("Shed or buffer-with-limit if you must.",["Drop oldest / lowest priority"]),("Recover below a low-water mark.",["Hysteresis avoids flapping"])],
   qa=[("Why not an unbounded buffer?","It hides the problem until memory runs out, then everything fails at once. Bounded + backpressure fails gracefully."),("Push vs pull?","Pull (consumer asks for N) is naturally back-pressured; push needs explicit credits/limits.")],
   pitfalls=["Unbounded queues = deferred OOM.","No hysteresis → on/off flapping."]),
 topic("Scalability & Performance","Read Replicas & Fan-out","📤","compare",
   ["Database Replication","Caching Strategies","Message Queues","Content Delivery Network (CDN)"],
   tldr="Scale reads by replicating, and scale feeds by choosing fan-out-on-write vs on-read.",
   a=("Fan-out on write",["Push each new item into every follower's feed at write time.","Reads are trivial (precomputed timeline).","Celebrity problem: one write → millions of inserts."]),
   b=("Fan-out on read",["Assemble the feed by querying followees at read time.","Cheap writes; no fan-out storm.","Reads are heavy + slow for big-following users."]),
   table=(["Axis","On write","On read"],[["Write cost","high","low"],["Read cost","low","high"],["Best for","most users","celebrities"]]),
   verdict="Hybrid: fan-out-on-write for normal users, on-read for celebrities; serve reads from replicas."),
 # ---- Resilience Patterns ----
 topic("Resilience Patterns","Circuit Breaker","⚡","deep",
   ["Retry with Backoff","Timeout & Deadline","Bulkhead","Graceful Degradation"],
   tldr="Stop hammering a failing dependency: trip OPEN after errors, fail fast, then probe HALF-OPEN before closing.",
   points=["Closed: calls flow; count failures in a window.","Open: threshold exceeded → reject instantly for a cooldown.","Half-open: a few trial calls; success → close, failure → re-open.","Failing fast protects your threads + gives the dependency time."],
   codekey="breaker",
   deep=["Pair with timeouts + retries + a fallback for graceful degradation.","Per-dependency breakers stop one slow service from exhausting your whole pool."],
   pitfalls=["No timeout → the breaker never sees failures.","Retrying through an open breaker defeats the purpose."],
   when=["Calls to flaky downstreams / 3rd-party APIs.","Preventing cascading failure + thread exhaustion."],
   table=(["State","Behavior","Exit"],[["Closed","allow, count fails","→ Open on threshold"],["Open","reject fast","→ Half-open after cooldown"],["Half-open","trial calls","→ Closed/Open by result"]])),
 topic("Resilience Patterns","Retry with Backoff","⏳","cheat",
   ["Circuit Breaker","Idempotency","Timeout & Deadline","Rate Limiting"],
   tldr="Retry transient failures with exponential backoff + jitter so you don't synchronize a thundering herd.",
   table=(["Strategy","Behavior","Risk"],[["Immediate","retry now","herd / amplifies outage"],["Fixed delay","wait constant","synchronized retries"],["Exponential","2^n × base","bursty waves"],["Expo + jitter","randomize","best — spreads load"]]),
   snippets=[("Exponential + full jitter","python","import random\n\ndef backoff(n, base=0.1, cap=10):\n    return random.uniform(0, min(cap, base * 2 ** n))","dark"),("Retry only the retryable","go","func retryable(err error, code int) bool {\n  return errors.Is(err, ErrTimeout) ||\n    code == 429 || code >= 500\n}","light")],
   tips=["Only retry idempotent ops (or use idempotency keys).","Cap total attempts + total time.","Full jitter beats fixed exponential under load."]),
 topic("Resilience Patterns","Bulkhead","🚢","anatomy",
   ["Circuit Breaker","Backpressure","Graceful Degradation","Microservices vs Monolith"],
   tldr="Isolate resources into compartments (like a ship's hull) so one overloaded dependency can't sink the service.",
   parts=[("Pools","🚢","Per-dependency limits",["Separate thread/conn pools","One saturates, others survive"]),("Quotas","📦","Caps per tenant/route",["Fair sharing","Noisy-neighbor containment"]),("Isolation","🧱","Process/instance split",["Blast-radius reduction","Independent failure domains"])],
   table=(["Without","With bulkheads"],[["one slow dep exhausts all threads","limited to its pool"],["one tenant starves others","per-tenant quota"]])),
 topic("Resilience Patterns","Timeout & Deadline","⏰","flow",
   ["Circuit Breaker","Retry with Backoff","Backpressure","SLO, SLI, SLA"],
   tldr="Never wait forever. Bound every remote call and propagate a deadline so the whole request gives up together.",
   steps=[("Set a timeout on every network call.",["No call is unbounded"]),("Propagate a deadline across hops (context).",["Downstreams inherit remaining time"]),("Budget: split the parent deadline among children.",["Leave slack for retries"]),("On timeout: cancel, free resources, return fast.",["Cancellation prevents zombie work"])],
   qa=[("Timeout vs deadline?","A timeout is a per-call duration; a deadline is an absolute time the whole request shares, so nested calls don't each restart the clock."),("Relation to circuit breakers?","Timeouts are how a breaker SEES failure; without them slow calls look 'fine' forever.")],
   pitfalls=["Per-call timeouts without a shared deadline → total = sum, blows SLO.","No cancellation → work continues after the client gave up."]),
 topic("Resilience Patterns","Graceful Degradation","🪶","flow",
   ["Circuit Breaker","Caching Strategies","Chaos Engineering","Feature Flags"],
   tldr="When a dependency fails, serve a reduced-but-useful experience instead of an error page.",
   steps=[("Classify features: core vs enhancement.",["Protect the core path"]),("Define a fallback per dependency.",["Cached/stale data, defaults, skeletons"]),("Detect failure (breaker/timeout) → switch to fallback.",["Fast, automatic"]),("Make it visible + auto-recover.",["'Showing cached results' banner"])],
   qa=[("Example?","Recommendations down → show popular items instead of a blank panel."),("Different from a hard failure?","The user still completes the core task; only the nice-to-haves degrade.")],
   pitfalls=["Silent fallbacks hide outages — emit metrics.","The fallback path is rarely tested → chaos-test it."]),
 topic("Resilience Patterns","CQRS","✂️","anatomy",
   ["Event Sourcing","Read Replicas & Fan-out","Message Queues","Microservices vs Monolith"],
   tldr="Command Query Responsibility Segregation: separate the write model from the read model so each is optimized.",
   parts=[("Command side","✍️","Handles writes",["Validates + emits events","Normalized aggregate model"]),("Read side","👁️","Serves queries",["Denormalized projections","Tuned per view"]),("Sync","🔁","Write→read propagation",["Via events; eventually consistent","Rebuildable projections"])],
   table=(["Aspect","Command","Query"],[["Shape","write-optimized","read-optimized"],["Consistency","strong","eventual"],["Scale","by writes","by reads"]]),
   codekey="cqrs"),
 topic("Resilience Patterns","Event Sourcing","📼","timeline",
   ["CQRS","Write-Ahead Log (WAL)","Saga Pattern","Message Queues"],
   tldr="Store the full sequence of state-changing events as the source of truth; current state is a fold over the log.",
   milestones=[("Append events","every change is an immutable fact",["OrderPlaced, ItemShipped — never update in place"]),("Derive state","replay/fold events to rebuild an aggregate",["state = reduce(events)"]),("Project views","build read models from the stream",["the CQRS read side"]),("Time-travel","replay to any point; add projections retroactively",["full audit + debuggability"])],
   quote="The log is the truth; every table is just a cache you can rebuild.",
   codekey="es"),
 topic("Resilience Patterns","Microservices vs Monolith","🧱","compare",
   ["Service Mesh","API Gateway","CQRS","Bulkhead"],
   tldr="Independent deployable services vs one cohesive codebase — an organizational trade, not just a technical one.",
   a=("Monolith",["One deployable, one codebase, in-process calls.","Simple ops, easy transactions, fast local dev.","Scales as a unit; big teams collide."]),
   b=("Microservices",["Many small services, independently deployed/scaled.","Team autonomy + fault isolation + polyglot.","Distributed-systems tax: network, data, ops."]),
   table=(["Axis","Monolith","Microservices"],[["Deploy","all at once","per service"],["Data","one DB, ACID","per service, eventual"],["Failure","all-or-nothing","isolated"],["Ops cost","low","high"]]),
   verdict="Start with a modular monolith; split out services only where scaling / team boundaries demand it."),
 topic("Resilience Patterns","Service Mesh","🕸️","anatomy",
   ["Microservices vs Monolith","API Gateway","Observability: Metrics, Logs, Traces","Circuit Breaker"],
   tldr="Move service-to-service concerns (mTLS, retries, routing, telemetry) into sidecar proxies, out of app code.",
   parts=[("Data plane","🛰️","Sidecar proxies",["Intercept all traffic","mTLS, retries, timeouts"]),("Control plane","🧭","Config + policy",["Pushes routing/security","Service discovery"]),("Observability","🔭","Free telemetry",["Golden metrics per hop","Distributed traces"])],
   table=(["Concern","Without mesh","With mesh"],[["mTLS","per-app libs","automatic"],["Retries","in each service","policy in mesh"],["Tracing","manual","injected"]])),
 topic("Resilience Patterns","Pub/Sub","📡","anatomy",
   ["Message Queues","Event Sourcing","CQRS","Gossip Protocol"],
   tldr="Publishers emit events to topics; any number of subscribers react — fully decoupled producers + consumers.",
   parts=[("Topic","📡","Named channel",["Publishers don't know subscribers","Fan-out to many"]),("Subscription","📥","Consumer's view",["Push or pull delivery","Independent offsets"]),("Delivery","🚚","Guarantees",["At-least-once + dedup","Ordering per key"])],
   table=(["vs Queue","Pub/Sub","Queue"],[["Consumers","many (each gets all)","competing (each once)"],["Coupling","topic","work distribution"]]),
   codekey="pubsub"),
 # ---- Reliability & Ops ----
 topic("Reliability & Ops","Observability: Metrics, Logs, Traces","🔭","anatomy",
   ["SLO, SLI, SLA","Service Mesh","Health Checks","Chaos Engineering"],
   tldr="The three pillars let you ask NEW questions about a running system without shipping new code.",
   parts=[("Metrics","📈","Aggregated numbers",["Cheap, long-retention","RED/USE; alert on these"]),("Logs","📜","Discrete events",["Rich context, high volume","Structured + sampled"]),("Traces","🧵","Request across services",["Spans + parent links","Find the slow hop"])],
   table=(["Pillar","Answers","Cost"],[["Metrics","is it healthy? (trends)","low"],["Logs","what happened here?","med-high"],["Traces","where is the latency?","medium"]])),
 topic("Reliability & Ops","SLO, SLI, SLA","🎯","cheat",
   ["Observability: Metrics, Logs, Traces","Timeout & Deadline","Canary Releases","Incident Response & Postmortems"],
   tldr="Measure reliability (SLI), target it (SLO), contract it (SLA) — and spend the error budget deliberately.",
   table=(["Term","Is","Example"],[["SLI","a measured signal","% requests <300ms"],["SLO","internal target","99.9% over 28d"],["SLA","external contract","99.5% or credits"],["Error budget","1 − SLO","0.1% ≈ 43m/mo"]]),
   eq=(r"A = \dfrac{\text{MTBF}}{\text{MTBF} + \text{MTTR}}","availability from mean time between / to repair"),
   tips=["Alert on SLO burn rate, not every blip.","Spend error budget on releases; freeze when exhausted.","Pick SLIs that reflect user pain, not server vanity."]),
 topic("Reliability & Ops","Chaos Engineering","🐵","socratic",
   ["Graceful Degradation","Circuit Breaker","Observability: Metrics, Logs, Traces","Canary Releases"],
   tldr="Deliberately inject failure in production-like conditions to find weaknesses before they find you.",
   qa=[("Isn't breaking prod reckless?","It's controlled: a hypothesis, a small blast radius, an automated abort, and monitoring. You verify resilience you already designed."),("A good first experiment?","Kill one instance and confirm the balancer + autoscaler recover with no user impact. Then add latency, then partition a dependency."),("What do you need first?","Steady-state metrics + alerting + the ability to stop instantly."),("The payoff?","You convert unknown failure modes into known, tested ones — and prove your fallbacks actually work.")],
   takeaway="Resilience you haven't tested under failure is just a hypothesis."),
 topic("Reliability & Ops","Blue-Green Deployment","🔵","compare",
   ["Canary Releases","Feature Flags","SLO, SLI, SLA","Health Checks"],
   tldr="Run two identical environments; flip traffic from old (blue) to new (green) for instant cutover + rollback.",
   a=("Blue-Green",["Two full envs; switch 100% at once.","Instant rollback (flip back).","Doubles infra; DB migrations need care."]),
   b=("Rolling update",["Replace instances batch by batch in place.","No extra full env.","Slow rollback; mixed versions mid-rollout."]),
   table=(["Axis","Blue-Green","Rolling"],[["Cutover","instant","gradual"],["Rollback","instant","slow"],["Cost","2× env","1× env"],["Mixed versions","no","yes"]]),
   verdict="Blue-green for instant rollback on critical paths; rolling/canary when infra cost matters."),
 topic("Reliability & Ops","Canary Releases","🐤","flow",
   ["Blue-Green Deployment","Feature Flags","SLO, SLI, SLA","Observability: Metrics, Logs, Traces"],
   tldr="Ship the new version to a tiny slice of traffic, watch the metrics, then ramp — or roll back automatically.",
   steps=[("Deploy the new version alongside the old.",["No traffic yet"]),("Route a small % (1–5%) to the canary.",["By header / user / random"]),("Compare canary vs baseline on SLIs.",["Errors, latency, business metrics"]),("Ramp gradually or auto-rollback on regression.",["10% → 50% → 100%"])],
   qa=[("Why not just blue-green?","Canary limits the blast radius to a few % and catches regressions real users surface, before full exposure."),("What makes it safe?","Automated metric comparison + an automatic rollback trigger.")],
   pitfalls=["Too-small canary → not enough signal.","No auto-rollback → a human is the 3am bottleneck."]),
 topic("Reliability & Ops","Feature Flags","🚩","flow",
   ["Canary Releases","Blue-Green Deployment","Graceful Degradation","CQRS"],
   tldr="Decouple deploy from release: ship code dark, then turn features on/off at runtime per cohort.",
   steps=[("Wrap the new path in a flag (default off).",["Deploy safely, release later"]),("Target cohorts: %, user, plan, region.",["Gradual rollout / A-B"]),("Flip on; monitor; kill instantly if bad.",["A flag is a runtime circuit breaker"]),("Remove the flag once stable.",["Avoid flag debt"])],
   qa=[("Flags vs canary?","Canary is infra-level traffic split; flags are app-level per-feature toggles — they compose."),("Risks?","Flag debt + combinatorial config; track and expire flags.")],
   pitfalls=["Stale flags rot into dead code paths.","Flag combinations explode the test surface."]),
 topic("Reliability & Ops","Health Checks","❤️","cheat",
   ["Load Balancing","Graceful Degradation","SLO, SLI, SLA","Blue-Green Deployment"],
   tldr="Expose liveness/readiness so orchestrators restart what's dead and route around what's not ready.",
   table=(["Probe","Asks","On fail"],[["Liveness","is the process wedged?","restart it"],["Readiness","can it serve now?","stop routing"],["Startup","still booting?","delay other probes"]]),
   snippets=[("Readiness handler","go","func ready(w http.ResponseWriter, r *http.Request) {\n  if db.Ping() != nil { w.WriteHeader(503); return }\n  w.WriteHeader(200)\n}","dark"),("k8s probe","yaml","readinessProbe:\n  httpGet: { path: /readyz, port: 8080 }\n  periodSeconds: 5\n  failureThreshold: 3","light")],
   tips=["Readiness checks critical deps; liveness should NOT (avoid restart storms).","Make checks cheap — they run constantly.","Fail readiness during shutdown to drain gracefully."]),
 topic("Reliability & Ops","Incident Response & Postmortems","🚨","timeline",
   ["SLO, SLI, SLA","Chaos Engineering","Observability: Metrics, Logs, Traces","Canary Releases"],
   tldr="Detect, mitigate, then learn — blameless postmortems turn incidents into systemic fixes, not scapegoats.",
   milestones=[("Detect","an alert fires (SLO burn / error spike)",["On-call acknowledges","Open an incident channel"]),("Triage & mitigate","stop the bleeding first",["Roll back / flip flag / scale","Communicate status"]),("Resolve","confirm recovery, close incident",["Verify SLIs back to normal"]),("Postmortem","blameless write-up + actions",["Timeline + root cause","Tracked, owned action items"])],
   quote="Blame the system, not the human — people don't cause incidents, broken systems let them."),
 # ---- Component Gallery (meta) ----
 topic("Component Gallery","Block Component Showcase","🎨","gallery",
   ["Layout & Color Playground","Load Balancing","CAP Theorem"], tldr="(gallery)"),
 topic("Component Gallery","Layout & Color Playground","🌈","playground",
   ["Block Component Showcase","Caching Strategies","Circuit Breaker"], tldr="(playground)"),
]

# ---- folder structure + emission -------------------------------------------
SUBFOLDERS = [("System Design","🧩"),("Distributed Systems","🌐"),
              ("Scalability & Performance","🚀"),("Resilience Patterns","🛡️"),
              ("Reliability & Ops","📈"),("Component Gallery","🎨")]
root_id = str(uuid.uuid4())
fid = {name: str(uuid.uuid4()) for name, _ in SUBFOLDERS}
for t in TOPICS: t["id"] = str(uuid.uuid4())
note_id = {t["title"]: t["id"] for t in TOPICS}

def relation_prop(related):
    ids = [note_id[r] for r in (related or []) if r in note_id]
    return [{"key":"related","label":"Related","type":"relation","value":ids,"relationTarget":"page"}] if ids else []
def b64(o): return base64.b64encode(json.dumps(o).encode()).decode()
def jcol(o): return f"convert_from(decode('{b64(o)}','base64'),'utf8')::jsonb"
def sqlstr(s): return "'" + s.replace("'","''") + "'"

rows = [(root_id, None, ROOT_TITLE, "🏛️", "folder", [], [])]
for name, ic in SUBFOLDERS:
    rows.append((fid[name], root_id, name, ic, "folder", [], []))
for t in TOPICS:
    content = ARCH[t["arch"]](t)
    rows.append((t["id"], fid[t["sub"]], t["title"], t["icon"], None,
                 relation_prop(t.get("related")), content))

lines = ["BEGIN;"]
for rid, parent, title, icon, surface, props, content in rows:
    parent_sql = f"'{parent}'" if parent else "NULL"
    icon_sql = sqlstr(icon) if icon else "NULL"
    surface_sql = sqlstr(surface) if surface else "NULL"
    lines.append(
        "INSERT INTO public.osionos_pages (id, workspace_id, parent_page_id, owner_id, title, "
        "icon, surface, visibility, collaborators, properties, content, created_at, updated_at) VALUES ("
        f"'{rid}', '{WS}', {parent_sql}, '{OWNER}', {sqlstr(title)}, {icon_sql}, {surface_sql}, "
        f"'private', '[]'::jsonb, {jcol(props)}, {jcol(content)}, now(), now());")
lines.append("COMMIT;")
out = "/home/dlesieur/Documents/ft_transcendence/temp/seed_arch.sql"
with open(out, "w") as fh:
    fh.write("\n".join(lines) + "\n")
print(f"root+folders: {len(SUBFOLDERS)+1}  notes: {len(TOPICS)}  rows: {len(rows)}", file=sys.stderr)
print(out)
