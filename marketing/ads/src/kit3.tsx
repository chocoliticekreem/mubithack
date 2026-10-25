// Wave 3 art: a front-view fire truck with a penguin driver, a scared puppy, a stopwatch, a night sky (stars, moon),
// and a "sticker rim" (thick white outline) that makes one subject pop at icon size.
import React from "react";
import { Face, Mood } from "./kit";
import { C, DISPLAY } from "./theme";

const rand = (s: number) => {
  const x = Math.sin(s * 127.1 + 311.7) * 43758.5453;
  return x - Math.floor(x);
};

// Thick outline around any element: 4 hard drop-shadows of `px` in `color`, then an ink pass on top.
export const rim = (px: number, color = "#FFFFFF", ink = 0) =>
  [
    `drop-shadow(${px}px 0 0 ${color})`,
    `drop-shadow(-${px}px 0 0 ${color})`,
    `drop-shadow(0 ${px}px 0 ${color})`,
    `drop-shadow(0 -${px}px 0 ${color})`,
    ink ? `drop-shadow(0 ${ink}px 0 ${C.ink})` : "",
  ].join(" ");

/* ------------------------------------------------------ front-view truck */

// Fire engine seen head-on, with a penguin driver behind the windshield. viewBox 600x520.
export const TruckFront: React.FC<{ width: number; mood?: Mood; flash?: number; number?: string; look?: [number, number, number, number] }> = ({
  width,
  mood = "brave",
  flash = 0.2,
  number = "67",
  look = [0, 6, 0, 6],
}) => {
  const ink = C.ink;
  const s = width / 600;
  const on = flash % 1 < 0.5;
  return (
    <div style={{ position: "relative", width, height: 520 * s }}>
      <svg width={width} height={520 * s} viewBox="0 0 600 520" style={{ position: "absolute", left: 0, top: 0, overflow: "visible" }}>
        {/* light glow */}
        <ellipse cx={220} cy={40} rx={120} ry={60} fill={on ? "rgba(255,60,60,0.55)" : "rgba(80,140,255,0.55)"} />
        <ellipse cx={380} cy={40} rx={120} ry={60} fill={on ? "rgba(80,140,255,0.55)" : "rgba(255,60,60,0.55)"} />
        {/* mirrors */}
        <rect x={-10} y={130} width={40} height={90} rx={10} fill="#C9CCD0" stroke={ink} strokeWidth={9} />
        <rect x={570} y={130} width={40} height={90} rx={10} fill="#C9CCD0" stroke={ink} strokeWidth={9} />
        <path d="M 30 170 L 64 170 M 570 170 L 536 170" stroke={ink} strokeWidth={10} />
        {/* cab */}
        <rect x={54} y={64} width={492} height={360} rx={44} fill={C.red} stroke={ink} strokeWidth={14} />
        <rect x={70} y={78} width={140} height={20} rx={10} fill="#fff" opacity={0.3} />
        {/* windshield */}
        <rect x={96} y={88} width={408} height={232} rx={26} fill={C.water} stroke={ink} strokeWidth={12} />
      </svg>
      {/* driver */}
      <div style={{ position: "absolute", left: 102 * s, top: 94 * s, width: 396 * s, height: 220 * s, overflow: "hidden", borderRadius: 20 * s }}>
        <Face size={240 * s} mood={mood} number={number} look={look} style={{ position: "absolute", left: 78 * s, top: -20 * s }} />
      </div>
      <svg width={width} height={520 * s} viewBox="0 0 600 520" style={{ position: "absolute", left: 0, top: 0, overflow: "visible" }}>
        {/* lower cab front hides the driver's body below the dashboard */}
        <rect x={61} y={316} width={478} height={96} fill={C.red} />
        {/* glass glare + dashboard covering the driver's lower half */}
        <path d="M 116 104 L 180 104 L 126 230 L 110 230 Z" fill="#fff" opacity={0.55} />
        <path d="M 96 290 L 504 290 L 504 304 Q 504 330 478 330 L 122 330 Q 96 330 96 304 Z" fill={C.redDark} stroke={ink} strokeWidth={12} strokeLinejoin="round" />
        {/* lightbar */}
        <rect x={150} y={22} width={150} height={50} rx={16} fill={on ? "#FF3B3B" : "#4F86FF"} stroke={ink} strokeWidth={11} />
        <rect x={300} y={22} width={150} height={50} rx={16} fill={on ? "#4F86FF" : "#FF3B3B"} stroke={ink} strokeWidth={11} />
        <rect x={168} y={30} width={60} height={12} rx={6} fill="#fff" opacity={0.6} />
        <rect x={318} y={30} width={60} height={12} rx={6} fill="#fff" opacity={0.6} />
        {/* grille */}
        <rect x={190} y={340} width={220} height={66} rx={12} fill="#C9CCD0" stroke={ink} strokeWidth={11} />
        {Array.from({ length: 7 }, (_, i) => (
          <line key={i} x1={212 + i * 29} y1={348} x2={212 + i * 29} y2={398} stroke={ink} strokeWidth={8} />
        ))}
        {/* number shield on the grille */}
        <path d="M 262 334 L 338 334 L 338 368 Q 338 394 300 406 Q 262 394 262 368 Z" fill={C.shield} stroke={ink} strokeWidth={10} strokeLinejoin="round" />
        <text x={300} y={384} textAnchor="middle" fontFamily={DISPLAY} fontSize={42} fill={ink}>
          {number}
        </text>
        {/* headlights */}
        {[118, 482].map((x) => (
          <g key={x}>
            <circle cx={x} cy={372} r={36} fill={C.fireCore} stroke={ink} strokeWidth={11} />
            <circle cx={x - 10} cy={362} r={11} fill="#fff" />
          </g>
        ))}
        {/* bumper */}
        <rect x={30} y={404} width={540} height={52} rx={16} fill="#D6D9DE" stroke={ink} strokeWidth={12} />
        {/* wheels */}
        <rect x={70} y={452} width={110} height={68} rx={18} fill={ink} />
        <rect x={420} y={452} width={110} height={68} rx={18} fill={ink} />
      </svg>
    </div>
  );
};

