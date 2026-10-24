import { loadFont as loadLilita } from "@remotion/google-fonts/LilitaOne";
import { loadFont as loadFredoka } from "@remotion/google-fonts/Fredoka";

export const DISPLAY = loadLilita("normal", { weights: ["400"], subsets: ["latin"] }).fontFamily;
// Fredoka is the family Fredoka One (the in-game HUD font) was folded into.
export const BODY = loadFredoka("normal", { weights: ["600", "700"], subsets: ["latin"] }).fontFamily;

// Game palette, sampled from the rides.
export const C = {
  red: "#E63946",
  gold: "#FFC23D",
  blue: "#3A86FF",
  pink: "#FF5FA8",
  cyan: "#22B8EE",
  purple: "#A77BFF",
  orange: "#FF7A2F",
  navy: "#1D3557",
  cream: "#FFF4E0",
  white: "#FFFFFF",
  sky: "#9FE3FA",
  grass: "#57C24A",
};

export const CONFETTI = [C.red, C.gold, C.blue, C.pink, C.cyan, C.purple, C.orange];
