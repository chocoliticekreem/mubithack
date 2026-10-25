// Wave 2: 14 sponsored-ad creatives (ad-10 .. ad-23), 1920x1080.
// Playbook: sell the core fantasy at a 3rd-grade reading level. One 2-4 word hook ("BE A FIREFIGHTER!",
// "SAVE THE PANDA!"), one focal action, fire in frame, our penguins. Layouts and colours vary on purpose
// so Roblox's rotation can find the winners. Text stays inside x 150..1770 / y 70..860 (RESEARCH.md).
import React from "react";
import { AbsoluteFill, Img, staticFile } from "remotion";
import { Head, Hero, nozzle } from "./Ads";
import { Burst, C, Cat, DISPLAY, Embers, Face, Flames, Glow, Halftone, HoseBody, House, Jet, Photo, Smoke, Sticker, Truck, Vignette } from "./kit";

export const W = 1920;
export const H = 1080;

const rand = (s: number) => {
  const x = Math.sin(s * 127.1 + 311.7) * 43758.5453;
  return x - Math.floor(x);
};

/* ------------------------------------------------------------- shared bits */

export const Rim: React.FC<{ color?: string }> = ({ color = C.ink }) => <AbsoluteFill style={{ boxShadow: `inset 0 0 0 14px ${color}` }} />;

export const FireFloor: React.FC<{ h?: number; seed?: number; count?: number }> = ({ h = 240, seed = 2, count = 16 }) => (
  <div style={{ position: "absolute", left: -20, right: -20, bottom: -14 }}>
    <Flames width={W + 40} height={h} count={count} seed={seed} outline={9} />
  </div>
);

export const At: React.FC<{ x: number; y: number; rot?: number; z?: number; shadow?: number; children: React.ReactNode; style?: React.CSSProperties }> = ({
  x,
  y,
  rot = 0,
  z,
  shadow = 10,
  children,
  style,
}) => (
  <div style={{ position: "absolute", left: x, top: y, transform: rot ? `rotate(${rot}deg)` : undefined, zIndex: z, filter: shadow ? `drop-shadow(0 ${shadow}px 0 ${C.ink})` : undefined, ...style }}>
    {children}
  </div>
);

// Big hook: optional small top line + big main line. align: left | center | right.
export const Hook: React.FC<{
  top?: string;
  main: string;
  topSize?: number;
  size?: number;
  fill?: string;
  rim?: string;
  topFill?: string;
  topRim?: string;
  align?: "left" | "center" | "right";
  x?: number;
  y?: number;
  rot?: number;
}> = ({ top, main, topSize = 160, size = 230, fill = C.fireCore, rim = C.fireEdge, topFill = C.cream, topRim = C.red, align = "center", x = 150, y = 80, rot = 0 }) => {
  const pos: React.CSSProperties =
    align === "center" ? { left: 0, right: 0, alignItems: "center" } : align === "left" ? { left: x, alignItems: "flex-start" } : { right: x, alignItems: "flex-end" };
  return (
    <div style={{ position: "absolute", top: y, display: "flex", flexDirection: "column", transform: rot ? `rotate(${rot}deg)` : undefined, ...pos }}>
      {top && (
        <Head size={topSize} fill={topFill} rim={topRim}>
          {top}
        </Head>
      )}
      <Head size={size} fill={fill} rim={rim} style={{ marginTop: top ? -size * 0.06 : 0 }}>
        {main}
      </Head>
    </div>
  );
};

const Speed: React.FC<{ n?: number; seed?: number; color?: string; y0?: number; y1?: number; o?: number }> = ({ n = 26, seed = 4, color = "#fff", y0 = 200, y1 = 1000, o = 0.55 }) => (
  <svg width={W} height={H} style={{ position: "absolute", left: 0, top: 0 }}>
    {Array.from({ length: n }, (_, i) => {
      const y = y0 + rand(seed + i * 3) * (y1 - y0);
      const x = -200 + rand(seed * 5 + i) * 1500;
      const len = 200 + rand(seed * 7 + i) * 500;
      return <rect key={i} x={x} y={y} width={len} height={6 + rand(i * 9) * 12} rx={8} fill={color} opacity={o * (0.5 + rand(i * 13) * 0.5)} />;
    })}
  </svg>
);

/* ------------------------------------------------------------ new cartoon kit */

// Hero facing LEFT: body mirrored, face (and its "67") kept readable. (x, y) = top-left of the head.
// Nozzle tip lands at (x - 0.144 f, y + 0.792 f).
export const HeroFlip: React.FC<{ x: number; y: number; f: number; mood?: "brave" | "panic" | "smug" | "shock" }> = ({ x, y, f, mood = "brave" }) => (
  <div style={{ position: "absolute", left: x, top: y, filter: `drop-shadow(0 ${f * 0.03}px 0 ${C.ink}) drop-shadow(${-f * 0.04}px ${-f * 0.03}px ${f * 0.08}px rgba(255,140,30,0.85))` }}>
    <HoseBody size={f * 1.2} style={{ position: "absolute", left: -f * 0.144, top: f * 0.672, transform: "scaleX(-1)" }} />
    <Face size={f} mood={mood} look={[-16, 4, -18, 4]} style={{ position: "absolute", left: 0, top: 0 }} />
  </div>
);
export const nozzleFlip = (x: number, y: number, f: number) => [x - 0.144 * f, y + 0.792 * f] as const;

