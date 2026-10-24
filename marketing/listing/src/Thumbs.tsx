import React from "react";
import { AbsoluteFill } from "remotion";
import {
  Burst,
  Flames,
  Frame,
  GasMask,
  GoldenAxe,
  Halftone,
  Halligan,
  Logo,
  Outline,
  PenguinFace,
  Ribbon,
  Sledge,
  Shot,
  Sticker,
  WaterArc,
} from "./art";
import { BODY, C, DISPLAY } from "./theme";

const shade = (dir: string, a = 0.85, stop = 55) => (
  <AbsoluteFill style={{ background: `linear-gradient(${dir}, rgba(26,18,16,${a}) 0%, rgba(26,18,16,0) ${stop}%)` }} />
);

const Corner: React.FC<{ children?: React.ReactNode }> = () => (
  <div style={{ position: "absolute", left: 46, top: 40 }}>
    <Logo size={64} sub={false} />
  </div>
);

/* 1. Key art */
export const ThumbKeyArt: React.FC<{ t?: number }> = ({ t = 0 }) => (
  <AbsoluteFill style={{ background: C.ink }}>
    <Shot src="station-dusk" scale={1.08} y={70} filter="saturate(1.25) contrast(1.08) brightness(1.15)" />
    <AbsoluteFill style={{ background: "radial-gradient(ellipse at 50% 40%, rgba(26,18,16,0) 30%, rgba(26,18,16,0.55) 90%)" }} />
    {shade("to bottom", 0.7, 34)}
    {shade("to top", 0.6, 30)}
    <div style={{ position: "absolute", top: 60, left: 0, right: 0, display: "flex", justifyContent: "center" }}>
      <Logo size={230} />
    </div>
    <div style={{ position: "absolute", left: 0, right: 0, bottom: -10 }}>
      <Flames width={1920} height={230} count={16} seed={2} t={t} outline={8} />
    </div>
    <div style={{ position: "absolute", left: 70, bottom: 40, filter: `drop-shadow(0 12px 0 ${C.ink})`, transform: "rotate(-8deg)" }}>
      <PenguinFace size={330} look={[18, 6, 6, 8]} />
    </div>
    <div style={{ position: "absolute", right: 70, bottom: 40, filter: `drop-shadow(0 12px 0 ${C.ink})`, transform: "rotate(9deg)" }}>
      <PenguinFace size={300} number="01" look={[-20, -6, -18, -8]} />
    </div>
    <div style={{ position: "absolute", left: 0, right: 0, bottom: 64, display: "flex", justifyContent: "center" }}>
      <Sticker bg={C.hose} rotate={-2} pad="8px 40px 2px">
        <span style={{ fontFamily: DISPLAY, fontSize: 64, color: C.ink, letterSpacing: "0.03em" }}>CO-OP FIREFIGHTING CHAOS</span>
      </Sticker>
    </div>
    <Frame />
  </AbsoluteFill>
);

/* 2. Save the day. Blame your friends. */
export const ThumbBlame: React.FC = () => (
  <AbsoluteFill style={{ background: C.ink }}>
    <Shot src="penguin-closeup" scale={1.05} origin="30% 40%" />
    {shade("to top", 0.92, 52)}
    {shade("to right", 0.35, 40)}
    {/* blame pointer at the side-eye penguin */}
    <div style={{ position: "absolute", left: 1270, top: 110, transform: "rotate(8deg)" }}>
      <Sticker bg={C.red} pad="10px 36px 2px" rotate={0}>
        <span style={{ fontFamily: DISPLAY, fontSize: 92, color: C.cream, letterSpacing: "0.03em" }}>IT WAS HIM!</span>
      </Sticker>
      <svg width={180} height={200} viewBox="0 0 180 200" style={{ position: "absolute", left: 20, top: 150 }}>
        <path d="M 120 10 Q 40 40 40 150" fill="none" stroke={C.ink} strokeWidth={34} strokeLinecap="round" />
        <path d="M 120 10 Q 40 40 40 150" fill="none" stroke={C.cream} strokeWidth={18} strokeLinecap="round" />
        <path d="M 6 128 L 40 194 L 76 126 Z" fill={C.cream} stroke={C.ink} strokeWidth={10} strokeLinejoin="round" />
      </svg>
    </div>
    <div style={{ position: "absolute", left: 70, bottom: 64 }}>
      <Outline size={110} fill={C.cream}>
        SAVE THE DAY.
      </Outline>
      <div style={{ height: 14 }} />
      <Outline size={150} fill={C.hose} layers={[{ stroke: 34, color: C.ink }]}>
        BLAME YOUR FRIENDS.
      </Outline>
    </div>
    <Corner />
    <Frame />
  </AbsoluteFill>
);

