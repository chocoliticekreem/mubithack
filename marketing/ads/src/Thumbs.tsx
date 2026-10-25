// Experience-page carousel thumbnails (thumb-01 .. thumb-05), 1920x1080.
// Each shows one real thing in the game: the fantasy, trucks + dispatch, the furnished school,
// the 8-player squad, and the new map's seasons and weather. Built on real in-game shots.
import React from "react";
import { AbsoluteFill } from "remotion";
import { At, Card, Chick, FireFloor, H, HeroFlip, Hook, nozzleFlip, Radio, Rim, W } from "./Ads2";
import { Head, Hero, nozzle } from "./Ads";
import { C, DISPLAY, Embers, Flames, Glow, Jet, Photo, Sticker } from "./kit";

/* 01  BE A FIREFIGHTER!  (real close-up of our penguins + fire) */
export const Thumb01: React.FC = () => {
  const [hx, hy, f] = [1330, 450, 340];
  const [nx, ny] = nozzleFlip(hx, hy, f);
  return (
    <AbsoluteFill style={{ background: C.ink, overflow: "hidden" }}>
      <Photo src="penguin-closeup" scale={1.1} x={-180} y={60} origin="40% 50%" filter="saturate(1.35) contrast(1.08) brightness(0.9)" />
      <AbsoluteFill style={{ background: "linear-gradient(to bottom, rgba(26,18,16,0.7) 0%, rgba(26,18,16,0) 40%, rgba(122,31,16,0.4) 100%)" }} />
      <FireFloor h={300} seed={301} count={14} />
      <Glow x="50%" y="95%" r={55} o={0.8} />
      <Embers w={W} h={H} n={50} seed={301} size={2.2} />
      <Jet x0={nx} y0={ny} x1={900} y1={880} w={60} bend={-0.2} splash={1.3} />
      <HeroFlip x={hx} y={hy} f={f} />
      <Hook top="BE A" main="FIREFIGHTER!" topSize={170} size={215} y={70} />
      <Rim />
    </AbsoluteFill>
  );
};

/* 02  A TRUCK FOR EVERYONE  + dispatch radio */
export const Thumb02: React.FC = () => (
  <AbsoluteFill style={{ background: C.ink, overflow: "hidden" }}>
    <Photo src="station-bays" scale={1.08} y={70} origin="50% 70%" filter="saturate(1.35) contrast(1.08) brightness(0.95)" />
    <AbsoluteFill style={{ background: "linear-gradient(to bottom, rgba(26,18,16,0.85) 0%, rgba(26,18,16,0.2) 40%, rgba(26,18,16,0) 60%)" }} />
    <Hook top="A TRUCK FOR" main="EVERYONE!" topSize={160} size={230} y={60} />
    <At x={1460} y={520} rot={12} shadow={14}>
      <Radio height={400} />
    </At>
    <div style={{ position: "absolute", left: 1150, top: 470, transform: "rotate(-6deg)" }}>
      <Sticker bg="#5FE3F2" pad="4px 26px 0" border={9}>
        <span style={{ fontFamily: DISPLAY, fontSize: 72, color: C.ink, whiteSpace: "nowrap" }}>NEW CALLS!</span>
      </Sticker>
    </div>
    <div style={{ position: "absolute", left: 1640, top: 760 }}>
      <Flames width={300} height={160} count={4} seed={311} outline={8} />
    </div>
    <Rim />
  </AbsoluteFill>
);

/* 03  SCHOOL RESCUE  (real furnished classroom, chick, fire) */
export const Thumb03: React.FC = () => {
  const [hx, hy, f] = [90, 470, 330];
  const [nx, ny] = nozzle(hx, hy, f);
  return (
    <AbsoluteFill style={{ background: "linear-gradient(135deg, #F59A3A 0%, #C8232B 100%)", overflow: "hidden" }}>
      <AbsoluteFill style={{ background: "repeating-linear-gradient(-45deg, rgba(255,255,255,0.06) 0 40px, rgba(255,255,255,0) 40px 80px)" }} />
      <div style={{ position: "absolute", left: 700, top: 310 }}>
        <Flames width={1100} height={260} count={9} seed={321} outline={9} />
      </div>
      <Card src="school-class" x={680} y={400} w={1020} h={600} rot={3} filter="saturate(1.25) contrast(1.05)" />
      <div style={{ position: "absolute", left: 1450, top: 780 }}>
        <Flames width={380} height={260} count={4} seed={322} outline={9} />
      </div>
      <At x={1500} y={400} rot={8} shadow={8}>
        <Chick size={170} bow="#FF6FA8" />
      </At>
      <Embers w={W} h={H} n={40} seed={321} size={2} />
      <Jet x0={nx} y0={ny} x1={1430} y1={880} w={58} bend={-0.18} splash={1.3} />
      <Hero x={hx} y={hy} f={f} />
      <Hook top="SCHOOL" main="RESCUE!" topSize={190} size={240} align="left" x={150} y={60} />
      <Rim />
    </AbsoluteFill>
  );
};