// Kid penguin chick: grey fluffy, no helmet. viewBox 200x220.
export const Chick: React.FC<{ size: number; mood?: "panic" | "happy"; bow?: string; style?: React.CSSProperties }> = ({ size, mood = "panic", bow, style }) => {
  const ink = C.ink;
  return (
    <svg width={size} height={(size * 220) / 200} viewBox="0 0 200 220" style={{ overflow: "visible", ...style }}>
      <path d="M 40 60 Q 30 20 60 30 Q 70 0 100 18 Q 130 0 140 30 Q 172 20 160 60 Q 196 120 160 190 Q 100 230 40 190 Q 4 120 40 60 Z" fill="#8C93A3" stroke={ink} strokeWidth={9} strokeLinejoin="round" />
      <ellipse cx={100} cy={140} rx={56} ry={58} fill="#EDEFF4" />
      <circle cx={72} cy={96} r={24} fill="#fff" stroke={ink} strokeWidth={6} />
      <circle cx={128} cy={96} r={24} fill="#fff" stroke={ink} strokeWidth={6} />
      <circle cx={mood === "panic" ? 72 : 76} cy={mood === "panic" ? 92 : 100} r={10} fill={ink} />
      <circle cx={mood === "panic" ? 128 : 124} cy={mood === "panic" ? 92 : 100} r={10} fill={ink} />
      {mood === "panic" ? (
        <g>
          <path d="M 78 128 L 122 128 L 100 168 Z" fill="#7A1F10" stroke={ink} strokeWidth={6} strokeLinejoin="round" />
          <path d="M 76 124 L 124 124 L 100 140 Z" fill={C.beak} stroke={ink} strokeWidth={6} strokeLinejoin="round" />
          <path d="M 52 62 Q 70 52 88 64" stroke={ink} strokeWidth={6} fill="none" strokeLinecap="round" />
          <path d="M 112 64 Q 130 52 148 62" stroke={ink} strokeWidth={6} fill="none" strokeLinecap="round" />
        </g>
      ) : (
        <path d="M 80 126 L 120 126 L 100 150 Z" fill={C.beak} stroke={ink} strokeWidth={6} strokeLinejoin="round" />
      )}
      <ellipse cx={58} cy={130} rx={12} ry={7} fill="#FF9FB0" opacity={0.8} />
      <ellipse cx={142} cy={130} rx={12} ry={7} fill="#FF9FB0" opacity={0.8} />
      {bow && (
        <g transform="translate(140 30) rotate(20)">
          <path d="M 0 0 L -30 -18 L -30 18 Z M 0 0 L 30 -18 L 30 18 Z" fill={bow} stroke={ink} strokeWidth={6} strokeLinejoin="round" />
          <circle r={9} fill={bow} stroke={ink} strokeWidth={5} />
        </g>
      )}
      {/* waving flippers */}
      <path d="M 30 110 Q -10 80 -4 40 Q 14 44 44 92 Z" fill="#8C93A3" stroke={ink} strokeWidth={8} strokeLinejoin="round" />
      <path d="M 170 110 Q 210 80 204 40 Q 186 44 156 92 Z" fill="#8C93A3" stroke={ink} strokeWidth={8} strokeLinejoin="round" />
    </svg>
  );
};

// Panda, sitting, scared. viewBox 300x300.
export const Panda: React.FC<{ size: number; style?: React.CSSProperties }> = ({ size, style }) => {
  const ink = C.ink;
  return (
    <svg width={size} height={size} viewBox="0 0 300 300" style={{ overflow: "visible", ...style }}>
      <ellipse cx={150} cy={225} rx={110} ry={78} fill="#fff" stroke={ink} strokeWidth={10} />
      <ellipse cx={70} cy={270} rx={44} ry={30} fill={ink} />
      <ellipse cx={230} cy={270} rx={44} ry={30} fill={ink} />
      <path d="M 60 190 Q 20 150 40 110 Q 70 120 90 175 Z" fill={ink} />
      <path d="M 240 190 Q 280 150 260 110 Q 230 120 210 175 Z" fill={ink} />
      <circle cx={68} cy={42} r={36} fill={ink} />
      <circle cx={232} cy={42} r={36} fill={ink} />
      <ellipse cx={150} cy={105} rx={110} ry={92} fill="#fff" stroke={ink} strokeWidth={10} />
      <ellipse cx={104} cy={100} rx={36} ry={44} fill={ink} transform="rotate(-25 104 100)" />
      <ellipse cx={196} cy={100} rx={36} ry={44} fill={ink} transform="rotate(25 196 100)" />
      <circle cx={106} cy={96} r={20} fill="#fff" />
      <circle cx={194} cy={96} r={20} fill="#fff" />
      <circle cx={108} cy={92} r={9} fill={ink} />
      <circle cx={192} cy={92} r={9} fill={ink} />
      <ellipse cx={150} cy={140} rx={20} ry={13} fill={ink} />
      <ellipse cx={150} cy={170} rx={22} ry={16} fill="#7A1F10" stroke={ink} strokeWidth={6} />
      <ellipse cx={92} cy={142} rx={14} ry={8} fill="#FF9FB0" opacity={0.8} />
      <ellipse cx={208} cy={142} rx={14} ry={8} fill="#FF9FB0" opacity={0.8} />
      <path d="M 262 70 Q 282 106 262 120 Q 242 106 262 70 Z" fill={C.water} stroke={ink} strokeWidth={6} />
    </svg>
  );
};

