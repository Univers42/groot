/* global React, Mascot, SketchApp */
const { useState, useEffect, useRef } = React;

/* =============================================================
   PRISMATICA — landing page
============================================================= */

const TWEAK_DEFAULTS = /*EDITMODE-BEGIN*/{
  "palette": "aurora",
  "mascot": "standard",
  "parallax": "medium"
}/*EDITMODE-END*/;

const PALETTES = {
  aurora: { label: "Aurora", swatch: ["#0a0a12", "#a78bfa", "#22d3ee"] },
  solar:  { label: "Solar",  swatch: ["#fdfaf2", "#6b46c1", "#0891b2"] },
  ember:  { label: "Ember",  swatch: ["#0d0806", "#fb7185", "#fbbf24"] },
  forest: { label: "Forest", swatch: ["#06120c", "#a3e635", "#5eead4"] },
};

const PARALLAX_MULT = { subtle: 0.4, medium: 1, bold: 1.8 };

/* ---------- Hooks ---------- */
function useReveal() {
  useEffect(() => {
    const els = document.querySelectorAll(".reveal");
    const io = new IntersectionObserver(
      (entries) => {
        entries.forEach((e) => {
          if (e.isIntersecting) {
            e.target.classList.add("in");
            io.unobserve(e.target);
          }
        });
      },
      { threshold: 0.12, rootMargin: "0px 0px -40px 0px" }
    );
    els.forEach((el) => io.observe(el));
    return () => io.disconnect();
  }, []);
}

function useParallax(mult = 1) {
  useEffect(() => {
    let raf = null;
    const apply = () => {
      const y = window.scrollY;
      document.documentElement.style.setProperty("--scroll", y);
      const items = document.querySelectorAll("[data-parallax]");
      items.forEach((el) => {
        const speed = parseFloat(el.dataset.parallax) || 0.2;
        const rect = el.getBoundingClientRect();
        const offsetTop = rect.top + window.scrollY;
        const center = window.innerHeight / 2;
        const fromCenter = (rect.top + rect.height / 2) - center;
        const tx = el.dataset.axis === "x" ? -fromCenter * speed * mult : 0;
        const ty = el.dataset.axis === "x" ? 0 : -fromCenter * speed * mult * 0.4;
        const rot = el.dataset.rot ? fromCenter * 0.005 * parseFloat(el.dataset.rot) * mult : 0;
        el.style.transform = `translate3d(${tx}px, ${ty}px, 0) rotate(${rot}deg)`;
      });
      raf = null;
    };
    const onScroll = () => {
      if (raf == null) raf = requestAnimationFrame(apply);
    };
    apply();
    window.addEventListener("scroll", onScroll, { passive: true });
    window.addEventListener("resize", onScroll);
    return () => {
      window.removeEventListener("scroll", onScroll);
      window.removeEventListener("resize", onScroll);
      if (raf) cancelAnimationFrame(raf);
    };
  }, [mult]);
}

function useNavScroll() {
  useEffect(() => {
    const nav = document.querySelector(".nav");
    const onScroll = () => nav.classList.toggle("scrolled", window.scrollY > 12);
    onScroll();
    window.addEventListener("scroll", onScroll, { passive: true });
    return () => window.removeEventListener("scroll", onScroll);
  }, []);
}

/* ---------- Sub components ---------- */
function Nav() {
  return (
    <nav className="nav">
      <a href="#top" className="nav-logo">
        <svg viewBox="0 0 32 32" fill="none">
          <circle cx="11" cy="16" r="8" stroke="currentColor" strokeWidth="1.6" />
          <circle cx="22" cy="16" r="8" stroke="currentColor" strokeWidth="1.6" />
          <circle cx="11" cy="16" r="3" fill="var(--violet)" />
          <circle cx="22" cy="16" r="3" fill="var(--cyan)" />
        </svg>
        prismatica
      </a>
      <div className="nav-links">
        <a href="#how">How it works</a>
        <a href="#what">The app</a>
        <a href="#pricing">Pricing</a>
        <a href="#voices">Voices</a>
        <a href="#faq">FAQ</a>
      </div>
      <div className="nav-cta">
        <a href="#signup" className="btn btn-ghost">Sign in</a>
        <a href="#signup" className="btn btn-primary">Get early access</a>
      </div>
    </nav>
  );
}

