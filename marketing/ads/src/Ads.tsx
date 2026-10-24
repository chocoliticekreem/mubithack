// 1920x1080 Roblox sponsored-experience ad creatives. One hook each.
// Rules (RESEARCH.md): headline 2-4 words, >= 12% of height, cream/yellow on a thick ink outline,
// text inside x 150..1770 / y 90..860 (bottom strip is covered by the player count), fire in every frame,
// one focal action. Only our own art and real in-game screenshots.
import React from "react";
import { AbsoluteFill } from "remotion";
import {
  Burst,
  C,
  Cat,
  ChiefHelmet,
  DISPLAY,
  Embers,
  Face,
  Flames,
  Glow,
  Halftone,
  HoseBody,
  House,
  Jet,
  Mood,
  Outline,
  Photo,
  Smoke,
  Sticker,
  Truck,
  Vignette,
} from "./kit";

const W = 1920;
const H = 1080;

/* ------------------------------------------------------------- helpers */

export const Head: React.FC<{
  children: React.ReactNode;
  size?: number;
  fill?: string;
  rim?: string;
  style?: React.CSSProperties;
}> = ({ children, size = 190, fill = C.cream, rim = C.red, style }) => (
  <Outline
    size={size}
    fill={fill}
    layers={[
      { stroke: size * 0.3, color: C.ink },
      { stroke: size * 0.16, color: rim },
    ]}
    shadow={0.09}
    style={style}
  >
    {children}
  </Outline>
);

// Penguin firefighter with a hose. (x, y) = top-left of the head; f = head width.
// Nozzle tip lands at (x + 1.144 f, y + 0.792 f).
export const Hero: React.FC<{ x: number; y: number; f: number; mood?: Mood; glow?: boolean; soot?: boolean; number?: string }> = ({
  x,
  y,
  f,
  mood = "brave",
  glow = true,
  soot,
  number,
}) => (
  <div
    style={{
      position: "absolute",
      left: x,
      top: y,
      filter: `drop-shadow(0 ${f * 0.03}px 0 ${C.ink})${glow ? ` drop-shadow(${f * 0.04}px ${-f * 0.03}px ${f * 0.08}px rgba(255,140,30,0.85))` : ""}`,
    }}
  >
    <HoseBody size={f * 1.2} style={{ position: "absolute", left: -f * 0.056, top: f * 0.672 }} />
    <Face size={f} mood={mood} soot={soot} number={number} style={{ position: "absolute", left: 0, top: 0 }} />
  </div>
);
export const nozzle = (x: number, y: number, f: number) => [x + 1.144 * f, y + 0.792 * f] as const;

const FireFloor: React.FC<{ h?: number; seed?: number; count?: number; t?: number }> = ({ h = 260, seed = 2, count = 16, t = 0 }) => (
  <div style={{ position: "absolute", left: -20, right: -20, bottom: -14 }}>
    <Flames width={W + 40} height={h} count={count} seed={seed} t={t} outline={9} />
  </div>
);

const Rim: React.FC = () => <AbsoluteFill style={{ boxShadow: `inset 0 0 0 14px ${C.ink}` }} />;

const Bar: React.FC<{ text: string; style?: React.CSSProperties; bg?: string; color?: string; size?: number }> = ({
  text,
  style,
  bg = C.hose,
  color = C.ink,
  size = 64,
}) => (
  <Sticker bg={bg} rotate={-2} pad="10px 40px 2px" style={style}>
    <span style={{ fontFamily: DISPLAY, fontSize: size, color, letterSpacing: "0.03em", whiteSpace: "nowrap" }}>{text}</span>
  </Sticker>
);

/* ------------------------------------------------- 01  SAVE THEM ALL? */

