// 512x512 store art: the two game passes and the four donation products. Same cartoon kit as the icons.
import React from "react";
import { AbsoluteFill } from "remotion";
import { Burst, C, ChiefHelmet, Embers, Face, Flames, Glow, HoseBody, House, Jet, Outline, Ribbon, Sticker, Vignette } from "./kit";
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

/* FIRE HELICOPTER: a penguin flying a red Station 67 chopper, bambi bucket dumping water on a burning house */
// Chopper art lives in a 500x320 box facing right; the penguin sits in the bubble (300..450, 84..214).
const BUBBLE = "M 300 88 Q 404 80 452 158 Q 466 196 446 214 L 300 214 Z";

const ChopperBack: React.FC = () => {
  const ink = C.ink;
  return (
    <svg width={500} height={320} viewBox="0 0 500 320" style={{ position: "absolute", left: 0, top: 0, overflow: "visible" }}>
      {/* tail boom + fin */}
      <path d="M 30 144 L 196 140 L 204 200 L 36 174 Z" fill={C.red} stroke={ink} strokeWidth={12} strokeLinejoin="round" />
      <path d="M 44 156 L 192 156" stroke={C.cream} strokeWidth={10} strokeLinecap="round" />
      <path d="M 6 84 L 50 90 L 66 176 L 24 180 Q 6 130 6 84 Z" fill={C.red} stroke={ink} strokeWidth={12} strokeLinejoin="round" />
      {/* tail rotor blur */}
      <circle cx={34} cy={140} r={40} fill="#FFFFFF" opacity={0.6} stroke={ink} strokeWidth={7} />
      <path d="M 34 102 L 34 178" stroke={ink} strokeWidth={10} strokeLinecap="round" />
      <circle cx={34} cy={140} r={10} fill="#C9CCD0" stroke={ink} strokeWidth={6} />
      {/* skids */}
      <path d="M 236 262 L 222 302 M 390 262 L 404 302" stroke={ink} strokeWidth={14} strokeLinecap="round" />
      <path d="M 170 304 L 440 304 Q 470 304 478 282" stroke={ink} strokeWidth={26} fill="none" strokeLinecap="round" />
      <path d="M 170 304 L 440 304 Q 470 304 478 282" stroke="#C9CCD0" strokeWidth={12} fill="none" strokeLinecap="round" />
      {/* body */}
      <path
        d="M 172 160 Q 182 80 300 74 Q 424 70 466 158 Q 494 230 444 258 Q 404 278 300 276 L 222 274 Q 160 266 166 214 Z"
        fill={C.red}
        stroke={ink}
        strokeWidth={14}
        strokeLinejoin="round"
      />
      <path d="M 196 140 Q 226 100 290 92" stroke="#FF8A8A" strokeWidth={12} fill="none" strokeLinecap="round" opacity={0.75} />
      {/* rotor mast */}
      <rect x={284} y={44} width={32} height={36} rx={6} fill="#6E7480" stroke={ink} strokeWidth={9} />
      {/* cockpit glass */}
      <path d={BUBBLE} fill={C.water} />
    </svg>
  );
};

const ChopperFront: React.FC = () => {
  const ink = C.ink;
  return (
    <svg width={500} height={320} viewBox="0 0 500 320" style={{ position: "absolute", left: 0, top: 0, overflow: "visible" }}>
      <path d={BUBBLE} fill="none" stroke={ink} strokeWidth={12} strokeLinejoin="round" />
      <path d="M 330 100 Q 380 98 414 124" stroke="#FFFFFF" strokeWidth={10} fill="none" strokeLinecap="round" opacity={0.85} />
      {/* white stripe across the belly */}
      <path d="M 166 214 Q 316 236 478 206 L 474 236 Q 316 262 172 244 Z" fill={C.cream} stroke={ink} strokeWidth={10} strokeLinejoin="round" />
      {/* 67 */}
      <text x={236} y={196} textAnchor="middle" fontFamily={DISPLAY} fontSize={78} fill={C.cream} stroke={ink} strokeWidth={14} paintOrder="stroke" strokeLinejoin="round">
        67
      </text>
      {/* main rotor: motion-blur disc + blade */}
      <ellipse cx={300} cy={40} rx={290} ry={26} fill="#FFFFFF" opacity={0.55} stroke={ink} strokeWidth={8} />
      <ellipse cx={300} cy={40} rx={200} ry={15} fill="#FFFFFF" opacity={0.6} />
      <path d="M 40 50 L 560 30" stroke={ink} strokeWidth={20} strokeLinecap="round" />
      <path d="M 40 50 L 560 30" stroke="#4A505C" strokeWidth={8} strokeLinecap="round" />
      <circle cx={300} cy={40} r={18} fill={C.red} stroke={ink} strokeWidth={9} />
    </svg>
  );
};

const Chopper: React.FC<{ x: number; y: number; k: number; rot?: number }> = ({ x, y, k, rot = 0 }) => (
  <div
    style={{
      position: "absolute",
      left: x,
      top: y,
      width: 500,
      height: 320,
      transform: `rotate(${rot}deg) scale(${k})`,
      transformOrigin: "0 0",
      filter: `drop-shadow(0 10px 0 ${C.ink})`,
    }}
  >
    <ChopperBack />
    <div style={{ position: "absolute", left: 0, top: 0, width: 500, height: 320, clipPath: `path("${BUBBLE}")` }}>
      <Face size={150} mood="brave" look={[20, 8, 18, 8]} style={{ position: "absolute", left: 306, top: 64 }} />
    </div>
    <ChopperFront />
  </div>
);

