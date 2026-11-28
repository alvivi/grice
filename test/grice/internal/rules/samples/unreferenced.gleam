//// The internal module of the flagged samples of
//// needlessly-public-function: public functions no other module refers
//// to. Its name is under `grice/internal`, so the compiler, building
//// grice's tests, treats it as internal, as grice does by its default
//// patterns for a package named `grice`. Nothing here runs.

/// No module refers to it.
pub fn unused() -> Int {
  1
}

/// Marked `@internal` in an internal module: the module is why it isn't
/// public API.
@internal
pub fn marked_too() -> Int {
  2
}

/// An external function, with a body for JavaScript.
@external(erlang, "erlang", "abs")
pub fn external(number: Int) -> Int {
  number
}

/// A `start` function, in a module no `application_start_module` names.
pub fn start() -> Int {
  3
}

/// Only this module refers to it, which doesn't count.
pub fn used_inside() -> Int {
  4
}

/// It refers to `used_inside`, and nothing refers to it.
pub fn calls_inside() -> Int {
  used_inside() + 1
}
