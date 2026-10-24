// Ad-specific art on top of the listing kit (../../listing/src/art.tsx): expressive penguin faces,
// a full-body penguin with a hose, water jets, embers, smoke, a cartoon fire truck, a cat, a chief helmet.
import React from "react";
import { AbsoluteFill, Img, staticFile } from "remotion";
import { PenguinFace } from "./art";
import { C } from "./theme";

export { Burst, Flames, Frame, Halftone, Logo, Outline, PenguinFace, Ribbon, Sticker } from "./art";
export { BODY, C, DISPLAY } from "./theme";

const rand = (s: number) => {
  const x = Math.sin(s * 127.1 + 311.7) * 43758.5453;
  return x - Math.floor(x);
};

/* ----------------------------------------------------------------- photo */

export const Photo: React.FC<{
  src: string;
  scale?: number;
  x?: number;
  y?: number;
  filter?: string;
  origin?: string;
  ext?: string;
}> = ({ src, scale = 1, x = 0, y = 0, filter = "saturate(1.25) contrast(1.08)", origin = "50% 50%", ext = "jpg" }) => (
  <AbsoluteFill style={{ overflow: "hidden" }}>
    <Img
      src={staticFile(`shots/${src}.${ext}`)}
      style={{
        width: "100%",
        height: "100%",
        objectFit: "cover",
        transform: `translate(${x}px, ${y}px) scale(${scale})`,
        transformOrigin: origin,
        filter,
      }}
    />
  </AbsoluteFill>
);

export const Glow: React.FC<{ x?: string; y?: string; r?: number; color?: string; o?: number }> = ({
  x = "50%",
  y = "50%",
  r = 55,
  color = "255,140,30",
  o = 0.75,
}) => (
  <AbsoluteFill
    style={{
      background: `radial-gradient(circle at ${x} ${y}, rgba(${color},${o}) 0%, rgba(${color},${o * 0.45}) ${r * 0.45}%, rgba(${color},0) ${r}%)`,
      mixBlendMode: "screen",
    }}
  />
);

export const Vignette: React.FC<{ o?: number; inner?: number }> = ({ o = 0.7, inner = 45 }) => (
  <AbsoluteFill style={{ background: `radial-gradient(ellipse at 50% 50%, rgba(26,18,16,0) ${inner}%, rgba(26,18,16,${o}) 100%)` }} />
);

/* --------------------------------------------------------------- embers */

export const Embers: React.FC<{ w: number; h: number; n?: number; seed?: number; t?: number; size?: number }> = ({
  w,
  h,
  n = 40,
  seed = 3,
  t = 0,
  size = 1,
}) => (
  <svg width={w} height={h} style={{ position: "absolute", left: 0, top: 0, overflow: "visible" }}>
    {Array.from({ length: n }, (_, i) => {
      const r1 = rand(seed * 7 + i);
      const r2 = rand(seed * 11 + i * 5);
      const r3 = rand(seed * 17 + i * 3);
      const rise = (t * (1.5 + r3 * 2.5) + r2 * h) % h;
      const cx = r1 * w + Math.sin(t * 0.08 + i) * 14;
      const cy = h - rise;
      const rr = (2 + r3 * 5) * size;
      return <circle key={i} cx={cx} cy={cy} r={rr} fill={r2 > 0.5 ? C.fireCore : C.fireBody} opacity={0.55 + r1 * 0.45} />;
    })}
  </svg>
);

/* ---------------------------------------------------------------- smoke */

