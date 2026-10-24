import React from "react";
import { AbsoluteFill } from "remotion";
import { Burst, Flames, Halftone, PenguinFace } from "./art";
import { C } from "./theme";

// 512x512 game icon: penguin firefighter head, helmet 67, flames behind. No small text.
export const Icon: React.FC = () => (
  <AbsoluteFill style={{ background: C.horizon, overflow: "hidden" }}>
    <Burst a={C.fireBody} b={C.horizon} y="62%" rays={20} spin={4} />
    <AbsoluteFill style={{ background: `radial-gradient(circle at 50% 60%, ${C.fireCore}cc 0%, transparent 42%)` }} />
    <Halftone opacity={0.12} size={10} />
    {/* back flames */}
    <div style={{ position: "absolute", left: -20, right: -20, bottom: -6 }}>
      <Flames width={552} height={300} count={8} seed={3} outline={6} />
    </div>
    <div style={{ position: "absolute", left: 0, right: 0, bottom: 18, display: "flex", justifyContent: "center", filter: `drop-shadow(0 10px 0 ${C.ink})` }}>
      <PenguinFace size={420} look={[16, 10, -14, -8]} />
    </div>
    {/* front flame lick at the bottom corners */}
    <div style={{ position: "absolute", left: -30, bottom: -10 }}>
      <Flames width={170} height={150} count={3} seed={9} outline={6} />
    </div>
    <div style={{ position: "absolute", right: -30, bottom: -10 }}>
      <Flames width={170} height={170} count={3} seed={5} outline={6} />
    </div>
    <AbsoluteFill style={{ boxShadow: `inset 0 0 0 10px ${C.ink}` }} />
  </AbsoluteFill>
);