export const AdSaveThem: React.FC<{ t?: number }> = ({ t = 0 }) => {
  const [hx, hy, f] = [90, 470, 400];
  const [nx, ny] = nozzle(hx, hy, f);
  return (
    <AbsoluteFill style={{ background: C.ink, overflow: "hidden" }}>
      <Photo src="house-fire" scale={1.25} x={-40} y={60} origin="55% 55%" filter="saturate(1.45) contrast(1.12) brightness(0.95)" />
      <AbsoluteFill style={{ background: "linear-gradient(to bottom, rgba(26,18,16,0.75) 0%, rgba(26,18,16,0) 40%)" }} />
      <Glow x="52%" y="50%" r={45} o={0.7} />
      <div style={{ position: "absolute", left: 560, top: 180 }}>
        <Flames width={820} height={330} count={9} seed={4} t={t} outline={9} />
      </div>
      <Embers w={W} h={H} n={60} seed={3} t={t + 50} size={2.2} />
      <FireFloor h={220} seed={6} t={t} />
      <Jet x0={nx} y0={ny} x1={980} y1={560} w={64} bend={-0.18} t={t} splash={1.3} />
      <Hero x={hx} y={hy} f={f} />
      <div style={{ position: "absolute", right: 150, top: 90, display: "flex", flexDirection: "column", alignItems: "flex-end" }}>
        <Head size={200}>SAVE THEM</Head>
        <Head size={250} fill={C.fireCore} rim={C.fireEdge} style={{ marginTop: -10, marginRight: 40 }}>
          ALL?
        </Head>
      </div>
      <Vignette o={0.45} inner={55} />
      <Rim />
    </AbsoluteFill>
  );
};

/* ---------------------------------------------- 02  WHO STARTED IT? */

const Point: React.FC<{ x: number; y: number; flip?: boolean; rot?: number }> = ({ x, y, flip, rot = 0 }) => (
  <svg
    width={300}
    height={180}
    viewBox="0 0 300 180"
    style={{ position: "absolute", left: x, top: y, overflow: "visible", transform: `scaleX(${flip ? -1 : 1}) rotate(${rot}deg)` }}
  >
    <path d="M 10 120 Q 120 30 250 70" fill="none" stroke={C.ink} strokeWidth={48} strokeLinecap="round" />
    <path d="M 10 120 Q 120 30 250 70" fill="none" stroke={C.cream} strokeWidth={28} strokeLinecap="round" />
    <path d="M 220 20 L 300 80 L 210 120 Z" fill={C.cream} stroke={C.ink} strokeWidth={12} strokeLinejoin="round" />
  </svg>
);

export const AdWhoStarted: React.FC<{ t?: number }> = ({ t = 0 }) => (
  <AbsoluteFill style={{ background: C.ink, overflow: "hidden" }}>
    <Photo src="truck-fire" scale={1.3} x={-60} y={40} origin="62% 45%" filter="saturate(1.4) contrast(1.1) brightness(0.8) blur(2px)" />
    <AbsoluteFill style={{ background: "linear-gradient(to bottom, rgba(26,18,16,0.8) 0%, rgba(26,18,16,0.1) 45%, rgba(122,31,16,0.35) 100%)" }} />
    <Glow x="50%" y="80%" r={60} o={0.8} />
    <FireFloor h={380} seed={11} count={14} t={t} />
    <Embers w={W} h={H} n={50} seed={9} t={t + 30} size={2} />
    {/* two penguins blaming each other */}
    <div style={{ position: "absolute", left: 170, top: 400, transform: "rotate(-7deg)", filter: `drop-shadow(0 14px 0 ${C.ink})` }}>
      <Face size={500} mood="smug" soot />
    </div>
    <div style={{ position: "absolute", left: 1250, top: 400, transform: "rotate(7deg)", filter: `drop-shadow(0 14px 0 ${C.ink})` }}>
      <Face size={500} mood="panic" number="01" />
    </div>
    <Point x={650} y={600} rot={-6} />
    <Point x={980} y={600} flip rot={-6} />
    <div style={{ position: "absolute", left: 0, right: 0, top: 70, display: "flex", flexDirection: "column", alignItems: "center" }}>
      <Head size={175}>WHO STARTED</Head>
      <Head size={210} fill={C.fireCore} rim={C.fireEdge} style={{ marginTop: -6 }}>
        THE FIRE?
      </Head>
    </div>
    <Rim />
  </AbsoluteFill>
);

/* ------------------------------------------------- 03  SAVE THE CAT! */