function Hero({ mascotVariant }) {
  const stars = useRef(
    Array.from({ length: 36 }, () => ({
      x: Math.random() * 100,
      y: Math.random() * 100,
      d: 1.8 + Math.random() * 3,
      delay: Math.random() * 4,
    }))
  ).current;

  return (
    <section id="top" className="hero">
      <div className="hero-orbit-2"></div>
      <div className="hero-orbit" data-parallax="0.04"></div>
      <div className="hero-planet" data-parallax="0.08"></div>

      <div className="hero-bg">
        <div className="grid" data-parallax="-0.05"></div>
        <div className="glow glow-1" data-parallax="-0.15"></div>
        <div className="glow glow-2" data-parallax="0.18"></div>
        <div className="glow glow-3" data-parallax="0.08"></div>
      </div>

      <div className="hero-comet"></div>
      <div className="hero-comet" style={{ top: "62%", left: "-14%", animationDelay: "5s", animationDuration: "9s" }}></div>

      <div className="hero-stars">
        {stars.map((s, i) => (
          <span
            key={i}
            className="star"
            style={{
              left: s.x + "%",
              top: s.y + "%",
              "--d": s.d + "s",
              "--delay": s.delay + "s",
            }}
          />
        ))}
      </div>

      <div className="hero-ticks">
        <span className="tl"><span className="corner"></span>N 47°36' · BETA-04</span>
        <span className="tr">PRISMATICA / OS · BUILD 0427<span className="corner"></span></span>
        <span className="bl"><span className="corner"></span>OBSERVATORY · WEB &amp; DESKTOP</span>
        <span className="br">SCROLL TO ENGAGE<span className="corner"></span></span>
      </div>

      <div className="wrap hero-inner">
        <span className="eyebrow"><span className="dot"></span>&nbsp;workspace OS · v0.4 beta · for the curious</span>

        <div className="hero-title">
          <h1>
            <span className="stack">See <em>everything</em>.</span>
            <span className="stack">Organise <em>anything</em>.</span>
          </h1>
        </div>

        <p className="hero-sub">
          Prismatica is a workspace OS for web and desktop. Notes, dashboards,
          databases, and your favourite LLM share one canvas — private, shared,
          or forkable. No code required, every line of code optional.
        </p>
        <div className="hero-cta">
          <a href="#signup" className="btn btn-primary">Open the workspace →</a>
          <a href="#what" className="btn btn-ghost">See it sketched</a>
        </div>

        <div className="mascot-stage">
          <div className="ring ring-3" data-parallax="0.04" data-rot="2"></div>
          <div className="ring ring-2" data-parallax="0.06" data-rot="-3"></div>
          <div className="ring ring-1" data-parallax="0.08" data-rot="4"></div>

          <span className="label" style={{ top: "8%", left: "12%" }} data-parallax="0.15">/notes</span>
          <span className="label" style={{ top: "18%", right: "10%" }} data-parallax="-0.15">/queries</span>
          <span className="label" style={{ bottom: "20%", left: "6%" }} data-parallax="0.1">/dashboards</span>
          <span className="label" style={{ bottom: "10%", right: "16%" }} data-parallax="-0.1">/llm</span>

          <div className="float float-1" data-parallax="0.18">
            <span className="dot"></span><span><strong>postgres</strong> · live</span>
          </div>
          <div className="float float-2" data-parallax="-0.22">
            <span><strong>↗ 12.4k</strong> events / hr</span>
          </div>
          <div className="float float-3" data-parallax="0.14">
            <span><strong>shared</strong> with 4</span>
          </div>
          <div className="float float-4" data-parallax="-0.18">
            <span><strong>git</strong> · public</span>
          </div>

          <div className="mascot-wrap" data-parallax="-0.04">
            <div className="mascot-shadow"></div>
            <Mascot variant={mascotVariant} />
          </div>
        </div>
      </div>

      <div className="scroll-cue">
        <span>scroll</span>
        <span className="line"></span>
      </div>
    </section>
  );
}

