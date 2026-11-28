//// A flagged sample of needlessly-public-function, linted as a module of a
//// package named `grice`, under `src/`, beside the internal module
//// `unreferenced`. These functions never run: the module is here to be
//// linted, and compiled by every build with `--warnings-as-errors`, which
//// shows the compiler is silent on it.

/// Marked `@internal` in a module that isn't internal, and no other module
/// refers to it.
@internal
pub fn marked() -> Int {
  1
}
