import React from "react";
import { Still } from "remotion";
import { AdBackdraft, AdBoom, AdChief, AdCloseup, AdRooftop, AdSaveCat, AdSaveThem, AdSquad, AdWhoStarted } from "./Ads";
import { IconA, IconB, IconC, IconD, IconE, IconFinal, IconFinalLine } from "./Icons";

const I = { width: 512, height: 512 };
const A = { width: 1920, height: 1080 };

export const Root: React.FC = () => (
  <>
    <Still id="icon-v2-a" component={IconA} {...I} />
    <Still id="icon-v2-b" component={IconB} {...I} />
    <Still id="icon-v2-c" component={IconC} {...I} />
    <Still id="icon-v2-d" component={IconD} {...I} />
    <Still id="icon-v2-e" component={IconE} {...I} />
    <Still id="icon-final" component={IconFinal} {...I} />
    <Still id="icon-final-oneline" component={IconFinalLine} {...I} />
    <Still id="ad-01-save-them-all" component={AdSaveThem} {...A} />
    <Still id="ad-02-who-started-the-fire" component={AdWhoStarted} {...A} />
    <Still id="ad-03-save-the-cat" component={AdSaveCat} {...A} />
    <Still id="ad-04-8-player-squad" component={AdSquad} {...A} />
    <Still id="ad-05-bring-the-water" component={AdCloseup} {...A} />
    <Still id="ad-06-ka-boom" component={AdBoom} {...A} />
    <Still id="ad-07-backdraft" component={AdBackdraft} {...A} />
    <Still id="ad-08-rooftop-rescue" component={AdRooftop} {...A} />
    <Still id="ad-09-fire-chief" component={AdChief} {...A} />
  </>
);
