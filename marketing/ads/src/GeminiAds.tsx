// 1920x1080 ads on top of Gemini 3D renders (public/gemini/*.jpg, no text in them): one huge, dead-obvious
// headline in the empty sky at the top, a small "PENGUIN FIREFIGHTERS" tag under it, game name ribbon.
import React from "react";
import { AbsoluteFill, Img, staticFile } from "remotion";
import { C, Outline, Ribbon } from "./kit";

const Headline: React.FC<{ lines: string[]; size: number; fill?: string; edge?: string }> = ({ lines, size, fill = "#FFFFFF", edge = C.red }) => (
  <div style={{ position: "absolute", left: 0, right: 0, top: 50, display: "flex", flexDirection: "column", alignItems: "center", transform: "rotate(-2deg)" }}>
    {lines.map((l, i) => (
      <Outline key={i} size={size} fill={i === lines.length - 1 ? C.fireCore : fill} layers={[{ stroke: size * 0.22, color: C.ink }, { stroke: size * 0.11, color: edge }]} style={{ marginTop: i === 0 ? 0 : -size * 0.18 }}>
        {l}
      </Outline>
    ))}
  </div>
);

const GeminiAd: React.FC<{ img: string; lines: string[]; size?: number; tag?: string; shift?: number }> = ({ img, lines, size = 170, tag = "PENGUIN FIREFIGHTERS", shift = 0 }) => (
  <AbsoluteFill style={{ background: C.ink, overflow: "hidden" }}>
    <Img src={staticFile(`gemini/${img}.jpg`)} style={{ position: "absolute", left: -7 + shift, top: 0, width: 1934, height: 1080, objectFit: "cover" }} />
    {/* darken the top so the headline always pops */}
    <AbsoluteFill style={{ background: "linear-gradient(to bottom, rgba(10,6,4,0.72) 0%, rgba(10,6,4,0.35) 32%, rgba(10,6,4,0) 50%)" }} />
    <Headline lines={lines} size={size} />
    {tag !== "" && (
      <div style={{ position: "absolute", left: 0, right: 0, top: 50 + size * (lines.length * 0.86) + 40, display: "flex", justifyContent: "center" }}>
        <Ribbon text={tag} size={40} />
      </div>
    )}
  </AbsoluteFill>
);

export const GBeFirefighter: React.FC = () => <GeminiAd img="hose" lines={["BE A", "FIREFIGHTER!"]} size={160} tag="" />;
export const GSaveKids: React.FC = () => <GeminiAd img="school" lines={["SAVE THE KIDS!"]} size={190} />;
export const GDriveTruck: React.FC = () => <GeminiAd img="truck" lines={["DRIVE THE", "FIRE TRUCK!"]} size={150} />;
export const GFireSquad: React.FC = () => <GeminiAd img="squad" lines={["FIRE SQUAD!"]} size={210} tag="PLAY WITH FRIENDS" />;
export const GSavePanda: React.FC = () => <GeminiAd img="panda" lines={["SAVE THE", "PANDA!"]} size={170} />;
export const GPutOut: React.FC = () => <GeminiAd img="hose" lines={["PUT OUT", "THE FIRE!"]} size={170} tag="" />;
