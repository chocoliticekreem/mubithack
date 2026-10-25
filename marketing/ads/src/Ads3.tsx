// Wave 3: ten sponsored-ad creatives (ad-24 .. ad-33), 1920x1080, each testing an angle waves 1-2 did not:
// friends, comedy, mystery, the NEW update tags, a time challenge, a pet close-up, a head-on truck, night,
// and two "bolder" variants (a giant screaming face, a single-word plea). Same rules as Ads2.tsx:
// one focal subject, 1-4 big words at the top, fire in frame, nothing important in the bottom 20%.
import React from "react";
import { AbsoluteFill } from "remotion";
import { Head, Hero, nozzle } from "./Ads";
import { At, Chick, FireFloor, Hook, HeroFlip, nozzleFlip, Radio, Rim } from "./Ads2";
import { Burst, C, DISPLAY, Embers, Face, Flames, Glow, Halftone, House, Jet, Smoke, Vignette } from "./kit";
import { Moon, Puppy, rim, Stars, Stopwatch, TruckFront } from "./kit3";

const W = 1920;
const H = 1080;

/* ------------------------------------------------------------ local art */

// A house that is NOT on fire (blue, calm, getting soaked). viewBox 400x380.
const CalmHouse: React.FC<{ width: number }> = ({ width }) => {
  const ink = C.ink;
  const win = (x: number) => (
    <g key={x}>
      <rect x={x} y={220} width={90} height={70} rx={6} fill="#BFEFFF" stroke={ink} strokeWidth={9} />
      <line x1={x + 45} y1={220} x2={x + 45} y2={290} stroke={ink} strokeWidth={6} />
      <path d={`M ${x - 10} 214 L ${x + 100} 214 L ${x + 92} 236 L ${x - 2} 236 Z`} fill="#F7F7F7" stroke={ink} strokeWidth={6} />
    </g>
  );
  return (
    <svg width={width} height={(width * 380) / 400} viewBox="0 0 400 380" style={{ overflow: "visible" }}>
      <rect x={40} y={150} width={320} height={230} fill="#8FD0F5" stroke={ink} strokeWidth={12} />
      <path d="M 10 160 L 200 30 L 390 160 Z" fill="#2F6FB0" stroke={ink} strokeWidth={12} strokeLinejoin="round" />
      {win(80)}
      {win(232)}
      <rect x={168} y={300} width={64} height={80} rx={6} fill="#F6C440" stroke={ink} strokeWidth={9} />
      {/* drips running down the wet wall */}
      {[70, 130, 300, 340].map((x, i) => (
        <path key={x} d={`M ${x} 160 L ${x} ${200 + i * 26} Q ${x + 8} ${214 + i * 26} ${x} ${222 + i * 26} Q ${x - 8} ${214 + i * 26} ${x} ${200 + i * 26}`} stroke="#fff" strokeWidth={8} fill="#fff" opacity={0.85} />
      ))}
    </svg>
  );
};

// A big burning window seen close up: brick wall, fire licking out of the top, dark inside. viewBox 900x700.
const BigWindow: React.FC<{ width: number; children?: React.ReactNode; inside?: string }> = ({ width, children, inside = "#120A12" }) => {
  const ink = C.ink;
  const s = width / 900;
  return (
    <div style={{ position: "relative", width, height: 700 * s }}>
      <svg width={width} height={700 * s} viewBox="0 0 900 700" style={{ position: "absolute", left: 0, top: 0, overflow: "visible" }}>
        <rect x={0} y={0} width={900} height={700} fill="#8E3A2A" stroke={ink} strokeWidth={16} />
        {Array.from({ length: 9 }, (_, r) => (
          <line key={r} x1={0} y1={70 + r * 72} x2={900} y2={70 + r * 72} stroke="#6E2A1E" strokeWidth={8} />
        ))}
        <rect x={130} y={120} width={640} height={500} rx={12} fill={inside} stroke={ink} strokeWidth={18} />
      </svg>
      <div style={{ position: "absolute", left: 140 * s, top: 130 * s, width: 620 * s, height: 480 * s, overflow: "hidden" }}>{children}</div>
      <svg width={width} height={700 * s} viewBox="0 0 900 700" style={{ position: "absolute", left: 0, top: 0, overflow: "visible" }}>
        <rect x={100} y={610} width={700} height={40} rx={8} fill="#D9C2A0" stroke={ink} strokeWidth={12} />
      </svg>
    </div>
  );
};