/* ------------------------------------------------------------------ puppy */

// Scared puppy, sitting. viewBox 300x300.
export const Puppy: React.FC<{ size: number; style?: React.CSSProperties }> = ({ size, style }) => {
  const ink = C.ink;
  const fur = "#E0A866";
  const dark = "#8A5226";
  return (
    <svg width={size} height={size} viewBox="0 0 300 300" style={{ overflow: "visible", ...style }}>
      {/* body + paws */}
      <ellipse cx={150} cy={238} rx={92} ry={62} fill={fur} stroke={ink} strokeWidth={10} />
      <ellipse cx={150} cy={250} rx={48} ry={40} fill="#FFF1DC" />
      <ellipse cx={104} cy={286} rx={30} ry={18} fill="#FFF1DC" stroke={ink} strokeWidth={8} />
      <ellipse cx={196} cy={286} rx={30} ry={18} fill="#FFF1DC" stroke={ink} strokeWidth={8} />
      {/* tail */}
      <path d="M 236 240 Q 290 220 280 180" stroke={ink} strokeWidth={30} fill="none" strokeLinecap="round" />
      <path d="M 236 240 Q 290 220 280 180" stroke={fur} strokeWidth={16} fill="none" strokeLinecap="round" />
      {/* head */}
      <ellipse cx={150} cy={112} rx={104} ry={90} fill={fur} stroke={ink} strokeWidth={10} />
      {/* floppy ears */}
      <path d="M 60 60 Q 10 70 18 170 Q 40 190 70 150 Q 80 100 74 66 Z" fill={dark} stroke={ink} strokeWidth={10} strokeLinejoin="round" />
      <path d="M 240 60 Q 290 70 282 170 Q 260 190 230 150 Q 220 100 226 66 Z" fill={dark} stroke={ink} strokeWidth={10} strokeLinejoin="round" />
      {/* eye patch */}
      <ellipse cx={196} cy={100} rx={44} ry={40} fill={dark} opacity={0.85} />
      {/* muzzle */}
      <ellipse cx={150} cy={150} rx={56} ry={40} fill="#FFF1DC" stroke={ink} strokeWidth={8} />
      {/* worried brows */}
      <path d="M 82 64 Q 104 46 128 70" stroke={ink} strokeWidth={9} fill="none" strokeLinecap="round" />
      <path d="M 172 70 Q 196 46 218 64" stroke={ink} strokeWidth={9} fill="none" strokeLinecap="round" />
      {/* huge eyes */}
      <circle cx={108} cy={104} r={32} fill="#fff" stroke={ink} strokeWidth={8} />
      <circle cx={192} cy={104} r={32} fill="#fff" stroke={ink} strokeWidth={8} />
      <circle cx={110} cy={110} r={18} fill={ink} />
      <circle cx={190} cy={110} r={18} fill={ink} />
      <circle cx={104} cy={102} r={7} fill="#fff" />
      <circle cx={184} cy={102} r={7} fill="#fff" />
      {/* tear */}
      <path d="M 86 132 Q 74 160 86 170 Q 98 160 86 132 Z" fill={C.water} stroke={ink} strokeWidth={5} />
      {/* nose + mouth */}
      <ellipse cx={150} cy={136} rx={20} ry={14} fill={ink} />
      <ellipse cx={144} cy={132} rx={6} ry={3} fill="#fff" opacity={0.6} />
      <path d="M 126 166 Q 150 150 174 166 Q 150 196 126 166 Z" fill="#7A1F10" stroke={ink} strokeWidth={6} />
      <ellipse cx={150} cy={178} rx={10} ry={6} fill="#FF7A8A" />
      {/* collar */}
      <path d="M 70 186 Q 150 214 230 186" stroke={ink} strokeWidth={24} fill="none" strokeLinecap="round" />
      <path d="M 70 186 Q 150 214 230 186" stroke="#2F8FE0" strokeWidth={12} fill="none" strokeLinecap="round" />
      <circle cx={150} cy={210} r={14} fill={C.gold} stroke={ink} strokeWidth={6} />
    </svg>
  );
};

