import { loadFont as loadLuckiest } from "@remotion/google-fonts/LuckiestGuy";
import { loadFont as loadFredoka } from "@remotion/google-fonts/Fredoka";

export const DISPLAY = loadLuckiest().fontFamily;
export const BODY = loadFredoka("normal", { weights: ["600", "700"] }).fontFamily;

// docs/game/02-art-feel-ui.md palette
export const C = {
  red: "#C8232B",
  redDark: "#8E1219",
  hose: "#E8B83A",
  cream: "#FFF4C4",
  ink: "#1A1210",
  fireCore: "#FFF6A0",
  fireBody: "#FFB12B",
  fireEdge: "#FF5A1F",
  fireDark: "#7A1F10",
  teal: "#0E4A52",
  tealDay: "#5FA6A8",
  horizon: "#EC9438",
  water: "#A9E3F0",
  gold: "#F6C440",
  goldDark: "#B9780F",
  beak: "#F59A1B",
  penguin: "#23252F",
  shield: "#E8C24A",
};