/* ======================================================================= ADS */

/* 24  PLAY WITH FRIENDS!  two penguins, two jets, one big fire */
export const Ad24: React.FC = () => {
  const f = 360;
  const [lx, ly] = [40, 420];
  const [rx, ry] = [1520, 420];
  const [n1x, n1y] = nozzle(lx, ly, f);
  const [n2x, n2y] = nozzleFlip(rx, ry, f);
  return (
    <AbsoluteFill style={{ background: "linear-gradient(to bottom, #1E7FD8 0%, #63C3F5 70%, #BFEFFF 100%)", overflow: "hidden" }}>
      <Burst a="rgba(255,255,255,0.12)" b="rgba(255,255,255,0)" x="50%" y="75%" rays={28} />
      <div style={{ position: "absolute", left: 540, top: 430 }}>
        <Flames width={840} height={600} count={7} seed={241} outline={10} />
      </div>
      <Glow x="50%" y="85%" r={40} o={0.8} />
      <Embers w={W} h={H} n={50} seed={241} size={2.4} />
      <Jet x0={n1x} y0={n1y} x1={900} y1={690} w={70} bend={-0.2} splash={1.4} />
      <Jet x0={n2x} y0={n2y} x1={1030} y1={680} w={70} bend={0.2} splash={1.4} />
      <AbsoluteFill style={{ filter: rim(10, "#FFFFFF") }}>
        <Hero x={lx} y={ly} f={f} glow={false} />
        <HeroFlip x={rx} y={ry} f={f} />
      </AbsoluteFill>
      <Hook top="PLAY WITH" main="FRIENDS!" topSize={170} size={270} y={60} rot={-2} />
      <Rim />
    </AbsoluteFill>
  );
};

/* 25  OOPS! WRONG HOUSE!  proud penguin soaking the calm house; the real fire is next door */
export const Ad25: React.FC = () => {
  const [hx, hy, f] = [40, 450, 380];
  const [nx, ny] = nozzle(hx, hy, f);
  return (
    <AbsoluteFill style={{ background: "linear-gradient(to bottom, #FFD54A 0%, #FFB12B 60%, #F59A3A 100%)", overflow: "hidden" }}>
      <Burst a="rgba(255,255,255,0.18)" b="rgba(255,255,255,0)" x="45%" y="70%" rays={26} />
      <div style={{ position: "absolute", left: 0, right: 0, bottom: 0, height: 150, background: "#5BB04A", borderTop: `12px solid ${C.ink}` }} />
      {/* the real fire, next door */}
      <div style={{ position: "absolute", left: 1330, top: 300 }}>
        <Flames width={620} height={420} count={6} seed={251} outline={9} />
      </div>
      <At x={1380} y={470} shadow={14}>
        <House width={540} />
      </At>
      <Glow x="85%" y="60%" r={35} o={0.7} />
      {/* the wrong house, soaked */}
      <At x={620} y={420} shadow={14}>
        <CalmHouse width={600} />
      </At>
      <Jet x0={nx} y0={ny} x1={880} y1={640} w={70} bend={-0.2} splash={1.6} />
      <Hero x={hx} y={hy} f={f} mood="smug" glow={false} />
      <Embers w={W} h={H} n={30} seed={251} size={2} />
      <div style={{ position: "absolute", left: 0, right: 0, top: 50, display: "flex", flexDirection: "column", alignItems: "center", transform: "rotate(-3deg)" }}>
        <Head size={250} fill="#FFFFFF" rim="#FF2E4D">
          OOPS!
        </Head>
        <Head size={170} fill={C.cream} rim={C.red} style={{ marginTop: -14 }}>
          WRONG HOUSE!
        </Head>
      </div>
      <Rim />
    </AbsoluteFill>
  );
};