export const Smoke: React.FC<{ w: number; h: number; seed?: number; t?: number; color?: string; o?: number; style?: React.CSSProperties }> = ({
  w,
  h,
  seed = 5,
  t = 0,
  color = "#3A302C",
  o = 0.85,
  style,
}) => (
  <svg width={w} height={h} viewBox={`0 0 ${w} ${h}`} style={{ overflow: "visible", ...style }}>
    <g opacity={o}>
      {Array.from({ length: 9 }, (_, i) => {
        const r1 = rand(seed + i * 3);
        const r2 = rand(seed * 2 + i * 7);
        const cx = w * (0.1 + 0.8 * r1) + Math.sin(t * 0.05 + i) * 10;
        const cy = h * (0.25 + 0.6 * r2) - t * 0.6;
        const rr = Math.min(w, h) * (0.18 + 0.16 * r2);
        return <circle key={i} cx={cx} cy={cy} r={rr} fill={color} stroke={C.ink} strokeWidth={6} />;
      })}
      {Array.from({ length: 9 }, (_, i) => {
        const r1 = rand(seed + i * 3);
        const r2 = rand(seed * 2 + i * 7);
        const cx = w * (0.1 + 0.8 * r1) + Math.sin(t * 0.05 + i) * 10;
        const cy = h * (0.25 + 0.6 * r2) - t * 0.6;
        const rr = Math.min(w, h) * (0.18 + 0.16 * r2);
        return <circle key={`f${i}`} cx={cx} cy={cy} r={rr - 3} fill={color} />;
      })}
    </g>
  </svg>
);

/* --------------------------------------------------------- expressive face */

export type Mood = "brave" | "panic" | "smug" | "shock";

// PenguinFace plus brows / open beak / sweat, in the same 400x420 box.
export const Face: React.FC<{
  size: number;
  mood?: Mood;
  number?: string;
  look?: [number, number, number, number];
  style?: React.CSSProperties;
  soot?: boolean;
}> = ({ size, mood = "brave", number = "67", look, style, soot }) => {
  const ink = C.ink;
  const defaultLook: Record<Mood, [number, number, number, number]> = {
    brave: [16, 4, 14, 4],
    panic: [0, -6, 0, -6],
    smug: [-14, 6, -16, 6],
    shock: [0, 0, 0, 0],
  };
  const lk = look ?? defaultLook[mood];
  return (
    <div style={{ position: "relative", width: size, height: (size * 420) / 400, ...style }}>
      <PenguinFace size={size} number={number} look={lk} soot={soot} style={{ position: "absolute", left: 0, top: 0 }} />
      <svg width={size} height={(size * 420) / 400} viewBox="0 0 400 420" style={{ position: "absolute", left: 0, top: 0, overflow: "visible" }}>
        {mood === "brave" && (
          <g stroke={ink} strokeWidth={20} strokeLinecap="round" fill="none">
            <path d="M 92 176 L 186 204" />
            <path d="M 312 168 L 222 200" />
          </g>
        )}
        {mood === "smug" && (
          <g>
            <path d="M 86 196 L 200 196 L 200 238 L 86 238 Z" fill={C.penguin} />
            <path d="M 84 200 Q 146 186 206 202" stroke={ink} strokeWidth={14} fill="none" strokeLinecap="round" />
            <path d="M 196 190 L 324 190 L 324 230 L 196 230 Z" fill={C.penguin} />
            <path d="M 194 196 Q 258 180 326 196" stroke={ink} strokeWidth={14} fill="none" strokeLinecap="round" />
          </g>
        )}
        {(mood === "panic" || mood === "shock") && (
          <g>
            <path d="M 100 150 Q 146 118 190 150" stroke={ink} strokeWidth={16} fill="none" strokeLinecap="round" />
            <path d="M 214 144 Q 260 108 312 142" stroke={ink} strokeWidth={16} fill="none" strokeLinecap="round" />
            {/* open beak */}
            <ellipse cx={204} cy={318} rx={70} ry={34} fill={C.beak} stroke={ink} strokeWidth={9} />
            <path d="M 150 322 Q 204 412 258 322 Z" fill="#7A1F10" stroke={ink} strokeWidth={9} strokeLinejoin="round" />
            <ellipse cx={204} cy={372} rx={22} ry={12} fill="#FF7A8A" />
            <ellipse cx={204} cy={304} rx={70} ry={26} fill={C.beak} stroke={ink} strokeWidth={9} />
            <ellipse cx={186} cy={296} rx={22} ry={7} fill="#FFD27A" opacity={0.8} />
            {mood === "panic" && (
              <path d="M 352 150 Q 376 196 352 214 Q 328 196 352 150 Z" fill={C.water} stroke={ink} strokeWidth={8} strokeLinejoin="round" />
            )}
          </g>
        )}
      </svg>
    </div>
  );
};

/* ------------------------------------------------------------- water jet */

