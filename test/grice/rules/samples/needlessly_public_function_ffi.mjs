// A clean sample of needlessly-public-function: JavaScript that imports a
// function of `referenced` from the module's file. Nothing loads it.
import { from_javascript } from "../../internal/rules/samples/referenced.mjs";

export function call() {
  return from_javascript();
}