const Tree: React.FC<{ x: number; y: number; s: number }> = ({ x, y, s }) => (
  <svg width={600 * s} height={800 * s} viewBox="0 0 600 800" style={{ position: "absolute", left: x, top: y, overflow: "visible" }}>
    <path d="M 250 800 L 270 420 Q 200 360 140 330 M 280 470 Q 380 380 470 360 M 300 800 L 310 420" stroke={C.ink} strokeWidth={34} fill="none" strokeLinecap="round" />
    <path d="M 240 800 Q 250 600 270 420 L 330 420 Q 340 600 360 800 Z" fill="#7A4A2A" stroke={C.ink} strokeWidth={14} strokeLinejoin="round" />
    <path d="M 290 450 Q 380 380 470 360" stroke="#7A4A2A" strokeWidth={26} fill="none" strokeLinecap="round" />
    <path d="M 270 440 Q 200 370 140 330" stroke="#7A4A2A" strokeWidth={26} fill="none" strokeLinecap="round" />
    {[
      [300, 230, 230],
      [150, 300, 160],
      [450, 300, 170],
      [220, 140, 150],
      [390, 150, 150],
    ].map(([cx, cy, r], i) => (
      <circle key={i} cx={cx} cy={cy} r={r} fill="#3E8A3A" stroke={C.ink} strokeWidth={14} />
    ))}
    {[
      [300, 230, 216],
      [150, 300, 146],
      [450, 300, 156],
      [220, 140, 136],
      [390, 150, 136],
    ].map(([cx, cy, r], i) => (
      <circle key={i} cx={cx} cy={cy} r={r} fill="#4FA548" />
    ))}
    <ellipse cx={230} cy={150} rx={60} ry={30} fill="#7CC86E" opacity={0.7} />
  </svg>
);

export const AdSaveCat: React.FC<{ t?: number }> = ({ t = 0 }) => {
  const [hx, hy, f] = [130, 520, 360];
  const [nx, ny] = nozzle(hx, hy, f);
  return (
    <AbsoluteFill style={{ background: C.ink, overflow: "hidden" }}>
      <Photo src="house-fire" scale={1.15} x={260} y={40} origin="50% 50%" filter="saturate(1.4) contrast(1.1) brightness(0.85)" />
      <AbsoluteFill style={{ background: "linear-gradient(to right, rgba(26,18,16,0.2), rgba(26,18,16,0) 40%, rgba(26,18,16,0.55))" }} />
      <Glow x="45%" y="70%" r={50} o={0.7} />
      <FireFloor h={250} seed={21} t={t} />
      <Tree x={1180} y={60} s={1.15} />
      <div style={{ position: "absolute", left: 1300, top: 150, transform: "rotate(-8deg)", filter: `drop-shadow(0 10px 0 ${C.ink})` }}>
        <Cat size={300} />
      </div>
      <Embers w={W} h={H} n={50} seed={21} t={t} size={2} />
      <Jet x0={nx} y0={ny} x1={1080} y1={760} w={56} bend={-0.12} t={t} />
      <Hero x={hx} y={hy} f={f} mood="panic" />
      <div style={{ position: "absolute", left: 150, top: 90, display: "flex", flexDirection: "column", alignItems: "flex-start" }}>
        <Head size={190}>SAVE</Head>
        <Head size={230} fill={C.fireCore} rim={C.fireEdge} style={{ marginTop: -14 }}>
          THE CAT!
        </Head>
      </div>
      <Vignette o={0.4} inner={58} />
      <Rim />
    </AbsoluteFill>
  );
};

/* -------------------------------------------- 04  8-PLAYER FIRE SQUAD */

