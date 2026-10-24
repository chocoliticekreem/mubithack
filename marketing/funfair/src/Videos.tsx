// 16:9 video ads (Roblox video ads are 16:9; ../ads/RESEARCH.md). Real shots with slow push-ins and
// pans, a punch and flash on every cut, tent-stripe wipes, captions that spring in letter by letter.
// No audio: we have no licensed track. Every image comes from SHOTS (src/shots.ts).
import React from "react";
import { AbsoluteFill, Easing, interpolate, Sequence, spring, useCurrentFrame, useVideoConfig } from "remotion";
import { Confetti, Frame, Photo, Pop, Popper, Rays, Shade, Star, TentBand, Ticket, Title, candy, cream, gold } from "./art";
import { BigTop, FerrisWheel, RIDES, RideToken } from "./props";
import { SHOTS, Shot } from "./shots";
import { BODY, C } from "./theme";
import { Burst, Bursts, H, Polaroid, StageBadge, Stickers, W } from "./Thumbs";

export const TRAILER_FRAMES = 450; // 15 s @ 30 fps
export const BUMPER_FRAMES = 180; // 6 s

const clamp = { extrapolateLeft: "clamp", extrapolateRight: "clamp" } as const;

/* ---------------------------------------------------------------- editing */

// Punch-in and a cream flash on every cut. The opening shot skips the flash so frame 0 is clean.
const Cut: React.FC<{ children: React.ReactNode; flash?: boolean }> = ({ children, flash = true }) => {
  const f = useCurrentFrame();
  const { fps } = useVideoConfig();
  const s = spring({ frame: f, fps, config: { damping: 12, stiffness: 160, mass: 0.7 } });
  return (
    <AbsoluteFill style={{ overflow: "hidden", background: C.navy }}>
      <AbsoluteFill style={{ transform: `scale(${interpolate(s, [0, 1], [1.16, 1])})` }}>{children}</AbsoluteFill>
      {flash && <AbsoluteFill style={{ background: C.cream, opacity: interpolate(f, [0, 5], [0.75, 0], clamp) }} />}
    </AbsoluteFill>
  );
};

// Quick punch for cuts inside a scene; no flash, since they come every few frames.
const Snap: React.FC<{ children: React.ReactNode }> = ({ children }) => {
  const s = interpolate(useCurrentFrame(), [0, 7], [1.1, 1], { ...clamp, easing: Easing.out(Easing.cubic) });
  return <AbsoluteFill style={{ transform: `scale(${s})` }}>{children}</AbsoluteFill>;
};

// Slow push-in / pan across one shot over `len` frames.
const Drift: React.FC<{ shot: Shot; len: number; from: number; to: number; x?: [number, number]; y?: [number, number]; filter?: string }> = ({
  shot,
  len,
  from,
  to,
  x = [0, 0],
  y = [0, 0],
  filter,
}) => {
  const p = interpolate(useCurrentFrame(), [0, len], [0, 1], clamp);
  return <Photo shot={shot} scale={from + (to - from) * p} x={x[0] + (x[1] - x[0]) * p} y={y[0] + (y[1] - y[0]) * p} filter={filter} />;
};

// Diagonal big-top stripes sweeping across; the frame is fully covered at the midpoint, where the cut sits.
const Wipe: React.FC<{ len: number }> = ({ len }) => {
  const x = interpolate(useCurrentFrame(), [0, len], [-W * 1.6, W * 1.1], clamp);
  return (
    <AbsoluteFill style={{ pointerEvents: "none" }}>
      <div
        style={{
          position: "absolute",
          top: -200,
          left: x,
          width: W * 1.5,
          height: H + 400,
          transform: "skewX(-14deg)",
          background: `repeating-linear-gradient(90deg, ${C.red} 0 90px, ${C.cream} 90px 180px)`,
          borderLeft: `16px solid ${C.navy}`,
          borderRight: `16px solid ${C.navy}`,
        }}
      />
    </AbsoluteFill>
  );
};

const Center: React.FC<{ top: number; children: React.ReactNode }> = ({ top, children }) => (
  <div style={{ position: "absolute", left: 0, right: 0, top, display: "flex", flexDirection: "column", alignItems: "center" }}>{children}</div>
);