/* 3. 8-player fire squads */
export const ThumbSquads: React.FC = () => (
  <AbsoluteFill style={{ background: C.ink }}>
    <Shot src="station-squad" scale={1.12} y={-40} origin="50% 40%" />
    {shade("to top", 0.9, 48)}
    <div style={{ position: "absolute", left: 60, bottom: 46, display: "flex", alignItems: "center", gap: 36 }}>
      <div
        style={{
          width: 330,
          height: 330,
          borderRadius: "50%",
          background: C.red,
          border: `14px solid ${C.ink}`,
          boxShadow: `0 16px 0 ${C.ink}`,
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
          transform: "rotate(-8deg)",
          position: "relative",
        }}
      >
        <div style={{ position: "absolute", inset: 18, borderRadius: "50%", border: `8px dashed ${C.cream}`, opacity: 0.55 }} />
        <Outline size={300} fill={C.cream} layers={[{ stroke: 40, color: C.ink }]} shadow={0} style={{ marginTop: 50 }}>
          8
        </Outline>
      </div>
      <div style={{ display: "flex", flexDirection: "column", gap: 6 }}>
        <Outline size={120} fill={C.cream}>
          PLAYER
        </Outline>
        <Outline size={150} fill={C.hose} layers={[{ stroke: 34, color: C.ink }]}>
          FIRE SQUADS
        </Outline>
      </div>
    </div>
    <div style={{ position: "absolute", right: 60, top: 50 }}>
      <Sticker bg={C.hose} rotate={5} pad="6px 30px 0">
        <span style={{ fontFamily: DISPLAY, fontSize: 58, color: C.ink }}>4 TRUCKS!</span>
      </Sticker>
    </div>
    <Frame />
  </AbsoluteFill>
);

/* 4. Drive. Spray. Yeet. */
export const ThumbDrive: React.FC<{ t?: number }> = ({ t = 0 }) => (
  <AbsoluteFill style={{ background: C.ink }}>
    <Shot src="truck-fire" scale={1.16} x={70} y={20} origin="62% 62%" filter="saturate(1.3) contrast(1.08) brightness(1.2)" />
    {shade("to right", 0.75, 48)}
    {shade("to top", 0.5, 30)}
    <div style={{ position: "absolute", left: 1150, top: 130 }}>
      <WaterArc width={820} height={300} t={t} flip />
    </div>
    <div style={{ position: "absolute", left: 70, top: 150, display: "flex", flexDirection: "column", gap: 34, alignItems: "flex-start" }}>
      <Sticker bg={C.red} rotate={-5} pad="16px 46px 0">
        <Outline size={170} fill={C.cream} layers={[{ stroke: 26, color: C.ink }]} shadow={0.05}>
          DRIVE.
        </Outline>
      </Sticker>
      <Sticker bg={C.water} rotate={3} pad="16px 46px 0" style={{ marginLeft: 90 }}>
        <Outline size={170} fill="#fff" layers={[{ stroke: 26, color: C.ink }]} shadow={0.05}>
          SPRAY.
        </Outline>
      </Sticker>
      <Sticker bg={C.hose} rotate={-3} pad="16px 46px 0" style={{ marginLeft: 30 }}>
        <Outline size={200} fill={C.fireEdge} layers={[{ stroke: 30, color: C.ink }]} shadow={0.05}>
          YEET.
        </Outline>
      </Sticker>
    </div>
    <Corner />
    <Frame />
  </AbsoluteFill>
);