// Bambi bucket on a rope, tipped open, water gushing down onto the roof. Screen coords.
const Bucket: React.FC<{ hx: number; hy: number; wy: number }> = ({ hx, hy, wy }) => {
  const ink = C.ink;
  const by = hy + 26; // bucket rim
  const drops: [number, number, number][] = [
    [hx - 78, wy - 4, 13], [hx - 56, wy - 30, 9], [hx + 78, wy - 6, 13], [hx + 58, wy - 32, 9], [hx - 96, wy + 22, 9], [hx + 98, wy + 20, 9],
  ];
  return (
    <svg width={S} height={S} viewBox={`0 0 ${S} ${S}`} style={{ position: "absolute", left: 0, top: 0, overflow: "visible" }}>
      {/* rope */}
      <path d={`M ${hx} ${hy - 24} L ${hx} ${hy}`} stroke={ink} strokeWidth={9} strokeLinecap="round" />
      <path d={`M ${hx} ${hy} L ${hx - 38} ${by} M ${hx} ${hy} L ${hx + 38} ${by}`} stroke={ink} strokeWidth={6} strokeLinecap="round" />
      {/* water stream */}
      <path
        d={`M ${hx - 24} ${by + 34} Q ${hx - 36} ${wy - 30} ${hx - 70} ${wy} L ${hx + 70} ${wy} Q ${hx + 36} ${wy - 30} ${hx + 24} ${by + 34} Z`}
        fill={C.water}
        stroke={ink}
        strokeWidth={9}
        strokeLinejoin="round"
      />
      <path d={`M ${hx - 6} ${by + 36} Q ${hx - 10} ${wy - 26} ${hx - 26} ${wy - 6}`} stroke="#FFFFFF" strokeWidth={8} fill="none" strokeLinecap="round" />
      <path d={`M ${hx + 12} ${by + 40} Q ${hx + 14} ${wy - 30} ${hx + 30} ${wy - 10}`} stroke="#FFFFFF" strokeWidth={5} fill="none" strokeLinecap="round" opacity={0.8} />
      {/* bucket */}
      <path d={`M ${hx - 40} ${by} L ${hx + 40} ${by} L ${hx + 26} ${by + 40} L ${hx - 26} ${by + 40} Z`} fill={C.red} stroke={ink} strokeWidth={9} strokeLinejoin="round" />
      <path d={`M ${hx - 34} ${by + 16} L ${hx + 34} ${by + 16}`} stroke={C.cream} strokeWidth={9} />
      <ellipse cx={hx} cy={by} rx={42} ry={10} fill="#6E7480" stroke={ink} strokeWidth={8} />
      {/* splash on the roof */}
      <ellipse cx={hx} cy={wy + 2} rx={64} ry={16} fill="#FFFFFF" stroke={ink} strokeWidth={8} />
      <ellipse cx={hx} cy={wy} rx={40} ry={8} fill={C.water} />
      {drops.map(([x, y, r], i) => (
        <circle key={i} cx={x} cy={y} r={r} fill={i % 2 ? "#FFFFFF" : C.water} stroke={ink} strokeWidth={5} />
      ))}
    </svg>
  );
};

export const PassHeli: React.FC = () => {
  const hx = 90;
  const hy = 82;
  const k = 0.64;
  const bx = hx + 300 * k; // bucket hangs under the rotor mast
  return (
    <AbsoluteFill style={{ background: "#2F8FCC", overflow: "hidden" }}>
      <Burst a="#86D6F8" b="#5BB9EC" x="55%" y="45%" rays={22} />
      <Glow x="56%" y="98%" r={46} color="255,140,30" o={0.9} />
      {/* burning house at the bottom */}
      <div style={{ position: "absolute", left: bx - 115, top: 386, filter: `drop-shadow(0 6px 0 ${C.ink})` }}>
        <House width={230} roof="#8A4630" />
      </div>
      <div style={{ position: "absolute", left: bx - 160, top: 392 }}>
        <Flames width={100} height={84} count={3} seed={4} outline={6} />
      </div>
      <div style={{ position: "absolute", left: bx + 62, top: 388 }}>
        <Flames width={100} height={88} count={3} seed={8} outline={6} />
      </div>
      <Embers w={S} h={S} n={12} seed={9} t={12} />
      <Bucket hx={bx} hy={hy + 304 * k + 18} wy={410} />
      <Chopper x={hx} y={hy} k={k} />
      <div style={{ position: "absolute", left: 0, right: 0, top: 20, display: "flex", justifyContent: "center", gap: 14, transform: "rotate(-4deg)" }}>
        <Title size={70} fill={C.fireCore} edge={C.fireEdge}>FIRE</Title>
        <Title size={70} fill="#FFFFFF" edge={C.red}>HELI</Title>
      </div>
      <Vignette o={0.25} inner={64} />
      <Rim />
    </AbsoluteFill>
  );
};

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