/* ----------------------------------------------------------------- scenes */

const Hook: React.FC<{ len: number }> = ({ len }) => {
  const f = useCurrentFrame();
  return (
    <AbsoluteFill>
      <Drift shot={SHOTS.gate} len={len} from={1.0} to={1.25} />
      <Shade dir="to top" a={0.55} stop={45} />
      <Popper x={40} y={H + 20} angle={-62} t={f - 1} seed={1} />
      <Popper x={W - 40} y={H + 20} angle={-118} t={f - 1} seed={2} />
      <Center top={610}>
        <Title text="THE FUNFAIR" size={140} {...cream(140)} wobble={3} enter={2} stagger={1.2} />
        <Title text="IS OPEN!" size={210} {...gold(210)} wobble={4} bob={0.02} enter={8} stagger={1.5} style={{ marginTop: -14 }} />
      </Center>
    </AbsoluteFill>
  );
};

const Stages: React.FC<{ len: number }> = ({ len }) => {
  const f = useCurrentFrame();
  const n = Math.round(interpolate(f, [2, 20], [1, 60], clamp));
  return (
    <AbsoluteFill>
      <Drift shot={SHOTS.stages} len={len} from={1.12} to={1.3} x={[90, -30]} />
      <Shade dir="to right" a={0.5} stop={50} />
      <Confetti w={W} h={H} n={36} seed={5} t={f} />
      <StageBadge cx={470} cy={410} r={235} text={String(n)} t={f} enter={1} />
      <div style={{ position: "absolute", left: -30, width: 1000, top: 650, display: "flex", justifyContent: "center" }}>
        <Title text="STAGES!" size={170} {...cream(170)} wobble={3} enter={7} />
      </div>
    </AbsoluteFill>
  );
};

// One real shot per ride in course order; each ride's token pops in and grows on its own cut. The
// title sits top right and the tokens run down the left edge, clear of the rides.
const Rides: React.FC<{ len: number }> = ({ len }) => {
  const f = useCurrentFrame();
  const at = (i: number) => Math.round((i * len) / RIDES.length);
  const step = 146;
  return (
    <AbsoluteFill>
      {RIDES.map((r, i) => (
        <Sequence key={r} from={at(i)} durationInFrames={at(i + 1) - at(i)}>
          <Snap>
            <Drift shot={SHOTS[r]} len={at(i + 1) - at(i)} from={1.06} to={1.14} />
          </Snap>
        </Sequence>
      ))}
      <Shade dir="to bottom" a={0.45} stop={35} />
      <Shade dir="to right" a={0.45} stop={14} />
      <Confetti w={W} h={H} n={30} seed={9} t={f} />
      <div style={{ position: "absolute", right: 130, top: 120 }}>
        <Title text="6 RIDES!" size={200} {...gold(200)} wobble={4} bob={0.02} enter={2} />
      </div>
      {RIDES.map((r, i) => {
        const live = f >= at(i) && f < at(i + 1);
        return (
          <Pop key={r} x={46} y={150 + i * step} delay={at(i) + 1}>
            <div style={{ transform: `translateX(${live ? 14 : 0}px) scale(${live ? 1.18 : 1})` }}>
              <RideToken ride={r} size={124} rotate={i % 2 === 0 ? -6 : 5} />
            </div>
          </Pop>
        );
      })}
    </AbsoluteFill>
  );
};

const CLIMB_BURSTS: Burst[] = [
  [840, 210, 110, C.gold, C.pink, 14],
  [1790, 600, 95, C.pink, C.cream, 12],
  [1210, 620, 80, C.cyan, C.gold, 12],
];

