import React, { useId } from "react";
import { AbsoluteFill, Img, spring, staticFile, useCurrentFrame, useVideoConfig } from "remotion";
import type { Shot } from "./shots";
import { C, CONFETTI, DISPLAY } from "./theme";

export const rand = (s: number) => {
  const x = Math.sin(s * 127.1 + 311.7) * 43758.5453;
  return x - Math.floor(x);
};

// SVG ids must be unique per page and useId() output contains colons.
const useSvgId = () => useId().replace(/:/g, "");

/* ------------------------------------------------------------------ type */

export type Layer = { stroke: number; color: string };

// Chunky outlined type, one span per letter so letters can tilt, bob and spring in.
// Each layer is a full copy of the line, so every stroke sits under every fill.
export const Title: React.FC<{
  text: string;
  size: number;
  fill?: string;
  layers?: Layer[];
  shadow?: number;
  wobble?: number;
  bob?: number;
  enter?: number;
  stagger?: number;
  style?: React.CSSProperties;
}> = ({ text, size, fill = C.cream, layers, shadow = 0.08, wobble = 0, bob = 0, enter, stagger = 1.5, style }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const ls = layers ?? [{ stroke: size * 0.24, color: C.navy }];
  const max = Math.max(...ls.map((l) => l.stroke));
  const chars = Array.from(text);
  const poses = chars.map((_, i) => {
    const tilt = wobble * Math.sin(i * 2.399 + 1.1);
    const dy = bob * size * Math.sin(i * 1.618 + 0.4);
    if (enter === undefined) return { transform: `translateY(${dy}px) rotate(${tilt}deg)`, opacity: 1 };
    const local = frame - enter - i * stagger;
    const s = spring({ frame: local, fps, config: { damping: 9, stiffness: 200, mass: 0.55 } });
    return {
      transform: `translateY(${dy + (1 - s) * size * 0.8}px) rotate(${tilt * s - (1 - s) * 30}deg) scale(${0.2 + 0.8 * s})`,
      opacity: local >= 0 ? 1 : 0,
    };
  });
  const row = (key: string, look: React.CSSProperties, under: boolean, drop = 0) => (
    <div
      key={key}
      aria-hidden={under}
      style={{ position: under ? "absolute" : "relative", left: 0, top: drop, display: "flex", whiteSpace: "pre" }}
    >
      {chars.map((ch, i) => (
        <span
          key={i}
          style={{
            display: "inline-block",
            fontFamily: DISPLAY,
            fontSize: size,
            lineHeight: 1.05,
            letterSpacing: "0.02em",
            ...(ch === " " ? { width: size * 0.3 } : {}),
            ...look,
            ...poses[i],
          }}
        >
          {ch}
        </span>
      ))}
    </div>
  );
  return (
    <div style={{ position: "relative", display: "inline-block", ...style }}>
      {shadow > 0 && row("shadow", { color: C.navy, WebkitTextStroke: `${max}px ${C.navy}` }, true, size * shadow)}
      {ls.map((l, i) => row(`layer${i}`, { color: l.color, WebkitTextStroke: `${l.stroke}px ${l.color}` }, true))}
      {row("fill", { color: fill }, false)}
    </div>
  );
};

// Preset looks: gold headline on a red rim, cream sub-line, and a pink rim for the costume beat.
export const gold = (size: number): Pick<React.ComponentProps<typeof Title>, "fill" | "layers"> => ({
  fill: C.gold,
  layers: [
    { stroke: size * 0.3, color: C.navy },
    { stroke: size * 0.15, color: C.red },
  ],
});
export const cream = (size: number): Pick<React.ComponentProps<typeof Title>, "fill" | "layers"> => ({
  fill: C.cream,
  layers: [{ stroke: size * 0.26, color: C.navy }],
});
export const candy = (size: number): Pick<React.ComponentProps<typeof Title>, "fill" | "layers"> => ({
  fill: C.white,
  layers: [
    { stroke: size * 0.3, color: C.navy },
    { stroke: size * 0.15, color: C.pink },
  ],
});

/* ----------------------------------------------------------------- photo */