// School building, viewBox 1000x560. Windows glow and optionally hold chicks.
export const School: React.FC<{ width: number; kids?: boolean; style?: React.CSSProperties }> = ({ width, kids = true, style }) => {
  const ink = C.ink;
  const win = (x: number, y: number, k: number) => (
    <g key={`${x}-${y}`}>
      <rect x={x} y={y} width={130} height={110} rx={8} fill={C.fireBody} stroke={ink} strokeWidth={10} />
      <rect x={x + 10} y={y + 10} width={110} height={44} rx={4} fill={C.fireCore} />
      <path
        d={`M ${x - 6} ${y + 8} Q ${x + 20} ${y - 80 * k} ${x + 50} ${y - 10} Q ${x + 70} ${y - 120 * k} ${x + 95} ${y - 8} Q ${x + 125} ${y - 70 * k} ${x + 136} ${y + 8} Z`}
        fill={C.fireBody}
        stroke={ink}
        strokeWidth={8}
        strokeLinejoin="round"
      />
      <path d={`M ${x + 30} ${y + 4} Q ${x + 52} ${y - 60 * k} ${x + 70} ${y - 4} Q ${x + 88} ${y - 50 * k} ${x + 104} ${y + 4} Z`} fill={C.fireCore} />
    </g>
  );
  return (
    <svg width={width} height={(width * 560) / 1000} viewBox="0 0 1000 560" style={{ overflow: "visible", ...style }}>
      <rect x={20} y={200} width={960} height={360} fill="#D9644A" stroke={ink} strokeWidth={14} />
      {Array.from({ length: 6 }, (_, r) => (
        <line key={r} x1={20} y1={250 + r * 52} x2={980} y2={250 + r * 52} stroke="#B84E38" strokeWidth={6} />
      ))}
      <rect x={0} y={170} width={1000} height={44} fill="#F1E2C2" stroke={ink} strokeWidth={12} />
      {/* bell tower */}
      <rect x={410} y={40} width={180} height={150} fill="#D9644A" stroke={ink} strokeWidth={12} />
      <path d="M 390 50 L 500 -40 L 610 50 Z" fill={C.redDark} stroke={ink} strokeWidth={12} strokeLinejoin="round" />
      <circle cx={500} cy={110} r={44} fill={C.cream} stroke={ink} strokeWidth={9} />
      <path d="M 500 110 L 500 80 M 500 110 L 522 118" stroke={ink} strokeWidth={8} strokeLinecap="round" />
      {/* sign */}
      <rect x={330} y={222} width={340} height={70} rx={12} fill={C.cream} stroke={ink} strokeWidth={10} />
      <text x={500} y={278} textAnchor="middle" fontFamily={DISPLAY} fontSize={56} fill={C.red}>
        SCHOOL
      </text>
      {win(70, 250, 1)}
      {win(790, 250, 1.2)}
      {win(70, 410, 0.7)}
      {win(790, 410, 0.9)}
      {/* doors */}
      <rect x={420} y={380} width={160} height={180} rx={10} fill="#5FA6A8" stroke={ink} strokeWidth={10} />
      <line x1={500} y1={380} x2={500} y2={560} stroke={ink} strokeWidth={8} />
      {win(250, 330, 0.6)}
      {win(620, 330, 0.8)}
    </svg>
  );
};

// Walkie-talkie radio. viewBox 260x520.
export const Radio: React.FC<{ height: number; style?: React.CSSProperties }> = ({ height, style }) => {
  const ink = C.ink;
  return (
    <svg width={(height * 260) / 520} height={height} viewBox="0 0 260 520" style={{ overflow: "visible", ...style }}>
      <rect x={170} y={0} width={36} height={150} rx={14} fill="#3A3F4C" stroke={ink} strokeWidth={10} />
      <rect x={20} y={120} width={220} height={390} rx={36} fill={C.red} stroke={ink} strokeWidth={14} />
      <rect x={50} y={160} width={160} height={110} rx={14} fill="#A8F0B0" stroke={ink} strokeWidth={10} />
      <path d="M 130 182 Q 108 214 120 246 Q 106 236 104 222 Q 96 252 130 256 Q 164 252 156 222 Q 152 236 140 246 Q 152 214 130 182 Z" fill={C.fireEdge} stroke={ink} strokeWidth={6} />
      {Array.from({ length: 4 }, (_, r) => (
        <rect key={r} x={60} y={300 + r * 40} width={140} height={18} rx={9} fill={C.redDark} />
      ))}
      <circle cx={70} cy={140} r={14} fill={C.fireCore} stroke={ink} strokeWidth={6} />
      <rect x={52} y={470} width={156} height={16} rx={8} fill="#fff" opacity={0.35} />
    </svg>
  );
};