// Stage 4, then a hard cut to stage 51 under the fireworks as FINALE! lands.
const Climb: React.FC<{ len: number }> = ({ len }) => {
  const f = useCurrentFrame();
  const cut = Math.round(len * 0.45);
  return (
    <AbsoluteFill>
      <Sequence durationInFrames={cut}>
        <Drift shot={SHOTS.climb} len={cut} from={1.04} to={1.18} y={[-30, 30]} />
      </Sequence>
      <Sequence from={cut}>
        <Snap>
          <Drift shot={SHOTS.summit} len={len - cut} from={1.06} to={1.2} />
        </Snap>
      </Sequence>
      <Shade dir="to bottom" a={0.6} stop={50} />
      <Bursts list={CLIMB_BURSTS} at={(i) => (f - cut - 2 - i * 5) / 22} />
      <div style={{ position: "absolute", right: 150, top: 140, display: "flex", flexDirection: "column", alignItems: "flex-end" }}>
        <Title text="CLIMB TO THE" size={120} {...cream(120)} wobble={2} enter={2} stagger={1} />
        <Title text="FINALE!" size={230} {...gold(230)} wobble={4} bob={0.02} enter={cut + 1} style={{ marginTop: -8 }} />
      </div>
      <AbsoluteFill style={{ background: C.cream, opacity: f >= cut ? interpolate(f, [cut, cut + 5], [0.7, 0], clamp) : 0 }} />
    </AbsoluteFill>
  );
};

// `pace` < 1 squeezes the entrances for the 6 s cut.
const Dress: React.FC<{ len: number; pace?: number }> = ({ len, pace = 1 }) => {
  const f = useCurrentFrame();
  return (
    <AbsoluteFill style={{ background: C.pink }}>
      <Drift shot={SHOTS.lobby} len={len} from={1.08} to={1.18} filter="saturate(1.2) contrast(1.05) blur(3px)" />
      <Rays a="rgba(255,95,168,0.42)" b="rgba(167,123,255,0.22)" x="68%" y="50%" rays={22} spin={f * 0.8} />
      <Shade dir="to right" a={0.45} stop={45} />
      <Confetti w={W} h={H} n={44} seed={8} t={f} />
      <Pop x={1010} y={170} delay={2} spin={-30}>
        <Polaroid w={600} h={700} rotate={4} />
      </Pop>
      <Stickers enter={Math.round(8 * pace)} gap={4 * pace} />
      <div style={{ position: "absolute", left: 150, top: 170 }}>
        <Title text="DRESS" size={250} {...candy(250)} wobble={3} bob={0.02} enter={3 * pace} />
      </div>
      <div style={{ position: "absolute", left: 210, top: 410 }}>
        <Title text="UP!" size={300} {...gold(300)} wobble={5} bob={0.03} enter={11 * pace} />
      </div>
    </AbsoluteFill>
  );
};

const Banner: React.FC<{ text: string; size: number }> = ({ text, size }) => (
  <div style={{ filter: `drop-shadow(0 8px 0 ${C.navy})` }}>
    <div style={{ background: C.navy, padding: 7, clipPath: "polygon(0 0, 100% 0, 96% 50%, 100% 100%, 0 100%, 4% 50%)" }}>
      <div
        style={{
          background: C.blue,
          clipPath: "polygon(0 0, 100% 0, 96.4% 50%, 100% 100%, 0 100%, 3.6% 50%)",
          padding: `${size * 0.14}px ${size * 1.2}px ${size * 0.12}px`,
          fontFamily: BODY,
          fontWeight: 700,
          fontSize: size,
          color: C.cream,
          letterSpacing: "0.1em",
          whiteSpace: "nowrap",
        }}
      >
        {text}
      </div>
    </div>
  </div>
);