export const Photo: React.FC<{ shot: Shot; scale?: number; x?: number; y?: number; filter?: string }> = ({
  shot,
  scale = 1,
  x = 0,
  y = 0,
  filter = "saturate(1.22) contrast(1.06)",
}) => {
  const focus = shot.focus ?? "50% 50%";
  return (
    <AbsoluteFill style={{ overflow: "hidden" }}>
      <Img
        src={staticFile(`shots/${shot.file}`)}
        style={{
          width: "100%",
          height: "100%",
          objectFit: "cover",
          objectPosition: focus,
          transform: `translate(${x}px, ${y}px) scale(${(shot.zoom ?? 1) * scale})`,
          transformOrigin: focus,
          filter,
        }}
      />
    </AbsoluteFill>
  );
};

/* ----------------------------------------------------------- backgrounds */

export const Rays: React.FC<{ a: string; b: string; x?: string; y?: string; rays?: number; spin?: number }> = ({
  a,
  b,
  x = "50%",
  y = "50%",
  rays = 24,
  spin = 0,
}) => {
  const step = 360 / rays;
  return (
    <AbsoluteFill
      style={{
        background: `repeating-conic-gradient(from ${spin}deg at ${x} ${y}, ${a} 0deg ${step / 2}deg, ${b} ${step / 2}deg ${step}deg)`,
      }}
    />
  );
};

export const Shade: React.FC<{ dir: string; a?: number; stop?: number }> = ({ dir, a = 0.7, stop = 50 }) => (
  <AbsoluteFill style={{ background: `linear-gradient(${dir}, rgba(29,53,87,${a}) 0%, rgba(29,53,87,0) ${stop}%)` }} />
);

export const Frame: React.FC = () => <AbsoluteFill style={{ boxShadow: `inset 0 0 0 14px ${C.navy}`, pointerEvents: "none" }} />;

/* ----------------------------------------------------------------- bulbs */

export type Pt = readonly [number, number];

export const lineOf = (x0: number, y0: number, x1: number, y1: number, n: number): Pt[] =>
  Array.from({ length: n }, (_, i) => {
    const k = n > 1 ? i / (n - 1) : 0;
    return [x0 + (x1 - x0) * k, y0 + (y1 - y0) * k] as const;
  });

export const ringOf = (cx: number, cy: number, r: number, n: number, phase = 0): Pt[] =>
  Array.from({ length: n }, (_, i) => {
    const a = phase + (i / n) * Math.PI * 2;
    return [cx + Math.cos(a) * r, cy + Math.sin(a) * r] as const;
  });

// Marquee bulbs, two of every three lit; `t` (frames) runs the chase one bulb every 4 frames.
export const Bulbs: React.FC<{ pts: Pt[]; r: number; t?: number }> = ({ pts, r, t = 0 }) => {
  const id = useSvgId();
  const step = Math.floor(t / 4);
  return (
    <g>
      <defs>
        <radialGradient id={`${id}glow`}>
          <stop offset="0" stopColor="#FFF6C8" stopOpacity={0.95} />
          <stop offset="0.4" stopColor={C.gold} stopOpacity={0.5} />
          <stop offset="1" stopColor={C.gold} stopOpacity={0} />
        </radialGradient>
      </defs>
      {pts.map(([x, y], i) => {
        const on = (i + step) % 3 !== 0;
        return (
          <g key={i}>
            {on && <circle cx={x} cy={y} r={r * 2.5} fill={`url(#${id}glow)`} />}
            <circle cx={x} cy={y} r={r} fill={on ? "#FFFBE6" : "#D79A2B"} stroke={C.navy} strokeWidth={r * 0.36} />
            <circle cx={x - r * 0.32} cy={y - r * 0.32} r={r * 0.3} fill="#fff" opacity={on ? 0.95 : 0.4} />
          </g>
        );
      })}
    </g>
  );
};

/* ------------------------------------------------------------- tent band */

