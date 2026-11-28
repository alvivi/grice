// JavaScript code behind grice's `@external` functions. Node is the
// runtime grice supports here; this uses only `globalThis.process` and
// `performance`.
import { Ok, Error, toList } from "./gleam.mjs";

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

// Foreign sources
//
// The words of a foreign source, for `grice/internal/loader`, split by the
// runtime rather than byte by byte in Gleam: a source is often as large as
// the project's Gleam code.

// `[words, names]`: each longest run of ASCII letters, digits, `_` and `@`
// in the bytes of `source`, and each such run that `.mjs` follows, each
// once. Any other byte ends a run, whatever the source's encoding.
export function foreign_words(source) {
  const words = new Set();
  const names = new Set();
  let word = "";
  for (let index = 0; index <= source.byteSize; index++) {
    const byte = index < source.byteSize ? source.byteAt(index) : 0;
    if (isWordByte(byte)) {
      word += String.fromCharCode(byte);
    } else if (word !== "") {
      words.add(word);
      if (followedByMjs(source, index)) names.add(word);
      word = "";
    }
  }
  return [toList(Array.from(words)), toList(Array.from(names))];
}

function isWordByte(byte) {
  return (
    (byte >= 97 && byte <= 122) ||
    (byte >= 65 && byte <= 90) ||
    (byte >= 48 && byte <= 57) ||
    byte === 95 ||
    byte === 64
  );
}

// Whether the bytes from `index` are `.mjs`.
function followedByMjs(source, index) {
  return (
    source.byteAt(index) === 46 &&
    source.byteAt(index + 1) === 109 &&
    source.byteAt(index + 2) === 106 &&
    source.byteAt(index + 3) === 115
  );
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
