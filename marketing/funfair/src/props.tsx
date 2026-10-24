// Cartoon props drawn from the park's own rides and costumes.
import React, { useId } from "react";
import { Bulbs, Firework, ringOf } from "./art";
import { C } from "./theme";

const useSvgId = () => useId().replace(/:/g, "");
const N = C.navy;

/* ---------------------------------------------------------------- big top */

// Striped circus tent (`a` stripes on cream), viewBox 400 x 320 (the flag pokes above the box).
export const BigTop: React.FC<{ width: number; a?: string; flag?: boolean; style?: React.CSSProperties }> = ({
  width,
  a = C.red,
  flag = true,
  style,
}) => {
  const id = useSvgId();
  const b = C.cream;
  const ex0 = 12;
  const ex1 = 388;
  const ey = 150;
  const roof = `M 200 24 Q 146 96 ${ex0} ${ey} L ${ex1} ${ey} Q 254 96 200 24 Z`;
  const wedges = 12;
  const wallStripes = 10;
  const scallops = 12;
  const sw = (ex1 - ex0) / scallops;
  const hem = (i: number) => {
    const x = ex0 + i * sw;
    return `M ${x} ${ey - 2} H ${x + sw} V ${ey + 12} A ${sw / 2} ${sw * 0.42} 0 0 1 ${x} ${ey + 12} Z`;
  };
  return (
    <svg width={width} height={(width * 320) / 400} viewBox="0 0 400 320" style={{ overflow: "visible", ...style }}>
      <defs>
        <clipPath id={`${id}roof`}>
          <path d={roof} />
        </clipPath>
        <clipPath id={`${id}wall`}>
          <rect x={40} y={140} width={320} height={166} />
        </clipPath>
        <linearGradient id={`${id}round`} x1="0" y1="0" x2="1" y2="0">
          <stop offset="0" stopColor="#000" stopOpacity={0.22} />
          <stop offset="0.4" stopColor="#fff" stopOpacity={0.1} />
          <stop offset="1" stopColor="#000" stopOpacity={0.26} />
        </linearGradient>
      </defs>
      {flag && (
        <>
          <line x1={200} y1={30} x2={200} y2={-40} stroke={N} strokeWidth={8} strokeLinecap="round" />
          <path d="M 204 -40 Q 236 -36 258 -22 Q 236 -12 204 -8 Z" fill={C.gold} stroke={N} strokeWidth={6} strokeLinejoin="round" />
        </>
      )}
      <rect x={40} y={140} width={320} height={166} fill={b} />
      <g clipPath={`url(#${id}wall)`}>
        {Array.from({ length: wallStripes }, (_, i) =>
          i % 2 === 0 ? <rect key={i} x={40 + (i * 320) / wallStripes} y={140} width={320 / wallStripes} height={166} fill={a} /> : null,
        )}
        <rect x={40} y={140} width={320} height={166} fill={`url(#${id}round)`} />
      </g>
      <path d="M 166 306 V 246 Q 200 200 234 246 V 306 Z" fill={N} />
      <path d="M 166 306 V 246 Q 178 226 196 216 Q 186 262 192 306 Z" fill={C.gold} stroke={N} strokeWidth={5} strokeLinejoin="round" />
      <path d="M 234 306 V 246 Q 222 226 204 216 Q 214 262 208 306 Z" fill={C.gold} stroke={N} strokeWidth={5} strokeLinejoin="round" />
      <rect x={40} y={140} width={320} height={166} fill="none" stroke={N} strokeWidth={10} />
      <path d={roof} fill={b} />
      <g clipPath={`url(#${id}roof)`}>
        {Array.from({ length: wedges }, (_, i) => {
          if (i % 2 === 1) return null;
          const x0 = ex0 + ((ex1 - ex0) * i) / wedges;
          const x1 = ex0 + ((ex1 - ex0) * (i + 1)) / wedges;
          return <path key={i} d={`M 200 20 L ${x0} ${ey + 6} L ${x1} ${ey + 6} Z`} fill={a} />;
        })}
        <path d={roof} fill={`url(#${id}round)`} />
      </g>
      <path d={roof} fill="none" stroke={N} strokeWidth={10} strokeLinejoin="round" />
      <g fill={N} stroke={N} strokeWidth={9} strokeLinejoin="round">
        {Array.from({ length: scallops }, (_, i) => (
          <path key={i} d={hem(i)} />
        ))}
      </g>
      {Array.from({ length: scallops }, (_, i) => (
        <path key={i} d={hem(i)} fill={i % 2 === 0 ? b : a} />
      ))}
      {Array.from({ length: scallops + 1 }, (_, i) => (
        <circle key={i} cx={ex0 + i * sw} cy={ey + 2} r={7.5} fill={C.gold} stroke={N} strokeWidth={4} />
      ))}
      <circle cx={200} cy={26} r={10} fill={C.gold} stroke={N} strokeWidth={5} />
    </svg>
  );
};

