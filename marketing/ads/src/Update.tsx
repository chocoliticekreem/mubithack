// 1920x1080 "BIG UPDATE" banner for Roblox Events & Updates.
import React from "react";
import { AbsoluteFill } from "remotion";
import { Burst, C, Embers, Face, Flames, Glow, HoseBody, Jet, Outline, Ribbon, Sticker, Truck, Vignette } from "./kit";
import { DISPLAY } from "./theme";

const T: React.FC<{ size: number; fill?: string; edge?: string; children: React.ReactNode; style?: React.CSSProperties }> = ({ size, fill = C.fireCore, edge = C.fireEdge, children, style }) => (
  <Outline size={size} fill={fill} layers={[{ stroke: size * 0.22, color: C.ink }, { stroke: size * 0.11, color: edge }]} style={style}>
    {children}
  </Outline>
);

export const UpdateBanner: React.FC = () => (
  <AbsoluteFill style={{ background: C.fireDark, overflow: "hidden" }}>
    <Burst a={C.fireBody} b={C.horizon} x="62%" y="62%" rays={28} />
    <Glow x="62%" y="60%" r={45} o={0.7} />
    <div style={{ position: "absolute", left: 980, top: 560 }}>
      <Flames width={1000} height={520} count={9} seed={21} outline={9} />
    </div>
    <Embers w={1920} h={1080} n={60} seed={9} t={20} size={1.6} />
    <div style={{ position: "absolute", left: 760, top: 470, filter: `drop-shadow(0 14px 0 ${C.ink})` }}>
      <Truck width={1100} flash={0.4} />
    </div>
    <Jet x0={560} y0={760} x1={1300} y1={560} w={70} bend={-0.2} />
    <div style={{ position: "absolute", left: 120, top: 470, filter: `drop-shadow(0 12px 0 ${C.ink})` }}>
      <HoseBody size={520} style={{ position: "absolute", left: 0, top: 290 }} />
      <Face size={440} mood="brave" style={{ position: "absolute", left: 30, top: 0 }} />
    </div>
    <div style={{ position: "absolute", left: 0, right: 0, top: 70, display: "flex", flexDirection: "column", alignItems: "center", transform: "rotate(-3deg)" }}>
      <T size={210} fill="#FFFFFF" edge={C.red}>BIG UPDATE!</T>
    </div>
    <div style={{ position: "absolute", left: 0, right: 0, top: 330, display: "flex", justifyContent: "center", gap: 28 }}>
      <Sticker bg={C.gold} rotate={-3} pad="6px 28px" border={8}>
        <div style={{ fontFamily: DISPLAY, fontSize: 60, color: C.ink }}>🚒 TRUCKS FOR ALL</div>
      </Sticker>
      <Sticker bg="#5FE3F2" rotate={2} pad="6px 28px" border={8}>
        <div style={{ fontFamily: DISPLAY, fontSize: 60, color: C.ink }}>📻 DISPATCH RADIO</div>
      </Sticker>
    </div>
    <div style={{ position: "absolute", right: 90, top: 470, transform: "rotate(6deg)" }}>
      <Ribbon text="STATION 67" size={46} />
    </div>
    <Vignette o={0.35} inner={60} />
  </AbsoluteFill>
);
