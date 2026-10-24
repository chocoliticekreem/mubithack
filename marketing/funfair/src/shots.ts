// The one place images are chosen. Every composition reads its screenshots from SHOTS, so swapping a
// picture is an edit to this file only. Files live in public/shots/ (the capture agent lists what it
// took, and how good each one is, in public/shots/manifest.json).
//   file  - file name in public/shots/
//   focus - the point to keep in frame and zoom toward (CSS position, "x% y%")
//   zoom  - extra crop on top of the composition's own framing
export type Shot = { file: string; focus?: string; zoom?: number };

export type ShotRole =
  | "icon"
  | "gate"
  | "course"
  | "lobby"
  | "costume"
  | "finale"
  | "stages"
  | "climb"
  | "summit"
  | "bigtop"
  | "carousel"
  | "bumper"
  | "teacup"
  | "ferris"
  | "fireworks";

export const SHOTS: Record<ShotRole, Shot> = {
  // Icon: the player under the stage 4 arch, the big top below; cropped square on the avatar.
  icon: { file: "action-stage4.png", focus: "40.4% 78.9%", zoom: 1.54 },
  // Entrance arch reading FUNFAIR FRENZY, from the spawn pad (trailer and bumper hook).
  gate: { file: "hero-gate.png", focus: "50% 40%" },
  // thumb-02: Twirly Teacup Terrace's course, three layers stacked on columns above the teacups.
  course: { file: "ride-teacups.png", focus: "62% 38%", zoom: 1.25 },
  // thumb-03 and the dress-up beat: the changing room (blurred behind the polaroid).
  lobby: { file: "changing-room.png", focus: "50% 50%" },
  // The polaroid: the player in the Party Cone, cropped to the avatar so the overlapping price labels
  // fall outside or into the Polaroid's background blur.
  costume: { file: "costume-party-cone.png", focus: "50% 33%", zoom: 1.5 },
  // thumb-04: the player in the Party Cone on stage 51, cropped low on the avatar; the in-game
  // fireworks render as white streaks, so the headline sits over them.
  finale: { file: "action-fireworks-stage51.png", focus: "45% 100%", zoom: 1.35 },
  // "60 STAGES!" beat: the whole zone 1 course and its ride gate.
  stages: { file: "ride-gate-zone1.png", focus: "40% 50%" },
  // "CLIMB TO THE FINALE!" beat: stage 4, then stage 51 under the fireworks.
  climb: { file: "action-stage4.png", focus: "50% 55%" },
  summit: { file: "action-fireworks-stage51.png", focus: "45% 45%" },
  // "6 RIDES!" montage, in course order (keys match the ride tokens). The title sits top right and
  // the tokens run down the left edge, so each ride is framed centre-low.
  bigtop: { file: "ride-bigtop.png", focus: "45% 70%" },
  carousel: { file: "ride-carousel.png", focus: "25% 90%" },
  bumper: { file: "ride-bumper-cars.png", focus: "40% 80%" },
  teacup: { file: "ride-teacups.png", focus: "60% 85%" },
  ferris: { file: "ride-ferris-wheel.png", focus: "40% 100%" },
  fireworks: { file: "ride-fireworks.png", focus: "45% 100%" },
};

// thumb-01's 3x2 collage, in course order: each crop fills a 631x386 tile with its ride
// (the fireworks crop stops under the white in-game fireworks).
export const RIDE_TILES: Shot[] = [
  { file: "ride-bigtop.png", focus: "36.6% 73.5%", zoom: 1.765 },
  { file: "ride-carousel.png", focus: "17.2% 99.2%", zoom: 1.96 },
  { file: "ride-bumper-cars.png", focus: "16.9% 97%", zoom: 1.765 },
  { file: "ride-teacups.png", focus: "58.7% 99.9%", zoom: 1.99 },
  { file: "ride-ferris-wheel.png", focus: "39.1% 71.3%", zoom: 1.54 },
  { file: "ride-fireworks.png", focus: "35% 99.9%", zoom: 2.08 },
];
