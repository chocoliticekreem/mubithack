// 512x512 experience icon: the player on a course platform under a stage arch, the big top below,
// and the title. It has to read at 150x150, so it is one avatar mid-course and two words.
import React from "react";
import { AbsoluteFill } from "remotion";
import { Photo, Shade, Title, candy, gold } from "./art";
import { SHOTS } from "./shots";
import { C } from "./theme";

export const Icon: React.FC = () => (
  <AbsoluteFill style={{ background: C.sky, overflow: "hidden" }}>
    <Photo shot={SHOTS.icon} />
    <Shade dir="to bottom" a={0.4} stop={40} />
    <div style={{ position: "absolute", left: 0, right: 0, top: 14, display: "flex", flexDirection: "column", alignItems: "center", transform: "rotate(-5deg)" }}>
      <Title text="FUNFAIR" size={104} {...gold(104)} shadow={0.07} wobble={3} bob={0.025} />
      <Title text="FRENZY" size={88} {...candy(88)} shadow={0.07} wobble={3} bob={0.03} style={{ marginTop: -18 }} />
    </div>
    <AbsoluteFill style={{ boxShadow: `inset 0 0 0 8px ${C.navy}` }} />
  </AbsoluteFill>
);
