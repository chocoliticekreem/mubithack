import React from "react";
import { AbsoluteFill, Img, staticFile } from "remotion";
import { BODY, C, DISPLAY } from "./theme";

/* ------------------------------------------------------------------ text */

type Layer = { stroke: number; color: string };

// Chunky cartoon text: stacked stroked copies behind a clean fill, plus a hard ink drop shadow.
export const Outline: React.FC<{
  children: React.ReactNode;
  size: number;
  fill?: string;
  layers?: Layer[];
  shadow?: number;
  font?: string;
  style?: React.CSSProperties;
  lineHeight?: number;
  letterSpacing?: number;
}> = ({ children, size, fill = C.cream, layers, shadow = 0.09, font = DISPLAY, style, lineHeight = 0.95, letterSpacing = 0.01 }) => {
  const ls = layers ?? [{ stroke: size * 0.2, color: C.ink }];
  const base: React.CSSProperties = {
    fontFamily: font,
    fontSize: size,
    lineHeight,
    letterSpacing: `${letterSpacing}em`,
    whiteSpace: "pre",
    margin: 0,
  };
  const max = Math.max(...ls.map((l) => l.stroke));
  return (
    <div style={{ position: "relative", display: "inline-block", ...style }}>
      {/* drop shadow: thickest layer, offset down */}
      {shadow > 0 && (
        <div
          aria-hidden
          style={{
            ...base,
            position: "absolute",
            inset: 0,
            color: C.ink,
            WebkitTextStroke: `${max}px ${C.ink}`,
            transform: `translateY(${size * shadow}px)`,
          }}
        >
          {children}
        </div>
      )}
      {ls.map((l, i) => (
        <div
          key={i}
          aria-hidden
          style={{ ...base, position: "absolute", inset: 0, color: l.color, WebkitTextStroke: `${l.stroke}px ${l.color}` }}
        >
          {children}
        </div>
      ))}
      <div style={{ ...base, position: "relative", color: fill }}>{children}</div>
    </div>
  );
};

export const Sticker: React.FC<{
  children: React.ReactNode;
  bg: string;
  rotate?: number;
  pad?: string;
  border?: number;
  style?: React.CSSProperties;
}> = ({ children, bg, rotate = 0, pad = "10px 34px", border = 9, style }) => (
  <div
    style={{
      display: "inline-block",
      background: bg,
      border: `${border}px solid ${C.ink}`,
      borderRadius: 26,
      padding: pad,
      transform: `rotate(${rotate}deg)`,
      boxShadow: `0 ${border + 6}px 0 ${C.ink}`,
      ...style,
    }}
  >
    {children}
  </div>
);

export const Ribbon: React.FC<{ text: string; size?: number; bg?: string; color?: string; style?: React.CSSProperties }> = ({
  text,
  size = 54,
  bg = C.red,
  color = C.cream,
  style,
}) => (
  <div style={{ position: "relative", display: "inline-block", filter: `drop-shadow(0 8px 0 ${C.ink})`, ...style }}>
    <div
      style={{
        background: C.ink,
        clipPath: "polygon(0 0, 100% 0, 96% 50%, 100% 100%, 0 100%, 4% 50%)",
        padding: 7,
      }}
    >
      <div
        style={{
          background: bg,
          clipPath: "polygon(0 0, 100% 0, 96.4% 50%, 100% 100%, 0 100%, 3.6% 50%)",
          padding: `${size * 0.16}px ${size * 1.1}px ${size * 0.1}px`,
          fontFamily: BODY,
          fontWeight: 700,
          fontSize: size,
          color,
          letterSpacing: "0.12em",
          whiteSpace: "nowrap",
        }}
      >
        {text}
      </div>
    </div>
  </div>
);

/* ------------------------------------------------------------- backgrounds */

export const Burst: React.FC<{ a?: string; b?: string; x?: string; y?: string; rays?: number; spin?: number; style?: React.CSSProperties }> = ({
  a = C.fireBody,
  b = C.horizon,
  x = "50%",
  y = "50%",
  rays = 24,
  spin = 0,
  style,
}) => {
  const step = 360 / rays;
  return (
    <AbsoluteFill
      style={{
        background: `repeating-conic-gradient(from ${spin}deg at ${x} ${y}, ${a} 0deg ${step / 2}deg, ${b} ${step / 2}deg ${step}deg)`,
        ...style,
      }}
    />
  );
};

