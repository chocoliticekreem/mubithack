// 512x512 Roblox badge icons for the 10 badge achievements (game/ReplicatedStorage/Config/AchievementConfig
// BadgeIds). Roblox shows badges cropped to a circle, so every one is a round medal: a tier ring, one bold
// subject from the same cartoon kit as the icons, and a short word inside the circle's safe area. The square
// corners repeat the medal colour so the uncropped image still looks finished.
//   sh render.sh badge-first_call ...   (renders to out/), or marketing/badges/render.sh (-> badges/out/<id>.png)
import React from "react";
import { AbsoluteFill } from "remotion";
import { Hero, nozzle } from "./Ads";
import { Chick, Panda } from "./Ads2";
import { Burst, C, Cat, Embers, Face, Flames, Glow, Jet, Outline } from "./kit";
import { Moon, rim, Stars, Stopwatch, TruckFront } from "./kit3";

const S = 512;
const R = 236; // medal radius (the circle crop keeps everything inside 256)

type Ring = "bronze" | "silver" | "gold";
const RING: Record<Ring, [string, string]> = {
  bronze: ["#E59A5B", "#9C5A2A"],
  silver: ["#E6EEF5", "#8D9AA8"],
  gold: ["#FFD54A", "#C98B10"],
};

const Word: React.FC<{ text: string; fill?: string; edge?: string; y?: number; max?: number }> = ({
  text,
  fill = "#FFFFFF",
  edge = C.red,
  y = 360,
  max = 74,
}) => {
  // fit the chord of the circle at this height (LuckiestGuy is ~0.62 em per glyph)
  const half = Math.sqrt(Math.max(0, R * R - (y + 40 - S / 2) ** 2)) - 22;
  const size = Math.min(max, (half * 2) / (text.length * 0.62));
  return (
    <div style={{ position: "absolute", left: 0, right: 0, top: y, display: "flex", justifyContent: "center" }}>
      <Outline size={size} fill={fill} layers={[{ stroke: size * 0.3, color: C.ink }, { stroke: size * 0.16, color: edge }]} shadow={0.08}>
        {text}
      </Outline>
    </div>
  );
};

const Medal: React.FC<{ bg: string; bg2: string; ring: Ring; rays?: [string, string]; children: React.ReactNode }> = ({
  bg,
  bg2,
  ring,
  rays,
  children,
}) => {
  const [hi, lo] = RING[ring];
  return (
    <AbsoluteFill style={{ background: lo }}>
      {/* the ring: ink, metal gradient, ink */}
      <div
        style={{
          position: "absolute",
          left: S / 2 - R - 14,
          top: S / 2 - R - 14,
          width: (R + 14) * 2,
          height: (R + 14) * 2,
          borderRadius: "50%",
          background: `conic-gradient(from 200deg, ${hi}, ${lo}, ${hi}, ${lo}, ${hi})`,
          boxShadow: `inset 0 0 0 8px ${C.ink}`,
        }}
      />
      <div
        style={{
          position: "absolute",
          left: S / 2 - R + 18,
          top: S / 2 - R + 18,
          width: (R - 18) * 2,
          height: (R - 18) * 2,
          borderRadius: "50%",
          overflow: "hidden",
          background: `radial-gradient(circle at 50% 40%, ${bg} 0%, ${bg2} 100%)`,
          boxShadow: `0 0 0 9px ${C.ink}`,
        }}
      >
        {rays ? <Burst a={rays[0]} b={rays[1]} x="50%" y="42%" rays={18} /> : null}
        <div style={{ position: "absolute", left: -(S / 2 - R + 18), top: -(S / 2 - R + 18), width: S, height: S }}>{children}</div>
      </div>
    </AbsoluteFill>
  );
};

const Abs: React.FC<{ x: number; y: number; rot?: number; filter?: string; children: React.ReactNode }> = ({ x, y, rot = 0, filter, children }) => (
  <div style={{ position: "absolute", left: x, top: y, transform: `rotate(${rot}deg)`, filter }}>{children}</div>
);

const pop = `${rim(7, "#FFFFFF")} drop-shadow(0 8px 0 ${C.ink})`;

/* FIRST CALL: the truck coming at you, lights flashing */
export const BadgeFirstCall: React.FC = () => (
  <Medal bg="#FF7A3D" bg2="#C8232B" ring="bronze" rays={["#FF8F4F", "#E04A2E"]}>
    <Abs x={86} y={88} filter={pop}>
      <TruckFront width={340} flash={0.2} />
    </Abs>
    <Word text="FIRST CALL" fill={C.fireCore} edge={C.fireEdge} />
  </Medal>
);

