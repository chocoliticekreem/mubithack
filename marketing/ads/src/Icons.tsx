// 512x512 experience icons v2: the action at a glance (penguin firefighter vs a roaring fire).
import React from "react";
import { AbsoluteFill } from "remotion";
import { C, Cat, Embers, Face, Flames, Glow, HoseBody, House, Jet, Outline, Photo, Smoke, Truck, Vignette } from "./kit";

const S = 512;

const Corners: React.FC = () => (
  // Roblox rounds icon corners; a thin ink rim keeps the edge crisp in light and dark UIs
  <AbsoluteFill style={{ boxShadow: `inset 0 0 0 8px ${C.ink}`, borderRadius: 0 }} />
);

const FireBg: React.FC<{ scale?: number; x?: number; y?: number; origin?: string }> = ({ scale = 2.0, x = 0, y = 0, origin = "48% 40%" }) => (
  <>
    <AbsoluteFill style={{ background: C.fireDark }} />
    <Photo src="house-fire" scale={scale} x={x} y={y} origin={origin} filter="saturate(1.5) contrast(1.15) brightness(1.05) sepia(0.15)" />
    <AbsoluteFill style={{ background: "linear-gradient(to bottom, rgba(122,31,16,0.15), rgba(26,18,16,0.55))" }} />
  </>
);

/* (a) penguin + hose + burning house */
export const IconA: React.FC = () => (
  <AbsoluteFill style={{ background: C.ink, overflow: "hidden" }}>
    <FireBg scale={2.1} origin="45% 38%" x={40} y={30} />
    <Smoke w={360} h={180} seed={4} color="#2E2522" o={0.9} style={{ position: "absolute", left: 170, top: -90 }} />
    <Glow x="70%" y="38%" r={62} o={0.85} />
    <div style={{ position: "absolute", left: 176, top: -6 }}>
      <Flames width={350} height={250} count={6} seed={3} outline={7} />
    </div>
    <div style={{ position: "absolute", left: 206, top: 128, filter: `drop-shadow(0 8px 0 ${C.ink})` }}>
      <House width={300} />
    </div>
    <Embers w={S} h={S} n={26} seed={2} t={40} size={1.3} />
    <Jet x0={292} y0={428} x1={380} y1={238} w={30} bend={-0.2} />
    <div style={{ position: "absolute", left: -10, top: 232, filter: `drop-shadow(0 8px 0 ${C.ink}) drop-shadow(10px -6px 18px rgba(255,140,30,0.85))` }}>
      <HoseBody size={300} style={{ position: "absolute", left: 0, top: 168 }} />
      <Face size={250} mood="brave" style={{ position: "absolute", left: 14, top: 0 }} />
    </div>
    <Vignette o={0.35} inner={60} />
    <Corners />
  </AbsoluteFill>
);

/* (b) penguin carrying a rescued cat out of the flames */
export const IconB: React.FC = () => (
  <AbsoluteFill style={{ background: C.ink, overflow: "hidden" }}>
    <FireBg scale={2.3} origin="50% 38%" />
    <div style={{ position: "absolute", left: -30, top: 150 }}>
      <Flames width={580} height={330} count={7} seed={9} outline={7} />
    </div>
    <Glow x="50%" y="55%" r={70} o={0.7} />
    <Embers w={S} h={S} n={30} seed={8} t={20} size={1.3} />
    <div style={{ position: "absolute", left: 100, top: 196, filter: `drop-shadow(0 8px 0 ${C.ink})` }}>
      <HoseBody size={330} carry />
    </div>
    <div style={{ position: "absolute", left: 120, top: 20, filter: `drop-shadow(0 8px 0 ${C.ink})` }}>
      <Face size={280} mood="panic" />
    </div>
    <div style={{ position: "absolute", left: 150, top: 268, transform: "rotate(-6deg)", filter: `drop-shadow(0 8px 0 ${C.ink})` }}>
      <Cat size={220} />
    </div>
    <Corners />
  </AbsoluteFill>
);

/* (c) close-up face lit by fire, hose blasting across */
export const IconC: React.FC = () => (
  <AbsoluteFill style={{ background: C.ink, overflow: "hidden" }}>
    <FireBg scale={2.6} origin="58% 36%" />
    <Glow x="80%" y="40%" r={70} o={0.85} />
    <div style={{ position: "absolute", left: 250, top: 10 }}>
      <Flames width={300} height={240} count={5} seed={5} outline={7} />
    </div>
    <div style={{ position: "absolute", left: 282, top: 140, filter: `drop-shadow(0 8px 0 ${C.ink})` }}>
      <House width={250} />
    </div>
    <Embers w={S} h={S} n={24} seed={4} t={60} size={1.4} />
    <Jet x0={230} y0={540} x1={420} y1={300} w={46} bend={-0.12} />
    <div style={{ position: "absolute", left: -52, top: 110, transform: "rotate(-8deg)", filter: `drop-shadow(0 10px 0 ${C.ink}) drop-shadow(14px -4px 22px rgba(255,140,30,0.9))` }}>
      <Face size={390} mood="brave" soot />
    </div>
    <Corners />
  </AbsoluteFill>
);

/* (d) fire truck with a penguin on top spraying */
export const IconD: React.FC = () => (
  <AbsoluteFill style={{ background: C.ink, overflow: "hidden" }}>
    <FireBg scale={2.0} origin="50% 36%" />
    <Glow x="78%" y="26%" r={60} o={0.85} />
    <div style={{ position: "absolute", left: 300, top: -40 }}>
      <Flames width={230} height={190} count={4} seed={12} outline={7} />
    </div>
    <div style={{ position: "absolute", left: 318, top: 40, filter: `drop-shadow(0 6px 0 ${C.ink})` }}>
      <House width={200} />
    </div>
    <Embers w={S} h={S} n={22} seed={6} t={30} />
    <Jet x0={238} y0={170} x1={372} y1={150} w={26} bend={-0.3} />
    <div style={{ position: "absolute", left: 50, top: 60, filter: `drop-shadow(0 6px 0 ${C.ink})` }}>
      <HoseBody size={210} style={{ position: "absolute", left: 0, top: 110 }} />
      <Face size={180} mood="brave" style={{ position: "absolute", left: 12, top: 0 }} />
    </div>
    <div style={{ position: "absolute", left: -50, top: 262, filter: `drop-shadow(0 8px 0 ${C.ink})` }}>
      <Truck width={580} flash={0.2} />
    </div>
    <Corners />
  </AbsoluteFill>
);

/* (e) bold word + action: FIRE! over penguin and hose */
export const IconE: React.FC = () => (
  <AbsoluteFill style={{ background: C.ink, overflow: "hidden" }}>
    <IconA />
    <div style={{ position: "absolute", left: 0, right: 0, top: 26, display: "flex", justifyContent: "center", transform: "rotate(-6deg)" }}>
      <Outline size={120} fill={C.fireCore} layers={[{ stroke: 30, color: C.ink }, { stroke: 16, color: C.fireEdge }]}>
        FIRE!
      </Outline>
    </div>
  </AbsoluteFill>
);