/* 26  WHO'S INSIDE?  mystery: glowing eyes in a dark burning window */
export const Ad26: React.FC = () => (
  <AbsoluteFill style={{ background: "radial-gradient(circle at 60% 60%, #2A1A4A 0%, #0A0612 80%)", overflow: "hidden" }}>
    <Smoke w={1300} h={420} seed={261} color="#2A2230" o={0.95} style={{ position: "absolute", left: 600, top: -100 }} />
    <div style={{ position: "absolute", left: 620, top: 250 }}>
      <Flames width={1200} height={300} count={9} seed={262} outline={10} />
    </div>
    <At x={760} y={420} shadow={16}>
      <BigWindow width={1000}>
        <AbsoluteFill style={{ background: "radial-gradient(circle at 50% 60%, #3A1E2A 0%, #0A0610 75%)" }}>
          {/* two pairs of glowing eyes in the dark */}
          <svg width={700} height={540} viewBox="0 0 700 540" style={{ position: "absolute", left: 0, top: 0 }}>
            {[
              [230, 220, 1],
              [470, 300, 0.75],
            ].map(([x, y, k], i) => (
              <g key={i} style={{ filter: "drop-shadow(0 0 18px #FFF6A0)" }}>
                <ellipse cx={x - 50 * k} cy={y} rx={40 * k} ry={52 * k} fill="#FFF6A0" />
                <ellipse cx={x + 50 * k} cy={y} rx={40 * k} ry={52 * k} fill="#FFF6A0" />
                <circle cx={x - 46 * k} cy={y + 10 * k} r={18 * k} fill={C.ink} />
                <circle cx={x + 54 * k} cy={y + 10 * k} r={18 * k} fill={C.ink} />
              </g>
            ))}
          </svg>
        </AbsoluteFill>
      </BigWindow>
    </At>
    <Glow x="66%" y="38%" r={35} o={0.8} />
    <Embers w={W} h={H} n={50} seed={261} size={2.2} />
    <At x={110} y={440} rot={-6} shadow={14} style={{ filter: rim(10, "#FFFFFF", 14) }}>
      <Face size={540} mood="shock" look={[26, -4, 26, -4]} />
    </At>
    <Hook main="WHO'S INSIDE?" size={250} fill="#FFFFFF" rim="#7E3FD8" y={70} rot={-2} />
    <Rim />
  </AbsoluteFill>
);