// Photo inside a chunky tilted frame (a "polaroid" card).
export const Card: React.FC<{ src: string; x: number; y: number; w: number; h: number; rot?: number; filter?: string; label?: string; labelBg?: string; pos?: string }> = ({
  src,
  x,
  y,
  w,
  h,
  rot = 0,
  filter = "saturate(1.3) contrast(1.08)",
  label,
  labelBg = C.gold,
  pos = "50% 50%",
}) => (
  <div style={{ position: "absolute", left: x, top: y, width: w, height: h, transform: `rotate(${rot}deg)`, filter: `drop-shadow(0 14px 0 ${C.ink})` }}>
    <div style={{ position: "absolute", inset: 0, background: C.cream, border: `12px solid ${C.ink}`, borderRadius: 22, overflow: "hidden" }}>
      <Img src={staticFile(`shots/${src}.jpg`)} style={{ position: "absolute", inset: 14, width: w - 52, height: h - 52, objectFit: "cover", objectPosition: pos, borderRadius: 10, filter }} />
    </div>
    {label && (
      <div style={{ position: "absolute", left: 0, right: 0, bottom: -40, display: "flex", justifyContent: "center" }}>
        <Sticker bg={labelBg} rotate={-rot * 0.5 - 2} pad="4px 26px 0" border={8}>
          <span style={{ fontFamily: DISPLAY, fontSize: 62, color: C.ink, whiteSpace: "nowrap" }}>{label}</span>
        </Sticker>
      </div>
    )}
  </div>
);

const Bamboo: React.FC<{ x: number; h: number; seed: number }> = ({ x, h, seed }) => (
  <svg width={60} height={h} style={{ position: "absolute", left: x, bottom: 0, overflow: "visible" }}>
    <rect x={10} y={0} width={40} height={h} rx={12} fill="#6FBF4A" stroke={C.ink} strokeWidth={9} />
    {Array.from({ length: Math.floor(h / 120) }, (_, i) => (
      <line key={i} x1={8} x2={52} y1={100 + i * 120} y2={100 + i * 120} stroke={C.ink} strokeWidth={8} />
    ))}
    <path d={`M 50 ${120 + seed * 30} Q 110 ${80 + seed * 30} 130 ${110 + seed * 30} Q 90 ${130 + seed * 30} 50 ${130 + seed * 30} Z`} fill="#4FA548" stroke={C.ink} strokeWidth={7} />
  </svg>
);

// Apartment tower with faces in windows. viewBox 600x900.
const Apartments: React.FC<{ x: number; y: number; w: number }> = ({ x, y, w }) => {
  const ink = C.ink;
  const s = w / 600;
  return (
    <div style={{ position: "absolute", left: x, top: y }}>
      <svg width={w} height={900 * s} viewBox="0 0 600 900" style={{ overflow: "visible" }}>
        <rect x={0} y={0} width={600} height={940} fill="#4C5A78" stroke={ink} strokeWidth={14} />
        <rect x={-24} y={-24} width={648} height={44} fill="#2E3650" stroke={ink} strokeWidth={12} />
        {Array.from({ length: 5 }, (_, r) =>
          Array.from({ length: 3 }, (_, c) => (
            <rect key={`${r}${c}`} x={40 + c * 190} y={60 + r * 170} width={140} height={120} rx={8} fill={r < 3 ? C.fireBody : "#24304A"} stroke={ink} strokeWidth={9} />
          )),
        )}
      </svg>
    </div>
  );
};

/* ======================================================================= ADS */

/* 10  BE A FIREFIGHTER!  (full cartoon, blue sky) */
export const Ad10: React.FC = () => {
  const [hx, hy, f] = [110, 410, 430];
  const [nx, ny] = nozzle(hx, hy, f);
  return (
    <AbsoluteFill style={{ background: "linear-gradient(to bottom, #1E7FD8 0%, #63C3F5 55%, #BFEFFF 100%)", overflow: "hidden" }}>
      <Burst a="rgba(255,255,255,0.10)" b="rgba(255,255,255,0)" x="70%" y="70%" rays={28} />
      <div style={{ position: "absolute", left: 0, right: 0, bottom: 0, height: 170, background: "#5BB04A", borderTop: `12px solid ${C.ink}` }} />
      <At x={1030} y={420} shadow={14}>
        <House width={760} />
      </At>
      <div style={{ position: "absolute", left: 1000, top: 300 }}>
        <Flames width={820} height={360} count={8} seed={101} outline={9} />
      </div>
      <Glow x="74%" y="55%" r={40} o={0.7} />
      <Embers w={W} h={H} n={40} seed={101} size={2.2} />
      <Jet x0={nx} y0={ny} x1={1260} y1={690} w={70} bend={-0.2} splash={1.3} />
      <Hero x={hx} y={hy} f={f} glow={false} />
      <Hook top="BE A" main="FIREFIGHTER!" topSize={170} size={215} y={70} />
      <Rim />
    </AbsoluteFill>
  );
};