/* 04  8 PLAYER SQUAD  (real station squad shot) */
export const Thumb04: React.FC = () => (
  <AbsoluteFill style={{ background: C.ink, overflow: "hidden" }}>
    <Photo src="station-squad" scale={1.12} y={90} origin="50% 75%" filter="saturate(1.35) contrast(1.08)" />
    <AbsoluteFill style={{ background: "linear-gradient(to bottom, rgba(26,18,16,0.85) 0%, rgba(26,18,16,0.15) 38%, rgba(26,18,16,0) 60%)" }} />
    <div style={{ position: "absolute", left: 0, right: 0, top: 60, display: "flex", justifyContent: "center", alignItems: "center", gap: 30 }}>
      <div style={{ position: "relative", width: 300, height: 300, transform: "rotate(-8deg)" }}>
        <div style={{ position: "absolute", inset: 0, borderRadius: "50%", background: C.red, border: `14px solid ${C.ink}`, boxShadow: `0 14px 0 ${C.ink}` }} />
        <div style={{ position: "absolute", left: 0, right: 0, top: 30, display: "flex", justifyContent: "center", fontFamily: DISPLAY, fontSize: 260, color: C.cream, WebkitTextStroke: `10px ${C.ink}`, lineHeight: 1 }}>8</div>
      </div>
      <div style={{ display: "flex", flexDirection: "column" }}>
        <Head size={150}>PLAYER</Head>
        <Head size={210} fill={C.fireCore} rim={C.fireEdge} style={{ marginTop: -8 }}>
          SQUAD!
        </Head>
      </div>
    </div>
    <div style={{ position: "absolute", left: 1580, top: 820 }}>
      <Flames width={360} height={220} count={4} seed={341} outline={8} />
    </div>
    <Rim />
  </AbsoluteFill>
);

/* 05  NEW MAP!  seasons + weather (real map shots) */
export const Thumb05: React.FC = () => {
  const cards: { src: string; label: string; bg: string; rot: number; f: string }[] = [
    { src: "map-winter", label: "SNOW", bg: "#FFFFFF", rot: -6, f: "saturate(1.3) contrast(1.1)" },
    { src: "map-fog", label: "FOG", bg: "#C9CCD0", rot: 3, f: "saturate(1.3) contrast(1.15)" },
    { src: "map-dusk", label: "SUNSET", bg: C.gold, rot: -3, f: "saturate(1.5) contrast(1.1) brightness(1.6)" },
    { src: "map-night", label: "NIGHT", bg: "#5FE3F2", rot: 6, f: "saturate(1.3) contrast(1.05) brightness(1.4)" },
  ];
  return (
    <AbsoluteFill style={{ background: "linear-gradient(to bottom, #1E7FD8 0%, #63C3F5 100%)", overflow: "hidden" }}>
      <AbsoluteFill style={{ background: "repeating-linear-gradient(90deg, rgba(255,255,255,0.07) 0 60px, rgba(255,255,255,0) 60px 120px)" }} />
      {cards.map((c, i) => (
        <Card key={c.src} src={c.src} x={70 + i * 450} y={350} w={430} h={540} rot={c.rot} filter={c.f} label={c.label} labelBg={c.bg} />
      ))}
      <div style={{ position: "absolute", left: 1560, top: 210 }}>
        <Flames width={260} height={170} count={4} seed={351} outline={8} />
      </div>
      <Hook main="NEW MAP!" size={260} y={60} rot={-2} fill={C.cream} rim={C.red} />
      <Rim />
    </AbsoluteFill>
  );
};

