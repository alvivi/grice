//// What a run needs from the runtime: the arguments, the environment, the
//// terminal, a clock and a way to exit.
////
//// Each has an Erlang and a JavaScript implementation, for Node. Only
//// Erlang counts reductions.

import argv
import gleam/option
import grice/internal/stats.{type Sample}

/// The arguments after the program name. `gleam run` passes on what comes
/// after its own `--`.
pub fn arguments() -> List(String) {
  argv.load().arguments
}

/// The value of the environment variable with the given name, or
/// `Error(Nil)` when it isn't set.
@external(erlang, "grice_ffi", "variable")
@external(javascript, "../../grice_ffi.mjs", "variable")
pub fn variable(name: String) -> Result(String, Nil)

/// Whether standard output is a terminal. When the runtime can't tell, it
/// isn't.
@external(erlang, "grice_ffi", "stdout_is_terminal")
@external(javascript, "../../grice_ffi.mjs", "stdout_is_terminal")
pub fn stdout_is_terminal() -> Bool

/// The monotonic clock, and on Erlang the reductions every process has
/// made.
pub fn sample() -> Sample {
  stats.Sample(
    milliseconds: milliseconds(),
    reductions: option.from_result(reductions()),
  )
}

/// Stop the program with the given exit status, once everything written so
/// far is out. On Erlang it stops right away. On JavaScript it returns,
/// and the program ends with the status once `main` returns, so call it
/// last.
@external(erlang, "grice_ffi", "exit")
@external(javascript, "../../grice_ffi.mjs", "exit")
pub fn exit(code: Int) -> Nil

@external(erlang, "grice_ffi", "milliseconds")
@external(javascript, "../../grice_ffi.mjs", "milliseconds")
fn milliseconds() -> Int

// Only Erlang counts reductions.
@external(erlang, "grice_ffi", "reductions")
fn reductions() -> Result(Int, Nil) {
  Error(Nil)
}
