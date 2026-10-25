// Wave 3: six 512x512 icon A/B candidates against icon-final. Each one is a different take on
// "Be a Firefighter", with ONE bold subject, saturated colour, an ink outline plus a white sticker rim,
// and big text or none. Built to read at 150 px and 100 px (Roblox home tiles).
import React from "react";
import { AbsoluteFill } from "remotion";
import { Hero, nozzle } from "./Ads";
import { Chick } from "./Ads2";
import { Burst, C, Embers, Face, Flames, Glow, HoseBody, House, Jet, Outline, Vignette } from "./kit";
import { Moon, rim, Stars, TruckFront } from "./kit3";

const S = 512;

const Edge: React.FC = () => <AbsoluteFill style={{ boxShadow: `inset 0 0 0 8px ${C.ink}` }} />;

const Word: React.FC<{ size: number; fill?: string; edge?: string; children: React.ReactNode; style?: React.CSSProperties }> = ({
  size,
  fill = C.fireCore,
  edge = C.fireEdge,
  children,
  style,
}) => (
  <Outline size={size} fill={fill} layers={[{ stroke: size * 0.26, color: C.ink }, { stroke: size * 0.14, color: edge }]} shadow={0.08} style={style}>
    {children}
  </Outline>
);

/* (face) giant brave penguin face in the red 67 helmet, on blue, fire licking up from the bottom */
export const IconFace: React.FC = () => (
  <AbsoluteFill style={{ background: "radial-gradient(circle at 50% 42%, #55C8FF 0%, #1565C0 62%, #0B2E6E 100%)", overflow: "hidden" }}>
    <Burst a="rgba(255,255,255,0.12)" b="rgba(255,255,255,0)" x="50%" y="45%" rays={20} />
    <div style={{ position: "absolute", left: -20, top: 330 }}>
      <Flames width={552} height={200} count={6} seed={31} outline={7} />
    </div>
    <Glow x="50%" y="100%" r={50} o={0.8} />
    <div style={{ position: "absolute", left: 22, top: 14, filter: rim(9, "#FFFFFF", 10) }}>
      <Face size={468} mood="brave" look={[4, 8, 2, 8]} />
    </div>
    <Embers w={S} h={S} n={16} seed={31} t={20} size={1.3} />
    <Edge />
  </AbsoluteFill>
);

/* (spray) penguin blasting a huge wall of fire: hot fire on deep blue */
export const IconSpray: React.FC = () => {
  const [hx, hy, f] = [-30, 196, 290];
  const [nx, ny] = nozzle(hx, hy, f);
  return (
    <AbsoluteFill style={{ background: "linear-gradient(160deg, #0B2E6E 0%, #1565C0 100%)", overflow: "hidden" }}>
      <div style={{ position: "absolute", left: 150, top: 20 }}>
        <Flames width={420} height={500} count={5} seed={41} outline={8} />
      </div>
      <Glow x="72%" y="60%" r={55} o={0.9} />
      <Embers w={S} h={S} n={26} seed={41} t={40} size={1.5} />
      <Jet x0={nx} y0={ny} x1={420} y1={230} w={52} bend={-0.18} splash={1.25} />
      <div style={{ position: "absolute", left: 0, top: 0, width: S, height: S, filter: rim(7, "#FFFFFF") }}>
        <Hero x={hx} y={hy} f={f} glow={false} />
      </div>
      <Vignette o={0.3} inner={65} />
      <Edge />
    </AbsoluteFill>
  );
};

/* (truck) head-on fire truck, penguin driver, sirens on a yellow burst */
export const IconTruck: React.FC = () => (
  <AbsoluteFill style={{ background: C.gold, overflow: "hidden" }}>
    <Burst a="#FFD54A" b="#F39A1E" x="50%" y="46%" rays={22} />
    <div style={{ position: "absolute", left: -30, top: 330 }}>
      <Flames width={572} height={200} count={7} seed={51} outline={7} />
    </div>
    <div style={{ position: "absolute", left: 20, top: 40, filter: rim(8, "#FFFFFF", 10) }}>
      <TruckFront width={472} mood="brave" />
    </div>
    <Edge />
  </AbsoluteFill>
);