export const AdSquad: React.FC<{ t?: number }> = ({ t = 0 }) => {
  const faces: { n: string; m: Mood }[] = [
    { n: "01", m: "brave" },
    { n: "02", m: "panic" },
    { n: "03", m: "smug" },
    { n: "04", m: "brave" },
    { n: "05", m: "shock" },
    { n: "06", m: "brave" },
    { n: "07", m: "panic" },
    { n: "67", m: "smug" },
  ];
  return (
    <AbsoluteFill style={{ background: C.ink, overflow: "hidden" }}>
      <Photo src="truck-fire" scale={1.12} x={0} y={-30} origin="60% 50%" filter="saturate(1.45) contrast(1.1) brightness(0.9)" />
      <AbsoluteFill style={{ background: "linear-gradient(to bottom, rgba(26,18,16,0.85) 0%, rgba(26,18,16,0) 42%, rgba(26,18,16,0.2) 100%)" }} />
      <Glow x="70%" y="45%" r={45} o={0.75} />
      <div style={{ position: "absolute", left: 1140, top: 190 }}>
        <Flames width={700} height={300} count={8} seed={31} t={t} outline={9} />
      </div>
      <Embers w={W} h={H} n={40} seed={31} t={t} size={2} />
      <FireFloor h={200} seed={33} t={t} />
      {/* the squad: two rows of four */}
      {faces.map((p, i) => {
        const row = i < 4 ? 0 : 1;
        const col = i % 4;
        const size = 250;
        const x = 160 + col * 230 + row * 115;
        const y = 470 + row * 190;
        return (
          <div key={i} style={{ position: "absolute", left: x, top: y, transform: `rotate(${(col - 1.5) * 4}deg)`, filter: `drop-shadow(0 8px 0 ${C.ink})`, zIndex: row }}>
            <Face size={size} mood={p.m} number={p.n} />
          </div>
        );
      })}
      <div style={{ position: "absolute", left: 150, top: 80, display: "flex", alignItems: "center", gap: 30 }}>
        <div style={{ position: "relative", width: 300, height: 300, transform: "rotate(-8deg)" }}>
          <div
            style={{
              position: "absolute",
              inset: 0,
              borderRadius: "50%",
              background: C.red,
              border: `14px solid ${C.ink}`,
              boxShadow: `0 14px 0 ${C.ink}`,
            }}
          />
          <div style={{ position: "absolute", left: 0, right: 0, top: 22, display: "flex", justifyContent: "center" }}>
            <Head size={270} fill={C.cream} rim={C.redDark}>
              8
            </Head>
          </div>
        </div>
        <div style={{ display: "flex", flexDirection: "column" }}>
          <Head size={150}>PLAYER</Head>
          <Head size={190} fill={C.fireCore} rim={C.fireEdge} style={{ marginTop: -4 }}>
            FIRE SQUAD
          </Head>
        </div>
      </div>
      <Vignette o={0.35} inner={60} />
      <Rim />
    </AbsoluteFill>
  );
};

/* ------------------------------------------ 05  penguin close-up: HOT HOT HOT */

export const AdCloseup: React.FC<{ t?: number }> = ({ t = 0 }) => (
  <AbsoluteFill style={{ background: C.ink, overflow: "hidden" }}>
    <Photo src="house-fire" scale={1.9} x={-150} y={180} origin="50% 40%" filter="saturate(1.5) contrast(1.15) brightness(0.9) blur(3px)" />
    <AbsoluteFill style={{ background: "radial-gradient(circle at 30% 55%, rgba(26,18,16,0) 20%, rgba(26,18,16,0.6) 80%)" }} />
    <Glow x="72%" y="55%" r={55} o={0.85} />
    <div style={{ position: "absolute", left: 900, top: 340 }}>
      <Flames width={1100} height={560} count={9} seed={41} t={t} outline={10} />
    </div>
    <div style={{ position: "absolute", left: 1180, top: 480, filter: `drop-shadow(0 10px 0 ${C.ink})` }}>
      <House width={540} />
    </div>
    <Embers w={W} h={H} n={70} seed={41} t={t} size={2.4} />
    <Jet x0={760} y0={1180} x1={1420} y1={700} w={80} bend={-0.1} t={t} splash={1.3} />
    <div style={{ position: "absolute", left: 60, top: 300, transform: "rotate(-6deg)", filter: `drop-shadow(0 16px 0 ${C.ink}) drop-shadow(24px -10px 40px rgba(255,140,30,0.9))` }}>
      <Face size={760} mood="brave" soot />
    </div>
    <div style={{ position: "absolute", right: 150, top: 80, display: "flex", flexDirection: "column", alignItems: "flex-end" }}>
      <Head size={200}>BRING THE</Head>
      <Head size={250} fill={C.water} rim="#2C7FA0" style={{ marginTop: -10 }}>
        WATER!
      </Head>
    </div>
    <Rim />
  </AbsoluteFill>
);

/* ------------------------------------------------- 06  KA-BOOM (gas station) */

const Tanker: React.FC<{ width: number }> = ({ width }) => (
  <svg width={width} height={(width * 300) / 700} viewBox="0 0 700 300" style={{ overflow: "visible" }}>
    <rect x={20} y={40} width={480} height={170} rx={85} fill="#D8DCE2" stroke={C.ink} strokeWidth={14} />
    <rect x={20} y={110} width={480} height={34} fill={C.red} stroke={C.ink} strokeWidth={8} />
    <rect x={70} y={62} width={300} height={22} rx={11} fill="#fff" opacity={0.6} />
    <path d="M 510 80 L 620 80 Q 660 80 670 120 L 690 200 L 690 230 L 510 230 Z" fill={C.red} stroke={C.ink} strokeWidth={14} strokeLinejoin="round" />
    <path d="M 540 100 L 610 100 Q 630 100 636 120 L 648 160 L 540 160 Z" fill={C.water} stroke={C.ink} strokeWidth={9} />
    <rect x={10} y={210} width={690} height={26} fill="#4A4F5A" stroke={C.ink} strokeWidth={10} />
    {[110, 230, 600].map((x) => (
      <g key={x}>
        <circle cx={x} cy={250} r={42} fill={C.ink} />
        <circle cx={x} cy={250} r={18} fill="#C9CCD0" />
      </g>
    ))}
  </svg>
);