/* 27  NEW! DISPATCH RADIO  the update tag, a giant buzzing radio */
export const Ad27: React.FC = () => (
  <AbsoluteFill style={{ background: "radial-gradient(circle at 55% 62%, #FF7AB8 0%, #C8235F 55%, #5A0E3A 100%)", overflow: "hidden" }}>
    <Burst a="rgba(255,255,255,0.12)" b="rgba(255,255,255,0)" x="52%" y="64%" rays={26} />
    <At x={1360} y={590} shadow={14}>
      <House width={430} />
    </At>
    <div style={{ position: "absolute", left: 1320, top: 480 }}>
      <Flames width={520} height={280} count={6} seed={271} outline={9} />
    </div>
    <svg width={W} height={H} style={{ position: "absolute", left: 0, top: 0 }}>
      {[0, 1, 2].map((i) => (
        <g key={i}>
          <path d={`M ${1150 + i * 70} ${440 - i * 40} Q ${1230 + i * 90} ${600} ${1150 + i * 70} ${760 + i * 40}`} stroke={C.ink} strokeWidth={36} fill="none" strokeLinecap="round" />
          <path d={`M ${1150 + i * 70} ${440 - i * 40} Q ${1230 + i * 90} ${600} ${1150 + i * 70} ${760 + i * 40}`} stroke={C.fireCore} strokeWidth={20} fill="none" strokeLinecap="round" />
          <path d={`M ${770 - i * 70} ${440 - i * 40} Q ${690 - i * 90} ${600} ${770 - i * 70} ${760 + i * 40}`} stroke={C.ink} strokeWidth={36} fill="none" strokeLinecap="round" />
          <path d={`M ${770 - i * 70} ${440 - i * 40} Q ${690 - i * 90} ${600} ${770 - i * 70} ${760 + i * 40}`} stroke={C.fireCore} strokeWidth={20} fill="none" strokeLinecap="round" />
        </g>
      ))}
    </svg>
    <At x={790} y={330} rot={-8} shadow={18} style={{ filter: rim(10, "#FFFFFF", 16) }}>
      <Radio height={700} />
    </At>
    <At x={110} y={500} rot={-6} shadow={14}>
      <Face size={440} mood="shock" look={[28, 0, 28, 0]} />
    </At>
    <Embers w={W} h={H} n={30} seed={271} size={2} />
    <Hook top="NEW!" main="DISPATCH RADIO!" topSize={170} size={190} topFill={C.fireCore} topRim={C.fireEdge} fill="#FFFFFF" rim="#FF2E4D" y={40} rot={-2} />
    <Rim />
  </AbsoluteFill>
);

/* 28  BEAT THE CLOCK!  a giant stopwatch on fire, panicking penguin */
export const Ad28: React.FC = () => (
  <AbsoluteFill style={{ background: "radial-gradient(circle at 35% 60%, #FFE27A 0%, #FF9A2B 45%, #C8232B 100%)", overflow: "hidden" }}>
    <Burst a="rgba(255,255,255,0.16)" b="rgba(255,255,255,0)" x="35%" y="62%" rays={30} />
    <div style={{ position: "absolute", left: 170, top: 250 }}>
      <Flames width={560} height={260} count={5} seed={281} outline={9} />
    </div>
    <At x={170} y={330} rot={-10} shadow={18} style={{ filter: rim(10, "#FFFFFF", 16) }}>
      <Stopwatch size={600} hand={290} />
    </At>
    {/* speed puffs behind the running penguin */}
    <svg width={W} height={H} style={{ position: "absolute", left: 0, top: 0 }}>
      {[0, 1, 2, 3].map((i) => (
        <rect key={i} x={980 + i * 30} y={520 + i * 70} width={260 - i * 40} height={22} rx={11} fill="#fff" opacity={0.8} stroke={C.ink} strokeWidth={5} />
      ))}
    </svg>
    <At x={1240} y={420} rot={8} shadow={14}>
      <Face size={520} mood="panic" look={[-20, -6, -20, -6]} />
    </At>
    <FireFloor h={160} seed={282} />
    <Embers w={W} h={H} n={40} seed={281} size={2.2} />
    <Hook main="BEAT THE CLOCK!" size={240} fill="#FFFFFF" rim={C.red} y={70} rot={-2} />
    <Rim />
  </AbsoluteFill>
);

/* 29  SAVE THE PUPPY!  giant scared puppy, fire on both sides, blue for contrast */
export const Ad29: React.FC = () => (
  <AbsoluteFill style={{ background: "radial-gradient(circle at 50% 62%, #6FD3FF 0%, #1E88E5 50%, #0B2E6E 100%)", overflow: "hidden" }}>
    <Halftone opacity={0.1} color="#0A2A6A" />
    <div style={{ position: "absolute", left: -80, top: 380 }}>
      <Flames width={620} height={720} count={5} seed={291} outline={10} />
    </div>
    <div style={{ position: "absolute", left: 1380, top: 380 }}>
      <Flames width={620} height={720} count={5} seed={292} outline={10} />
    </div>
    <Glow x="10%" y="85%" r={35} o={0.85} />
    <Glow x="90%" y="85%" r={35} o={0.85} />
    <At x={590} y={330} rot={-3} shadow={18} style={{ filter: rim(12, "#FFFFFF", 18) }}>
      <Puppy size={740} />
    </At>
    <At x={1440} y={330} rot={10} shadow={12}>
      <Face size={340} mood="brave" look={[-24, 10, -24, 10]} />
    </At>
    <Embers w={W} h={H} n={50} seed={291} size={2.4} />
    <Hook top="SAVE THE" main="PUPPY!" topSize={160} size={240} y={40} rot={-2} />
    <Rim />
  </AbsoluteFill>
);

