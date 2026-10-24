// 1920x1080 thumbnails, one selling point each. Rules from ../ads/RESEARCH.md: few words in big
// outlined type, text inside x 150..1770 and y 90..860 (the player count covers the bottom strip),
// real in-game screenshots only, no fake buttons. Every image comes from SHOTS (src/shots.ts).
// The pieces below take an optional `enter` frame so the videos can spring them in.
import React from "react";
import { AbsoluteFill, spring, useCurrentFrame, useVideoConfig } from "remotion";
import { Bulbs, Confetti, DieCut, Firework, Frame, Photo, Pop, Rays, Shade, Star, TentBand, Ticket, Title, candy, cream, gold, ringOf } from "./art";
import { Costume, CostumeArt } from "./props";
import { RIDE_TILES, SHOTS } from "./shots";
import { C } from "./theme";

export const W = 1920;
export const H = 1080;

/* ---------------------------------------------------------- shared pieces */

// Round marquee sign with chasing bulbs and a big number in the middle.
export const StageBadge: React.FC<{ cx: number; cy: number; r: number; text: string; t?: number; enter?: number }> = ({ cx, cy, r, text, t = 0, enter }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const s = enter === undefined ? 1 : spring({ frame: frame - enter, fps, config: { damping: 10, stiffness: 170, mass: 0.7 } });
  const box = r + 40;
  return (
    <div style={{ position: "absolute", left: cx - box, top: cy - box, width: box * 2, height: box * 2, transform: `scale(${s}) rotate(${(1 - s) * -25}deg)` }}>
      <svg width={box * 2} height={box * 2} style={{ position: "absolute", left: 0, top: 0, overflow: "visible", filter: `drop-shadow(0 16px 0 ${C.navy})` }}>
        <circle cx={box} cy={box} r={r + 22} fill={C.navy} />
        <circle cx={box} cy={box} r={r + 10} fill={C.gold} />
        <circle cx={box} cy={box} r={r - 34} fill={C.red} stroke={C.navy} strokeWidth={12} />
        <Bulbs pts={ringOf(box, box, r - 12, 28)} r={11} t={t} />
      </svg>
      <div style={{ position: "absolute", left: 0, right: 0, top: box - r * 0.78, display: "flex", justifyContent: "center" }}>
        <Title text={text} size={r * 1.3} {...gold(r * 1.3)} wobble={4} />
      </div>
    </div>
  );
};

// Portrait-mode focus on the avatar: the cone and the body stay sharp, and the in-world price labels
// around them (which overlap in the shot) go soft.
const PORTRAIT_MASK = [
  "radial-gradient(ellipse 58px 125px at 48% 22%, #000 55%, transparent 100%)",
  "radial-gradient(ellipse 200px 270px at 50% 72%, #000 70%, transparent 100%)",
].join(", ");

export const Polaroid: React.FC<{ w: number; h: number; rotate?: number }> = ({ w, h, rotate = 0 }) => (
  <div
    style={{
      position: "relative",
      width: w,
      height: h,
      background: C.cream,
      border: `10px solid ${C.navy}`,
      borderRadius: 18,
      boxShadow: `0 18px 0 ${C.navy}`,
      transform: `rotate(${rotate}deg)`,
    }}
  >
    <div style={{ position: "absolute", left: 28, right: 28, top: 28, bottom: 110, borderRadius: 8, overflow: "hidden", border: `6px solid ${C.navy}` }}>
      <Photo shot={SHOTS.costume} scale={1.03} filter="saturate(1.22) contrast(1.06) blur(9px)" />
      <AbsoluteFill style={{ maskImage: PORTRAIT_MASK, WebkitMaskImage: PORTRAIT_MASK }}>
        <Photo shot={SHOTS.costume} />
      </AbsoluteFill>
    </div>
    <div style={{ position: "absolute", left: 0, right: 0, bottom: 22, display: "flex", justifyContent: "center", gap: 16 }}>
      {[C.red, C.gold, C.blue, C.pink, C.purple].map((c) => (
        <Star key={c} size={54} fill={c} />
      ))}
    </div>
  </div>
);

// Costume stickers around the polaroid: [item, x, y, size, tilt].
export const STICKERS: [Costume, number, number, number, number][] = [
  ["mouseEars", 900, 110, 200, -14],
  ["topHat", 1560, 120, 220, 12],
  ["crown", 1610, 480, 200, -10],
  ["partyCone", 860, 600, 210, 10],
  ["clownWig", 1470, 770, 200, -6],
  ["starCape", 560, 690, 220, 8],
];

export const Stickers: React.FC<{ enter?: number; gap?: number }> = ({ enter, gap = 4 }) => (
  <>
    {STICKERS.map(([item, x, y, size, tilt], i) => (
      <Pop key={item} x={x} y={y} delay={enter === undefined ? undefined : enter + i * gap} spin={tilt * 3}>
        <DieCut rotate={tilt}>
          <CostumeArt item={item} size={size} />
        </DieCut>
      </Pop>
    ))}
  </>
);

// Cartoon firework bursts: [x, y, radius, colour, tip colour, rays].
export type Burst = [number, number, number, string, string, number];

// `at(i)` gives each burst's progress 0..1; the stills leave it fully open.
export const Bursts: React.FC<{ list: Burst[]; at?: (i: number) => number }> = ({ list, at = () => 0.8 }) => (
  <svg width={W} height={H} style={{ position: "absolute", left: 0, top: 0, overflow: "visible" }}>
    {list.map(([x, y, r, col, tip, rays], i) => (
      <Firework key={i} cx={x} cy={y} r={r} color={col} color2={tip} rays={rays} p={at(i)} />
    ))}
  </svg>
);