const Pump: React.FC<{ h: number }> = ({ h }) => (
  <svg width={(h * 200) / 380} height={h} viewBox="0 0 200 380" style={{ overflow: "visible" }}>
    <rect x={20} y={20} width={160} height={340} rx={18} fill={C.red} stroke={C.ink} strokeWidth={14} />
    <rect x={44} y={50} width={112} height={80} rx={8} fill={C.cream} stroke={C.ink} strokeWidth={9} />
    <rect x={56} y={160} width={88} height={30} rx={6} fill={C.ink} />
    <path d="M 180 220 Q 250 240 230 320" stroke={C.ink} strokeWidth={22} fill="none" strokeLinecap="round" />
    <rect x={10} y={350} width={180} height={30} rx={8} fill="#6E7480" stroke={C.ink} strokeWidth={10} />
    <path d="M 100 70 Q 90 95 100 110 Q 110 95 100 70 Z" fill={C.fireEdge} stroke={C.ink} strokeWidth={5} />
  </svg>
);

const Boom: React.FC<{ x: number; y: number; r: number; t?: number }> = ({ x, y, r, t = 0 }) => {
  const spikes = 18;
  const pts = (k: number, rr: number) =>
    Array.from({ length: spikes * 2 }, (_, i) => {
      const a = (i / (spikes * 2)) * Math.PI * 2 + t * 0.01;
      const m = i % 2 ? rr * (0.62 + 0.1 * Math.sin(i * 3.1)) : rr * (1 + 0.08 * Math.sin(i * 1.7));
      return `${x + Math.cos(a) * m * k},${y + Math.sin(a) * m * k}`;
    }).join(" ");
  return (
    <svg width={W} height={H} style={{ position: "absolute", left: 0, top: 0, overflow: "visible" }}>
      <polygon points={pts(1.08, r)} fill={C.ink} />
      <polygon points={pts(1, r)} fill={C.fireEdge} />
      <polygon points={pts(0.74, r)} fill={C.fireBody} />
      <polygon points={pts(0.45, r)} fill={C.fireCore} />
      <circle cx={x} cy={y} r={r * 0.18} fill="#fff" />
    </svg>
  );
};

export const AdBoom: React.FC<{ t?: number }> = ({ t = 0 }) => (
  <AbsoluteFill style={{ background: C.ink, overflow: "hidden" }}>
    <Photo src="gas-dusk" ext="png" scale={1.05} origin="50% 60%" filter="saturate(1.3) contrast(1.1) brightness(0.8)" />
    <Burst a="rgba(255,177,43,0.5)" b="rgba(200,35,43,0.25)" x="58%" y="52%" rays={30} spin={t * 0.5} />
    <Smoke w={900} h={420} seed={51} color="#2E2522" o={0.95} style={{ position: "absolute", left: 640, top: -60 }} />
    <Boom x={1110} y={560} r={360} t={t} />
    <Glow x="58%" y="52%" r={60} o={0.9} />
    <div style={{ position: "absolute", left: 900, top: 300, transform: `rotate(${-8 + t * 0.6}deg)`, filter: `drop-shadow(0 10px 0 ${C.ink})` }}>
      <Tanker width={620} />
    </div>
    <div style={{ position: "absolute", left: 300, top: 470, transform: "rotate(-10deg)", filter: `drop-shadow(0 10px 0 ${C.ink})` }}>
      <Pump h={380} />
    </div>
    <Embers w={W} h={H} n={80} seed={51} t={t} size={2.6} />
    <FireFloor h={230} seed={53} t={t} />
    {/* flying penguin */}
    <div style={{ position: "absolute", left: 1520, top: 50, transform: "rotate(28deg)", filter: `drop-shadow(0 10px 0 ${C.ink})` }}>
      <Face size={300} mood="shock" number="04" />
    </div>
    <div style={{ position: "absolute", left: 150, top: 90, display: "flex", flexDirection: "column", alignItems: "flex-start", transform: "rotate(-5deg)" }}>
      <Head size={250} fill={C.fireCore} rim={C.fireEdge}>
        KA-BOOM!
      </Head>
    </div>
    <Rim />
  </AbsoluteFill>
);

