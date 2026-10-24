import React from "react";
import { AbsoluteFill, interpolate, Sequence, spring, useCurrentFrame, useVideoConfig } from "remotion";
import { Burst, Flames, Frame, GoldenAxe, Halftone, Logo, Outline, PenguinFace, Shot, Sticker, WaterArc } from "./art";
import { C, DISPLAY } from "./theme";

export const TRAILER_FRAMES = 420; // 14 s @ 30 fps

const Slam: React.FC<{ children: React.ReactNode; delay?: number; rot?: number; style?: React.CSSProperties }> = ({ children, delay = 0, rot = -4, style }) => {
  const f = useCurrentFrame();
  const { fps } = useVideoConfig();
  const s = spring({ frame: f - delay, fps, config: { damping: 9, stiffness: 180, mass: 0.6 } });
  const scale = interpolate(s, [0, 1], [2.6, 1]);
  const op = interpolate(f - delay, [0, 3], [0, 1], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
  return <div style={{ transform: `scale(${scale}) rotate(${rot * s}deg)`, opacity: op, ...style }}>{children}</div>;
};

const KenBurns: React.FC<{ src: string; len: number; from?: number; to?: number; x?: [number, number]; y?: [number, number]; origin?: string }> = ({
  src,
  len,
  from = 1.05,
  to = 1.2,
  x = [0, 0],
  y = [0, 0],
  origin,
}) => {
  const f = useCurrentFrame();
  const p = f / len;
  return <Shot src={src} scale={from + (to - from) * p} x={x[0] + (x[1] - x[0]) * p} y={y[0] + (y[1] - y[0]) * p} origin={origin} />;
};

const Flash: React.FC = () => {
  const f = useCurrentFrame();
  const o = interpolate(f, [0, 5], [0.85, 0], { extrapolateRight: "clamp" });
  return <AbsoluteFill style={{ background: C.fireCore, opacity: o }} />;
};

const Shake: React.FC<{ children: React.ReactNode; amt?: number }> = ({ children, amt = 8 }) => {
  const f = useCurrentFrame();
  const k = Math.max(0, 1 - f / 12);
  return (
    <AbsoluteFill style={{ transform: `translate(${Math.sin(f * 2.1) * amt * k}px, ${Math.cos(f * 2.7) * amt * k}px)` }}>{children}</AbsoluteFill>
  );
};

const bottomShade = <AbsoluteFill style={{ background: "linear-gradient(to top, rgba(26,18,16,0.85) 0%, rgba(26,18,16,0) 50%)" }} />;
const center: React.CSSProperties = { position: "absolute", left: 0, right: 0, display: "flex", justifyContent: "center" };

const Intro: React.FC = () => {
  const f = useCurrentFrame();
  return (
    <AbsoluteFill style={{ background: C.ink }}>
      <KenBurns src="station-dusk" len={60} from={1.25} to={1.08} y={[60, 70]} />
      <AbsoluteFill style={{ background: "radial-gradient(ellipse at 50% 30%, rgba(26,18,16,0.1), rgba(26,18,16,0.75) 85%)" }} />
      <div style={{ ...center, top: 120 }}>
        <Slam delay={8} rot={-3}>
          <Logo size={230} />
        </Slam>
      </div>
      <div style={{ position: "absolute", left: 0, right: 0, bottom: -10 }}>
        <Flames width={1920} height={240} count={16} seed={2} t={f} outline={8} />
      </div>
    </AbsoluteFill>
  );
};

const WordScene: React.FC<{ src: string; word: string; bg: string; fill: string; len: number; kb?: Partial<React.ComponentProps<typeof KenBurns>>; extra?: React.ReactNode }> = ({
  src,
  word,
  bg,
  fill,
  len,
  kb,
  extra,
}) => (
  <AbsoluteFill style={{ background: C.ink }}>
    <Shake>
      <KenBurns src={src} len={len} {...kb} />
      {bottomShade}
      {extra}
      <div style={{ ...center, bottom: 90 }}>
        <Slam delay={2} rot={-4}>
          <Sticker bg={bg} pad="18px 60px 0">
            <Outline size={220} fill={fill} layers={[{ stroke: 34, color: C.ink }]} shadow={0.05}>
              {word}
            </Outline>
          </Sticker>
        </Slam>
      </div>
    </Shake>
    <Flash />
  </AbsoluteFill>
);

const SprayExtra: React.FC = () => {
  const f = useCurrentFrame();
  const w = interpolate(f, [0, 14], [0, 1], { extrapolateRight: "clamp" });
  return (
    <div style={{ position: "absolute", left: 160, top: 210, clipPath: `inset(-200px ${100 - w * 100}% -200px -200px)` }}>
      <WaterArc width={900} height={360} t={f} />
    </div>
  );
};

const YeetExtra: React.FC = () => {
  const f = useCurrentFrame();
  const x = interpolate(f, [0, 40], [-300, 2100]);
  const y = 520 - Math.sin((f / 40) * Math.PI) * 420;
  return (
    <div style={{ position: "absolute", left: x, top: y, transform: `rotate(${f * 24}deg)`, filter: `drop-shadow(0 10px 0 ${C.ink})` }}>
      <PenguinFace size={260} look={[22, -18, -22, 18]} />
    </div>
  );
};

const BurnScene: React.FC = () => {
  const f = useCurrentFrame();
  return (
    <AbsoluteFill style={{ background: C.ink }}>
      <KenBurns src="house-fire" len={60} from={1.05} to={1.25} y={[90, 110]} origin="50% 60%" />
      <AbsoluteFill style={{ background: "linear-gradient(to bottom, rgba(26,18,16,0.85) 0%, rgba(26,18,16,0) 45%)" }} />
      <div style={{ ...center, top: 50, flexDirection: "column", alignItems: "center" }}>
        <Slam delay={2} rot={0}>
          <Outline size={150} fill={C.cream}>
            HOUSES BURN DOWN
          </Outline>
        </Slam>
        <Slam delay={12} rot={-3}>
          <Sticker bg={C.fireEdge} pad="14px 50px 0" style={{ marginTop: 10 }}>
            <Outline size={130} fill={C.fireCore} layers={[{ stroke: 26, color: C.ink }]} shadow={0.05}>
              FOR REAL
            </Outline>
          </Sticker>
        </Slam>
      </div>
      <div style={{ position: "absolute", left: -40, bottom: -10 }}>
        <Flames width={420} height={300} count={5} seed={7} t={f} outline={8} />
      </div>
      <div style={{ position: "absolute", right: -40, bottom: -10 }}>
        <Flames width={420} height={330} count={5} seed={11} t={f} outline={8} />
      </div>
      <Flash />
    </AbsoluteFill>
  );
};

const SquadScene: React.FC = () => (
  <AbsoluteFill style={{ background: C.ink }}>
    <KenBurns src="station-squad" len={45} from={1.3} to={1.1} y={[-40, -40]} origin="50% 40%" />
    {bottomShade}
    <div style={{ ...center, bottom: 70 }}>
      <Slam delay={2} rot={-3}>
        <Outline size={170} fill={C.hose} layers={[{ stroke: 36, color: C.ink }]}>
          8-PLAYER SQUADS
        </Outline>
      </Slam>
    </div>
    <Flash />
  </AbsoluteFill>
);

const BlameScene: React.FC = () => (
  <AbsoluteFill style={{ background: C.ink }}>
    <KenBurns src="penguin-closeup" len={40} from={1.05} to={1.18} origin="60% 40%" />
    {bottomShade}
    <div style={{ position: "absolute", left: 1260, top: 110 }}>
      <Slam delay={14} rot={8}>
        <Sticker bg={C.red} pad="10px 36px 2px">
          <span style={{ fontFamily: DISPLAY, fontSize: 92, color: C.cream }}>IT WAS HIM!</span>
        </Sticker>
      </Slam>
    </div>
    <div style={{ ...center, bottom: 70 }}>
      <Slam delay={2} rot={-2}>
        <Outline size={150} fill={C.hose} layers={[{ stroke: 34, color: C.ink }]}>
          BLAME YOUR FRIENDS.
        </Outline>
      </Slam>
    </div>
    <Flash />
  </AbsoluteFill>
);

const EndCard: React.FC = () => {
  const f = useCurrentFrame();
  return (
    <AbsoluteFill style={{ background: C.red, overflow: "hidden" }}>
      <Burst a={C.fireBody} b={C.horizon} y="45%" rays={28} spin={f * 0.8} />
      <Halftone opacity={0.12} />
      <div style={{ position: "absolute", left: -60, top: 520, transform: "rotate(-12deg)", filter: `drop-shadow(0 12px 0 ${C.ink})` }}>
        <PenguinFace size={420} look={[18, 8, 4, 10]} />
      </div>
      <div style={{ position: "absolute", right: -40, top: 470, filter: `drop-shadow(0 12px 0 ${C.ink})`, transform: "rotate(10deg)" }}>
        <GoldenAxe size={520} shine={f * 0.3} />
      </div>
      <div style={{ ...center, top: 150 }}>
        <Slam delay={0} rot={-3}>
          <Logo size={240} />
        </Slam>
      </div>
      <div style={{ ...center, bottom: 110 }}>
        <Slam delay={10} rot={2}>
          <Sticker bg={C.hose} pad="12px 54px 0">
            <span style={{ fontFamily: DISPLAY, fontSize: 110, color: C.ink }}>PLAY NOW</span>
          </Sticker>
        </Slam>
      </div>
      <div style={{ position: "absolute", left: 0, right: 0, bottom: -10 }}>
        <Flames width={1920} height={150} count={18} seed={4} t={f} outline={8} />
      </div>
      <Flash />
    </AbsoluteFill>
  );
};

export const Trailer: React.FC = () => (
  <AbsoluteFill style={{ background: C.ink }}>
    <Sequence durationInFrames={60}>
      <Intro />
    </Sequence>
    <Sequence from={60} durationInFrames={40}>
      <WordScene src="truck-fire" word="DRIVE." bg={C.red} fill={C.cream} len={40} kb={{ from: 1.15, to: 1.35, x: [140, -40], origin: "62% 62%" }} />
    </Sequence>
    <Sequence from={100} durationInFrames={40}>
      <WordScene src="house-fire" word="SPRAY." bg={C.water} fill="#fff" len={40} kb={{ from: 1.1, to: 1.25, y: [80, 80] }} extra={<SprayExtra />} />
    </Sequence>
    <Sequence from={140} durationInFrames={45}>
      <WordScene src="station-bays" word="YEET." bg={C.hose} fill={C.fireEdge} len={45} kb={{ from: 1.05, to: 1.2 }} extra={<YeetExtra />} />
    </Sequence>
    <Sequence from={185} durationInFrames={65}>
      <BurnScene />
    </Sequence>
    <Sequence from={250} durationInFrames={50}>
      <SquadScene />
    </Sequence>
    <Sequence from={300} durationInFrames={50}>
      <BlameScene />
    </Sequence>
    <Sequence from={350} durationInFrames={70}>
      <EndCard />
    </Sequence>
    <Frame />
  </AbsoluteFill>
);
