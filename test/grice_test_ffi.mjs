// JavaScript code behind the tests' `@external` functions: reading a
// panic's message, a counter, running a program, work done once per
// runtime and the runtime's name.
import { spawnSync } from "node:child_process";
import { Ok, Error } from "./gleam.mjs";

// `Ok(message)` when `run` raises a Gleam `panic` with `message`, and
// `Error(undefined)` when it raises anything else or returns.
export function panic_message(run) {
  try {
    run();
  } catch (error) {
    if (error?.gleam_error === "panic") return new Ok(error.message);
  }
  return new Error(undefined);
}

export function new_counter() {
  return { count: 0 };
}

export function increment(counter) {
  counter.count += 1;
  return counter.count;
}

export function count(counter) {
  return counter.count;
}

// Run the `gleam` on `PATH` with `args` in `directory`, and return
// `Ok([status, stdout, stderr])`, or an `Error` when there's no `gleam`.
// `spawnSync` captures standard error itself, so no file is needed.
export function run_gleam(directory, args, _stderr_file) {
  const result = spawnSync("gleam", args.toArray(), {
    cwd: directory,
    encoding: "utf8",
    maxBuffer: 256 * 1024 * 1024,
  });
  if (result.error?.code === "ENOENT") {
    return new Error("There's no gleam executable on PATH.");
  }
  if (result.error) return new Error(String(result.error));
  if (result.status === null) {
    return new Error(`gleam stopped on ${result.signal}.`);
  }
  return new Ok([result.status, result.stdout, result.stderr]);
}

const done = new Set();

// Call `f` the first time `once` is called with `key` in this runtime, and
// do nothing after that.
export function once(key, f) {
  if (!done.has(key)) {
    f();
    done.add(key);
  }
  return undefined;
}

// The runtime, such as `Node 24.11.1`.
export function runtime() {
  return `Node ${globalThis.process.versions.node}`;
}
