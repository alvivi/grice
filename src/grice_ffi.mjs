// JavaScript code behind grice's `@external` functions. Node is the
// runtime grice supports here; this uses only `globalThis.process` and
// `performance`.
import { Ok, Error } from "./gleam.mjs";

// Syntax trees
//
// What glance's offsets count, for `grice/internal/line_index`.

// JavaScript strings count UTF-16 code units, as glexer does here.
export function utf16_length(text) {
  return text.length;
}

// `Ok(run())`, or `Error(undefined)` when `run` uses up the call stack,
// which glance's parser does on a module with thousands of definitions.
// Any other exception goes on.
export function catching_stack_overflow(run) {
  try {
    return new Ok(run());
  } catch (error) {
    if (error instanceof RangeError && /call stack/i.test(error.message)) {
      return new Error(undefined);
    }
    throw error;
  }
}

// Platform
//
// What a run needs from the runtime, for `grice/internal/platform`.

// The variable's value when the environment has it as its own key, so an
// inherited property such as `toString` isn't a variable.
export function variable(name) {
  const environment = globalThis.process?.env;
  return environment && Object.hasOwn(environment, name)
    ? new Ok(environment[name])
    : new Error(undefined);
}

export function stdout_is_terminal() {
  return globalThis.process?.stdout?.isTTY === true;
}

// A monotonic clock, in milliseconds from an arbitrary start.
export function milliseconds() {
  return Math.floor(performance.now());
}

// `process.exit` would drop output still queued for a pipe, so this only
// sets the code Node exits with once the program ends, after flushing.
export function exit(code) {
  globalThis.process.exitCode = code;
  return undefined;
}