/* 11  PUT OUT THE FIRE!  (real house-fire photo, water hitting flames) */
export const Ad11: React.FC = () => {
  const [hx, hy, f] = [70, 500, 380];
  const [nx, ny] = nozzle(hx, hy, f);
  return (
    <AbsoluteFill style={{ background: C.ink, overflow: "hidden" }}>
      <Photo src="house-fire" scale={1.45} x={120} y={140} origin="50% 50%" filter="saturate(1.5) contrast(1.15) brightness(0.85)" />
      <AbsoluteFill style={{ background: "linear-gradient(to bottom, rgba(26,18,16,0.7) 0%, rgba(26,18,16,0) 45%)" }} />
      <div style={{ position: "absolute", left: 760, top: 470 }}>
        <Flames width={1100} height={480} count={9} seed={111} outline={10} />
      </div>
      <Glow x="70%" y="75%" r={45} o={0.8} />
      <Smoke w={600} h={300} seed={112} color="#E8F4F8" o={0.9} style={{ position: "absolute", left: 980, top: 380 }} />
      <Embers w={W} h={H} n={60} seed={111} size={2.4} />
      <Jet x0={nx} y0={ny} x1={1190} y1={600} w={74} bend={-0.22} splash={1.6} />
      <Hero x={hx} y={hy} f={f} />
      <Hook top="PUT OUT" main="THE FIRE!" topSize={200} size={250} align="right" x={150} y={70} />
      <Vignette o={0.4} inner={60} />
      <Rim />
    </AbsoluteFill>
  );
};

/* 12  SAVE THE KIDS!  (school fire, kid chicks in the windows) */
export const Ad12: React.FC = () => (
  <AbsoluteFill style={{ background: "linear-gradient(to bottom, #3B1E5A 0%, #C8432B 60%, #F59A3A 100%)", overflow: "hidden" }}>
    <Halftone opacity={0.1} />
    <Smoke w={1300} h={420} seed={121} color="#3A2A30" o={0.9} style={{ position: "absolute", left: 500, top: -60 }} />
    <div style={{ position: "absolute", left: 600, top: 300 }}>
      <Flames width={1250} height={330} count={10} seed={122} outline={9} />
    </div>
    <At x={620} y={480} shadow={14}>
      <School width={1180} />
    </At>
    {/* kids waving in the windows */}
    <At x={690} y={600} rot={-8} shadow={8}>
      <Chick size={180} bow="#FF6FA8" />
    </At>
    <At x={1530} y={600} rot={8} shadow={8}>
      <Chick size={180} />
    </At>
    <At x={1120} y={760} shadow={8}>
      <Chick size={150} bow="#5FE3F2" />
    </At>
    <Glow x="70%" y="60%" r={45} o={0.6} />
    <Embers w={W} h={H} n={60} seed={121} size={2.2} />
    {/* firefighter running in */}
    <At x={90} y={470} rot={-6} shadow={14}>
      <Face size={480} mood="brave" look={[22, 2, 22, 2]} />
    </At>
    <FireFloor h={150} seed={123} />
    <Hook top="SAVE" main="THE KIDS!" topSize={190} size={240} align="left" x={150} y={70} />
    <Rim />
  </AbsoluteFill>
);

/* 13  DRIVE THE FIRE TRUCK!  (purple night, speed lines) */
export const Ad13: React.FC = () => (
  <AbsoluteFill style={{ background: "linear-gradient(to bottom, #1A0F3A 0%, #4A2380 60%, #2A1650 100%)", overflow: "hidden" }}>
    <Speed n={30} seed={131} color="#B9A8FF" y0={420} y1={1000} o={0.5} />
    <div style={{ position: "absolute", left: 0, right: 0, bottom: 0, height: 150, background: "#2B2B35", borderTop: `12px solid ${C.ink}` }} />
    <svg width={W} height={H} style={{ position: "absolute", left: 0, top: 0 }}>
      {Array.from({ length: 6 }, (_, i) => (
        <rect key={i} x={-100 + i * 380} y={990} width={220} height={20} rx={8} fill={C.gold} />
      ))}
    </svg>
    <div style={{ position: "absolute", left: 1380, top: 520 }}>
      <Flames width={600} height={480} count={6} seed={132} outline={9} />
    </div>
    <Glow x="85%" y="80%" r={40} o={0.8} />
    <Speed n={14} seed={133} color="#fff" y0={560} y1={960} o={0.8} />
    <At x={130} y={430} rot={-3} shadow={16}>
      <div style={{ position: "relative" }}>
        <Truck width={1350} flash={0.2} />
        <Face size={210} mood="brave" look={[24, 0, 24, 0]} style={{ position: "absolute", left: 1000, top: 120 }} />
      </div>
    </At>
    <Embers w={W} h={H} n={40} seed={131} size={2} />
    <Hook top="DRIVE THE" main="FIRE TRUCK!" topSize={170} size={230} y={70} />
    <Rim />
  </AbsoluteFill>
);

