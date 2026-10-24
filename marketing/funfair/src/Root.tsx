import React from "react";
import { Composition, Still } from "remotion";
import { Icon } from "./Icon";
import { ThumbDressUp, ThumbFinale, ThumbPark, ThumbStages } from "./Thumbs";
import { Bumper, BUMPER_FRAMES, Trailer, TRAILER_FRAMES } from "./Videos";

const T = { width: 1920, height: 1080 };

export const Root: React.FC = () => (
  <>
    <Still id="icon" component={Icon} width={512} height={512} />
    <Still id="thumb-01" component={ThumbPark} {...T} />
    <Still id="thumb-02" component={ThumbStages} {...T} />
    <Still id="thumb-03" component={ThumbDressUp} {...T} />
    <Still id="thumb-04" component={ThumbFinale} {...T} />
    <Composition id="vid-trailer-15s" component={Trailer} durationInFrames={TRAILER_FRAMES} fps={30} {...T} />
    <Composition id="vid-bumper-6s" component={Bumper} durationInFrames={BUMPER_FRAMES} fps={30} {...T} />
  </>
);