/* 30  YOUR OWN FIRE TRUCK!  head-on truck, sirens, penguin at the wheel */
export const Ad30: React.FC = () => (
  <AbsoluteFill style={{ background: "radial-gradient(circle at 70% 55%, #4FC3F7 0%, #1565C0 55%, #0B1E4E 100%)", overflow: "hidden" }}>
    <Burst a="rgba(255,255,255,0.14)" b="rgba(255,255,255,0)" x="72%" y="55%" rays={30} />
    <div style={{ position: "absolute", left: 820, top: 640 }}>
      <Flames width={1200} height={460} count={9} seed={301} outline={10} />
    </div>
    <At x={900} y={150} shadow={0} style={{ filter: rim(12, "#FFFFFF", 18) }}>
      <TruckFront width={960} mood="brave" look={[-6, 8, -6, 8]} />
    </At>
    <Embers w={W} h={H} n={40} seed={301} size={2.2} />
    <div style={{ position: "absolute", left: 130, top: 70, display: "flex", flexDirection: "column", alignItems: "flex-start", transform: "rotate(-4deg)" }}>
      <Head size={170} fill="#FFFFFF" rim="#1E88E5">
        YOUR OWN
      </Head>
      <Head size={230} fill={C.fireCore} rim={C.fireEdge} style={{ marginTop: -14 }}>
        FIRE
      </Head>
      <Head size={230} fill={C.fireCore} rim={C.fireEdge} style={{ marginTop: -24 }}>
        TRUCK!
      </Head>
    </div>
    <Rim />
  </AbsoluteFill>
);

/* 31  NIGHT FIRE!  navy sky, moon, glowing house fire, cyan-rimmed hero with a glowing jet */
export const Ad31: React.FC = () => {
  const [hx, hy, f] = [90, 470, 400];
  const [nx, ny] = nozzle(hx, hy, f);
  return (
    <AbsoluteFill style={{ background: "linear-gradient(to bottom, #040920 0%, #0F1E52 65%, #2A1A4A 100%)", overflow: "hidden" }}>
      <Stars w={W} h={620} n={70} seed={311} />
      <Moon size={220} style={{ position: "absolute", left: 1640, top: 40 }} />
      <Glow x="66%" y="62%" r={45} o={0.95} />
      <div style={{ position: "absolute", left: 860, top: 250 }}>
        <Flames width={900} height={460} count={8} seed={312} outline={10} />
      </div>
      <At x={900} y={430} shadow={14}>
        <House width={820} wall="#B8906A" roof="#2E1A2A" />
      </At>
      <Embers w={W} h={H} n={70} seed={311} size={2.6} />
      <AbsoluteFill style={{ filter: "drop-shadow(0 0 14px #7FF5F0) drop-shadow(0 0 36px #3FC8FF)" }}>
        <Jet x0={nx} y0={ny} x1={1180} y1={720} w={72} bend={-0.2} splash={1.5} />
      </AbsoluteFill>
      <AbsoluteFill style={{ filter: `${rim(10, "#7FF5F0")} drop-shadow(16px -8px 30px rgba(255,140,30,0.9))` }}>
        <Hero x={hx} y={hy} f={f} glow={false} />
      </AbsoluteFill>
      <Hook main="NIGHT FIRE!" size={250} fill="#FFFFFF" rim="#3FA0FF" align="left" x={150} y={70} rot={-3} />
      <Rim />
    </AbsoluteFill>
  );
};