/* 14  HOUSE ON FIRE!  (real truck-fire photo, giant cartoon house fire) */
export const Ad14: React.FC = () => (
  <AbsoluteFill style={{ background: C.ink, overflow: "hidden" }}>
    <Photo src="truck-fire" scale={1.2} x={0} y={20} origin="50% 60%" filter="saturate(1.4) contrast(1.1) brightness(0.6) blur(3px)" />
    <Burst a="rgba(255,90,31,0.35)" b="rgba(26,18,16,0)" x="58%" y="70%" rays={32} />
    <div style={{ position: "absolute", left: 640, top: 270 }}>
      <Flames width={1100} height={520} count={9} seed={141} outline={10} />
    </div>
    <At x={760} y={480} shadow={16}>
      <House width={860} />
    </At>
    <Glow x="62%" y="62%" r={50} o={0.8} />
    <Embers w={W} h={H} n={70} seed={141} size={2.6} />
    <At x={110} y={480} rot={-8} shadow={14}>
      <Face size={470} mood="panic" />
    </At>
    <Hook main="HOUSE ON FIRE!" size={235} y={80} rot={-2} />
    <Rim />
  </AbsoluteFill>
);

/* 15  ANSWER THE CALL!  (teal, giant dispatch radio) */
export const Ad15: React.FC = () => (
  <AbsoluteFill style={{ background: "radial-gradient(circle at 60% 60%, #2FB7B0 0%, #0E4A52 75%)", overflow: "hidden" }}>
    <Burst a="rgba(255,255,255,0.08)" b="rgba(255,255,255,0)" x="48%" y="62%" rays={24} />
    <At x={1330} y={560} shadow={14}>
      <House width={480} />
    </At>
    <div style={{ position: "absolute", left: 1290, top: 450 }}>
      <Flames width={560} height={300} count={6} seed={151} outline={9} />
    </div>
    <Glow x="80%" y="70%" r={35} o={0.7} />
    {/* radio waves */}
    <svg width={W} height={H} style={{ position: "absolute", left: 0, top: 0 }}>
      {[0, 1, 2].map((i) => (
        <path key={i} d={`M ${1000 + i * 70} ${420 - i * 40} Q ${1080 + i * 90} ${560} ${1000 + i * 70} ${700 + i * 40}`} stroke={C.fireCore} strokeWidth={22} fill="none" strokeLinecap="round" />
      ))}
    </svg>
    <At x={720} y={360} rot={10} shadow={16}>
      <Radio height={620} />
    </At>
    <At x={140} y={430} rot={-6} shadow={14}>
      <Face size={500} mood="shock" />
    </At>
    <Embers w={W} h={H} n={30} seed={151} size={2} />
    <FireFloor h={130} seed={152} />
    <Hook top="ANSWER" main="THE CALL!" topSize={180} size={235} align="left" x={150} y={70} />
    <Rim />
  </AbsoluteFill>
);

/* 16  SAVE THE PANDA!  (green zoo, bamboo burning) */
export const Ad16: React.FC = () => {
  const [hx, hy, f] = [1440, 470, 330];
  const [nx, ny] = nozzleFlip(hx, hy, f);
  return (
    <AbsoluteFill style={{ background: "linear-gradient(to bottom, #8FE07A 0%, #3E9A48 70%, #2C6E34 100%)", overflow: "hidden" }}>
      <Halftone opacity={0.08} />
      {[120, 260, 380, 1700, 1820, 560].map((x, i) => (
        <Bamboo key={x} x={x} h={700 + (i % 3) * 120} seed={i % 3} />
      ))}
      <div style={{ position: "absolute", left: 0, right: 0, bottom: 0, height: 150, background: "#7A5A3A", borderTop: `12px solid ${C.ink}` }} />
      <div style={{ position: "absolute", left: 60, top: 470 }}>
        <Flames width={760} height={470} count={7} seed={161} outline={9} />
      </div>
      <Glow x="22%" y="75%" r={40} o={0.7} />
      <At x={640} y={400} rot={-4} shadow={14}>
        <Panda size={540} />
      </At>
      <Jet x0={nx} y0={ny} x1={420} y1={640} w={60} bend={-0.25} splash={1.4} />
      <HeroFlip x={hx} y={hy} f={f} />
      <Embers w={W} h={H} n={50} seed={161} size={2.2} />
      <Hook top="SAVE THE" main="PANDA!" topSize={190} size={270} align="right" x={150} y={70} />
      <Rim />
    </AbsoluteFill>
  );
};