function Stats() {
  const items = [
    { num: "27", unit: "k", label: "Events processed / sec" },
    { num: "4", unit: ".9★", label: "User rating, beta" },
    { num: "120", unit: "+", label: "Integrations & adapters" },
    { num: "0", unit: "ms", label: "Lock-in. Self-host or cloud." },
  ];
  return (
    <section className="stats">
      <div className="wrap stats-grid">
        {items.map((it, i) => (
          <div key={i} className="stat reveal" style={{ transitionDelay: i * 80 + "ms" }}>
            <div className="stat-num">{it.num}<span className="unit">{it.unit}</span></div>
            <div className="stat-label">{it.label}</div>
          </div>
        ))}
      </div>
    </section>
  );
}

function HowItWorks() {
  const steps = [
    { n: "01", t: "Plug in", p: "Connect cloud or local databases, drop in markdown notes, point your LLM endpoint at the workspace.", icon: "M4 6h16M4 12h16M4 18h10" },
    { n: "02", t: "Compose", p: "Drag windows onto the canvas — tables, charts, prompts, code. Snap them into a layout that thinks like you do.", icon: "M3 3h7v7H3zM14 3h7v7h-7zM3 14h7v7H3zM14 14h7v7h-7z" },
    { n: "03", t: "Track", p: "Build dashboards without code. When you outgrow the no-code path, eject into typescript and keep going.", icon: "M3 17l6-6 4 4 8-8" },
    { n: "04", t: "Share", p: "Keep it private, share with a team, or publish a public, forkable workspace others can build on.", icon: "M12 2v6m0 0l-3-3m3 3l3-3M5 12a7 7 0 1014 0H5z" },
  ];
  return (
    <section id="how" className="section">
      <div className="wrap">
        <div className="section-head reveal">
          <div>
            <span className="eyebrow">how it works</span>
            <h2 style={{ marginTop: 18 }}>Four moves.<br /><em className="italic">That&rsquo;s the whole loop.</em></h2>
          </div>
          <p>
            Prismatica is built around a single canvas where data, ideas, and tools meet.
            You&rsquo;re never more than a drag away from the next thing.
          </p>
        </div>
        <div className="steps">
          {steps.map((s, i) => (
            <div key={i} className="step reveal" style={{ transitionDelay: i * 80 + "ms" }}>
              <div className="step-num">{s.n} &nbsp;·&nbsp; step</div>
              <div className="step-icon">
                <svg width="28" height="28" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round">
                  <path d={s.icon} />
                </svg>
              </div>
              <h3>{s.t}</h3>
              <p>{s.p}</p>
            </div>
          ))}
        </div>
      </div>
    </section>
  );
}

function WhatItDoes() {
  return (
    <section id="what" className="section" style={{ paddingTop: 60 }}>
      <div className="wrap">
        <div className="section-head reveal">
          <div>
            <span className="eyebrow">the application</span>
            <h2 style={{ marginTop: 18 }}>One canvas, <em className="italic">many windows</em>.</h2>
          </div>
          <p>
            Notes, charts, queries, AI, and code share the same surface. Resize them,
            snap them, scope them to a workspace. Below: a sketch of the live thing.
          </p>
        </div>
        <div className="sketch-wrap reveal">
          <div className="sketch-grid-bg"></div>
          <SketchApp />
        </div>
      </div>
    </section>
  );
}