/* FIRST RESCUE: our penguin hero hugging a saved chick */
export const BadgeFirstRescue: React.FC = () => (
  <Medal bg="#7FD8FF" bg2="#1565C0" ring="bronze" rays={["#6CCBFA", "#3E95E0"]}>
    <Abs x={100} y={60} filter={pop}>
      <Face size={250} mood="brave" />
    </Abs>
    <Abs x={262} y={170} rot={10} filter={pop}>
      <Chick size={130} mood="happy" />
    </Abs>
    <Word text="RESCUE!" fill="#FFFFFF" edge="#2FA8FF" />
  </Medal>
);

/* SAVE THE PANDA: the panda, big and safe */
export const BadgeSavePanda: React.FC = () => (
  <Medal bg="#B6F08A" bg2="#3E9B3A" ring="bronze" rays={["#A6E57A", "#6BCB5A"]}>
    <Abs x={106} y={66} filter={pop}>
      <Panda size={300} />
    </Abs>
    <Word text="PANDA!" fill="#FFFFFF" edge="#2E9E44" max={84} />
  </Medal>
);

/* 100 FIRES OUT: a jet of water smashing a wall of fire */
export const BadgeFires100: React.FC = () => (
  <Medal bg="#FFB12B" bg2="#C8232B" ring="silver" rays={["#FFB84D", "#FF7A2E"]}>
    <Abs x={110} y={150}>
      <Flames width={330} height={230} count={5} seed={12} outline={8} />
    </Abs>
    <Glow x="55%" y="55%" r={50} o={0.7} />
    <Jet x0={20} y0={250} x1={170} y1={290} w={40} bend={-0.2} splash={0.9} />
    <Embers w={S} h={S} n={14} seed={12} t={30} size={1.2} />
    <Word text="100" fill={C.fireCore} edge={C.fireEdge} y={86} max={120} />
    <Word text="FIRES OUT" fill="#FFFFFF" edge="#2FA8FF" y={360} />
  </Medal>
);

/* CAT IN A TREE: the cat clinging to a branch in a round green tree */
export const BadgeCatTree: React.FC = () => (
  <Medal bg="#9BE7FF" bg2="#3A9AD9" ring="silver">
    <svg width={S} height={S} style={{ position: "absolute", left: 0, top: 0 }}>
      <rect x={300} y={250} width={56} height={260} fill="#8A5226" stroke={C.ink} strokeWidth={9} />
      <circle cx={330} cy={150} r={130} fill="#4DB34A" stroke={C.ink} strokeWidth={10} />
      <circle cx={210} cy={210} r={90} fill="#5BC556" stroke={C.ink} strokeWidth={10} />
      <circle cx={400} cy={240} r={80} fill="#3FA23D" stroke={C.ink} strokeWidth={10} />
      <path d="M 320 300 L 120 270" stroke={C.ink} strokeWidth={34} strokeLinecap="round" />
      <path d="M 320 300 L 120 270" stroke="#8A5226" strokeWidth={20} strokeLinecap="round" />
    </svg>
    <Abs x={92} y={130} rot={-6} filter={pop}>
      <Cat size={190} />
    </Abs>
    <Word text="MEOW!" fill="#FFFFFF" edge="#E07B1F" max={84} />
  </Medal>
);

/* NIGHT HERO: moon, stars, a glowing penguin spraying in the dark */
export const BadgeNightHero: React.FC = () => {
  const [hx, hy, f] = [40, 150, 190];
  const [nx, ny] = nozzle(hx, hy, f);
  return (
    <Medal bg="#2C3F8F" bg2="#070D2A" ring="silver">
      <Stars w={S} h={300} n={30} seed={81} />
      <Moon size={140} style={{ position: "absolute", left: 300, top: 50 }} />
      <Abs x={310} y={200}>
        <Flames width={170} height={150} count={3} seed={5} outline={7} />
      </Abs>
      <div style={{ position: "absolute", left: 0, top: 0, width: S, height: S, filter: "drop-shadow(0 0 10px #7FF5F0)" }}>
        <Jet x0={nx} y0={ny} x1={380} y1={300} w={32} bend={-0.2} splash={1.1} />
      </div>
      <div style={{ position: "absolute", left: 0, top: 0, width: S, height: S, filter: rim(6, "#7FF5F0") }}>
        <Hero x={hx} y={hy} f={f} glow={false} />
      </div>
      <Word text="NIGHT HERO" fill="#FFF3B8" edge="#5B4BD8" y={372} />
    </Medal>
  );
};