/* ----------------------------------------------------------- ferris wheel */

const CABINS = [C.red, C.gold, C.blue, C.pink, C.cyan, C.purple, C.orange, C.red, C.gold, C.pink];

// Ferris wheel, viewBox 400 x 440. `angle` (radians) turns the wheel; cabins hang level.
export const FerrisWheel: React.FC<{ size: number; angle?: number; t?: number; cabins?: number; bulbs?: boolean; style?: React.CSSProperties }> = ({
  size,
  angle = 0,
  t = 0,
  cabins = 10,
  bulbs = true,
  style,
}) => {
  const cx = 200;
  const cy = 200;
  const R = 166;
  const spokes = ringOf(cx, cy, R, cabins, angle);
  return (
    <svg width={size} height={(size * 440) / 400} viewBox="0 0 400 440" style={{ overflow: "visible", ...style }}>
      <g strokeLinecap="round">
        <path d={`M ${cx} ${cy} L 96 432 M ${cx} ${cy} L 304 432`} stroke={N} strokeWidth={26} />
        <path d={`M ${cx} ${cy} L 96 432 M ${cx} ${cy} L 304 432`} stroke={C.white} strokeWidth={12} />
        <path d="M 130 356 H 270" stroke={N} strokeWidth={16} />
        <path d="M 130 356 H 270" stroke={C.white} strokeWidth={6} />
      </g>
      <circle cx={cx} cy={cy} r={R} fill="none" stroke={N} strokeWidth={24} />
      <circle cx={cx} cy={cy} r={R} fill="none" stroke={C.white} strokeWidth={11} />
      <circle cx={cx} cy={cy} r={R * 0.64} fill="none" stroke={N} strokeWidth={13} />
      <circle cx={cx} cy={cy} r={R * 0.64} fill="none" stroke={C.pink} strokeWidth={5} />
      {spokes.map(([x, y], i) => (
        <line key={i} x1={cx} y1={cy} x2={x} y2={y} stroke={N} strokeWidth={6} />
      ))}
      {bulbs && <Bulbs pts={ringOf(cx, cy, R, cabins * 3, angle + Math.PI / (cabins * 3))} r={5.5} t={t} />}
      <circle cx={cx} cy={cy} r={26} fill={C.gold} stroke={N} strokeWidth={8} />
      <circle cx={cx} cy={cy} r={9} fill={C.red} stroke={N} strokeWidth={4} />
      {spokes.map(([x, y], i) => (
        <g key={i}>
          <line x1={x} y1={y} x2={x} y2={y + 16} stroke={N} strokeWidth={6} strokeLinecap="round" />
          <path d={`M ${x - 26} ${y + 20} Q ${x} ${y - 2} ${x + 26} ${y + 20} Z`} fill={CABINS[i % CABINS.length]} stroke={N} strokeWidth={6} strokeLinejoin="round" />
          <path
            d={`M ${x - 22} ${y + 18} H ${x + 22} V ${y + 34} Q ${x + 22} ${y + 54} ${x} ${y + 54} Q ${x - 22} ${y + 54} ${x - 22} ${y + 34} Z`}
            fill={CABINS[i % CABINS.length]}
            stroke={N}
            strokeWidth={6}
            strokeLinejoin="round"
          />
          <rect x={x - 14} y={y + 24} width={28} height={10} rx={4} fill={C.cream} stroke={N} strokeWidth={3} />
        </g>
      ))}
    </svg>
  );
};

/* ------------------------------------------------------------ ride tokens */

export type Ride = "bigtop" | "carousel" | "bumper" | "teacup" | "ferris" | "fireworks";
export const RIDES: Ride[] = ["bigtop", "carousel", "bumper", "teacup", "ferris", "fireworks"];