// Thick cartoon water jet from (x0,y0) to (x1,y1), slight arc, foamy splash at the end. Absolute coords.
export const Jet: React.FC<{ x0: number; y0: number; x1: number; y1: number; w?: number; bend?: number; t?: number; splash?: number }> = ({
  x0,
  y0,
  x1,
  y1,
  w = 40,
  bend = -0.18,
  t = 0,
  splash = 1,
}) => {
  const mx = (x0 + x1) / 2 + (y1 - y0) * bend;
  const my = (y0 + y1) / 2 - (x1 - x0) * bend;
  const d = `M ${x0} ${y0} Q ${mx} ${my} ${x1} ${y1}`;
  const drops = Array.from({ length: 9 }, (_, i) => {
    const a = (i / 9) * Math.PI * 2 + rand(i + 3);
    const rr = w * (0.9 + rand(i * 5) * 0.9) * splash;
    return { x: x1 + Math.cos(a) * rr, y: y1 + Math.sin(a) * rr * 0.8, r: w * (0.18 + rand(i * 9) * 0.22) * splash };
  });
  return (
    <svg style={{ position: "absolute", left: 0, top: 0, overflow: "visible" }} width={1} height={1}>
      <path d={d} fill="none" stroke={C.ink} strokeWidth={w + 14} strokeLinecap="round" />
      <path d={d} fill="none" stroke={C.water} strokeWidth={w} strokeLinecap="round" />
      <path d={d} fill="none" stroke="#fff" strokeWidth={w * 0.28} strokeLinecap="round" strokeDasharray={`${w * 1.6} ${w * 1.1}`} strokeDashoffset={-t * w * 0.4} />
      <circle cx={x1} cy={y1} r={w * 1.05 * splash} fill="#fff" stroke={C.ink} strokeWidth={8} />
      <circle cx={x1} cy={y1} r={w * 0.7 * splash} fill={C.water} />
      {drops.map((p, i) => (
        <circle key={i} cx={p.x} cy={p.y} r={p.r} fill={i % 2 ? "#fff" : C.water} stroke={C.ink} strokeWidth={5} />
      ))}
    </svg>
  );
};

/* -------------------------------------------------------- penguin body */

// Body + flippers + yellow hose + brass nozzle (viewBox 400x380); head goes on top (Face).
// The nozzle tip is at (372, 70) in body coords, pointing up-right.
export const HoseBody: React.FC<{ size: number; style?: React.CSSProperties; carry?: boolean }> = ({ size, style, carry = false }) => {
  const ink = C.ink;
  return (
    <svg width={size} height={(size * 380) / 400} viewBox="0 0 400 380" style={{ overflow: "visible", ...style }}>
      {/* air tank behind */}
      <rect x={20} y={70} width={70} height={200} rx={30} fill="#C9CCD0" stroke={ink} strokeWidth={10} />
      <rect x={34} y={84} width={16} height={150} rx={8} fill="#fff" opacity={0.5} />
      {/* body */}
      <path d="M 70 40 Q 200 -10 330 40 Q 380 220 320 360 L 80 360 Q 20 220 70 40 Z" fill={C.penguin} stroke={ink} strokeWidth={12} strokeLinejoin="round" />
      <path d="M 130 70 Q 200 40 270 70 Q 300 220 270 350 L 130 350 Q 100 220 130 70 Z" fill="#fff" />
      {/* reflective stripes */}
      <path d="M 66 230 Q 200 262 336 230 L 334 268 Q 200 300 68 268 Z" fill={C.hose} stroke={ink} strokeWidth={9} strokeLinejoin="round" />
      <path d="M 72 244 Q 200 274 330 244" stroke="#fff" strokeWidth={6} fill="none" opacity={0.7} />
      {/* feet */}
      <ellipse cx={140} cy={366} rx={56} ry={20} fill={C.beak} stroke={ink} strokeWidth={10} />
      <ellipse cx={262} cy={366} rx={56} ry={20} fill={C.beak} stroke={ink} strokeWidth={10} />
      {!carry && (
        <>
          {/* hose from bottom-left to nozzle */}
          <path d="M -60 380 Q 60 300 190 220 Q 280 160 330 110" stroke={ink} strokeWidth={56} fill="none" strokeLinecap="round" />
          <path d="M -60 380 Q 60 300 190 220 Q 280 160 330 110" stroke={C.hose} strokeWidth={38} fill="none" strokeLinecap="round" />
          <path d="M -40 360 Q 70 290 190 214" stroke="#FFE38A" strokeWidth={8} fill="none" strokeLinecap="round" opacity={0.8} />
          {/* nozzle */}
          <g transform="rotate(-42 340 100)">
            <rect x={300} y={78} width={90} height={44} rx={10} fill="#D9A23A" stroke={ink} strokeWidth={10} />
            <rect x={380} y={70} width={26} height={60} rx={8} fill={C.red} stroke={ink} strokeWidth={9} />
            <rect x={312} y={86} width={50} height={10} rx={5} fill="#FFE9A8" />
          </g>
          {/* flippers gripping the hose */}
          <path d="M 300 120 Q 250 210 180 236 Q 150 236 170 206 Q 230 170 268 104 Z" fill={C.penguin} stroke={ink} strokeWidth={11} strokeLinejoin="round" />
          <path d="M 100 150 Q 130 230 200 236 Q 228 230 206 206 Q 160 190 140 140 Z" fill={C.penguin} stroke={ink} strokeWidth={11} strokeLinejoin="round" />
        </>
      )}
    </svg>
  );
};