/* (word) BE A / FIRE / FIGHTER! : the core fantasy in three huge words over a fire */
export const IconWord: React.FC = () => (
  <AbsoluteFill style={{ background: "linear-gradient(to bottom, #2A0A10 0%, #8E1219 55%, #C8232B 100%)", overflow: "hidden" }}>
    <div style={{ position: "absolute", left: -30, top: 230 }}>
      <Flames width={572} height={300} count={6} seed={61} outline={8} />
    </div>
    <Glow x="50%" y="85%" r={60} o={0.8} />
    <Embers w={S} h={S} n={24} seed={61} t={10} size={1.4} />
    <div style={{ position: "absolute", left: 0, right: 0, top: 44, display: "flex", flexDirection: "column", alignItems: "center", transform: "rotate(-4deg)" }}>
      <Word size={96} fill="#FFFFFF" edge={C.red}>
        BE A
      </Word>
      <Word size={178} style={{ marginTop: -14 }}>
        FIRE
      </Word>
      <Word size={108} fill="#FFFFFF" edge="#1E88E5" style={{ marginTop: -12 }}>
        FIGHTER!
      </Word>
    </div>
    <Edge />
  </AbsoluteFill>
);

/* (rescue) penguin carrying a happy kid chick out of the flames */
export const IconRescue: React.FC = () => (
  <AbsoluteFill style={{ background: "radial-gradient(circle at 50% 40%, #FFB12B 0%, #FF5A1F 45%, #7A1F10 100%)", overflow: "hidden" }}>
    <div style={{ position: "absolute", left: -40, top: 150 }}>
      <Flames width={592} height={380} count={7} seed={71} outline={8} />
    </div>
    <Embers w={S} h={S} n={24} seed={71} t={30} size={1.4} />
    <div style={{ position: "absolute", left: 0, top: 0, width: S, height: S, filter: rim(8, "#FFFFFF", 10) }}>
      <HoseBody size={330} carry style={{ position: "absolute", left: 100, top: 248 }} />
      <Face size={270} mood="brave" look={[18, 14, 16, 14]} style={{ position: "absolute", left: 6, top: 14 }} />
      <div style={{ position: "absolute", left: 236, top: 200, transform: "rotate(10deg)" }}>
        <Chick size={250} mood="happy" bow="#FF6FA8" />
      </div>
    </div>
    <Edge />
  </AbsoluteFill>
);

/* (night) night fire: navy sky, moon, burning house, a glowing hose jet */
export const IconNight: React.FC = () => {
  const [hx, hy, f] = [-10, 268, 214];
  const [nx, ny] = nozzle(hx, hy, f);
  return (
    <AbsoluteFill style={{ background: "linear-gradient(to bottom, #050B24 0%, #13235A 70%, #2A1A4A 100%)", overflow: "hidden" }}>
      <Stars w={S} h={300} n={30} seed={81} />
      <Moon size={150} style={{ position: "absolute", left: 20, top: 16 }} />
      <Glow x="68%" y="52%" r={55} o={0.95} />
      <div style={{ position: "absolute", left: 186, top: 40 }}>
        <Flames width={330} height={250} count={5} seed={82} outline={8} />
      </div>
      <div style={{ position: "absolute", left: 206, top: 176, filter: `drop-shadow(0 6px 0 ${C.ink})` }}>
        <House width={300} wall="#C9A27A" roof="#3A2030" />
      </div>
      <Embers w={S} h={S} n={30} seed={82} t={60} size={1.4} />
      <div style={{ position: "absolute", left: 0, top: 0, width: S, height: S, filter: "drop-shadow(0 0 10px #7FF5F0) drop-shadow(0 0 22px #3FC8FF)" }}>
        <Jet x0={nx} y0={ny} x1={360} y1={290} w={38} bend={-0.2} splash={1.2} />
      </div>
      <div style={{ position: "absolute", left: 0, top: 0, width: S, height: S, filter: `${rim(6, "#7FF5F0")} drop-shadow(8px -4px 16px rgba(255,140,30,0.9))` }}>
        <Hero x={hx} y={hy} f={f} glow={false} />
      </div>
      <Edge />
    </AbsoluteFill>
  );
};