/* 5. Houses burn down for real */
export const ThumbBurn: React.FC<{ t?: number }> = ({ t = 0 }) => (
  <AbsoluteFill style={{ background: C.ink }}>
    <Shot src="house-fire" scale={1.12} y={90} origin="50% 70%" />
    {shade("to bottom", 0.88, 46)}
    <AbsoluteFill style={{ background: "radial-gradient(ellipse at 50% 62%, rgba(255,120,30,0.25) 0%, transparent 45%)", mixBlendMode: "screen" }} />
    <div style={{ position: "absolute", top: 46, left: 0, right: 0, display: "flex", flexDirection: "column", alignItems: "center" }}>
      <Outline size={150} fill={C.cream}>
        HOUSES BURN DOWN
      </Outline>
      <Sticker bg={C.fireEdge} rotate={-3} pad="14px 50px 0" style={{ marginTop: 8 }}>
        <Outline size={130} fill={C.fireCore} layers={[{ stroke: 26, color: C.ink }]} shadow={0.05}>
          FOR REAL
        </Outline>
      </Sticker>
    </div>
    <div style={{ position: "absolute", left: -40, bottom: -10 }}>
      <Flames width={420} height={300} count={5} seed={7} t={t} outline={8} />
    </div>
    <div style={{ position: "absolute", right: -40, bottom: -10 }}>
      <Flames width={420} height={330} count={5} seed={11} t={t} outline={8} />
    </div>
    <Frame />
  </AbsoluteFill>
);

/* 6. Unlock the golden axe */
const Card: React.FC<{ lvl: number; name: string; children: React.ReactNode; rot: number }> = ({ lvl, name, children, rot }) => (
  <div
    style={{
      width: 250,
      background: C.cream,
      border: `10px solid ${C.ink}`,
      borderRadius: 30,
      boxShadow: `0 14px 0 ${C.ink}`,
      transform: `rotate(${rot}deg)`,
      display: "flex",
      flexDirection: "column",
      alignItems: "center",
      paddingTop: 16,
      overflow: "hidden",
    }}
  >
    <div style={{ fontFamily: DISPLAY, fontSize: 40, color: C.red, lineHeight: 1 }}>LVL {lvl}</div>
    <div style={{ height: 150, display: "flex", alignItems: "center" }}>{children}</div>
    <div style={{ background: C.ink, color: C.cream, width: "100%", textAlign: "center", fontFamily: BODY, fontWeight: 700, fontSize: 30, padding: "8px 0 10px", letterSpacing: "0.08em" }}>
      {name}
    </div>
  </div>
);

export const ThumbAxe: React.FC<{ t?: number }> = ({ t = 0 }) => (
  <AbsoluteFill style={{ background: C.red, overflow: "hidden" }}>
    <Shot src="station-dusk" filter="blur(10px) saturate(1.2) brightness(0.55)" scale={1.1} />
    <Burst a="rgba(246,196,64,0.55)" b="rgba(200,35,43,0.35)" x="73%" y="48%" rays={28} spin={t * 0.4} />
    <AbsoluteFill style={{ background: `radial-gradient(circle at 73% 48%, ${C.fireCore} 0%, rgba(255,177,43,0.6) 18%, transparent 46%)` }} />
    <Halftone opacity={0.14} />
    <div style={{ position: "absolute", left: 1010, top: 90, filter: `drop-shadow(0 18px 0 ${C.ink})` }}>
      <GoldenAxe size={780} shine={t * 0.2} />
    </div>
    <div style={{ position: "absolute", left: 70, top: 70 }}>
      <Outline size={120} fill={C.cream}>
        UNLOCK THE
      </Outline>
      <div style={{ height: 6 }} />
      <Outline size={190} fill={C.gold} layers={[{ stroke: 40, color: C.ink }, { stroke: 22, color: C.goldDark }]}>
        {"GOLDEN\nAXE"}
      </Outline>
    </div>
    <div style={{ position: "absolute", left: 70, bottom: 70, display: "flex", gap: 30, alignItems: "flex-end" }}>
      <Card lvl={2} name="GAS MASK" rot={-4}>
        <GasMask size={140} />
      </Card>
      <Card lvl={3} name="HALLIGAN" rot={2}>
        <Halligan size={150} />
      </Card>
      <Card lvl={8} name="SLEDGE" rot={-2}>
        <Sledge size={150} />
      </Card>
    </div>
    <div style={{ position: "absolute", right: 90, bottom: 70 }}>
      <Ribbon text="LEVEL 10 · BATTLE PASS" size={44} bg={C.ink} color={C.gold} />
    </div>
    <Frame />
  </AbsoluteFill>
);
