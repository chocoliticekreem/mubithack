// 16:9 video ads (Roblox video ads are 16:9; RESEARCH.md). Each scene is one of the static ads, animated
// through its `t` prop (flames flicker, embers rise, jets flow), with a punch-in and flash on every cut.
import React from "react";
import { AbsoluteFill, interpolate, Sequence, spring, useCurrentFrame, useVideoConfig } from "remotion";
import { AdBoom, AdSaveCat, AdSaveThem, AdSquad, AdWhoStarted, Hero, nozzle } from "./Ads";
import { C, Embers, Flames, Jet, Logo, Photo, Ribbon } from "./kit";

export const VID15_FRAMES = 450; // 15 s @ 30 fps
export const VID6_FRAMES = 180; // 6 s

const Punch: React.FC<{ children: (t: number) => React.ReactNode; shake?: number }> = ({ children, shake = 0 }) => {
  const f = useCurrentFrame();
  const { fps } = useVideoConfig();
  const s = spring({ frame: f, fps, config: { damping: 12, stiffness: 160, mass: 0.7 } });
  const scale = interpolate(s, [0, 1], [1.18, 1]) + f * 0.0006;
  const k = Math.max(0, 1 - f / 14) * shake;
  const flash = interpolate(f, [0, 6], [0.8, 0], { extrapolateRight: "clamp" });
  return (
    <AbsoluteFill style={{ overflow: "hidden", background: C.ink }}>
      <AbsoluteFill style={{ transform: `scale(${scale}) translate(${Math.sin(f * 2.3) * k}px, ${Math.cos(f * 2.9) * k}px)` }}>{children(f)}</AbsoluteFill>
      <AbsoluteFill style={{ background: C.fireCore, opacity: flash }} />
    </AbsoluteFill>
  );
};

const EndCard: React.FC = () => {
  const f = useCurrentFrame();
  const { fps } = useVideoConfig();
  const s = spring({ frame: f - 4, fps, config: { damping: 9, stiffness: 170, mass: 0.6 } });
  const [hx, hy, hf] = [120, 600, 360];
  const [nx, ny] = nozzle(hx, hy, hf);
  return (
    <AbsoluteFill style={{ background: C.ink, overflow: "hidden" }}>
      <Photo src="station-dusk" scale={1.1 + f * 0.0008} y={60} filter="saturate(1.3) contrast(1.08) brightness(0.75)" />
      <AbsoluteFill style={{ background: "radial-gradient(ellipse at 50% 35%, rgba(26,18,16,0.1), rgba(26,18,16,0.75) 85%)" }} />
      <div style={{ position: "absolute", left: 0, right: 0, bottom: -14 }}>
        <Flames width={1940} height={260} count={16} seed={2} t={f} outline={9} />
      </div>
      <Embers w={1920} h={1080} n={60} seed={5} t={f} size={2.2} />
      <Jet x0={nx} y0={ny} x1={1500} y1={720} w={60} bend={-0.15} t={f} />
      <Hero x={hx} y={hy} f={hf} />
      <div style={{ position: "absolute", left: 0, right: 0, top: 110, display: "flex", justifyContent: "center", transform: `scale(${interpolate(s, [0, 1], [2.4, 1])})`, opacity: s > 0.02 ? 1 : 0 }}>
        <Logo size={220} />
      </div>
      <div style={{ position: "absolute", left: 0, right: 0, top: 460, display: "flex", justifyContent: "center", opacity: interpolate(f, [18, 24], [0, 1], { extrapolateLeft: "clamp", extrapolateRight: "clamp" }) }}>
        <Ribbon text="CO-OP FIREFIGHTING · UP TO 8 FRIENDS" size={52} bg={C.ink} color={C.hose} />
      </div>
      <AbsoluteFill style={{ boxShadow: `inset 0 0 0 14px ${C.ink}` }} />
    </AbsoluteFill>
  );
};

// 15 s: question hook -> cat -> boom -> blame -> squad -> end card
export const Vid15: React.FC = () => (
  <AbsoluteFill style={{ background: C.ink }}>
    <Sequence from={0} durationInFrames={75}>
      <Punch>{(t) => <AdSaveThem t={t} />}</Punch>
    </Sequence>
    <Sequence from={75} durationInFrames={70}>
      <Punch>{(t) => <AdSaveCat t={t} />}</Punch>
    </Sequence>
    <Sequence from={145} durationInFrames={75}>
      <Punch shake={22}>{(t) => <AdBoom t={t} />}</Punch>
    </Sequence>
    <Sequence from={220} durationInFrames={75}>
      <Punch>{(t) => <AdWhoStarted t={t} />}</Punch>
    </Sequence>
    <Sequence from={295} durationInFrames={65}>
      <Punch>{(t) => <AdSquad t={t} />}</Punch>
    </Sequence>
    <Sequence from={360} durationInFrames={90}>
      <EndCard />
    </Sequence>
  </AbsoluteFill>
);

// 6 s bumper: hook -> boom -> end card
export const Vid6: React.FC = () => (
  <AbsoluteFill style={{ background: C.ink }}>
    <Sequence from={0} durationInFrames={55}>
      <Punch>{(t) => <AdSaveThem t={t} />}</Punch>
    </Sequence>
    <Sequence from={55} durationInFrames={55}>
      <Punch shake={22}>{(t) => <AdBoom t={t} />}</Punch>
    </Sequence>
    <Sequence from={110} durationInFrames={70}>
      <EndCard />
    </Sequence>
  </AbsoluteFill>
);