// thumb-04 bursts in the sky right of the headline.
const FINALE_BURSTS: Burst[] = [
  [1170, 430, 105, C.gold, C.pink, 14],
  [1720, 520, 85, C.pink, C.cream, 12],
  [1420, 690, 70, C.cyan, C.gold, 12],
];

const Top: React.FC<{ t?: number }> = ({ t = 0 }) => <TentBand width={W} t={t} />;

/* ------------------------------------------------------ 01  6 RIDES. 1 PARK. */

const TILE_TOP = 300;
const GUTTER = 14;

// The six real rides as a 3x2 collage in course order, under a title band.
export const ThumbPark: React.FC<{ t?: number }> = ({ t = 0 }) => {
  const w = (W - 2 * GUTTER) / 3;
  const h = (H - TILE_TOP - GUTTER) / 2;
  return (
    <AbsoluteFill style={{ background: C.navy, overflow: "hidden" }}>
      <AbsoluteFill style={{ background: `linear-gradient(180deg, ${C.blue} 0%, ${C.cyan} 100%)`, bottom: H - TILE_TOP }}>
        <Rays a="rgba(255,255,255,0.2)" b="rgba(255,255,255,0)" y="70%" rays={22} spin={t * 0.5} />
      </AbsoluteFill>
      {RIDE_TILES.map((shot, i) => (
        <div
          key={shot.file}
          style={{ position: "absolute", left: (i % 3) * (w + GUTTER), top: TILE_TOP + Math.floor(i / 3) * (h + GUTTER), width: w, height: h, overflow: "hidden" }}
        >
          <Photo shot={shot} />
        </div>
      ))}
      <div style={{ position: "absolute", left: 0, right: 0, top: 112, display: "flex", justifyContent: "center", alignItems: "center", gap: 40 }}>
        <Title text="6 RIDES." size={170} {...gold(170)} wobble={3} bob={0.02} />
        <Ticket w={520} h={160} color={C.red} rotate={4} stubContent={<Star size={54} />}>
          <Title text="1 PARK." size={108} {...cream(108)} shadow={0.06} wobble={2} />
        </Ticket>
      </div>
      <Top t={t} />
      <Frame />
    </AbsoluteFill>
  );
};

/* ------------------------------------------------------------- 02  60 STAGES */

// The badge sits left so the wheel and the course stacked beside it stay in view.
export const ThumbStages: React.FC<{ t?: number }> = ({ t = 0 }) => (
  <AbsoluteFill style={{ background: C.sky, overflow: "hidden" }}>
    <Photo shot={SHOTS.course} scale={1.18} x={150} />
    <Shade dir="to right" a={0.45} stop={40} />
    <Confetti w={W} h={H} n={44} seed={5} t={t} />
    <StageBadge cx={440} cy={390} r={225} text="60" t={t} />
    <div style={{ position: "absolute", left: -60, width: 1000, top: 610, display: "flex", justifyContent: "center" }}>
      <Title text="STAGES" size={160} {...cream(160)} wobble={3} bob={0.02} />
    </div>
    <Top t={t} />
    <Frame />
  </AbsoluteFill>
);

/* ------------------------------------------------------------- 03  DRESS UP! */

export const ThumbDressUp: React.FC<{ t?: number }> = ({ t = 0 }) => (
  <AbsoluteFill style={{ background: C.pink, overflow: "hidden" }}>
    <Photo shot={SHOTS.lobby} scale={1.08} filter="saturate(1.2) contrast(1.05) blur(3px)" />
    <Rays a="rgba(255,95,168,0.42)" b="rgba(167,123,255,0.22)" x="68%" y="50%" rays={22} spin={t * 0.5} />
    <Shade dir="to right" a={0.45} stop={45} />
    <Confetti w={W} h={H} n={50} seed={8} t={t} />
    <Pop x={1010} y={170}>
      <Polaroid w={600} h={700} rotate={4} />
    </Pop>
    <Stickers />
    <div style={{ position: "absolute", left: 150, top: 170 }}>
      <Title text="DRESS" size={250} {...candy(250)} wobble={3} bob={0.02} />
    </div>
    <div style={{ position: "absolute", left: 210, top: 410 }}>
      <Title text="UP!" size={300} {...gold(300)} wobble={5} bob={0.03} />
    </div>
    <Top t={t} />
    <Frame />
  </AbsoluteFill>
);

/* ---------------------------------------------------- 04  RIDE TO THE FINALE */

// The player on stage 51 sits right of centre; the headline covers the white in-game fireworks on the
// left, and cartoon bursts carry the colour.
export const ThumbFinale: React.FC<{ t?: number }> = ({ t = 0 }) => (
  <AbsoluteFill style={{ background: C.navy, overflow: "hidden" }}>
    <Photo shot={SHOTS.finale} filter="saturate(1.25) contrast(1.12)" />
    <Shade dir="to right" a={0.5} stop={50} />
    <Bursts list={FINALE_BURSTS} />
    <Confetti w={W} h={H} n={40} seed={11} t={t} />
    <div style={{ position: "absolute", left: 150, top: 150, display: "flex", flexDirection: "column", alignItems: "flex-start" }}>
      <Title text="RIDE TO THE" size={130} {...cream(130)} wobble={2} bob={0.02} />
      <Title text="FINALE!" size={240} {...gold(240)} wobble={4} bob={0.025} style={{ marginTop: -8 }} />
    </div>
    <Top t={t} />
    <Frame />
  </AbsoluteFill>
);