function Pricing() {
  const tiers = [
    {
      name: "Solo",
      price: "0",
      period: "/forever",
      tag: "For curious minds. Local workspaces, one device, zero strings.",
      features: [
        "Unlimited private workspaces",
        "Local databases & file notes",
        "Bring your own LLM key",
        "Community templates",
        { text: "Team sharing", muted: true },
        { text: "SSO & audit logs", muted: true },
      ],
      cta: "Download",
    },
    {
      name: "Studio",
      price: "12",
      period: "/seat / mo",
      tag: "For makers and small teams who want to publish, share, and fork.",
      featured: true,
      features: [
        "Everything in Solo",
        "Shared & public workspaces",
        "Cloud sync + version history",
        "Up to 25 collaborators",
        "Hosted LLM credits included",
        "Community publishing",
      ],
      cta: "Start free 14 days",
    },
    {
      name: "Atlas",
      price: "Custom",
      period: "",
      tag: "For organisations running internal dashboards on top of real data.",
      features: [
        "Everything in Studio",
        "Self-host or VPC deploy",
        "SSO, SCIM, audit logs",
        "Dedicated infra & support",
        "Volume LLM contracts",
        "Custom adapters",
      ],
      cta: "Talk to us",
    },
  ];
  return (
    <section id="pricing" className="section" style={{ background: "var(--bg-2)" }}>
      <div className="wrap">
        <div className="section-head reveal">
          <div>
            <span className="eyebrow">pricing</span>
            <h2 style={{ marginTop: 18 }}>Pay for the <em className="italic">scale</em>,<br />never for the idea.</h2>
          </div>
          <p>The full canvas is free, forever, on your machine. Pay only when you want the cloud, the team, or the org-grade controls.</p>
        </div>
        <div className="pricing-grid">
          {tiers.map((t, i) => (
            <div key={i} className={"tier reveal " + (t.featured ? "tier-featured" : "")} style={{ transitionDelay: i * 80 + "ms" }}>
              {t.featured && <span className="tier-badge">Most popular</span>}
              <div className="tier-name">{t.name}</div>
              <div className="tier-price">
                {t.price !== "Custom" && <span className="currency">$</span>}
                {t.price}
                {t.period && <span className="period">{t.period}</span>}
              </div>
              <p className="tier-tagline">{t.tag}</p>
              <ul className="tier-features">
                {t.features.map((f, j) => {
                  const text = typeof f === "string" ? f : f.text;
                  const muted = typeof f === "object" && f.muted;
                  return <li key={j} className={muted ? "muted" : ""}>{text}</li>;
                })}
              </ul>
              <a href="#signup" className={"btn " + (t.featured ? "btn-primary" : "btn-ghost")}>{t.cta}</a>
            </div>
          ))}
        </div>
      </div>
    </section>
  );
}