/* SPEED RUN RECORD: a stopwatch with a checkered flag */
export const BadgeSpeedRun: React.FC = () => (
  <Medal bg="#FFE45C" bg2="#FF8A1F" ring="silver" rays={["#FFE070", "#FFB02E"]}>
    <svg width={S} height={S} style={{ position: "absolute", left: 0, top: 0 }}>
      {[0, 1, 2].map((i) => (
        <path key={i} d={`M ${70 - i * 10} ${170 + i * 50} L ${150 - i * 10} ${170 + i * 50}`} stroke={C.ink} strokeWidth={16} strokeLinecap="round" />
      ))}
    </svg>
    <Abs x={150} y={58} rot={12} filter={pop}>
      <Stopwatch size={250} hand={70} />
    </Abs>
    <Word text="RECORD!" fill="#FFFFFF" edge={C.red} />
  </Medal>
);

/* COMBO MASTER: two jets crossing on one fire */
export const BadgeComboMaster: React.FC = () => (
  <Medal bg="#7FF5F0" bg2="#0E6E8C" ring="silver" rays={["#7AE5F0", "#3FB8D8"]}>
    <Abs x={146} y={170}>
      <Flames width={220} height={190} count={4} seed={22} outline={8} />
    </Abs>
    <Glow x="50%" y="62%" r={40} o={0.6} />
    <Jet x0={20} y0={170} x1={170} y1={290} w={36} bend={-0.18} splash={0.8} />
    <Jet x0={492} y0={170} x1={342} y1={290} w={36} bend={0.18} splash={0.8} />
    <Word text="x2" fill={C.fireCore} edge={C.fireEdge} y={60} max={110} />
    <Word text="COMBO!" fill="#FFFFFF" edge="#2FA8FF" y={366} />
  </Medal>
);

/* YEET!: a happy chick flying through the air with speed lines */
export const BadgeYeet: React.FC = () => (
  <Medal bg="#FF9BD0" bg2="#B8327A" ring="bronze" rays={["#FFA8D6", "#E065A6"]}>
    <svg width={S} height={S} style={{ position: "absolute", left: 0, top: 0 }}>
      <path d="M 70 330 Q 160 120 330 110" stroke="#FFFFFF" strokeWidth={14} strokeDasharray="26 22" fill="none" strokeLinecap="round" />
      {[0, 1, 2].map((i) => (
        <path key={i} d={`M ${130 + i * 20} ${250 - i * 40} L ${200 + i * 20} ${215 - i * 40}`} stroke={C.ink} strokeWidth={12} strokeLinecap="round" />
      ))}
    </svg>
    <Abs x={250} y={60} rot={24} filter={pop}>
      <Chick size={190} mood="happy" />
    </Abs>
    <Word text="YEET!" fill={C.fireCore} edge="#E0408A" y={338} max={110} />
  </Medal>
);

/* LEVEL 25: the brave penguin with a big gold star */
export const BadgeLevel25: React.FC = () => (
  <Medal bg="#FFF1A6" bg2="#F0A21E" ring="gold" rays={["#FFE987", "#FFC531"]}>
    <svg width={S} height={S} style={{ position: "absolute", left: 0, top: 0 }}>
      <polygon
        points={Array.from({ length: 10 }, (_, i) => {
          const a = (i / 10) * Math.PI * 2 - Math.PI / 2;
          const r = i % 2 === 0 ? 200 : 92;
          return `${256 + Math.cos(a) * r},${236 + Math.sin(a) * r}`;
        }).join(" ")}
        fill="#FFD54A"
        stroke={C.ink}
        strokeWidth={12}
        strokeLinejoin="round"
      />
    </svg>
    <Abs x={150} y={110} filter={pop}>
      <Face size={210} mood="smug" />
    </Abs>
    <Word text="LEVEL 25" fill="#FFFFFF" edge={C.red} />
  </Medal>
);

export const BADGES: { id: string; component: React.FC }[] = [
  { id: "first_call", component: BadgeFirstCall },
  { id: "first_rescue", component: BadgeFirstRescue },
  { id: "save_panda", component: BadgeSavePanda },
  { id: "fires_100", component: BadgeFires100 },
  { id: "cat_tree", component: BadgeCatTree },
  { id: "night_hero", component: BadgeNightHero },
  { id: "speed_run", component: BadgeSpeedRun },
  { id: "combo_master", component: BadgeComboMaster },
  { id: "yeet", component: BadgeYeet },
  { id: "level_25", component: BadgeLevel25 },
];
