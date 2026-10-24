import React from "react";
import { Still } from "remotion";
import { IconA, IconB, IconC, IconD, IconE } from "./Icons";

const I = { width: 512, height: 512 };

export const Root: React.FC = () => (
  <>
    <Still id="icon-v2-a" component={IconA} {...I} />
    <Still id="icon-v2-b" component={IconB} {...I} />
    <Still id="icon-v2-c" component={IconC} {...I} />
    <Still id="icon-v2-d" component={IconD} {...I} />
    <Still id="icon-v2-e" component={IconE} {...I} />
  </>
);