/* -------------------------------------------------------------- stopwatch */

// Cartoon stopwatch, viewBox 400x440. `hand` is the hand angle in degrees (0 = 12 o'clock).
export const Stopwatch: React.FC<{ size: number; hand?: number; style?: React.CSSProperties }> = ({ size, hand = 300, style }) => {
  const ink = C.ink;
  const a = ((hand - 90) * Math.PI) / 180;
  return (
    <svg width={size} height={(size * 440) / 400} viewBox="0 0 400 440" style={{ overflow: "visible", ...style }}>
      <rect x={170} y={0} width={60} height={50} rx={12} fill={C.red} stroke={ink} strokeWidth={10} />
      <rect x={186} y={40} width={28} height={30} fill="#C9CCD0" stroke={ink} strokeWidth={8} />
      <rect x={300} y={60} width={50} height={36} rx={10} fill={C.red} stroke={ink} strokeWidth={9} transform="rotate(40 325 78)" />
      <circle cx={200} cy={250} r={184} fill={C.red} stroke={ink} strokeWidth={14} />
      <circle cx={200} cy={250} r={148} fill={C.cream} stroke={ink} strokeWidth={10} />
      {/* elapsed wedge */}
      <path d={`M 200 250 L 200 102 A 148 148 0 1 1 ${200 + Math.cos(a) * 148} ${250 + Math.sin(a) * 148} Z`} fill="#FFB3A0" opacity={0.75} />
      {Array.from({ length: 12 }, (_, i) => {
        const t = (i / 12) * Math.PI * 2;
        return <line key={i} x1={200 + Math.sin(t) * 120} y1={250 - Math.cos(t) * 120} x2={200 + Math.sin(t) * 140} y2={250 - Math.cos(t) * 140} stroke={ink} strokeWidth={i % 3 ? 7 : 12} strokeLinecap="round" />;
      })}
      <line x1={200} y1={250} x2={200 + Math.cos(a) * 118} y2={250 + Math.sin(a) * 118} stroke={ink} strokeWidth={16} strokeLinecap="round" />
      <circle cx={200} cy={250} r={18} fill={ink} />
      <ellipse cx={120} cy={150} rx={40} ry={16} fill="#fff" opacity={0.6} transform="rotate(-40 120 150)" />
    </svg>
  );
};

/* -------------------------------------------------------------- night sky */

export const Stars: React.FC<{ w: number; h: number; n?: number; seed?: number }> = ({ w, h, n = 40, seed = 7 }) => (
  <svg width={w} height={h} style={{ position: "absolute", left: 0, top: 0 }}>
    {Array.from({ length: n }, (_, i) => {
      const x = rand(seed + i * 3) * w;
      const y = rand(seed * 5 + i) * h;
      const r = 2 + rand(seed * 9 + i) * 5;
      return <circle key={i} cx={x} cy={y} r={r} fill="#FFF8D0" opacity={0.5 + rand(i * 11) * 0.5} />;
    })}
  </svg>
);

export const Moon: React.FC<{ size: number; style?: React.CSSProperties }> = ({ size, style }) => (
  <svg width={size} height={size} viewBox="0 0 200 200" style={{ overflow: "visible", ...style }}>
    <circle cx={100} cy={100} r={98} fill="rgba(255,248,208,0.18)" />
    <circle cx={100} cy={100} r={74} fill="#FFF3B8" stroke={C.ink} strokeWidth={8} />
    <circle cx={76} cy={84} r={14} fill="#E8D88A" />
    <circle cx={122} cy={124} r={20} fill="#E8D88A" />
    <circle cx={126} cy={72} r={9} fill="#E8D88A" />
  </svg>
);
