//// What a run needs from the runtime: the arguments, the environment, the
//// terminal, a clock and a way to exit.
////
//// Erlang implements each. On other targets each has a Gleam body, so
//// grice and a client's entry module compile for JavaScript too, and
//// `is_supported` says that a run can't work there yet.

import argv
import grice/internal/stats.{type Sample}

/// The arguments after the program name. `gleam run` passes on what comes
/// after its own `--`.
pub fn arguments() -> List(String) {
  argv.load().arguments
}

/// The value of the environment variable with the given name, or
/// `Error(Nil)` when it isn't set.
@external(erlang, "grice_ffi", "variable")
pub fn variable(_name: String) -> Result(String, Nil) {
  Error(Nil)
}

/// Whether standard output is a terminal. When the runtime can't tell, it
/// isn't.
@external(erlang, "grice_ffi", "stdout_is_terminal")
pub fn stdout_is_terminal() -> Bool {
  False
}

/// The monotonic clock and the reductions every process has made.
@external(erlang, "grice_ffi", "sample")
pub fn sample() -> Sample {
  stats.Sample(milliseconds: 0, reductions: 0)
}

/// Stop the program with the given exit status, once everything written so
/// far is out.
@external(erlang, "grice_ffi", "exit")
pub fn exit(_code: Int) -> Nil {
  Nil
}

/// Whether a run works on this target. Only Erlang implements the rest of
/// this module for now.
@external(erlang, "grice_ffi", "is_supported")
pub fn is_supported() -> Bool {
  False
}