// Striped big-top valance with a scalloped hem, hung from a rail of marquee bulbs.
export const TentBand: React.FC<{ width: number; t?: number }> = ({ width, t = 0 }) => {
  const id = useSvgId();
  const stripe = 96;
  const depth = 64;
  const colors = [C.red, C.cream];
  const n = Math.ceil(width / stripe) + 1;
  const r = stripe / 2;
  const rail = 34;
  const h = depth + r * 0.85 + 14;
  const scallop = (i: number) => {
    const x = i * stripe;
    return `M ${x} 0 H ${x + stripe} V ${depth} A ${r} ${r * 0.85} 0 0 1 ${x} ${depth} Z`;
  };
  const idx = Array.from({ length: n }, (_, i) => i);
  return (
    <svg
      width={width}
      height={h}
      viewBox={`0 0 ${width} ${h}`}
      style={{ position: "absolute", left: 0, top: 0, overflow: "visible", filter: "drop-shadow(0 8px 0 rgba(29,53,87,0.45))" }}
    >
      <defs>
        <linearGradient id={`${id}fold`} x1="0" y1="0" x2="1" y2="0">
          <stop offset="0" stopColor="#000" stopOpacity={0.16} />
          <stop offset="0.35" stopColor="#fff" stopOpacity={0.12} />
          <stop offset="1" stopColor="#000" stopOpacity={0.18} />
        </linearGradient>
      </defs>
      <g fill={C.navy} stroke={C.navy} strokeWidth={14} strokeLinejoin="round">
        {idx.map((i) => (
          <path key={i} d={scallop(i)} />
        ))}
      </g>
      {idx.map((i) => (
        <path key={i} d={scallop(i)} fill={colors[i % 2]} />
      ))}
      {idx.map((i) => (
        <path key={i} d={scallop(i)} fill={`url(#${id}fold)`} />
      ))}
      <rect x={-10} y={0} width={width + 20} height={rail} fill={C.navy} />
      <Bulbs pts={lineOf(r, rail / 2 + 2, r + (n - 1) * stripe, rail / 2 + 2, n)} r={10} t={t} />
    </svg>
  );
};

/* ---------------------------------------------------------------- ticket */

const starPath = (cx: number, cy: number, R: number, r: number, n = 5) =>
  Array.from({ length: n * 2 }, (_, i) => {
    const a = -Math.PI / 2 + (i * Math.PI) / n;
    const rr = i % 2 === 0 ? R : r;
    return `${i === 0 ? "M" : "L"} ${cx + Math.cos(a) * rr} ${cy + Math.sin(a) * rr}`;
  }).join(" ") + " Z";

export const Star: React.FC<{ size: number; fill?: string }> = ({ size, fill = C.gold }) => (
  <svg width={size} height={size} viewBox="0 0 100 100" style={{ overflow: "visible" }}>
    <path d={starPath(50, 52, 48, 21)} fill={fill} stroke={C.navy} strokeWidth={8} strokeLinejoin="round" />
    <path d={starPath(44, 44, 12, 5, 4)} fill="#fff" opacity={0.7} />
  </svg>
);

// Funfair ticket stub: notched sides, a perforated tear line, and a stub on the right.
export const Ticket: React.FC<{
  w: number;
  h: number;
  color?: string;
  stub?: number;
  rotate?: number;
  children?: React.ReactNode;
  stubContent?: React.ReactNode;
}> = ({ w, h, color = C.red, stub = 0.2, rotate = 0, children, stubContent }) => {
  const rn = h * 0.13;
  const rc = h * 0.1;
  const sx = w * (1 - stub);
  const d = `M ${rc} 0 H ${w - rc} Q ${w} 0 ${w} ${rc} V ${h / 2 - rn} A ${rn} ${rn} 0 0 0 ${w} ${h / 2 + rn} V ${h - rc} Q ${w} ${h} ${w - rc} ${h} H ${rc} Q 0 ${h} 0 ${h - rc} V ${h / 2 + rn} A ${rn} ${rn} 0 0 0 0 ${h / 2 - rn} V ${rc} Q 0 0 ${rc} 0 Z`;
  const inset = rn + h * 0.07;
  return (
    <div style={{ position: "relative", width: w, height: h, transform: `rotate(${rotate}deg)`, filter: `drop-shadow(0 ${h * 0.06}px 0 ${C.navy})` }}>
      <svg width={w} height={h} viewBox={`0 0 ${w} ${h}`} style={{ position: "absolute", left: 0, top: 0, overflow: "visible" }}>
        <path d={d} fill={color} stroke={C.navy} strokeWidth={Math.max(6, h * 0.045)} strokeLinejoin="round" />
        <rect
          x={inset}
          y={h * 0.11}
          width={sx - inset - h * 0.09}
          height={h * 0.78}
          rx={h * 0.06}
          fill="none"
          stroke={C.cream}
          strokeWidth={Math.max(2, h * 0.016)}
          strokeDasharray={`${h * 0.02} ${h * 0.035}`}
          strokeLinecap="round"
          opacity={0.75}
        />
        <path d={`M ${sx} ${h * 0.08} V ${h * 0.92}`} stroke={C.navy} strokeWidth={Math.max(3, h * 0.025)} strokeDasharray={`${h * 0.05} ${h * 0.045}`} strokeLinecap="round" opacity={0.7} />
      </svg>
      <div style={{ position: "absolute", left: 0, top: 0, width: sx, height: h, display: "flex", alignItems: "center", justifyContent: "center" }}>
        {children}
      </div>
      {stubContent && (
        <div style={{ position: "absolute", left: sx, top: 0, width: w - sx, height: h, display: "flex", alignItems: "center", justifyContent: "center" }}>
          {stubContent}
        </div>
      )}
    </div>
  );
};

