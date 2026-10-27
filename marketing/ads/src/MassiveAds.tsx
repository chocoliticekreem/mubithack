// 1920x1080 "massive text" ads on the second batch of Gemini renders (public/gemini2/*.jpg, no text in them).
// Rules from docs/research/marketing/ai-ad-creative-playbook.md: 2-3 words, font-size about 22-26% of the height,
// text in the top ~45%, nothing important in the bottom 20% (Roblox draws the player count there), >=5% side margins.
// The picture is pushed down so the faces sit under the text; the top is filled with a blurred, darkened copy of the
// same picture (one continuous scene, never a flat black band).
import React from "react";
import { AbsoluteFill, Img, staticFile } from "remotion";
import { C, Outline } from "./kit";

const W = 1920;
const H = 1080;

const Scene: React.FC<{ img: string; drop: number; zoom: number; x: number }> = ({ img, drop, zoom, x }) => {
  const src = staticFile(`gemini2/${img}.jpg`);
  const w = W * zoom;
  const h = H * zoom;
  return (
    <AbsoluteFill style={{ overflow: "hidden", background: C.ink }}>
      {/* blurred fill behind everything, so the pushed-down picture never leaves an empty band */}
      <Img src={src} style={{ position: "absolute", left: -60, top: -60, width: W + 120, height: H + 120, objectFit: "cover", filter: "blur(28px) brightness(0.55) saturate(1.3)" }} />
      <Img
        src={src}
        style={{
          position: "absolute",
          left: (W - w) / 2 + x,
          top: drop,
          width: w,
          height: h,
          objectFit: "cover",
          filter: "saturate(1.15) contrast(1.06)",
          WebkitMaskImage: "linear-gradient(to bottom, transparent 0px, black 220px)",
          maskImage: "linear-gradient(to bottom, transparent 0px, black 220px)",
        }}
      />
      {/* darken the top so the words always pop */}
      <AbsoluteFill style={{ background: "linear-gradient(to bottom, rgba(8,4,2,0.7) 0%, rgba(8,4,2,0.4) 28%, rgba(8,4,2,0) 46%)" }} />
    </AbsoluteFill>
  );
};

type Line = string | [string, number];

const Words: React.FC<{ lines: Line[]; size: number; top?: number }> = ({ lines, size, top = 24 }) => (
  <div style={{ position: "absolute", left: 0, right: 0, top, display: "flex", flexDirection: "column", alignItems: "center", transform: "rotate(-2deg)" }}>
    {lines.map((raw, i) => {
      const [l, sz] = typeof raw === "string" ? [raw, size] : raw;
      const prev = i === 0 ? 0 : typeof lines[i - 1] === "string" ? size : (lines[i - 1] as [string, number])[1];
      return (
        <Outline
          key={i}
          size={sz}
          fill={i === lines.length - 1 ? C.fireCore : "#FFFFFF"}
          shadow={0.1}
          layers={[
            { stroke: sz * 0.19, color: C.ink },
            { stroke: sz * 0.095, color: C.red },
          ]}
          style={{ marginTop: i === 0 ? 0 : -Math.min(sz, prev) * 0.06 }}
        >
          {l}
        </Outline>
      );
    })}
  </div>
);

const Massive: React.FC<{ img: string; lines: Line[]; size: number; drop?: number; zoom?: number; x?: number; top?: number }> = ({
  img,
  lines,
  size,
  drop = 230,
  zoom = 1.0,
  x = 0,
  top,
}) => (
  <AbsoluteFill>
    <Scene img={img} drop={drop} zoom={zoom} x={x} />
    <Words lines={lines} size={size} top={top} />
  </AbsoluteFill>
);

export const MSavePanda: React.FC = () => <Massive img="panda" lines={[["SAVE THE", 190], ["PANDA!", 400]]} size={300} drop={70} />;
export const MSavePuppy: React.FC = () => <Massive img="puppy" lines={[["SAVE THE", 190], ["PUPPY!", 400]]} size={300} drop={40} />;
export const MPandaTrapped: React.FC = () => <Massive img="trapped" lines={[["PANDA IS", 180], ["TRAPPED!", 340]]} size={300} drop={170} />;
export const MPutOut: React.FC = () => <Massive img="hose" lines={[["PUT OUT", 190], ["THE FIRE!", 330]]} size={300} drop={150} />;
export const MDriveTruck: React.FC = () => <Massive img="truck" lines={[["DRIVE THE", 180], ["FIRE TRUCK!", 290]]} size={300} drop={170} />;
export const MAaahFire: React.FC = () => <Massive img="face" lines={[["AAAH! FIRE!", 290]]} size={290} drop={80} top={30} />;