function Voices() {
  const quotes = [
    { feat: true, q: "We replaced four dashboards, two notebooks, and a Notion garden with one Prismatica workspace. The team actually opens it now.", n: "Lin Ostrov", r: "Head of Data · Meridian Labs", i: "LO" },
    { q: "It&rsquo;s the first tool that let me hand off a dashboard to my CFO without writing SQL.", n: "Saoirse Patel", r: "Founder · Kelp Logistics", i: "SP" },
    { q: "I forked a public workspace, swapped in our DB, and shipped it the same afternoon.", n: "Ahmad Rivera", r: "Eng Lead · Northtide", i: "AR" },
    { q: "Felt like I was building Lego with my data. In a good way.", n: "Mira Tanaka", r: "Product · Quartzlight", i: "MT" },
    { q: "The LLM lives next to the database. That&rsquo;s the whole pitch and it&rsquo;s the right pitch.", n: "Jules Okafor", r: "Researcher · Polylab", i: "JO" },
    { q: "Our ops team writes their own dashboards now. I&rsquo;m almost out of a job. (I&rsquo;m thrilled.)", n: "Diane Crowley", r: "BI Lead · Bramble &amp; Co.", i: "DC" },
    { q: "Public workspaces are the best documentation we&rsquo;ve ever shipped.", n: "Rafael Quincy", r: "DX · Loomstate", i: "RQ" },
    { q: "I run my private journal, my company KPIs, and a generative writing tool side by side. It just works.", n: "Hae-jin Park", r: "Indie hacker", i: "HP" },
    { q: "The forkability changes the calculus. Templates feel alive.", n: "Bea Hofstadter", r: "Design Eng · Greybox", i: "BH" },
    { q: "Self-hosted, audit-logged, and we still ship features weekly. Rare combo.", n: "Vito Ramos", r: "CTO · Tideline Health", i: "VR" },
    { q: "I stopped opening Excel.", n: "Ana Ferreira", r: "Operations · Salt &amp; Marrow", i: "AF" },
  ];

  const logos = [
    "Meridian Labs", "Kelp Logistics", "Northtide", "Quartzlight", "Polylab",
    "Bramble & Co.", "Loomstate", "Greybox", "Tideline Health", "Salt & Marrow", "Hexalith",
  ];

  return (
    <section id="voices" className="section">
      <div className="wrap">
        <div className="section-head reveal">
          <div>
            <span className="eyebrow">voices</span>
            <h2 style={{ marginTop: 18 }}>People are <em className="italic">building</em><br />on Prismatica.</h2>
          </div>
          <p>Eleven of them, picked from a private beta of around three hundred. Each is using the same canvas in a wildly different way.</p>
        </div>

        <div className="testimonials-grid">
          {quotes.map((q, i) => {
            const cls = ["testimonial", "reveal"];
            if (q.feat) cls.push("feature");
            return (
              <div key={i} className={cls.join(" ")} style={{ transitionDelay: (i % 6) * 60 + "ms" }}>
                <p className="testimonial-quote" dangerouslySetInnerHTML={{ __html: q.q }} />
                <div className="testimonial-author">
                  <div className="avatar">{q.i}</div>
                  <div className="author-meta">
                    <span className="author-name" dangerouslySetInnerHTML={{ __html: q.n }} />
                    <span className="author-role" dangerouslySetInnerHTML={{ __html: q.r }} />
                  </div>
                </div>
              </div>
            );
          })}
        </div>

        <div className="logos">
          <div className="logos-track">
            {[...logos, ...logos].map((l, i) => (
              <span className="logo-item" key={i}>
                <span className="glyph">◆</span>
                {l}
              </span>
            ))}
          </div>
        </div>
      </div>
    </section>
  );
}

function FAQ() {
  const items = [
    { q: "Is it really a full operating system?", a: "Not in the kernel sense. Prismatica behaves like an OS for your data and tools — windows, workspaces, processes — running in a browser tab or as a desktop app." },
    { q: "Do I need to write code?", a: "No. The whole canvas is no-code by default. If you want to extend a widget, every public workspace exposes a TypeScript repo you can fork on the spot." },
    { q: "Where does my data live?", a: "Wherever you put it. Local SQLite, a Postgres in your VPC, Supabase, Snowflake, plain markdown — Prismatica adapts. We don't move data we weren't asked to." },
    { q: "Which LLMs are supported?", a: "Bring your own key for OpenAI, Anthropic, Mistral, or any OpenAI-compatible endpoint. Studio plans include hosted credits if you'd rather not babysit a key." },
    { q: "What's a public workspace?", a: "A canvas anyone can view and fork — like a Jupyter notebook, a Figma file, and a Git repo had a kid. Great for templates, demos, and open analytics." },
    { q: "Do you have an open-source story?", a: "The runtime and a generous slice of widgets are MIT-licensed. Hosted features and the binary are commercial. We're transparent about which is which." },
  ];
  const [open, setOpen] = useState(0);
  return (
    <section id="faq" className="section">
      <div className="wrap">
        <div className="section-head reveal" style={{ gridTemplateColumns: "1fr", textAlign: "center", maxWidth: "720px", margin: "0 auto 60px" }}>
          <div>
            <span className="eyebrow">questions</span>
            <h2 style={{ marginTop: 18 }}>Things people <em className="italic">ask first</em>.</h2>
          </div>
        </div>
        <div className="faq reveal">
          {items.map((it, i) => (
            <div key={i} className={"faq-item " + (open === i ? "open" : "")} onClick={() => setOpen(open === i ? -1 : i)}>
              <div className="faq-q">
                <span>{it.q}</span>
                <span className="faq-toggle">+</span>
              </div>
              <div className="faq-a">{it.a}</div>
            </div>
          ))}
        </div>
      </div>
    </section>
  );
}