/* -------------------------------------------------------------- confetti */

const piece = (i: number, s: number, col: string) => {
  const edge = { stroke: C.navy, strokeWidth: 2.2 * s };
  if (i % 3 === 0) return <circle r={7 * s} fill={col} {...edge} />;
  if (i % 3 === 1) return <rect x={-11 * s} y={-6 * s} width={22 * s} height={12 * s} rx={2 * s} fill={col} {...edge} />;
  return <rect x={-16 * s} y={-4.5 * s} width={32 * s} height={9 * s} rx={4.5 * s} fill={col} {...edge} />;
};

// Falling confetti. With t = 0 it is a still scatter.
export const Confetti: React.FC<{ w: number; h: number; n?: number; seed?: number; t?: number; fall?: number }> = ({
  w,
  h,
  n = 60,
  seed = 1,
  t = 0,
  fall = 3,
}) => (
  <svg width={w} height={h} style={{ position: "absolute", left: 0, top: 0, overflow: "visible", pointerEvents: "none" }}>
    {Array.from({ length: n }, (_, i) => {
      const r1 = rand(seed * 31 + i);
      const r2 = rand(seed * 17 + i * 7);
      const r3 = rand(seed * 5 + i * 13);
      const r4 = rand(seed * 11 + i * 3);
      const span = h + 80;
      const y = ((r2 * span + t * fall * (0.6 + r3)) % span) - 40;
      const x = r1 * w + Math.sin(t * 0.06 + i) * 18;
      const rot = r4 * 360 + t * (r3 - 0.5) * 14;
      const flip = 0.25 + 0.75 * Math.abs(Math.cos(t * 0.16 + i * 1.3));
      return (
        <g key={i} transform={`translate(${x} ${y}) rotate(${rot}) scale(1 ${flip})`}>
          {piece(i, 0.8 + r3 * 0.6, CONFETTI[i % CONFETTI.length])}
        </g>
      );
    })}
  </svg>
);

// Confetti cannon: 46 pieces fly out from (x, y) in a 50 degree cone around `angle`
// (degrees, screen space) and fall.
export const Popper: React.FC<{ x: number; y: number; angle: number; t: number; seed?: number }> = ({ x, y, angle, t, seed = 1 }) => {
  if (t < 0) return null;
  const travel = (1 - Math.exp(-0.06 * t)) / 0.06;
  const size = 1.3;
  return (
    <svg width={1} height={1} style={{ position: "absolute", left: 0, top: 0, overflow: "visible", pointerEvents: "none" }}>
      {Array.from({ length: 46 }, (_, i) => {
        const r1 = rand(seed * 41 + i);
        const r2 = rand(seed * 23 + i * 5);
        const r3 = rand(seed * 7 + i * 11);
        const a = ((angle + (r1 - 0.5) * 50) * Math.PI) / 180;
        const v = 46 * (0.45 + r2 * 0.75);
        const px = x + Math.cos(a) * v * travel + Math.sin(t * 0.2 + i) * 8;
        const py = y + Math.sin(a) * v * travel + 0.07 * t * t;
        const rot = r3 * 360 + t * (r1 - 0.5) * 30;
        const flip = 0.25 + 0.75 * Math.abs(Math.cos(t * 0.22 + i));
        return (
          <g key={i} transform={`translate(${px} ${py}) rotate(${rot}) scale(1 ${flip})`}>
            {piece(i, size * (0.8 + r3 * 0.6), CONFETTI[(i + seed) % CONFETTI.length])}
          </g>
        );
      })}
    </svg>
  );
};