/* 17  STOP THE FIRE!  (split: wall of fire vs blue water) */
export const Ad17: React.FC = () => {
  const [hx, hy, f] = [1180, 400, 400];
  const [nx, ny] = nozzleFlip(hx, hy, f);
  return (
    <AbsoluteFill style={{ background: "#1565C0", overflow: "hidden" }}>
      <svg width={W} height={H} style={{ position: "absolute", left: 0, top: 0 }}>
        <polygon points="0,0 900,0 700,1080 0,1080" fill={C.fireDark} />
        <polygon points="900,0 1920,0 1920,1080 700,1080" fill="#1E88E5" />
        <line x1={900} y1={0} x2={700} y2={1080} stroke={C.ink} strokeWidth={16} />
      </svg>
      <div style={{ position: "absolute", left: -80, top: 290 }}>
        <Flames width={980} height={790} count={7} seed={171} outline={10} />
      </div>
      <Glow x="20%" y="70%" r={45} o={0.85} />
      <Jet x0={nx} y0={ny} x1={640} y1={680} w={86} bend={-0.15} splash={1.7} />
      <HeroFlip x={hx} y={hy} f={f} />
      <Embers w={W} h={H} n={50} seed={171} size={2.4} />
      <Hook main="STOP THE FIRE!" size={240} fill="#FFFFFF" rim="#1565C0" y={80} rot={-2} />
      <Rim />
    </AbsoluteFill>
  );
};

/* 18  FIRE TRUCK RACE!  (yellow burst, two trucks racing to a fire) */
export const Ad18: React.FC = () => (
  <AbsoluteFill style={{ background: C.gold, overflow: "hidden" }}>
    <Burst a="#FFD54A" b="#F6B12E" x="88%" y="70%" rays={30} />
    <div style={{ position: "absolute", left: 1450, top: 470 }}>
      <Flames width={520} height={430} count={5} seed={181} outline={9} />
    </div>
    <div style={{ position: "absolute", left: 0, right: 0, bottom: 0, height: 140, background: "#3A3A44", borderTop: `12px solid ${C.ink}` }} />
    <Speed n={22} seed={181} color={C.ink} y0={500} y1={980} o={0.35} />
    <At x={40} y={420} rot={-2} shadow={12}>
      <div style={{ position: "relative" }}>
        <Truck width={860} flash={0.7} number="12" />
        <Face size={140} mood="smug" number="12" style={{ position: "absolute", left: 640, top: 70 }} />
      </div>
    </At>
    <At x={420} y={560} rot={-3} shadow={14}>
      <div style={{ position: "relative" }}>
        <Truck width={1080} flash={0.2} />
        <Face size={175} mood="brave" look={[24, 0, 24, 0]} style={{ position: "absolute", left: 800, top: 90 }} />
      </div>
    </At>
    <Embers w={W} h={H} n={30} seed={181} size={2} />
    <Hook main="FIRE TRUCK RACE!" size={220} y={80} rot={-2} fill={C.cream} rim={C.red} />
    <Rim />
  </AbsoluteFill>
);

/* 19  SPRAY IT!  (blue, extreme close-up face, huge jet into fire) */
export const Ad19: React.FC = () => (
  <AbsoluteFill style={{ background: "radial-gradient(circle at 30% 60%, #4FC3F7 0%, #0D47A1 80%)", overflow: "hidden" }}>
    <Halftone opacity={0.12} color="#0A2A6A" />
    <div style={{ position: "absolute", left: 1080, top: 420 }}>
      <Flames width={900} height={680} count={7} seed={191} outline={10} />
    </div>
    <Glow x="80%" y="75%" r={40} o={0.85} />
    <Jet x0={640} y0={1120} x1={1420} y1={720} w={130} bend={-0.15} splash={1.4} />
    <At x={40} y={260} rot={-8} shadow={16}>
      <Face size={720} mood="brave" look={[26, 6, 26, 6]} />
    </At>
    <Embers w={W} h={H} n={50} seed={191} size={2.4} />
    <Hook main="SPRAY IT!" size={300} fill="#FFFFFF" rim="#1E88E5" align="right" x={150} y={80} rot={-4} />
    <Rim />
  </AbsoluteFill>
);

/* 20  RESCUE EVERYONE!  (photo, firefighter leading cat, chick and panda out) */
export const Ad20: React.FC = () => (
  <AbsoluteFill style={{ background: C.ink, overflow: "hidden" }}>
    <Photo src="house-fire" scale={1.3} x={-200} y={60} origin="50% 50%" filter="saturate(1.5) contrast(1.1) brightness(0.95)" />
    <AbsoluteFill style={{ background: "linear-gradient(to bottom, rgba(26,18,16,0.75) 0%, rgba(26,18,16,0) 45%)" }} />
    <div style={{ position: "absolute", left: -60, top: 520 }}>
      <Flames width={520} height={460} count={5} seed={201} outline={9} />
    </div>
    <Glow x="18%" y="75%" r={40} o={0.8} />
    <Embers w={W} h={H} n={50} seed={201} size={2.2} />
    <At x={330} y={520} rot={-6} shadow={12}>
      <Panda size={420} />
    </At>
    <At x={780} y={600} rot={4} shadow={12}>
      <Chick size={270} mood="happy" bow="#FF6FA8" />
    </At>
    <At x={1060} y={620} rot={-4} shadow={12}>
      <Cat size={300} />
    </At>
    <At x={1400} y={430} rot={6} shadow={14}>
      <Face size={430} mood="brave" look={[24, 4, 24, 4]} />
    </At>
    <Hook top="RESCUE" main="EVERYONE!" topSize={190} size={240} y={70} />
    <Rim />
  </AbsoluteFill>
);

