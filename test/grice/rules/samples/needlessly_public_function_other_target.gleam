//// A clean sample of needlessly-public-function: a call compiled only for
//// JavaScript, which counts on a project linted for Erlang too. Nothing
//// here runs.

@target(javascript)
import grice/internal/rules/samples/referenced

@target(javascript)
pub fn on_javascript() -> Int {
  referenced.other_target()
}

/// Something for Erlang, so the module isn't empty there.
pub fn on_every_target() -> Int {
  0
}
