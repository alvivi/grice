//// A clean sample of needlessly-public-function, linted as a module of a
//// package named `grice`, under `src/`, beside the internal module
//// `referenced` and the other clean samples. Each refers to functions of
//// `referenced` in one way. These functions never run: the module is here
//// to be linted, and compiled by every build with `--warnings-as-errors`,
//// which shows the compiler is silent on it.

import grice/internal/rules/samples/referenced.{
  renamed as other_name, unqualified,
}

/// A constant that names a function.
pub const by_constant = referenced.in_constant

/// A qualified call, and unqualified calls.
pub fn qualified() -> Int {
  referenced.qualified() + unqualified() + other_name()
}

/// A call to a function that calls another through an `@external`.
pub fn through_external() -> Int {
  referenced.through_external()
}

/// A public function of a module that isn't internal, which users of the
/// package may call.
pub fn exported() -> Int {
  1
}
