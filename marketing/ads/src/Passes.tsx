// 512x512 store art: the two game passes and the four donation products. Same cartoon kit as the icons.
import React from "react";
import { AbsoluteFill } from "remotion";
import { Burst, C, ChiefHelmet, Embers, Face, Flames, Glow, HoseBody, Jet, Outline, Ribbon, Sticker, Vignette } from "./kit";
import { DISPLAY } from "./theme";

const S = 512;

const Rim: React.FC = () => <AbsoluteFill style={{ boxShadow: `inset 0 0 0 8px ${C.ink}` }} />;

const Title: React.FC<{ size: number; fill?: string; edge?: string; children: React.ReactNode; style?: React.CSSProperties }> = ({
  size,
  fill = C.fireCore,
  edge = C.fireEdge,
  children,
  style,
}) => (
  <Outline size={size} fill={fill} layers={[{ stroke: size * 0.25, color: C.ink }, { stroke: size * 0.13, color: edge }]} style={style}>
    {children}
  </Outline>
);

/* UNLIMITED FOAM: a penguin blasting an endless jet, with a big infinity badge */
export const PassFoam: React.FC = () => (
  <AbsoluteFill style={{ background: C.teal, overflow: "hidden" }}>
    <Burst a="#1E7C86" b={C.teal} x="64%" y="56%" rays={20} />
    <Glow x="66%" y="58%" r={60} color={C.water} o={0.55} />
    <div style={{ position: "absolute", left: 250, top: 300 }}>
      <Flames width={300} height={200} count={4} seed={7} outline={7} />
    </div>
    <Jet x0={250} y0={430} x1={440} y1={380} w={44} bend={-0.14} splash={1.3} />
    <Embers w={S} h={S} n={14} seed={3} t={10} />
    <div style={{ position: "absolute", left: -30, top: 200, filter: `drop-shadow(0 8px 0 ${C.ink})` }}>
      <HoseBody size={300} style={{ position: "absolute", left: 0, top: 168 }} />
      <Face size={250} mood="brave" style={{ position: "absolute", left: 14, top: 0 }} />
    </div>
    <div style={{ position: "absolute", left: 0, right: 0, top: 26, display: "flex", flexDirection: "column", alignItems: "center", transform: "rotate(-4deg)" }}>
      <Title size={70} fill="#FFFFFF" edge="#2FA8FF">UNLIMITED</Title>
      <Title size={96} fill={C.water} edge="#2FA8FF" style={{ marginTop: -14 }}>FOAM</Title>
    </div>
    <div style={{ position: "absolute", right: 24, top: 160, transform: "rotate(10deg) scale(0.85)" }}>
      <Sticker bg={C.gold} pad="0px 22px 4px" border={8}>
        <div style={{ fontFamily: DISPLAY, fontSize: 110, lineHeight: 1, color: C.ink }}>∞</div>
      </Sticker>
    </div>
    <Vignette o={0.3} inner={62} />
    <Rim />
  </AbsoluteFill>
);

/* PREMIUM PASS: the gold Fire Chief helmet on a gold burst */
export const PassPremium: React.FC = () => (
  <AbsoluteFill style={{ background: C.goldDark, overflow: "hidden" }}>
    <Burst a={C.gold} b="#E09A1C" x="50%" y="58%" rays={24} />
    <Glow x="50%" y="56%" r={55} color="#FFF6C8" o={0.8} />
    <Embers w={S} h={S} n={30} seed={11} t={30} size={1.2} />
    <div style={{ position: "absolute", left: 66, top: 176, filter: `drop-shadow(0 10px 0 ${C.ink}) drop-shadow(0 0 26px rgba(255,240,160,0.9))` }}>
      <ChiefHelmet size={380} />
    </div>
    <div style={{ position: "absolute", left: 0, right: 0, top: 30, display: "flex", flexDirection: "column", alignItems: "center", transform: "rotate(-4deg)" }}>
      <Title size={84} fill="#FFFFFF" edge={C.red}>PREMIUM</Title>
      <Title size={84} fill={C.fireCore} edge={C.red} style={{ marginTop: -10 }}>PASS</Title>
    </div>
    <div style={{ position: "absolute", left: 0, right: 0, bottom: 34, display: "flex", justifyContent: "center" }}>
      <Ribbon text="1.5x XP + GOLD LOOT" size={30} />
    </div>
    <Vignette o={0.25} inner={64} />
    <Rim />
  </AbsoluteFill>
);

/* Donation tiers: a grateful penguin, a burst in the tier colour, the amount huge */
const TIERS: Record<string, { a: string; b: string; bg: string; mood: "smug" | "brave" | "shock" | "panic"; flames: number }> = {
  "10": { a: "#E8A06A", b: "#B8683A", bg: "#7A4020", mood: "smug", flames: 0 },
  "50": { a: "#D9DEE6", b: "#9AA3B0", bg: "#5A6270", mood: "brave", flames: 0 },
  "100": { a: C.gold, b: "#E09A1C", bg: C.goldDark, mood: "brave", flames: 3 },
  "500": { a: C.fireBody, b: C.fireEdge, bg: C.fireDark, mood: "shock", flames: 6 },
};

const Donate: React.FC<{ amount: keyof typeof TIERS }> = ({ amount }) => {
  const t = TIERS[amount];
  return (
    <AbsoluteFill style={{ background: t.bg, overflow: "hidden" }}>
      <Burst a={t.a} b={t.b} x="50%" y="62%" rays={22} />
      {t.flames > 0 && (
        <div style={{ position: "absolute", left: -20, top: 300 }}>
          <Flames width={552} height={240} count={t.flames} seed={Number(amount)} outline={7} />
        </div>
      )}
      <Embers w={S} h={S} n={amount === "500" ? 36 : 14} seed={5} t={20} />
      <div style={{ position: "absolute", left: 136, top: 214, filter: `drop-shadow(0 8px 0 ${C.ink})` }}>
        <Face size={240} mood={t.mood} />
      </div>
      <div style={{ position: "absolute", left: 0, right: 0, top: 22, display: "flex", justifyContent: "center", transform: "rotate(-4deg)" }}>
        <Ribbon text="TIP THE CREW" size={34} />
      </div>
      <div style={{ position: "absolute", left: 0, right: 0, top: 86, display: "flex", justifyContent: "center", transform: "rotate(-4deg)" }}>
        <Title size={amount.length > 2 ? 120 : 140} fill="#FFFFFF" edge={C.red}>
          {amount}
        </Title>
      </div>
      <div style={{ position: "absolute", right: 26, bottom: 30, transform: "rotate(8deg)" }}>
        <Sticker bg={C.red} pad="2px 18px" border={7}>
          <div style={{ fontFamily: DISPLAY, fontSize: 40, color: C.cream }}>THANKS!</div>
        </Sticker>
      </div>
      <Vignette o={0.25} inner={64} />
      <Rim />
    </AbsoluteFill>
  );
};

export const Donate10: React.FC = () => <Donate amount="10" />;
export const Donate50: React.FC = () => <Donate amount="50" />;
export const Donate100: React.FC = () => <Donate amount="100" />;
export const Donate500: React.FC = () => <Donate amount="500" />;