/* ----------------------------------------------------------------- cat */

export const Cat: React.FC<{ size: number; style?: React.CSSProperties }> = ({ size, style }) => {
  const ink = C.ink;
  const fur = "#F29A3A";
  return (
    <svg width={size} height={size} viewBox="0 0 300 300" style={{ overflow: "visible", ...style }}>
      {/* tail */}
      <path d="M 220 230 Q 300 200 270 120" stroke={ink} strokeWidth={40} fill="none" strokeLinecap="round" />
      <path d="M 220 230 Q 300 200 270 120" stroke={fur} strokeWidth={24} fill="none" strokeLinecap="round" />
      {/* body */}
      <ellipse cx={160} cy={220} rx={90} ry={66} fill={fur} stroke={ink} strokeWidth={10} />
      {/* ears */}
      <path d="M 70 90 L 80 10 L 140 60 Z" fill={fur} stroke={ink} strokeWidth={10} strokeLinejoin="round" />
      <path d="M 230 90 L 220 10 L 160 60 Z" fill={fur} stroke={ink} strokeWidth={10} strokeLinejoin="round" />
      <path d="M 88 70 L 92 34 L 120 58 Z" fill="#FF9FB0" />
      <path d="M 212 70 L 208 34 L 180 58 Z" fill="#FF9FB0" />
      {/* head */}
      <ellipse cx={150} cy={110} rx={98} ry={80} fill={fur} stroke={ink} strokeWidth={10} />
      <path d="M 120 40 L 130 70 M 150 34 L 150 66 M 180 40 L 170 70" stroke="#C86A1A" strokeWidth={10} strokeLinecap="round" />
      {/* eyes (huge, scared) */}
      <circle cx={112} cy={106} r={30} fill="#fff" stroke={ink} strokeWidth={8} />
      <circle cx={190} cy={106} r={30} fill="#fff" stroke={ink} strokeWidth={8} />
      <circle cx={112} cy={110} r={11} fill={ink} />
      <circle cx={190} cy={110} r={11} fill={ink} />
      {/* mouth */}
      <path d="M 136 148 Q 151 136 166 148 Q 151 176 136 148 Z" fill="#7A1F10" stroke={ink} strokeWidth={6} />
      <path d="M 144 132 L 158 132 L 151 140 Z" fill="#FF7A8A" stroke={ink} strokeWidth={4} />
      <path d="M 60 130 L 100 136 M 60 150 L 100 146 M 240 130 L 200 136 M 240 150 L 200 146" stroke={ink} strokeWidth={5} strokeLinecap="round" />
      {/* paws */}
      <ellipse cx={110} cy={278} rx={26} ry={16} fill={fur} stroke={ink} strokeWidth={8} />
      <ellipse cx={200} cy={278} rx={26} ry={16} fill={fur} stroke={ink} strokeWidth={8} />
    </svg>
  );
};

/* ---------------------------------------------------------- fire truck */