/* ------------------------------------------------- 07  BACKDRAFT! */

export const AdBackdraft: React.FC<{ t?: number }> = ({ t = 0 }) => (
  <AbsoluteFill style={{ background: C.ink, overflow: "hidden" }}>
    <Photo src="house-fire" scale={1.6} x={0} y={100} origin="50% 50%" filter="saturate(1.4) contrast(1.15) brightness(0.55)" />
    <Burst a="rgba(255,90,31,0.35)" b="rgba(26,18,16,0.0)" x="50%" y="60%" rays={36} spin={t * 0.4} />
    {/* fireball behind a wall, blasting out through the doorway */}
    <Boom x={960} y={640} r={520} t={t} />
    <svg width={W} height={H} style={{ position: "absolute", left: 0, top: 0 }}>
      <path d="M 520 330 L 1400 330 L 1400 1100 L 520 1100 Z M 770 420 L 770 1100 L 1150 1100 L 1150 420 Z" fill="#B4553A" fillRule="evenodd" stroke={C.ink} strokeWidth={18} />
      <path d="M 500 300 L 1420 300 L 1420 350 L 500 350 Z" fill="#6E3B2A" stroke={C.ink} strokeWidth={16} />
      {[0, 1, 2, 3, 4, 5].map((r) => (
        <line key={r} x1={520} y1={460 + r * 110} x2={770} y2={460 + r * 110} stroke="#8E3E2A" strokeWidth={10} />
      ))}
      {[0, 1, 2, 3, 4, 5].map((r) => (
        <line key={`b${r}`} x1={1150} y1={460 + r * 110} x2={1400} y2={460 + r * 110} stroke="#8E3E2A" strokeWidth={10} />
      ))}
      {/* the door, blown off its hinges */}
      <g transform="rotate(-28 1380 700)">
        <rect x={1240} y={560} width={300} height={520} rx={14} fill={C.redDark} stroke={C.ink} strokeWidth={16} />
        <circle cx={1500} cy={830} r={16} fill={C.gold} stroke={C.ink} strokeWidth={6} />
      </g>
    </svg>
    <Boom x={960} y={700} r={300} t={t + 7} />
    <Glow x="50%" y="62%" r={65} o={0.95} />
    <Embers w={W} h={H} n={90} seed={61} t={t} size={2.8} />
    {/* penguin blown backwards */}
    <div style={{ position: "absolute", left: 90, top: 470, transform: "rotate(-24deg)", filter: `drop-shadow(0 10px 0 ${C.ink})` }}>
      <Face size={420} mood="shock" soot number="02" />
    </div>
    <div style={{ position: "absolute", left: 0, right: 0, top: 80, display: "flex", justifyContent: "center", transform: "rotate(-3deg)" }}>
      <Head size={260} fill={C.fireCore} rim={C.fireEdge}>
        BACKDRAFT!
      </Head>
    </div>
    <Rim />
  </AbsoluteFill>
);

/* ------------------------------------------- 08  ROOFTOP RESCUE (sky tower) */

const Tower: React.FC<{ x: number; y: number; w: number; h: number }> = ({ x, y, w, h }) => (
  <svg width={w} height={h} viewBox={`0 0 ${w} ${h}`} style={{ position: "absolute", left: x, top: y, overflow: "visible" }}>
    <rect x={0} y={0} width={w} height={h + 40} fill="#5A6070" stroke={C.ink} strokeWidth={16} />
    {Array.from({ length: Math.floor(h / 110) }, (_, r) =>
      Array.from({ length: 4 }, (_, c) => (
        <rect
          key={`${r}-${c}`}
          x={30 + c * ((w - 60) / 4)}
          y={40 + r * 110}
          width={(w - 60) / 4 - 26}
          height={70}
          rx={6}
          fill={r < 3 ? C.fireBody : r % 2 ? "#2A3A4A" : "#3A5068"}
          stroke={C.ink}
          strokeWidth={8}
        />
      )),
    )}
    <rect x={-30} y={-24} width={w + 60} height={40} fill="#3A3F4C" stroke={C.ink} strokeWidth={14} />
  </svg>
);

