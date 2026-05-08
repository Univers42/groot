/* global React */
const { useState, useEffect, useRef } = React;

/* =============================================================
   SKETCHED APPLICATION — hand-drawn dashboard with annotations
============================================================= */
function SketchApp() {
  return (
    <svg className="sketch-svg" viewBox="0 0 1100 640" xmlns="http://www.w3.org/2000/svg" fill="none">
      <defs>
        <filter id="wobble" x="-5%" y="-5%" width="110%" height="110%">
          <feTurbulence type="fractalNoise" baseFrequency="0.02" numOctaves="2" seed="3" />
          <feDisplacementMap in="SourceGraphic" scale="2.4" />
        </filter>
        <filter id="wobble2" x="-5%" y="-5%" width="110%" height="110%">
          <feTurbulence type="fractalNoise" baseFrequency="0.04" numOctaves="2" seed="7" />
          <feDisplacementMap in="SourceGraphic" scale="1.8" />
        </filter>
        <pattern id="dots" width="14" height="14" patternUnits="userSpaceOnUse">
          <circle cx="2" cy="2" r="1" fill="var(--text-mute)" opacity="0.4" />
        </pattern>
      </defs>

      {/* dotted paper bg */}
      <rect x="0" y="0" width="1100" height="640" fill="url(#dots)" opacity="0.5" />

      {/* === Main canvas frame === */}
      <g filter="url(#wobble)" stroke="var(--text)" strokeWidth="1.6" fill="none" strokeLinecap="round" strokeLinejoin="round">
        {/* outer window */}
        <rect x="120" y="60" width="860" height="520" rx="12" />
        {/* topbar */}
        <line x1="120" y1="100" x2="980" y2="100" />
        <circle cx="146" cy="80" r="5" />
        <circle cx="166" cy="80" r="5" />
        <circle cx="186" cy="80" r="5" />
        {/* breadcrumb */}
        <rect x="220" y="70" width="180" height="22" rx="4" />
        <line x1="430" y1="80" x2="500" y2="80" strokeDasharray="4 4" />
        <rect x="500" y="70" width="100" height="22" rx="4" />
        {/* sidebar */}
        <line x1="220" y1="100" x2="220" y2="580" />
        <rect x="140" y="120" width="60" height="14" rx="3" />
        <rect x="140" y="146" width="70" height="10" rx="3" />
        <rect x="140" y="166" width="50" height="10" rx="3" />
        <rect x="140" y="186" width="64" height="10" rx="3" />
        <line x1="135" y1="208" x2="205" y2="208" />
        <rect x="140" y="220" width="60" height="14" rx="3" />
        <rect x="140" y="246" width="70" height="10" rx="3" />
        <rect x="140" y="266" width="46" height="10" rx="3" />
      </g>

      {/* === Workspace tiles (windows) === */}
      {/* Notes window */}
      <g filter="url(#wobble2)" stroke="var(--text)" strokeWidth="1.6" fill="none" strokeLinecap="round" strokeLinejoin="round">
        <rect x="250" y="130" width="240" height="170" rx="8" />
        <line x1="250" y1="158" x2="490" y2="158" />
        <text x="262" y="150" fontFamily="var(--hand)" fontSize="14" fill="var(--text)" stroke="none">notes.md</text>
        <line x1="266" y1="178" x2="460" y2="178" />
        <line x1="266" y1="194" x2="430" y2="194" />
        <line x1="266" y1="210" x2="450" y2="210" />
        <line x1="266" y1="226" x2="380" y2="226" />
        <line x1="266" y1="246" x2="420" y2="246" />
        <line x1="266" y1="262" x2="400" y2="262" />
        <line x1="266" y1="278" x2="350" y2="278" />
      </g>

      {/* Chart window */}
      <g filter="url(#wobble2)" stroke="var(--violet)" strokeWidth="1.6" fill="none" strokeLinecap="round" strokeLinejoin="round">
        <rect x="510" y="130" width="280" height="170" rx="8" stroke="var(--text)" />
        <line x1="510" y1="158" x2="790" y2="158" stroke="var(--text)" />
        <text x="522" y="150" fontFamily="var(--hand)" fontSize="14" fill="var(--text)" stroke="none">live_metrics</text>
        {/* axis */}
        <line x1="530" y1="280" x2="770" y2="280" stroke="var(--text)" />
        <line x1="530" y1="180" x2="530" y2="280" stroke="var(--text)" />
        {/* line chart */}
        <polyline points="540,260 570,240 600,250 630,210 660,225 690,180 720,200 760,170" />
        <circle cx="690" cy="180" r="3" fill="var(--violet)" />
        <circle cx="760" cy="170" r="3" fill="var(--violet)" />
        {/* bars below baseline */}
        <line x1="550" y1="280" x2="550" y2="270" strokeWidth="6" stroke="var(--cyan)" />
        <line x1="580" y1="280" x2="580" y2="262" strokeWidth="6" stroke="var(--cyan)" />
        <line x1="610" y1="280" x2="610" y2="258" strokeWidth="6" stroke="var(--cyan)" />
        <line x1="640" y1="280" x2="640" y2="248" strokeWidth="6" stroke="var(--cyan)" />
        <line x1="670" y1="280" x2="670" y2="240" strokeWidth="6" stroke="var(--cyan)" />
        <line x1="700" y1="280" x2="700" y2="232" strokeWidth="6" stroke="var(--cyan)" />
        <line x1="730" y1="280" x2="730" y2="224" strokeWidth="6" stroke="var(--cyan)" />
      </g>

      {/* AI chat window */}
      <g filter="url(#wobble2)" stroke="var(--text)" strokeWidth="1.6" fill="none" strokeLinecap="round" strokeLinejoin="round">
        <rect x="800" y="130" width="160" height="240" rx="8" />
        <line x1="800" y1="158" x2="960" y2="158" />
        <text x="812" y="150" fontFamily="var(--hand)" fontSize="14" fill="var(--text)" stroke="none">~/ assistant</text>
        {/* chat bubbles */}
        <rect x="816" y="174" width="100" height="22" rx="11" />
        <rect x="844" y="206" width="100" height="22" rx="11" stroke="var(--violet)" />
        <rect x="816" y="238" width="120" height="32" rx="11" />
        <rect x="844" y="280" width="100" height="22" rx="11" stroke="var(--violet)" />
        <line x1="816" y1="346" x2="944" y2="346" />
        <text x="822" y="340" fontFamily="var(--mono)" fontSize="9" fill="var(--text-mute)" stroke="none">ask anything ·</text>
        <text x="930" y="340" fontFamily="var(--mono)" fontSize="11" fill="var(--violet)" stroke="none">↵</text>
      </g>

      {/* Database tile */}
      <g filter="url(#wobble2)" stroke="var(--text)" strokeWidth="1.6" fill="none" strokeLinecap="round" strokeLinejoin="round">
        <rect x="250" y="320" width="240" height="240" rx="8" />
        <line x1="250" y1="348" x2="490" y2="348" />
        <text x="262" y="340" fontFamily="var(--hand)" fontSize="14" fill="var(--text)" stroke="none">postgres · /tracking</text>
        {/* column headers */}
        <line x1="250" y1="372" x2="490" y2="372" strokeDasharray="3 3" />
        <text x="266" y="366" fontFamily="var(--mono)" fontSize="10" fill="var(--text-dim)" stroke="none">id</text>
        <text x="306" y="366" fontFamily="var(--mono)" fontSize="10" fill="var(--text-dim)" stroke="none">metric</text>
        <text x="386" y="366" fontFamily="var(--mono)" fontSize="10" fill="var(--text-dim)" stroke="none">value</text>
        <text x="446" y="366" fontFamily="var(--mono)" fontSize="10" fill="var(--text-dim)" stroke="none">ts</text>
        {[0,1,2,3,4,5,6].map(i => (
          <g key={i}>
            <line x1="250" y1={394 + i*22} x2="490" y2={394 + i*22} strokeDasharray="2 4" opacity="0.5" />
            <rect x="266" y={380 + i*22} width="18" height="8" rx="2" />
            <rect x="306" y={380 + i*22} width="60" height="8" rx="2" />
            <rect x="386" y={380 + i*22} width={20 + (i*7) % 40} height="8" rx="2" stroke="var(--cyan)" />
            <rect x="446" y={380 + i*22} width="34" height="8" rx="2" />
          </g>
        ))}
      </g>

      {/* Workspace cards */}
      <g filter="url(#wobble2)" stroke="var(--text)" strokeWidth="1.6" fill="none" strokeLinecap="round" strokeLinejoin="round">
        <rect x="510" y="320" width="135" height="115" rx="8" />
        <text x="522" y="345" fontFamily="var(--hand)" fontSize="16" fill="var(--violet)" stroke="none">Private</text>
        <line x1="522" y1="360" x2="610" y2="360" strokeDasharray="2 3" />
        <line x1="522" y1="376" x2="600" y2="376" strokeDasharray="2 3" />
        <line x1="522" y1="392" x2="580" y2="392" strokeDasharray="2 3" />
        <circle cx="618" cy="412" r="10" stroke="var(--text)" />
        <path d="M 614 412 L 618 416 L 624 408" stroke="var(--cyan)" strokeWidth="2" />

        <rect x="655" y="320" width="135" height="115" rx="8" />
        <text x="667" y="345" fontFamily="var(--hand)" fontSize="16" fill="var(--cyan)" stroke="none">Shared</text>
        <circle cx="672" cy="380" r="10" />
        <circle cx="690" cy="380" r="10" />
        <circle cx="708" cy="380" r="10" />
        <line x1="667" y1="408" x2="780" y2="408" strokeDasharray="2 3" />

        <rect x="510" y="445" width="280" height="115" rx="8" />
        <text x="522" y="470" fontFamily="var(--hand)" fontSize="16" fill="var(--rose)" stroke="none">Public · forkable</text>
        <rect x="522" y="486" width="80" height="14" rx="3" />
        <rect x="612" y="486" width="80" height="14" rx="3" />
        <rect x="702" y="486" width="80" height="14" rx="3" />
        <line x1="522" y1="514" x2="780" y2="514" strokeDasharray="2 3" />
        <line x1="522" y1="530" x2="700" y2="530" strokeDasharray="2 3" />
        <line x1="522" y1="546" x2="650" y2="546" strokeDasharray="2 3" />
      </g>

      {/* Code tile */}
      <g filter="url(#wobble2)" stroke="var(--text)" strokeWidth="1.6" fill="none" strokeLinecap="round" strokeLinejoin="round">
        <rect x="800" y="380" width="160" height="180" rx="8" />
        <line x1="800" y1="408" x2="960" y2="408" />
        <text x="812" y="400" fontFamily="var(--hand)" fontSize="14" fill="var(--text)" stroke="none">extend.ts</text>
        <text x="816" y="428" fontFamily="var(--mono)" fontSize="10" fill="var(--violet)" stroke="none">export const</text>
        <text x="816" y="442" fontFamily="var(--mono)" fontSize="10" fill="var(--text)" stroke="none">  widget = ()=&gt;{"{"}</text>
        <text x="816" y="456" fontFamily="var(--mono)" fontSize="10" fill="var(--cyan)" stroke="none">    return ...</text>
        <text x="816" y="470" fontFamily="var(--mono)" fontSize="10" fill="var(--text)" stroke="none">{"}"}</text>
        <line x1="812" y1="490" x2="948" y2="490" strokeDasharray="3 3" />
        <line x1="812" y1="504" x2="900" y2="504" strokeDasharray="3 3" />
        <line x1="812" y1="518" x2="930" y2="518" strokeDasharray="3 3" />
        <line x1="812" y1="532" x2="880" y2="532" strokeDasharray="3 3" />
      </g>

      {/* === HAND ANNOTATIONS === */}
      {/* arrow → notes */}
      <g stroke="var(--violet)" fill="none" strokeWidth="1.8" strokeLinecap="round">
        <path d="M 100 130 Q 180 110 240 160" filter="url(#wobble2)" />
        <path d="M 232 154 L 244 162 L 232 170" />
      </g>
      <text x="36" y="116" fontFamily="var(--hand)" fontSize="22" fill="var(--violet)">drag anything in</text>

      {/* arrow → chart */}
      <g stroke="var(--cyan)" fill="none" strokeWidth="1.8" strokeLinecap="round">
        <path d="M 590 50 Q 620 80 640 130" filter="url(#wobble2)" />
        <path d="M 634 122 L 642 134 L 650 124" />
      </g>
      <text x="450" y="42" fontFamily="var(--hand)" fontSize="22" fill="var(--cyan)">no-code dashboards</text>

      {/* arrow → AI */}
      <g stroke="var(--rose)" fill="none" strokeWidth="1.8" strokeLinecap="round">
        <path d="M 1040 200 Q 1000 200 970 220" filter="url(#wobble2)" />
        <path d="M 980 212 L 968 220 L 976 232" />
      </g>
      <text x="990" y="180" fontFamily="var(--hand)" fontSize="22" fill="var(--rose)">your LLM,</text>
      <text x="990" y="200" fontFamily="var(--hand)" fontSize="22" fill="var(--rose)">in context</text>

      {/* arrow → DB */}
      <g stroke="var(--violet)" fill="none" strokeWidth="1.8" strokeLinecap="round">
        <path d="M 70 460 Q 130 440 240 420" filter="url(#wobble2)" />
        <path d="M 232 412 L 244 420 L 234 432" />
      </g>
      <text x="22" y="490" fontFamily="var(--hand)" fontSize="22" fill="var(--violet)">cloud or local DB</text>

      {/* arrow → workspaces */}
      <g stroke="var(--cyan)" fill="none" strokeWidth="1.8" strokeLinecap="round">
        <path d="M 660 600 Q 660 580 660 440" filter="url(#wobble2)" />
        <path d="M 654 448 L 660 438 L 668 448" />
      </g>
      <text x="540" y="618" fontFamily="var(--hand)" fontSize="22" fill="var(--cyan)">private · shared · public</text>

      {/* arrow → code */}
      <g stroke="var(--warm)" fill="none" strokeWidth="1.8" strokeLinecap="round">
        <path d="M 1050 470 Q 1000 480 970 470" filter="url(#wobble2)" />
        <path d="M 980 462 L 968 470 L 978 482" />
      </g>
      <text x="998" y="510" fontFamily="var(--hand)" fontSize="22" fill="var(--warm)">fork &amp; extend</text>

      {/* circle highlight on focus ring */}
      <ellipse cx="660" cy="234" rx="88" ry="42" stroke="var(--violet)" strokeWidth="1.6" strokeDasharray="4 5" fill="none" filter="url(#wobble2)" opacity="0.7" />

    </svg>
  );
}

window.SketchApp = SketchApp;