function Footer() {
  return (
    <footer className="footer" id="signup">
      <div className="hero-bg" style={{ inset: 0, position: "absolute", zIndex: 0, opacity: 0.6 }}>
        <div className="glow glow-1" style={{ opacity: 0.2 }} data-parallax="-0.08"></div>
        <div className="glow glow-2" style={{ opacity: 0.2 }} data-parallax="0.1"></div>
      </div>
      <div className="footer-cta wrap" style={{ position: "relative", zIndex: 1 }}>
        <span className="eyebrow">join the beta</span>
        <h2>Bring your <em className="italic">data</em>.<br />We&rsquo;ll bring the <em className="italic">canvas</em>.</h2>
        <p>Drop your email and we&rsquo;ll send you a build for macOS, Windows, or Linux — plus a public workspace to fork on day one.</p>
        <form className="newsletter" onSubmit={(e) => { e.preventDefault(); alert("Thanks! We'll be in touch."); }}>
          <input type="email" placeholder="you@studio.com" required />
          <button type="submit">Get the build</button>
        </form>
      </div>
      <div className="footer-bottom wrap" style={{ position: "relative", zIndex: 1 }}>
        <span>© 2026 Prismatica · workspaces for the curious</span>
        <div className="footer-links">
          <a href="#">Docs</a>
          <a href="#">Changelog</a>
          <a href="#">Github</a>
          <a href="#">Privacy</a>
          <a href="#">Status</a>
        </div>
      </div>
    </footer>
  );
}

/* =============================================================
   App + Tweaks
============================================================= */
function App() {
  const [tweaks, setTweak] = window.useTweaks(TWEAK_DEFAULTS);

  // apply palette
  useEffect(() => {
    document.documentElement.dataset.palette = tweaks.palette;
  }, [tweaks.palette]);

  useReveal();
  useNavScroll();
  useParallax(PARALLAX_MULT[tweaks.parallax] ?? 1);

  return (
    <>
      <Nav />
      <Hero mascotVariant={tweaks.mascot} />
      <Stats />
      <HowItWorks />
      <WhatItDoes />
      <Pricing />
      <Voices />
      <FAQ />
      <Footer />

      <window.TweaksPanel title="Tweaks" defaultOpen={false}>
        <window.TweakSection label="Palette" />
        <window.TweakSelect
          label="Theme"
          value={tweaks.palette}
          onChange={(v) => setTweak("palette", v)}
          options={[
            { value: "aurora", label: "Aurora — violet & cyan" },
            { value: "solar",  label: "Solar — paper & ink" },
            { value: "ember",  label: "Ember — warm dark" },
            { value: "forest", label: "Forest — deep green" },
          ]}
        />
        <window.TweakColor
          label="Swatches"
          value={PALETTES[tweaks.palette].swatch}
          onChange={(arr) => {
            const match = Object.entries(PALETTES).find(([, p]) =>
              JSON.stringify(p.swatch).toLowerCase() === JSON.stringify(arr).toLowerCase()
            );
            if (match) setTweak("palette", match[0]);
          }}
          options={[PALETTES.aurora.swatch, PALETTES.solar.swatch, PALETTES.ember.swatch, PALETTES.forest.swatch]}
        />
        <window.TweakSection label="Mascot" />
        <window.TweakSelect
          label="Mood"
          value={tweaks.mascot}
          onChange={(v) => setTweak("mascot", v)}
          options={[
            { value: "standard", label: "Standard — eyes track" },
            { value: "curious",  label: "Curious — wider eyes" },
            { value: "sleepy",   label: "Sleepy — closed eyes" },
            { value: "excited",  label: "Excited — big eyes" },
          ]}
        />
        <window.TweakSection label="Parallax" />
        <window.TweakRadio
          label="Intensity"
          value={tweaks.parallax}
          onChange={(v) => setTweak("parallax", v)}
          options={["subtle", "medium", "bold"]}
        />
      </window.TweaksPanel>
    </>
  );
}

ReactDOM.createRoot(document.getElementById("root")).render(<App />);