export const AdRooftop: React.FC<{ t?: number }> = ({ t = 0 }) => (
  <AbsoluteFill style={{ background: C.ink, overflow: "hidden" }}>
    <AbsoluteFill style={{ background: "linear-gradient(to bottom, #1B1030 0%, #5A1E2A 45%, #EC6A2A 100%)" }} />
    <Halftone opacity={0.12} />
    <Smoke w={1300} h={500} seed={71} color="#2A2024" o={0.9} style={{ position: "absolute", left: 500, top: -120 }} />
    <Tower x={820} y={360} w={700} h={760} />
    <div style={{ position: "absolute", left: 760, top: 120 }}>
      <Flames width={820} height={300} count={8} seed={72} t={t} outline={9} />
    </div>
    <div style={{ position: "absolute", left: 820, top: 340 }}>
      <Flames width={700} height={120} count={7} seed={73} t={t} outline={7} />
    </div>
    <Glow x="60%" y="30%" r={50} o={0.8} />
    <Embers w={W} h={H} n={60} seed={71} t={t} size={2.2} />
    {/* stranded penguin waving on the roof edge */}
    <div style={{ position: "absolute", left: 1330, top: 140, transform: "rotate(8deg)", filter: `drop-shadow(0 10px 0 ${C.ink})` }}>
      <Face size={240} mood="panic" number="05" />
    </div>
    {/* ladder truck below */}
    <div style={{ position: "absolute", left: -120, top: 690, filter: `drop-shadow(0 10px 0 ${C.ink})` }}>
      <Truck width={1000} flash={0.2} />
    </div>
    <svg width={W} height={H} style={{ position: "absolute", left: 0, top: 0 }}>
      <g transform="rotate(-38 560 760)">
        <rect x={560} y={740} width={760} height={50} rx={10} fill="#C9CCD0" stroke={C.ink} strokeWidth={12} />
        {Array.from({ length: 12 }, (_, i) => (
          <line key={i} x1={600 + i * 60} y1={740} x2={600 + i * 60} y2={790} stroke={C.ink} strokeWidth={10} />
        ))}
      </g>
    </svg>
    <div style={{ position: "absolute", left: 150, top: 90, display: "flex", flexDirection: "column", alignItems: "flex-start" }}>
      <Head size={210}>ROOFTOP</Head>
      <Head size={230} fill={C.fireCore} rim={C.fireEdge} style={{ marginTop: -14 }}>
        RESCUE!
      </Head>
    </div>
    <Rim />
  </AbsoluteFill>
);

/* ------------------------------------------- 09  BECOME FIRE CHIEF (battle pass tier 20) */

export const AdChief: React.FC<{ t?: number }> = ({ t = 0 }) => (
  <AbsoluteFill style={{ background: C.red, overflow: "hidden" }}>
    <Photo src="house-fire" scale={1.2} filter="blur(8px) saturate(1.3) brightness(0.5)" />
    <Burst a="rgba(246,196,64,0.55)" b="rgba(200,35,43,0.3)" x="72%" y="62%" rays={28} spin={t * 0.4} />
    <AbsoluteFill style={{ background: `radial-gradient(circle at 72% 62%, ${C.fireCore} 0%, rgba(255,177,43,0.55) 20%, transparent 48%)` }} />
    <Halftone opacity={0.12} />
    <FireFloor h={300} seed={81} t={t} />
    <div style={{ position: "absolute", left: 1010, top: 400, filter: `drop-shadow(0 18px 0 ${C.ink})`, transform: "rotate(-6deg)" }}>
      <ChiefHelmet size={760} />
    </div>
    <div style={{ position: "absolute", left: 300, top: 560, transform: "rotate(-6deg)", filter: `drop-shadow(0 12px 0 ${C.ink})` }}>
      <Face size={430} mood="brave" look={[22, -8, 20, -10]} />
    </div>
    <div style={{ position: "absolute", left: 150, top: 90, display: "flex", flexDirection: "column", alignItems: "flex-start" }}>
      <Head size={190}>BECOME</Head>
      <Head size={250} fill={C.gold} rim={C.goldDark} style={{ marginTop: -10 }}>
        FIRE CHIEF
      </Head>
    </div>
    <Embers w={W} h={H} n={50} seed={81} t={t} size={2} />
    <Rim />
  </AbsoluteFill>
);
