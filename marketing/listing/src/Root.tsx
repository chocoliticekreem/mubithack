import React from "react";
import { Composition, Still } from "remotion";
import { Icon } from "./Icon";
import { ThumbAxe, ThumbBlame, ThumbBurn, ThumbDrive, ThumbKeyArt, ThumbSquads } from "./Thumbs";
import { Trailer, TRAILER_FRAMES } from "./Trailer";

const T = { width: 1920, height: 1080 };

export const Root: React.FC = () => (
  <>
    <Still id="icon" component={Icon} width={512} height={512} />
    <Still id="thumb-1-keyart" component={ThumbKeyArt} {...T} />
    <Still id="thumb-2-blame" component={ThumbBlame} {...T} />
    <Still id="thumb-3-squads" component={ThumbSquads} {...T} />
    <Still id="thumb-4-drive" component={ThumbDrive} {...T} />
    <Still id="thumb-5-burn" component={ThumbBurn} {...T} />
    <Still id="thumb-6-golden-axe" component={ThumbAxe} {...T} />
    <Composition id="trailer" component={Trailer} durationInFrames={TRAILER_FRAMES} fps={30} {...T} />
  </>
);