/* 21  CAN YOU SAVE THEM?  (pink dusk, apartment tower, faces in windows) */
export const Ad21: React.FC = () => (
  <AbsoluteFill style={{ background: "linear-gradient(to bottom, #3A1450 0%, #B0306A 55%, #FF8A50 100%)", overflow: "hidden" }}>
    <Smoke w={900} h={400} seed={211} color="#2A1A2A" o={0.9} style={{ position: "absolute", left: 1000, top: -80 }} />
    <div style={{ position: "absolute", left: 980, top: 130 }}>
      <Flames width={800} height={270} count={7} seed={212} outline={9} />
    </div>
    <Apartments x={1020} y={360} w={720} />
    {[
      [1084, 418, "#FF6FA8"],
      [1312, 418, undefined],
      [1540, 418, "#5FE3F2"],
      [1084, 622, undefined],
      [1540, 622, "#FFD54A"],
    ].map(([x, y, bow], i) => (
      <At key={i} x={x as number} y={y as number} rot={i % 2 ? 5 : -5} shadow={5}>
        <Chick size={135} bow={bow as string | undefined} />
      </At>
    ))}
    <At x={1308} y={624} shadow={5}>
      <Cat size={150} />
    </At>
    <Glow x="72%" y="40%" r={40} o={0.6} />
    <Embers w={W} h={H} n={50} seed={211} size={2.2} />
    <At x={170} y={500} rot={-6} shadow={14}>
      <Face size={440} mood="brave" look={[24, -10, 24, -10]} />
    </At>
    <Hook top="CAN YOU" main="SAVE THEM?" topSize={180} size={215} align="left" x={150} y={70} />
    <Rim />
  </AbsoluteFill>
);

/* 22  GIANT FIRE!  (scale: tiny penguin vs a wall of flame) */
export const Ad22: React.FC = () => (
  <AbsoluteFill style={{ background: "linear-gradient(to bottom, #12080A 0%, #4A0E0E 50%, #8E1219 100%)", overflow: "hidden" }}>
    <div style={{ position: "absolute", left: -200, top: 260 }}>
      <Flames width={2320} height={840} count={11} seed={221} outline={12} />
    </div>
    <Glow x="50%" y="90%" r={60} o={0.9} />
    <Embers w={W} h={H} n={100} seed={221} size={3} />
    <div style={{ position: "absolute", left: 0, right: 0, bottom: 0, height: 120, background: C.ink }} />
    <At x={860} y={650} shadow={10}>
      <div style={{ position: "relative", width: 200, height: 360 }}>
        <Hero x={0} y={0} f={200} mood="shock" glow />
      </div>
    </At>
    <Hook main="GIANT FIRE!" size={290} fill="#FFFFFF" rim={C.red} y={70} rot={-2} />
    <Rim />
  </AbsoluteFill>
);

/* 23  FIRE SQUAD!  (real station photo, four friends) */
export const Ad23: React.FC = () => {
  const squad: { n: string; m: "brave" | "smug" | "panic" | "shock"; x: number; r: number }[] = [
    { n: "01", m: "smug", x: 120, r: -8 },
    { n: "67", m: "brave", x: 520, r: -2 },
    { n: "07", m: "shock", x: 960, r: 4 },
    { n: "12", m: "brave", x: 1360, r: 9 },
  ];
  return (
    <AbsoluteFill style={{ background: C.ink, overflow: "hidden" }}>
      <Photo src="station-squad" scale={1.15} y={-40} filter="saturate(1.3) contrast(1.05) brightness(0.65) blur(4px)" />
      <AbsoluteFill style={{ background: "linear-gradient(to bottom, rgba(26,18,16,0.6) 0%, rgba(26,18,16,0) 40%, rgba(122,31,16,0.5) 100%)" }} />
      <FireFloor h={430} seed={231} count={14} />
      <Glow x="50%" y="95%" r={60} o={0.8} />
      {squad.map((p, i) => (
        <At key={i} x={p.x} y={i % 2 ? 470 : 520} rot={p.r} shadow={14}>
          <Face size={430} mood={p.m} number={p.n} />
        </At>
      ))}
      <Embers w={W} h={H} n={50} seed={231} size={2.2} />
      <Hook main="FIRE SQUAD!" size={290} fill={C.gold} rim={C.goldDark} y={80} rot={-2} />
      <Rim />
    </AbsoluteFill>
  );
};