const EndCard: React.FC<{ pace?: number }> = ({ pace = 1 }) => {
  const f = useCurrentFrame();
  const { fps } = useVideoConfig();
  const at = (d: number) => Math.round(d * pace);
  const sub = spring({ frame: f - at(16), fps, config: { damping: 12, stiffness: 150, mass: 0.6 } });
  return (
    <AbsoluteFill style={{ background: `linear-gradient(180deg, ${C.cyan} 0%, ${C.sky} 100%)`, overflow: "hidden" }}>
      <Rays a="rgba(255,255,255,0.2)" b="rgba(255,255,255,0)" y="46%" rays={28} spin={f * 0.5} />
      <div style={{ position: "absolute", left: W - 500, top: 380 }}>
        <FerrisWheel size={500} angle={f * 0.015} t={f} />
      </div>
      <svg width={W} height={H} style={{ position: "absolute", left: 0, top: 0 }}>
        <ellipse cx={W / 2} cy={1300} rx={1500} ry={330} fill={C.grass} stroke={C.navy} strokeWidth={10} />
      </svg>
      <div style={{ position: "absolute", left: 30, top: 650, filter: `drop-shadow(0 12px 0 ${C.navy})` }}>
        <BigTop width={500} />
      </div>
      <div style={{ position: "absolute", left: W - 420, top: 800, filter: `drop-shadow(0 12px 0 ${C.navy})` }}>
        <BigTop width={360} a={C.pink} />
      </div>
      <Confetti w={W} h={H} n={70} seed={13} t={f} fall={4} />
      <Popper x={40} y={H + 20} angle={-60} t={f - 1} seed={3} />
      <Popper x={W - 40} y={H + 20} angle={-120} t={f - 1} seed={4} />
      <Center top={120}>
        <Title text="FUNFAIR" size={270} {...gold(270)} wobble={3} bob={0.02} enter={at(2)} />
        <Title text="FRENZY" size={240} {...candy(240)} wobble={3} bob={0.025} enter={at(7)} style={{ marginTop: -34 }} />
      </Center>
      <div style={{ position: "absolute", left: 0, right: 0, top: 640, display: "flex", justifyContent: "center", transform: `scale(${sub})`, opacity: f >= at(16) ? 1 : 0 }}>
        <Banner text="AMUSEMENT PARK OBBY" size={58} />
      </div>
      <Pop x={W / 2 - 480} y={780} delay={at(24)} spin={8}>
        <Ticket w={960} h={160} color={C.red} stub={0.15} rotate={-2} stubContent={<Star size={62} />}>
          <Title text="PLAY NOW ON ROBLOX" size={66} {...cream(66)} shadow={0.06} />
        </Ticket>
      </Pop>
    </AbsoluteFill>
  );
};

/* --------------------------------------------------------------- cuts */

// 15 s: open gates -> 60 stages -> 6 rides -> climb to the finale -> dress up -> end card
export const Trailer: React.FC = () => {
  const f = useCurrentFrame();
  return (
    <AbsoluteFill style={{ background: C.navy }}>
      <Sequence durationInFrames={60}>
        <Cut flash={false}>
          <Hook len={60} />
        </Cut>
      </Sequence>
      <Sequence from={60} durationInFrames={70}>
        <Cut>
          <Stages len={70} />
        </Cut>
      </Sequence>
      <Sequence from={130} durationInFrames={120}>
        <Cut>
          <Rides len={120} />
        </Cut>
      </Sequence>
      <Sequence from={250} durationInFrames={70}>
        <Cut>
          <Climb len={70} />
        </Cut>
      </Sequence>
      <Sequence from={320} durationInFrames={75}>
        <Cut>
          <Dress len={75} />
        </Cut>
      </Sequence>
      <Sequence from={395} durationInFrames={55}>
        <Cut>
          <EndCard pace={0.7} />
        </Cut>
      </Sequence>
      <Sequence from={312} durationInFrames={16}>
        <Wipe len={16} />
      </Sequence>
      <Sequence from={387} durationInFrames={16}>
        <Wipe len={16} />
      </Sequence>
      <TentBand width={W} t={f} />
      <Frame />
    </AbsoluteFill>
  );
};

// 6 s bumper: hook -> 60 stages -> dress up -> end card
export const Bumper: React.FC = () => {
  const f = useCurrentFrame();
  return (
    <AbsoluteFill style={{ background: C.navy }}>
      <Sequence durationInFrames={48}>
        <Cut flash={false}>
          <Hook len={48} />
        </Cut>
      </Sequence>
      <Sequence from={48} durationInFrames={40}>
        <Cut>
          <Stages len={40} />
        </Cut>
      </Sequence>
      <Sequence from={88} durationInFrames={42}>
        <Cut>
          <Dress len={42} pace={0.6} />
        </Cut>
      </Sequence>
      <Sequence from={130} durationInFrames={50}>
        <Cut>
          <EndCard pace={0.6} />
        </Cut>
      </Sequence>
      <Sequence from={122} durationInFrames={16}>
        <Wipe len={16} />
      </Sequence>
      <TentBand width={W} t={f} />
      <Frame />
    </AbsoluteFill>
  );
};