export const Halftone: React.FC<{ opacity?: number; size?: number; color?: string }> = ({ opacity = 0.18, size = 14, color = C.ink }) => (
  <AbsoluteFill
    style={{
      backgroundImage: `radial-gradient(${color} 22%, transparent 24%)`,
      backgroundSize: `${size}px ${size}px`,
      opacity,
      mixBlendMode: "multiply",
    }}
  />
);

export const Shot: React.FC<{
  src: string;
  scale?: number;
  x?: number;
  y?: number;
  filter?: string;
  origin?: string;
}> = ({ src, scale = 1, x = 0, y = 0, filter = "saturate(1.18) contrast(1.06)", origin = "50% 50%" }) => (
  <AbsoluteFill style={{ overflow: "hidden" }}>
    <Img
      src={staticFile(`shots/${src}.jpg`)}
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

// Thick comic frame around the whole thumbnail.
export const Frame: React.FC<{ color?: string; width?: number }> = ({ color = C.ink, width = 14 }) => (
  <AbsoluteFill style={{ boxShadow: `inset 0 0 0 ${width}px ${color}`, pointerEvents: "none" }} />
);

/* ------------------------------------------------------------------ flames */

const tongue = (cx: number, base: number, w: number, h: number, lean: number) =>
  `M ${cx - w / 2} ${base}
   C ${cx - w / 2} ${base - h * 0.42}, ${cx - w * 0.12 + lean * 0.4} ${base - h * 0.62}, ${cx + lean} ${base - h}
   C ${cx + w * 0.3 + lean * 0.4} ${base - h * 0.6}, ${cx + w / 2} ${base - h * 0.42}, ${cx + w / 2} ${base} Z`;

const rand = (s: number) => {
  const x = Math.sin(s * 127.1 + 311.7) * 43758.5453;
  return x - Math.floor(x);
};

export const Flames: React.FC<{
  width: number;
  height: number;
  count?: number;
  seed?: number;
  t?: number; // animation time (frames)
  outline?: number;
  style?: React.CSSProperties;
}> = ({ width, height, count = 7, seed = 1, t = 0, outline = 10, style }) => {
  const W = width;
  const H = height;
  const items = Array.from({ length: count }, (_, i) => {
    const r1 = rand(seed * 13 + i);
    const r2 = rand(seed * 29 + i * 3);
    const flick = 1 + 0.09 * Math.sin(t * 0.45 + i * 1.7 + seed) + 0.05 * Math.sin(t * 1.1 + i * 2.3);
    const edge = Math.min(i + 0.5, count - i - 0.5) / (count / 2); // taller in the middle
    return {
      cx: ((i + 0.5) / count) * W + (r1 - 0.5) * (W / count) * 0.5,
      w: (W / count) * (1.7 + r2 * 0.5),
      h: H * (0.45 + 0.55 * Math.pow(edge, 0.6) * (0.75 + r1 * 0.25)) * flick,
      lean: (r2 - 0.5) * (W / count) * 0.9 + Math.sin(t * 0.3 + i) * (W / count) * 0.12,
    };
  });
  const base = H + 4;
  const layer = (k: number, col: string, stroke?: number) => (
    <g>
      {items.map((f, i) => (
        <path
          key={i}
          d={tongue(f.cx, base, f.w * k, f.h * (0.25 + 0.75 * k), f.lean * k)}
          fill={col}
          stroke={stroke ? C.ink : "none"}
          strokeWidth={stroke}
          strokeLinejoin="round"
        />
      ))}
    </g>
  );
  return (
    <svg width={W} height={H} viewBox={`0 0 ${W} ${H}`} style={{ overflow: "visible", ...style }}>
      {outline > 0 && layer(1, C.ink, outline * 2)}
      {layer(1, C.fireEdge)}
      {layer(0.72, C.fireBody)}
      {layer(0.42, C.fireCore)}
    </svg>
  );
};

/* ----------------------------------------------------------------- penguin */

// Penguin firefighter head: red numbered helmet + googly eyes. viewBox 400x420.
export const PenguinFace: React.FC<{
  size: number;
  number?: string;
  look?: [number, number, number, number]; // pupil offsets lx, ly, rx, ry
  style?: React.CSSProperties;
  blush?: boolean;
  soot?: boolean;
}> = ({ size, number = "67", look = [14, 12, -12, -10], style, blush = true, soot = false }) => {
  const ink = C.ink;
  const mask = (
    <>
      <circle cx={148} cy={262} r={84} />
      <circle cx={252} cy={262} r={84} />
      <ellipse cx={200} cy={322} rx={118} ry={86} />
    </>
  );
  return (
    <svg width={size} height={(size * 420) / 400} viewBox="0 0 400 420" style={{ overflow: "visible", ...style }}>
      {/* head */}
      <ellipse cx={200} cy={262} rx={168} ry={150} fill={C.penguin} stroke={ink} strokeWidth={12} />
      {/* face mask: stroke pass then fill pass = outline of the union */}
      <g fill="#fff" stroke={ink} strokeWidth={14}>
        {mask}
      </g>
      <g fill="#fff">{mask}</g>
      {soot && (
        <g fill={ink} opacity={0.22}>
          <ellipse cx={110} cy={330} rx={30} ry={16} />
          <ellipse cx={300} cy={350} rx={22} ry={12} />
        </g>
      )}
      {blush && (
        <g fill="#FF8FA0" opacity={0.75}>
          <ellipse cx={98} cy={318} rx={24} ry={14} />
          <ellipse cx={302} cy={318} rx={24} ry={14} />
        </g>
      )}
      {/* beak */}
      <ellipse cx={204} cy={344} rx={48} ry={22} fill="#E07A10" stroke={ink} strokeWidth={9} />
      <ellipse cx={204} cy={318} rx={66} ry={30} fill={C.beak} stroke={ink} strokeWidth={9} />
      <ellipse cx={186} cy={309} rx={22} ry={8} fill="#FFD27A" opacity={0.8} />
      {/* googly eyes */}
      <circle cx={146} cy={240} r={62} fill="#fff" stroke={ink} strokeWidth={10} />
      <circle cx={258} cy={234} r={68} fill="#fff" stroke={ink} strokeWidth={10} />
      <circle cx={146 + look[0]} cy={240 + look[1]} r={26} fill={ink} />
      <circle cx={258 + look[2]} cy={234 + look[3]} r={28} fill={ink} />
      <circle cx={146 + look[0] - 8} cy={240 + look[1] - 9} r={8} fill="#fff" />
      <circle cx={258 + look[2] - 8} cy={234 + look[3] - 10} r={9} fill="#fff" />
      {/* helmet */}
      <path d="M 52 176 C 52 26, 348 26, 348 176 Z" fill={C.red} stroke={ink} strokeWidth={12} strokeLinejoin="round" />
      <path d="M 200 40 C 196 70, 196 130, 200 170" stroke={C.redDark} strokeWidth={14} fill="none" strokeLinecap="round" opacity={0.6} />
      <ellipse cx={118} cy={92} rx={40} ry={16} fill="#fff" opacity={0.35} transform="rotate(-32 118 92)" />
      <ellipse cx={200} cy={172} rx={196} ry={44} fill={C.red} stroke={ink} strokeWidth={12} />
      <ellipse cx={200} cy={164} rx={150} ry={18} fill={C.redDark} opacity={0.45} />
      <circle cx={200} cy={40} r={20} fill={C.red} stroke={ink} strokeWidth={10} />
      {/* shield badge */}
      <path
        d="M 146 66 L 254 66 L 254 116 Q 254 156 200 172 Q 146 156 146 116 Z"
        fill={C.shield}
        stroke={ink}
        strokeWidth={10}
        strokeLinejoin="round"
      />
      <text
        x={200}
        y={142}
        textAnchor="middle"
        fontFamily={DISPLAY}
        fontSize={70}
        fill={ink}
        style={{ letterSpacing: "0.02em" }}
      >
        {number}
      </text>
    </svg>
  );
};

/* ------------------------------------------------------------------- props */

const Sparkle: React.FC<{ x: number; y: number; r: number; color?: string }> = ({ x, y, r, color = "#fff" }) => (
  <path
    d={`M ${x} ${y - r} Q ${x + r * 0.18} ${y - r * 0.18} ${x + r} ${y} Q ${x + r * 0.18} ${y + r * 0.18} ${x} ${y + r} Q ${x - r * 0.18} ${y + r * 0.18} ${x - r} ${y} Q ${x - r * 0.18} ${y - r * 0.18} ${x} ${y - r} Z`}
    fill={color}
    stroke={C.ink}
    strokeWidth={r * 0.12}
    strokeLinejoin="round"
  />
);

export const GoldenAxe: React.FC<{ size: number; style?: React.CSSProperties; shine?: number }> = ({ size, style, shine = 0 }) => (
  <svg width={size} height={size} viewBox="0 0 600 600" style={{ overflow: "visible", ...style }}>
    <defs>
      <linearGradient id="gold" x1="0" y1="0" x2="1" y2="1">
        <stop offset="0" stopColor="#FFF0A0" />
        <stop offset="0.45" stopColor={C.gold} />
        <stop offset="1" stopColor={C.goldDark} />
      </linearGradient>
      <linearGradient id="wood" x1="0" y1="0" x2="1" y2="0">
        <stop offset="0" stopColor="#B87440" />
        <stop offset="1" stopColor="#7A4320" />
      </linearGradient>
    </defs>
    <g transform="rotate(32 300 300)">
      {/* handle */}
      <rect x={278} y={70} width={48} height={500} rx={22} fill="url(#wood)" stroke={C.ink} strokeWidth={12} />
      <rect x={272} y={470} width={60} height={22} rx={8} fill={C.red} stroke={C.ink} strokeWidth={8} />
      <rect x={272} y={510} width={60} height={22} rx={8} fill={C.red} stroke={C.ink} strokeWidth={8} />
      {/* pick */}
      <path d="M 290 104 L 200 128 L 140 150 L 200 172 L 290 196 Z" fill="url(#gold)" stroke={C.ink} strokeWidth={12} strokeLinejoin="round" />
      {/* blade */}
      <path
        d="M 300 92 L 376 84 Q 470 30 512 150 Q 470 270 376 216 L 300 208 Z"
        fill="url(#gold)"
        stroke={C.ink}
        strokeWidth={12}
        strokeLinejoin="round"
      />
      <path d="M 478 92 Q 500 150 478 208" fill="none" stroke="#FFFBE0" strokeWidth={14} strokeLinecap="round" />
      <rect x={270} y={84} width={64} height={132} rx={14} fill="url(#gold)" stroke={C.ink} strokeWidth={12} />
      <circle cx={302} cy={150} r={14} fill={C.goldDark} stroke={C.ink} strokeWidth={6} />
      <ellipse cx={400} cy={118} rx={34} ry={12} fill="#fff" opacity={0.55} transform="rotate(-20 400 118)" />
    </g>
    <g opacity={0.9 + 0.1 * Math.sin(shine)}>
      <Sparkle x={520} y={90} r={44 + 8 * Math.sin(shine)} />
      <Sparkle x={110} y={210} r={30 + 6 * Math.sin(shine + 2)} color="#FFF3B0" />
      <Sparkle x={470} y={430} r={26 + 6 * Math.sin(shine + 4)} />
    </g>
  </svg>
);

export const GasMask: React.FC<{ size: number }> = ({ size }) => (
  <svg width={size} height={size} viewBox="0 0 200 200">
    <path d="M 40 70 Q 100 10 160 70 Q 175 140 100 182 Q 25 140 40 70 Z" fill="#4A515C" stroke={C.ink} strokeWidth={9} strokeLinejoin="round" />
    <circle cx={72} cy={84} r={24} fill={C.water} stroke={C.ink} strokeWidth={8} />
    <circle cx={128} cy={84} r={24} fill={C.water} stroke={C.ink} strokeWidth={8} />
    <ellipse cx={66} cy={78} rx={8} ry={5} fill="#fff" />
    <ellipse cx={122} cy={78} rx={8} ry={5} fill="#fff" />
    <circle cx={100} cy={146} r={30} fill={C.hose} stroke={C.ink} strokeWidth={8} />
    <path d="M 82 146 H 118 M 100 128 V 164" stroke={C.ink} strokeWidth={6} strokeLinecap="round" />
  </svg>
);

export const Halligan: React.FC<{ size: number }> = ({ size }) => (
  <svg width={size} height={size} viewBox="0 0 200 200">
    <g transform="rotate(-40 100 100)">
      <rect x={92} y={22} width={16} height={160} rx={6} fill="#C9CCD0" stroke={C.ink} strokeWidth={7} />
      <path d="M 60 34 L 140 34 L 128 22 L 72 22 Z" fill="#C9CCD0" stroke={C.ink} strokeWidth={7} strokeLinejoin="round" />
      <path d="M 60 34 L 44 50 M 140 34 L 160 26" stroke={C.ink} strokeWidth={10} strokeLinecap="round" />
      <path d="M 92 176 L 82 196 M 108 176 L 118 196" stroke={C.ink} strokeWidth={12} strokeLinecap="round" />
      <path d="M 92 176 L 82 196 M 108 176 L 118 196" stroke="#C9CCD0" strokeWidth={5} strokeLinecap="round" />
      <rect x={90} y={96} width={20} height={44} rx={6} fill={C.red} stroke={C.ink} strokeWidth={6} />
    </g>
  </svg>
);

export const Sledge: React.FC<{ size: number }> = ({ size }) => (
  <svg width={size} height={size} viewBox="0 0 200 200">
    <g transform="rotate(35 100 100)">
      <rect x={91} y={58} width={18} height={130} rx={8} fill="#B87440" stroke={C.ink} strokeWidth={7} />
      <rect x={48} y={22} width={104} height={50} rx={10} fill="#6E7480" stroke={C.ink} strokeWidth={8} />
      <rect x={58} y={30} width={40} height={10} rx={5} fill="#fff" opacity={0.4} />
    </g>
  </svg>
);

export const WaterArc: React.FC<{ width: number; height: number; t?: number; style?: React.CSSProperties; flip?: boolean }> = ({
  width,
  height,
  t = 0,
  style,
  flip = false,
}) => {
  const d = `M 0 ${height * 0.95} Q ${width * 0.45} ${-height * 0.35} ${width} ${height * 0.62}`;
  return (
    <svg width={width} height={height} viewBox={`0 0 ${width} ${height}`} style={{ overflow: "visible", transform: flip ? "scaleX(-1)" : undefined, ...style }}>
      <path d={d} fill="none" stroke={C.ink} strokeWidth={74} strokeLinecap="round" />
      <path d={d} fill="none" stroke={C.water} strokeWidth={56} strokeLinecap="round" />
      <path d={d} fill="none" stroke="#fff" strokeWidth={14} strokeLinecap="round" strokeDasharray="60 46" strokeDashoffset={-t * 9} opacity={0.9} />
      {[0, 1, 2, 3, 4].map((i) => (
        <circle
          key={i}
          cx={width + 10 + i * 26 + (i % 2) * 12}
          cy={height * 0.62 + 20 + i * 22 - (i % 2) * 30}
          r={16 - i * 2}
          fill={C.water}
          stroke={C.ink}
          strokeWidth={6}
        />
      ))}
    </svg>
  );
};

/* -------------------------------------------------------------------- logo */

export const Logo: React.FC<{ size?: number; sub?: boolean; style?: React.CSSProperties }> = ({ size = 200, sub = true, style }) => (
  <div style={{ display: "flex", flexDirection: "column", alignItems: "center", ...style }}>
    <Outline
      size={size}
      fill={C.cream}
      layers={[
        { stroke: size * 0.26, color: C.ink },
        { stroke: size * 0.15, color: C.red },
      ]}
      shadow={0.08}
    >
      STATION 67
    </Outline>
    {sub && <Ribbon text="FLAME AND BLAME" size={size * 0.27} style={{ marginTop: -size * 0.02 }} />}
  </div>
);
