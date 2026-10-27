import React from "react";
import { Composition, Still } from "remotion";
import { AdBackdraft, AdBoom, AdChief, AdCloseup, AdRooftop, AdSaveCat, AdSaveThem, AdSquad, AdWhoStarted } from "./Ads";
import { Ad10, Ad11, Ad12, Ad13, Ad14, Ad15, Ad16, Ad17, Ad18, Ad19, Ad20, Ad21, Ad22, Ad23 } from "./Ads2";
import { Ad24, Ad25, Ad26, Ad27, Ad28, Ad29, Ad30, Ad31, Ad32, Ad33 } from "./Ads3";
import { Thumb01, Thumb02, Thumb03, Thumb04, Thumb05 } from "./Thumbs";
import { Vid15, Vid6, VID15_FRAMES, VID6_FRAMES } from "./Videos";
import { UpdateBanner } from "./Update";
import { MAaahFire, MDriveTruck, MPandaTrapped, MPutOut, MSavePanda, MSavePuppy } from "./MassiveAds";
import { GBeFirefighter, GDriveTruck, GFireSquad, GPutOut, GSaveKids, GSavePanda } from "./GeminiAds";
import { Donate10, Donate100, Donate50, Donate500, PassFoam, PassHeli, PassPremium } from "./Passes";
import { IconFace, IconNight, IconRescue, IconSpray, IconTruck, IconWord } from "./Icons3";
import { BADGES } from "./Badges";
import { IconA, IconB, IconC, IconD, IconE, IconFinal, IconFinalLine } from "./Icons";

const I = { width: 512, height: 512 };
const A = { width: 1920, height: 1080 };

export const Root: React.FC = () => (
  <>
    <Still id="update-2026-10-24" component={UpdateBanner} {...A} />
    <Still id="g-ad-01-be-a-firefighter" component={GBeFirefighter} {...A} />
    <Still id="g-ad-02-save-the-kids" component={GSaveKids} {...A} />
    <Still id="g-ad-03-drive-the-fire-truck" component={GDriveTruck} {...A} />
    <Still id="g-ad-04-fire-squad" component={GFireSquad} {...A} />
    <Still id="g-ad-05-save-the-panda" component={GSavePanda} {...A} />
    <Still id="g-ad-06-put-out-the-fire" component={GPutOut} {...A} />
    <Still id="m-ad-01-save-the-panda" component={MSavePanda} {...A} />
    <Still id="m-ad-02-save-the-puppy" component={MSavePuppy} {...A} />
    <Still id="m-ad-03-panda-is-trapped" component={MPandaTrapped} {...A} />
    <Still id="m-ad-04-put-out-the-fire" component={MPutOut} {...A} />
    <Still id="m-ad-05-drive-the-fire-truck" component={MDriveTruck} {...A} />
    <Still id="m-ad-06-aaah-fire" component={MAaahFire} {...A} />
    {BADGES.map((b) => (
      <Still key={b.id} id={`badge-${b.id.replace(/_/g, "-")}`} component={b.component} {...I} />
    ))}
    <Still id="pass-unlimited-foam" component={PassFoam} {...I} />
    <Still id="pass-premium" component={PassPremium} {...I} />
    <Still id="pass-helicopter" component={PassHeli} {...I} />
    <Still id="donate-10" component={Donate10} {...I} />
    <Still id="donate-50" component={Donate50} {...I} />
    <Still id="donate-100" component={Donate100} {...I} />
    <Still id="donate-500" component={Donate500} {...I} />
    <Still id="icon-v2-a" component={IconA} {...I} />
    <Still id="icon-v2-b" component={IconB} {...I} />
    <Still id="icon-v2-c" component={IconC} {...I} />
    <Still id="icon-v2-d" component={IconD} {...I} />
    <Still id="icon-v2-e" component={IconE} {...I} />
    <Still id="icon-final" component={IconFinal} {...I} />
    <Still id="icon-final-oneline" component={IconFinalLine} {...I} />
    <Still id="icon-v3-face" component={IconFace} {...I} />
    <Still id="icon-v3-spray" component={IconSpray} {...I} />
    <Still id="icon-v3-truck" component={IconTruck} {...I} />
    <Still id="icon-v3-word" component={IconWord} {...I} />
    <Still id="icon-v3-rescue" component={IconRescue} {...I} />
    <Still id="icon-v3-night" component={IconNight} {...I} />
    <Still id="ad-01-save-them-all" component={AdSaveThem} {...A} />
    <Still id="ad-02-who-started-the-fire" component={AdWhoStarted} {...A} />
    <Still id="ad-03-save-the-cat" component={AdSaveCat} {...A} />
    <Still id="ad-04-8-player-squad" component={AdSquad} {...A} />
    <Still id="ad-05-bring-the-water" component={AdCloseup} {...A} />
    <Still id="ad-06-ka-boom" component={AdBoom} {...A} />
    <Still id="ad-07-backdraft" component={AdBackdraft} {...A} />
    <Still id="ad-08-rooftop-rescue" component={AdRooftop} {...A} />
    <Still id="ad-09-fire-chief" component={AdChief} {...A} />
    <Still id="ad-10-be-a-firefighter" component={Ad10} {...A} />
    <Still id="ad-11-put-out-the-fire" component={Ad11} {...A} />
    <Still id="ad-12-save-the-kids" component={Ad12} {...A} />
    <Still id="ad-13-drive-the-fire-truck" component={Ad13} {...A} />
    <Still id="ad-14-house-on-fire" component={Ad14} {...A} />
    <Still id="ad-15-answer-the-call" component={Ad15} {...A} />
    <Still id="ad-16-save-the-panda" component={Ad16} {...A} />
    <Still id="ad-17-stop-the-fire" component={Ad17} {...A} />
    <Still id="ad-18-fire-truck-race" component={Ad18} {...A} />
    <Still id="ad-19-spray-it" component={Ad19} {...A} />
    <Still id="ad-20-rescue-everyone" component={Ad20} {...A} />
    <Still id="ad-21-can-you-save-them" component={Ad21} {...A} />
    <Still id="ad-22-giant-fire" component={Ad22} {...A} />
    <Still id="ad-23-fire-squad" component={Ad23} {...A} />
    <Still id="ad-24-play-with-friends" component={Ad24} {...A} />
    <Still id="ad-25-oops-wrong-house" component={Ad25} {...A} />
    <Still id="ad-26-whos-inside" component={Ad26} {...A} />
    <Still id="ad-27-new-dispatch-radio" component={Ad27} {...A} />
    <Still id="ad-28-beat-the-clock" component={Ad28} {...A} />
    <Still id="ad-29-save-the-puppy" component={Ad29} {...A} />
    <Still id="ad-30-your-own-fire-truck" component={Ad30} {...A} />
    <Still id="ad-31-night-fire" component={Ad31} {...A} />
    <Still id="ad-32-aaah-fire" component={Ad32} {...A} />
    <Still id="ad-33-help" component={Ad33} {...A} />
    <Still id="thumb-01-be-a-firefighter" component={Thumb01} {...A} />
    <Still id="thumb-02-trucks-and-dispatch" component={Thumb02} {...A} />
    <Still id="thumb-03-school-rescue" component={Thumb03} {...A} />
    <Still id="thumb-04-8-player-squad" component={Thumb04} {...A} />
    <Still id="thumb-05-new-map" component={Thumb05} {...A} />
    <Composition id="vid-15s-16x9" component={Vid15} durationInFrames={VID15_FRAMES} fps={30} {...A} />
    <Composition id="vid-06s-16x9" component={Vid6} durationInFrames={VID6_FRAMES} fps={30} {...A} />
  </>
);