const Carousel: React.FC<{ size: number }> = ({ size }) => (
  <svg width={size} height={size} viewBox="0 0 100 100" style={{ overflow: "visible" }}>
    <line x1={50} y1={10} x2={50} y2={2} stroke={N} strokeWidth={3} />
    <path d="M 51 2 L 62 5 L 51 9 Z" fill={C.gold} stroke={N} strokeWidth={2} strokeLinejoin="round" />
    {[26, 50, 74].map((x) => (
      <line key={x} x1={x} y1={40} x2={x} y2={80} stroke={C.gold} strokeWidth={4} />
    ))}
    {[
      [26, 62],
      [50, 56],
      [74, 64],
    ].map(([x, y], i) => (
      <ellipse key={i} cx={x} cy={y} rx={10} ry={6} fill={[C.cream, C.cyan, C.purple][i]} stroke={N} strokeWidth={3} />
    ))}
    <path d="M 50 10 Q 32 26 10 38 H 90 Q 68 26 50 10 Z" fill={C.cream} stroke={N} strokeWidth={4} strokeLinejoin="round" />
    <path d="M 50 11 Q 40 26 30 38 H 42 Z M 50 11 L 58 38 H 70 Q 58 26 50 11 Z" fill={C.pink} />
    <path d="M 50 10 Q 32 26 10 38 H 90 Q 68 26 50 10 Z" fill="none" stroke={N} strokeWidth={4} strokeLinejoin="round" />
    <path d="M 10 38 H 90 V 42 Q 85 48 80 42 Q 75 48 70 42 Q 65 48 60 42 Q 55 48 50 42 Q 45 48 40 42 Q 35 48 30 42 Q 25 48 20 42 Q 15 48 10 42 Z" fill={C.pink} stroke={N} strokeWidth={3} strokeLinejoin="round" />
    <ellipse cx={50} cy={82} rx={42} ry={9} fill={C.pink} stroke={N} strokeWidth={4} />
    <ellipse cx={50} cy={80} rx={34} ry={5} fill={C.cream} opacity={0.6} />
  </svg>
);

const Bumper: React.FC<{ size: number }> = ({ size }) => (
  <svg width={size} height={size} viewBox="0 0 100 100" style={{ overflow: "visible" }}>
    <line x1={50} y1={44} x2={50} y2={14} stroke={N} strokeWidth={4} />
    <path d="M 44 16 L 54 4 L 52 12 L 60 10 L 48 24 L 50 16 Z" fill={C.gold} stroke={N} strokeWidth={2.5} strokeLinejoin="round" />
    <path d="M 14 66 Q 14 46 34 46 H 66 Q 86 46 86 66 V 72 H 14 Z" fill={C.blue} stroke={N} strokeWidth={4} strokeLinejoin="round" />
    <rect x={38} y={36} width={24} height={14} rx={5} fill={C.red} stroke={N} strokeWidth={3} />
    <rect x={8} y={66} width={84} height={16} rx={8} fill={N} />
    <rect x={14} y={70} width={72} height={4} rx={2} fill="#fff" opacity={0.35} />
    <circle cx={24} cy={58} r={4.5} fill={C.gold} stroke={N} strokeWidth={2} />
    <circle cx={76} cy={58} r={4.5} fill={C.gold} stroke={N} strokeWidth={2} />
    <path d="M 30 50 Q 50 46 70 50" stroke="#fff" strokeWidth={3} fill="none" opacity={0.5} strokeLinecap="round" />
  </svg>
);

const Teacup: React.FC<{ size: number }> = ({ size }) => (
  <svg width={size} height={size} viewBox="0 0 100 100" style={{ overflow: "visible" }}>
    <ellipse cx={50} cy={82} rx={42} ry={10} fill={C.cream} stroke={N} strokeWidth={4} />
    <path d="M 78 46 Q 96 46 92 60 Q 88 70 74 66" fill="none" stroke={N} strokeWidth={10} strokeLinecap="round" />
    <path d="M 78 46 Q 96 46 92 60 Q 88 70 74 66" fill="none" stroke={C.pink} strokeWidth={4} strokeLinecap="round" />
    <path d="M 16 36 H 84 Q 82 76 50 80 Q 18 76 16 36 Z" fill={C.pink} stroke={N} strokeWidth={4} strokeLinejoin="round" />
    <ellipse cx={50} cy={36} rx={34} ry={8} fill="#D6418A" stroke={N} strokeWidth={4} />
    {[
      [32, 52],
      [50, 60],
      [68, 52],
      [42, 70],
      [60, 70],
    ].map(([x, y], i) => (
      <circle key={i} cx={x} cy={y} r={4} fill="#fff" />
    ))}
  </svg>
);

