/* global React */
const { useEffect, useRef } = React;

/* =============================================================
   PRISMATICA MASCOT — "Specs"
   Editorial cosmic binoculars. Lenses are little universes.
============================================================= */
function Mascot({ variant = "standard" }) {
  const ref = useRef(null);

  useEffect(() => {
    if (variant === "sleepy") return;
    const handler = (e) => {
      if (!ref.current) return;
      const rect = ref.current.getBoundingClientRect();
      const cx = rect.left + rect.width / 2;
      const cy = rect.top + rect.height / 2;
      const dx = e.clientX - cx;
      const dy = e.clientY - cy;
      const angle = Math.atan2(dy, dx);
      const dist = Math.min(Math.hypot(dx, dy) / 80, 4);
      ref.current.style.setProperty("--ex", Math.cos(angle) * dist + "px");
      ref.current.style.setProperty("--ey", Math.sin(angle) * dist + "px");
    };
    window.addEventListener("mousemove", handler);
    return () => window.removeEventListener("mousemove", handler);
  }, [variant]);

  const eyeR = variant === "excited" ? 9 : variant === "curious" ? 6 : 7;
  const pupilStyle = {
    transform: "translate(var(--ex,0px), var(--ey,0px))",
    transition: "transform 90ms ease-out",
  };

  return (
    <svg
      ref={ref}
      className="mascot-svg"
      viewBox="0 0 400 400"
      fill="none"
      xmlns="http://www.w3.org/2000/svg"
    >
      <defs>
        {/* left lens: deep cosmos */}
        <radialGradient id="lensL" cx="0.3" cy="0.3" r="0.9">
          <stop offset="0%"  stopColor="#3b2a6b" />
          <stop offset="55%" stopColor="#1a1240" />
          <stop offset="100%" stopColor="#05030f" />
        </radialGradient>
        {/* right lens: cyan nebula */}
        <radialGradient id="lensR" cx="0.65" cy="0.35" r="0.95">
          <stop offset="0%"  stopColor="#0d4a5e" />
          <stop offset="55%" stopColor="#0a1f33" />
          <stop offset="100%" stopColor="#020610" />
        </radialGradient>
        <clipPath id="clipL"><circle cx="138" cy="210" r="62" /></clipPath>
        <clipPath id="clipR"><circle cx="262" cy="210" r="62" /></clipPath>

        {/* paper-noise filter for hand-printed feel */}
        <filter id="grain">
          <feTurbulence type="fractalNoise" baseFrequency="0.9" numOctaves="2" stitchTiles="stitch" />
          <feColorMatrix values="0 0 0 0 0
                                  0 0 0 0 0
                                  0 0 0 0 0
                                  0 0 0 0.08 0" />
          <feComposite in2="SourceGraphic" operator="in" />
        </filter>
      </defs>

      {/* ── ground shadow ── */}
      <ellipse cx="200" cy="368" rx="100" ry="6" fill="#000" opacity="0.35" />

      {/* ── orbital ring behind ── */}
      <ellipse cx="200" cy="220" rx="170" ry="48" stroke="var(--violet)" strokeWidth="1" fill="none" opacity="0.35" strokeDasharray="2 4" />
      <circle cx="34" cy="218" r="3" fill="var(--violet)" />
      <circle cx="368" cy="222" r="2" fill="var(--cyan)" />

      {/* ── strap (single line, hand drawn arc) ── */}
      <path d="M 70 110 Q 130 70 200 92 Q 270 70 330 110" stroke="var(--text)" strokeWidth="2" fill="none" strokeLinecap="round" />
      <circle cx="70" cy="110" r="4" fill="var(--text)" />
      <circle cx="330" cy="110" r="4" fill="var(--text)" />

      {/* ── BARRELS — flat outlined style ── */}
      {/* Left barrel */}
      <g>
        {/* top hood */}
        <path d="M 86 130 L 190 130 L 190 158 L 86 158 Z" fill="var(--text)" opacity="0.92" />
        <rect x="86" y="130" width="104" height="28" rx="3" fill="var(--text)" />
        {/* main body */}
        <rect x="92" y="158" width="92" height="120" fill="var(--bg-2)" stroke="var(--text)" strokeWidth="2" />
        {/* focus ridge */}
        <rect x="88" y="186" width="100" height="14" fill="var(--text)" />
        {[0,1,2,3,4,5,6,7,8,9,10].map(i => (
          <line key={i} x1={94 + i*9} y1="190" x2={94 + i*9} y2="196" stroke="var(--bg-2)" strokeWidth="1.4" />
        ))}
        {/* lens rim */}
        <circle cx="138" cy="210" r="68" fill="var(--text)" />
        <circle cx="138" cy="210" r="64" fill="#0a0a16" />
        <circle cx="138" cy="210" r="62" fill="url(#lensL)" />
        {/* cosmos inside lens (clipped) */}
        <g clipPath="url(#clipL)">
          {/* tiny stars */}
          <circle cx="108" cy="178" r="1" fill="#fff" />
          <circle cx="162" cy="172" r="0.8" fill="#fff" />
          <circle cx="180" cy="200" r="1" fill="#fff" opacity="0.7" />
          <circle cx="100" cy="230" r="0.7" fill="#fff" opacity="0.6" />
          <circle cx="170" cy="244" r="1" fill="#fff" />
          <circle cx="120" cy="252" r="0.6" fill="#fff" opacity="0.5" />
          {/* ringed planet */}
          <ellipse cx="148" cy="220" rx="22" ry="7" stroke="var(--violet)" strokeWidth="1.4" fill="none" />
          <circle cx="148" cy="220" r="11" fill="var(--rose)" />
          <ellipse cx="148" cy="220" rx="22" ry="7" stroke="var(--violet)" strokeWidth="1.4" fill="none" opacity="0.5" />
          {/* nebula glow */}
          <circle cx="115" cy="195" r="20" fill="var(--violet)" opacity="0.25" />
        </g>
        {/* eye */}
        <g style={pupilStyle}>
          <circle cx="138" cy="210" r={eyeR} fill="#fff" />
          <circle cx={138 + eyeR/3} cy={210 - eyeR/3} r={eyeR/2.4} fill="#0a0a16" />
        </g>
        {variant === "sleepy" && (
          <path d="M 118 210 Q 138 220 158 210" stroke="#fff" strokeWidth="2.4" fill="none" strokeLinecap="round" />
        )}
        {/* lens highlight */}
        <path d="M 102 188 Q 116 178 134 178" stroke="#fff" strokeWidth="2" fill="none" strokeLinecap="round" opacity="0.55" />
        <circle cx="170" cy="246" r="3" fill="#fff" opacity="0.4" />
      </g>

      {/* center bridge */}
      <g>
        <rect x="186" y="160" width="28" height="80" fill="var(--text)" />
        <rect x="186" y="172" width="28" height="6" fill="var(--bg-2)" />
        <rect x="186" y="222" width="28" height="6" fill="var(--bg-2)" />
        {/* tiny dial */}
        <circle cx="200" cy="200" r="6" fill="var(--bg-2)" stroke="var(--text)" strokeWidth="1.5" />
        <line x1="200" y1="200" x2="204" y2="196" stroke="var(--violet)" strokeWidth="1.6" strokeLinecap="round" />
      </g>

      {/* Right barrel */}
      <g>
        <rect x="210" y="130" width="104" height="28" rx="3" fill="var(--text)" />
        <rect x="216" y="158" width="92" height="120" fill="var(--bg-2)" stroke="var(--text)" strokeWidth="2" />
        <rect x="212" y="186" width="100" height="14" fill="var(--text)" />
        {[0,1,2,3,4,5,6,7,8,9,10].map(i => (
          <line key={i} x1={218 + i*9} y1="190" x2={218 + i*9} y2="196" stroke="var(--bg-2)" strokeWidth="1.4" />
        ))}
        <circle cx="262" cy="210" r="68" fill="var(--text)" />
        <circle cx="262" cy="210" r="64" fill="#0a0a16" />
        <circle cx="262" cy="210" r="62" fill="url(#lensR)" />
        <g clipPath="url(#clipR)">
          <circle cx="232" cy="180" r="0.9" fill="#fff" />
          <circle cx="290" cy="178" r="1" fill="#fff" />
          <circle cx="304" cy="216" r="0.7" fill="#fff" opacity="0.6" />
          <circle cx="226" cy="244" r="1" fill="#fff" />
          <circle cx="284" cy="252" r="0.7" fill="#fff" opacity="0.5" />
          {/* moon */}
          <circle cx="278" cy="194" r="9" fill="#e5e5ea" />
          <circle cx="276" cy="192" r="2" fill="#b8b8c0" opacity="0.6" />
          <circle cx="281" cy="196" r="1.4" fill="#b8b8c0" opacity="0.6" />
          {/* comet streak */}
          <path d="M 222 246 L 250 232" stroke="var(--cyan)" strokeWidth="2" strokeLinecap="round" opacity="0.85" />
          <circle cx="250" cy="232" r="2.4" fill="var(--cyan)" />
          {/* nebula */}
          <circle cx="240" cy="220" r="20" fill="var(--cyan)" opacity="0.2" />
        </g>
        <g style={pupilStyle}>
          <circle cx="262" cy="210" r={eyeR} fill="#fff" />
          <circle cx={262 + eyeR/3} cy={210 - eyeR/3} r={eyeR/2.4} fill="#0a0a16" />
        </g>
        {variant === "sleepy" && (
          <path d="M 242 210 Q 262 220 282 210" stroke="#fff" strokeWidth="2.4" fill="none" strokeLinecap="round" />
        )}
        <path d="M 226 188 Q 240 178 258 178" stroke="#fff" strokeWidth="2" fill="none" strokeLinecap="round" opacity="0.55" />
      </g>

      {/* tiny antenna w/ pulse */}
      <line x1="200" y1="160" x2="200" y2="128" stroke="var(--text)" strokeWidth="2" />
      <circle cx="200" cy="124" r="5" fill="var(--cyan)" />
      <circle cx="200" cy="124" r="5" fill="var(--cyan)" opacity="0.5">
        <animate attributeName="r" values="5;14;5" dur="2.6s" repeatCount="indefinite" />
        <animate attributeName="opacity" values="0.6;0;0.6" dur="2.6s" repeatCount="indefinite" />
      </circle>

      {/* tripod legs (editorial — like an old camera stand) */}
      <line x1="160" y1="278" x2="138" y2="350" stroke="var(--text)" strokeWidth="2.2" strokeLinecap="round" />
      <line x1="240" y1="278" x2="262" y2="350" stroke="var(--text)" strokeWidth="2.2" strokeLinecap="round" />
      <line x1="200" y1="278" x2="200" y2="345" stroke="var(--text)" strokeWidth="2.2" strokeLinecap="round" />
      <circle cx="138" cy="350" r="4" fill="var(--text)" />
      <circle cx="200" cy="345" r="4" fill="var(--text)" />
      <circle cx="262" cy="350" r="4" fill="var(--text)" />

      {/* floating sparkles */}
      <g opacity="0.85">
        <path d="M 60 70 L 64 80 L 74 84 L 64 88 L 60 98 L 56 88 L 46 84 L 56 80 Z" fill="var(--cyan)">
          <animateTransform attributeName="transform" type="rotate" from="0 60 84" to="360 60 84" dur="14s" repeatCount="indefinite" />
        </path>
        <path d="M 340 60 L 343 68 L 351 71 L 343 74 L 340 82 L 337 74 L 329 71 L 337 68 Z" fill="var(--violet)">
          <animateTransform attributeName="transform" type="rotate" from="360 340 71" to="0 340 71" dur="16s" repeatCount="indefinite" />
        </path>
        <circle cx="350" cy="290" r="2" fill="var(--rose)" />
        <circle cx="50" cy="280" r="1.5" fill="var(--cyan)" />
        <circle cx="370" cy="180" r="1.4" fill="#fff" opacity="0.6" />
        <circle cx="32" cy="160" r="1.4" fill="#fff" opacity="0.6" />
      </g>
    </svg>
  );
}

window.Mascot = Mascot;