/* 32  AAAH! FIRE!  bold: a giant screaming penguin face, fire reflected on it */
export const Ad32: React.FC = () => (
  <AbsoluteFill style={{ background: "radial-gradient(circle at 30% 55%, #FFF6A0 0%, #FFB12B 35%, #FF5A1F 70%, #7A1F10 100%)", overflow: "hidden" }}>
    <Burst a="rgba(255,255,255,0.22)" b="rgba(255,255,255,0)" x="32%" y="55%" rays={32} />
    <div style={{ position: "absolute", left: 1000, top: 300 }}>
      <Flames width={1000} height={800} count={6} seed={321} outline={12} />
    </div>
    <Glow x="80%" y="80%" r={40} o={0.9} />
    <At x={90} y={60} rot={-8} shadow={20} style={{ filter: rim(14, "#FFFFFF", 20) }}>
      <Face size={920} mood="panic" look={[30, -10, 30, -10]} />
    </At>
    <Embers w={W} h={H} n={60} seed={321} size={2.8} />
    <div style={{ position: "absolute", right: 130, top: 70, display: "flex", flexDirection: "column", alignItems: "flex-end", transform: "rotate(5deg)" }}>
      <Head size={260} fill="#FFFFFF" rim="#FF2E4D">
        AAAH!
      </Head>
      <Head size={260} fill={C.fireCore} rim={C.fireEdge} style={{ marginTop: -20 }}>
        FIRE!
      </Head>
    </div>
    <Rim />
  </AbsoluteFill>
);

/* 33  HELP!  bold: a kid chick at a burning window, one-word plea, the hero on the way */
export const Ad33: React.FC = () => (
  <AbsoluteFill style={{ background: "radial-gradient(circle at 50% 50%, #1E4A9A 0%, #0B1E4E 70%, #050B24 100%)", overflow: "hidden" }}>
    <Stars w={W} h={500} n={30} seed={331} />
    <div style={{ position: "absolute", left: 300, top: 120 }}>
      <Flames width={1320} height={360} count={9} seed={332} outline={10} />
    </div>
    <Glow x="50%" y="40%" r={40} o={0.8} />
    <At x={460} y={360} shadow={16}>
      <BigWindow width={1000} inside="#FFB12B">
        <AbsoluteFill style={{ background: "radial-gradient(circle at 50% 70%, #FFF6A0 0%, #FFB12B 50%, #FF5A1F 100%)" }} />
        <div style={{ position: "absolute", left: 150, top: 40 }}>
          <Chick size={380} mood="panic" bow="#FF6FA8" />
        </div>
      </BigWindow>
    </At>
    {/* speech bubble */}
    <div style={{ position: "absolute", left: 1230, top: 230, transform: "rotate(8deg)", filter: `drop-shadow(0 14px 0 ${C.ink})` }}>
      <svg width={560} height={330} viewBox="0 0 560 330" style={{ position: "absolute", left: 0, top: 0, overflow: "visible" }}>
        <path d="M 60 20 L 500 20 Q 540 20 540 60 L 540 220 Q 540 260 500 260 L 160 260 L 60 330 L 90 260 L 60 260 Q 20 260 20 220 L 20 60 Q 20 20 60 20 Z" fill="#FFFFFF" stroke={C.ink} strokeWidth={14} strokeLinejoin="round" />
      </svg>
      <div style={{ position: "relative", width: 560, height: 280, display: "flex", alignItems: "center", justifyContent: "center", fontFamily: DISPLAY, fontSize: 210, color: "#FF2E4D", paddingTop: 30 }}>
        HELP!
      </div>
    </div>
    <At x={80} y={480} rot={-8} shadow={14} style={{ filter: rim(10, "#FFFFFF", 14) }}>
      <Face size={460} mood="brave" look={[28, -14, 28, -14]} />
    </At>
    <Embers w={W} h={H} n={50} seed={331} size={2.2} />
    <Vignette o={0.35} inner={60} />
    <Rim />
  </AbsoluteFill>
);