const Burst: React.FC<{ size: number }> = ({ size }) => (
  <svg width={size} height={size} viewBox="0 0 100 100" style={{ overflow: "visible" }}>
    <Firework cx={50} cy={50} r={40} color={C.gold} color2={C.pink} p={0.8} rays={10} />
  </svg>
);

const TOKEN_BG: Record<Ride, string> = {
  bigtop: C.cyan,
  carousel: C.purple,
  bumper: C.orange,
  teacup: C.gold,
  ferris: C.pink,
  fireworks: C.navy,
};

export const RideToken: React.FC<{ ride: Ride; size: number; rotate?: number }> = ({ ride, size, rotate = 0 }) => {
  const art = size * 0.72;
  return (
    <div
      style={{
        width: size,
        height: size,
        borderRadius: "50%",
        background: TOKEN_BG[ride],
        border: `${size * 0.06}px solid ${N}`,
        boxShadow: `inset 0 0 0 ${size * 0.045}px rgba(255,255,255,0.55), 0 ${size * 0.07}px 0 ${N}`,
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        transform: `rotate(${rotate}deg)`,
        overflow: "visible",
      }}
    >
      {ride === "bigtop" && <BigTop width={art} style={{ marginTop: size * 0.1 }} />}
      {ride === "carousel" && <Carousel size={art} />}
      {ride === "bumper" && <Bumper size={art} />}
      {ride === "teacup" && <Teacup size={art} />}
      {ride === "ferris" && <FerrisWheel size={art * 0.86} bulbs={false} cabins={8} style={{ marginTop: size * 0.05 }} />}
      {ride === "fireworks" && <Burst size={art} />}
    </div>
  );
};

/* --------------------------------------------------------------- costumes */

export type Costume = "topHat" | "crown" | "partyCone" | "mouseEars" | "clownWig" | "starCape";

const TopHat = () => (
  <>
    <ellipse cx={100} cy={158} rx={84} ry={20} fill={N} stroke={N} strokeWidth={8} />
    <path d="M 52 40 Q 100 26 148 40 L 140 152 Q 100 164 60 152 Z" fill={N} />
    <path d="M 56 112 Q 100 124 144 112 L 141 140 Q 100 152 59 140 Z" fill={C.red} />
    <path d="M 64 48 Q 70 90 70 104" stroke="#fff" strokeWidth={9} strokeLinecap="round" opacity={0.3} fill="none" />
    <ellipse cx={100} cy={40} rx={48} ry={11} fill="#2E4A75" />
  </>
);

const Crown = () => (
  <>
    <path d="M 28 156 L 18 62 L 64 104 L 100 36 L 136 104 L 182 62 L 172 156 Z" fill={C.gold} stroke={N} strokeWidth={9} strokeLinejoin="round" />
    <rect x={26} y={128} width={148} height={30} rx={8} fill="#F0A21E" stroke={N} strokeWidth={8} />
    {[
      [58, C.red],
      [100, C.blue],
      [142, C.pink],
    ].map(([x, col]) => (
      <circle key={x as number} cx={x as number} cy={143} r={10} fill={col as string} stroke={N} strokeWidth={4} />
    ))}
    {[
      [18, 62],
      [100, 36],
      [182, 62],
    ].map(([x, y]) => (
      <circle key={x} cx={x} cy={y} r={10} fill={C.cream} stroke={N} strokeWidth={5} />
    ))}
    <path d="M 44 120 L 40 84" stroke="#fff" strokeWidth={7} strokeLinecap="round" opacity={0.55} />
  </>
);

const PartyCone = () => {
  const id = useSvgId();
  const cone = "M 100 22 L 152 168 Q 100 186 48 168 Z";
  return (
    <>
      <defs>
        <clipPath id={`${id}c`}>
          <path d={cone} />
        </clipPath>
      </defs>
      <path d={cone} fill={C.gold} />
      <g clipPath={`url(#${id}c)`}>
        {[0, 1, 2, 3].map((i) => (
          <path key={i} d={`M 20 ${70 + i * 40} L 180 ${40 + i * 40} L 180 ${56 + i * 40} L 20 ${86 + i * 40} Z`} fill={C.pink} />
        ))}
        {[
          [92, 66],
          [110, 108],
          [80, 140],
          [128, 150],
        ].map(([x, y], i) => (
          <circle key={i} cx={x} cy={y} r={6} fill={C.cyan} />
        ))}
      </g>
      <path d={cone} fill="none" stroke={N} strokeWidth={9} strokeLinejoin="round" />
      <circle cx={100} cy={22} r={18} fill={C.cyan} stroke={N} strokeWidth={8} />
      <circle cx={94} cy={16} r={5} fill="#fff" opacity={0.8} />
    </>
  );
};