// Side-view cartoon engine facing right. viewBox 900x420. lights: 0..1 flash phase.
export const Truck: React.FC<{ width: number; style?: React.CSSProperties; flash?: number; number?: string }> = ({
  width,
  style,
  flash = 0,
  number = "67",
}) => {
  const ink = C.ink;
  const on = flash % 1 < 0.5;
  return (
    <svg width={width} height={(width * 420) / 900} viewBox="0 0 900 420" style={{ overflow: "visible", ...style }}>
      {/* light glow */}
      <ellipse cx={671} cy={96} rx={110} ry={46} fill={on ? "rgba(255,70,70,0.5)" : "rgba(90,140,255,0.5)"} />
      {/* ladder */}
      <g stroke={ink} strokeWidth={10}>
        <rect x={60} y={86} width={520} height={34} rx={8} fill="#C9CCD0" />
        {Array.from({ length: 10 }, (_, i) => (
          <line key={i} x1={90 + i * 50} y1={86} x2={90 + i * 50} y2={120} />
        ))}
      </g>
      {/* body */}
      <path d="M 30 130 L 600 130 L 600 330 L 30 330 Q 14 330 14 314 L 14 146 Q 14 130 30 130 Z" fill={C.red} stroke={ink} strokeWidth={12} strokeLinejoin="round" />
      {/* cab */}
      <path d="M 590 110 L 760 110 Q 790 110 806 140 L 860 240 Q 872 260 872 280 L 872 330 L 590 330 Z" fill={C.red} stroke={ink} strokeWidth={12} strokeLinejoin="round" />
      <path d="M 640 136 L 750 136 Q 766 136 774 150 L 818 236 L 640 236 Z" fill={C.water} stroke={ink} strokeWidth={10} strokeLinejoin="round" />
      <path d="M 660 150 L 700 150 L 680 220 L 650 220 Z" fill="#fff" opacity={0.6} />
      {/* compartments */}
      {[40, 180, 320, 460].map((x) => (
        <rect key={x} x={x} y={156} width={120} height={110} rx={10} fill={C.redDark} stroke={ink} strokeWidth={8} />
      ))}
      {/* stripe */}
      <rect x={14} y={276} width={858} height={26} fill={C.cream} stroke={ink} strokeWidth={8} />
      {/* number shield */}
      <path d="M 690 246 L 770 246 L 770 280 Q 770 306 730 316 Q 690 306 690 280 Z" fill={C.shield} stroke={ink} strokeWidth={8} />
      <text x={730} y={292} textAnchor="middle" fontFamily="Luckiest Guy" fontSize={40} fill={ink}>
        {number}
      </text>
      {/* lights bar */}
      <rect x={606} y={84} width={130} height={30} rx={12} fill={on ? "#FF4040" : "#5A8CFF"} stroke={ink} strokeWidth={9} />
      <rect x={606} y={84} width={65} height={30} rx={12} fill={on ? "#5A8CFF" : "#FF4040"} stroke={ink} strokeWidth={9} />
      {/* headlight + bumper */}
      <circle cx={858} cy={262} r={16} fill={C.fireCore} stroke={ink} strokeWidth={7} />
      <rect x={820} y={316} width={70} height={28} rx={8} fill="#C9CCD0" stroke={ink} strokeWidth={8} />
      {/* wheels */}
      {[150, 450, 740].map((x) => (
        <g key={x}>
          <circle cx={x} cy={338} r={66} fill={C.ink} />
          <circle cx={x} cy={338} r={34} fill="#C9CCD0" stroke={ink} strokeWidth={8} />
          <circle cx={x} cy={338} r={10} fill={ink} />
        </g>
      ))}
    </svg>
  );
};

/* -------------------------------------------------------- chief helmet */