/* ------------------------------------------------------------- fireworks */

// A cartoon firework burst; p runs 0 (launch) .. 1 (fully open), fading after 0.85.
export const Firework: React.FC<{ cx: number; cy: number; r: number; color: string; color2?: string; p?: number; rays?: number }> = ({
  cx,
  cy,
  r,
  color,
  color2 = C.cream,
  p = 1,
  rays = 14,
}) => {
  const id = useSvgId();
  if (p <= 0) return null;
  const k = Math.min(1, p);
  const e = 1 - Math.pow(1 - k, 3);
  const outer = r * e;
  const inner = r * (0.12 + 0.45 * e);
  const fade = p > 0.85 ? Math.max(0, 1 - (p - 0.85) / 0.35) : 1;
  const w = r * 0.075;
  const dirs = (count: number, off: number) =>
    Array.from({ length: count }, (_, i) => {
      const a = off + (i / count) * Math.PI * 2;
      return [Math.cos(a), Math.sin(a)] as const;
    });
  const main = dirs(rays, 0.2);
  const minor = dirs(rays, 0.2 + Math.PI / rays);
  const seg = (list: ReturnType<typeof dirs>, i0: number, i1: number, stroke: string, sw: number, key: string) =>
    list.map(([dx, dy], i) => (
      <line key={`${key}${i}`} x1={cx + dx * i0} y1={cy + dy * i0} x2={cx + dx * i1} y2={cy + dy * i1} stroke={stroke} strokeWidth={sw} strokeLinecap="round" />
    ));
  return (
    <g opacity={fade}>
      <defs>
        <radialGradient id={`${id}glow`}>
          <stop offset="0" stopColor={color} stopOpacity={0.5} />
          <stop offset="1" stopColor={color} stopOpacity={0} />
        </radialGradient>
      </defs>
      <circle cx={cx} cy={cy} r={outer * 1.3} fill={`url(#${id}glow)`} />
      {seg(main, inner, outer, C.navy, w + r * 0.05, "mo")}
      {seg(minor, inner * 0.9, outer * 0.62, C.navy, w * 0.8 + r * 0.045, "no")}
      {seg(main, inner, outer, color, w, "m")}
      {seg(minor, inner * 0.9, outer * 0.62, color2, w * 0.8, "n")}
      {main.map(([dx, dy], i) => (
        <circle key={`d${i}`} cx={cx + dx * (outer + r * 0.12)} cy={cy + dy * (outer + r * 0.12)} r={r * 0.045} fill={color2} stroke={C.navy} strokeWidth={r * 0.022} />
      ))}
      <path d={starPath(cx, cy, r * 0.16 * (0.4 + e * 0.6), r * 0.06)} fill="#fff" stroke={C.navy} strokeWidth={r * 0.02} />
    </g>
  );
};

/* ------------------------------------------------------------------ pop */

// Places artwork at (x, y). With a `delay` it springs in from its own centre at that frame;
// without one it is static, which is what the stills use.
export const Pop: React.FC<{ x: number; y: number; delay?: number; spin?: number; children: React.ReactNode }> = ({ x, y, delay, spin = -20, children }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const s = delay === undefined ? 1 : spring({ frame: frame - delay, fps, config: { damping: 10, stiffness: 180, mass: 0.6 } });
  const shown = delay === undefined || frame >= delay;
  return (
    <div style={{ position: "absolute", left: x, top: y, transform: `scale(${s}) rotate(${(1 - s) * spin}deg)`, opacity: shown ? 1 : 0 }}>
      {children}
    </div>
  );
};

/* -------------------------------------------------------------- stickers */

// Die-cut sticker look: a 6 px white rim and a hard navy drop under any artwork.
export const DieCut: React.FC<{ children: React.ReactNode; rotate?: number }> = ({ children, rotate = 0 }) => (
  <div
    style={{
      display: "inline-block",
      transform: `rotate(${rotate}deg)`,
      filter: `drop-shadow(6px 0 0 #fff) drop-shadow(-6px 0 0 #fff) drop-shadow(0 6px 0 #fff) drop-shadow(0 -6px 0 #fff) drop-shadow(0 8px 0 ${C.navy})`,
    }}
  >
    {children}
  </div>
);