// Cap-and-ears silhouette with the red band the in-game ears have. A bare headband with two
// circles read as headphones or a face at sticker size.
const MouseEars = () => (
  <>
    <circle cx={44} cy={86} r={44} fill={N} />
    <circle cx={156} cy={86} r={44} fill={N} />
    <path d="M 34 182 Q 30 96 100 92 Q 170 96 166 182 Z" fill={N} />
    <path d="M 33 158 Q 100 146 167 158 L 166 182 H 34 Z" fill={C.red} />
    <circle cx={30} cy={70} r={12} fill="#fff" opacity={0.3} />
    <circle cx={142} cy={70} r={12} fill="#fff" opacity={0.3} />
    <path d="M 64 120 Q 76 106 94 104" stroke="#fff" strokeWidth={8} strokeLinecap="round" fill="none" opacity={0.25} />
  </>
);

const ClownWig = () => {
  const puffs: [number, number, number, string][] = [
    [40, 120, 34, C.orange],
    [62, 76, 34, C.red],
    [100, 58, 36, C.gold],
    [138, 76, 34, C.pink],
    [160, 120, 34, C.purple],
    [100, 112, 40, C.cyan],
  ];
  return (
    <>
      {puffs.map(([x, y, r], i) => (
        <circle key={`o${i}`} cx={x} cy={y} r={r + 5} fill={N} />
      ))}
      {puffs.map(([x, y, r, col], i) => (
        <g key={i}>
          <circle cx={x} cy={y} r={r} fill={col} />
          <circle cx={x - r * 0.35} cy={y - r * 0.35} r={r * 0.28} fill="#fff" opacity={0.45} />
        </g>
      ))}
    </>
  );
};

// Stand-up collar and a wavy hem, so it reads as a cape rather than a skirt.
const capePath =
  "M 72 40 Q 100 52 128 40 Q 150 100 184 172 Q 164 162 146 178 Q 124 164 100 180 Q 76 164 54 178 Q 36 162 16 172 Q 50 100 72 40 Z";

const StarCape = () => {
  const star = (cx: number, cy: number, r: number) =>
    Array.from({ length: 10 }, (_, i) => {
      const a = -Math.PI / 2 + (i * Math.PI) / 5;
      const rr = i % 2 === 0 ? r : r * 0.45;
      return `${i === 0 ? "M" : "L"} ${cx + Math.cos(a) * rr} ${cy + Math.sin(a) * rr}`;
    }).join(" ") + " Z";
  return (
    <>
      <path d="M 70 48 L 36 4 L 98 38 Z M 130 48 L 164 4 L 102 38 Z" fill="#7C55D6" stroke={N} strokeWidth={7} strokeLinejoin="round" />
      <path d={capePath} fill={C.purple} stroke={N} strokeWidth={9} strokeLinejoin="round" />
      <path d="M 86 52 Q 74 118 58 172 M 114 52 Q 126 118 142 172" stroke="#7C55D6" strokeWidth={7} fill="none" opacity={0.7} />
      {[
        [76, 96, 15],
        [122, 126, 18],
        [92, 150, 11],
        [126, 76, 11],
      ].map(([x, y, r], i) => (
        <path key={i} d={star(x, y, r)} fill={C.gold} stroke={N} strokeWidth={3.5} strokeLinejoin="round" />
      ))}
      <circle cx={100} cy={46} r={14} fill={C.gold} stroke={N} strokeWidth={6} />
    </>
  );
};

export const CostumeArt: React.FC<{ item: Costume; size: number }> = ({ item, size }) => (
  <svg width={size} height={size} viewBox="0 0 200 200" style={{ overflow: "visible" }}>
    {item === "topHat" && <TopHat />}
    {item === "crown" && <Crown />}
    {item === "partyCone" && <PartyCone />}
    {item === "mouseEars" && <MouseEars />}
    {item === "clownWig" && <ClownWig />}
    {item === "starCape" && <StarCape />}
  </svg>
);