export const ChiefHelmet: React.FC<{ size: number; style?: React.CSSProperties }> = ({ size, style }) => {
  const ink = C.ink;
  return (
    <svg width={size} height={(size * 360) / 500} viewBox="0 0 500 360" style={{ overflow: "visible", ...style }}>
      <defs>
        <linearGradient id="chiefgold" x1="0" y1="0" x2="1" y2="1">
          <stop offset="0" stopColor="#FFF0A0" />
          <stop offset="0.5" stopColor={C.gold} />
          <stop offset="1" stopColor={C.goldDark} />
        </linearGradient>
      </defs>
      <ellipse cx={250} cy={290} rx={240} ry={56} fill="#F2F2F2" stroke={ink} strokeWidth={14} />
      <path d="M 70 290 C 70 40, 430 40, 430 290 Z" fill="#F7F7F7" stroke={ink} strokeWidth={14} strokeLinejoin="round" />
      <path d="M 250 50 C 244 120, 244 200, 250 284" stroke="#D0D0D0" strokeWidth={18} fill="none" strokeLinecap="round" />
      <ellipse cx={150} cy={130} rx={44} ry={18} fill="#fff" transform="rotate(-36 150 130)" />
      {/* gold eagle-ish crest */}
      <path d="M 250 20 Q 290 40 286 80 L 250 96 L 214 80 Q 210 40 250 20 Z" fill="url(#chiefgold)" stroke={ink} strokeWidth={10} strokeLinejoin="round" />
      {/* badge */}
      <path d="M 180 110 L 320 110 L 320 180 Q 320 236 250 256 Q 180 236 180 180 Z" fill="url(#chiefgold)" stroke={ink} strokeWidth={12} strokeLinejoin="round" />
      <text x={250} y={210} textAnchor="middle" fontFamily="Luckiest Guy" fontSize={52} fill={C.red}>
        CHIEF
      </text>
    </svg>
  );
};

/* -------------------------------------------------------- burning house */

// Cartoon house on fire: glowing windows with flames licking out. viewBox 400x380, base at y=380.
export const House: React.FC<{ width: number; style?: React.CSSProperties; wall?: string; roof?: string }> = ({
  width,
  style,
  wall = "#E9C9A0",
  roof = "#6E3B2A",
}) => {
  const ink = C.ink;
  const win = (x: number, y: number, w: number, h: number, k: number) => (
    <g key={`${x}-${y}`}>
      <rect x={x} y={y} width={w} height={h} rx={6} fill={C.fireCore} stroke={ink} strokeWidth={9} />
      <rect x={x + 8} y={y + h * 0.4} width={w - 16} height={h * 0.6 - 8} rx={4} fill={C.fireBody} />
      <line x1={x + w / 2} y1={y} x2={x + w / 2} y2={y + h} stroke={ink} strokeWidth={6} />
      <path
        d={`M ${x - 4} ${y + 6} Q ${x + w * 0.1} ${y - h * 0.9 * k} ${x + w * 0.35} ${y - h * 0.15} Q ${x + w * 0.55} ${y - h * 1.4 * k} ${x + w * 0.75} ${y - h * 0.1} Q ${x + w * 1.05} ${y - h * 0.7 * k} ${x + w + 4} ${y + 6} Z`}
        fill={C.fireBody}
        stroke={ink}
        strokeWidth={7}
        strokeLinejoin="round"
      />
      <path
        d={`M ${x + w * 0.2} ${y + 4} Q ${x + w * 0.35} ${y - h * 0.6 * k} ${x + w * 0.55} ${y - h * 0.05} Q ${x + w * 0.7} ${y - h * 0.5 * k} ${x + w * 0.85} ${y + 4} Z`}
        fill={C.fireCore}
      />
    </g>
  );
  return (
    <svg width={width} height={(width * 380) / 400} viewBox="0 0 400 380" style={{ overflow: "visible", ...style }}>
      <rect x={40} y={150} width={320} height={230} fill={wall} stroke={ink} strokeWidth={12} strokeLinejoin="round" />
      <path d="M 46 156 L 354 156 L 354 196 Q 200 226 46 196 Z" fill={ink} opacity={0.25} />
      <rect x={280} y={50} width={44} height={80} fill="#9A4A34" stroke={ink} strokeWidth={10} />
      <path d="M 10 160 L 200 30 L 390 160 Z" fill={roof} stroke={ink} strokeWidth={12} strokeLinejoin="round" />
      <path d="M 120 110 L 200 56 L 230 76" stroke="#fff" strokeWidth={8} fill="none" opacity={0.25} strokeLinecap="round" />
      {win(80, 220, 90, 70, 1)}
      {win(232, 220, 90, 70, 1.2)}
      <rect x={168} y={300} width={64} height={80} rx={6} fill={C.redDark} stroke={ink} strokeWidth={9} />
      <circle cx={218} cy={342} r={6} fill={C.gold} />
    </svg>
  );
};
