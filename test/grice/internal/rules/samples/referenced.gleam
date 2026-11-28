//// The internal module of the clean samples of needlessly-public-function:
//// each public function is referred to in one way, by another module of
//// the samples or by a foreign source, or is called by name. Its name is
//// under `grice/internal`, so the compiler, building grice's tests, treats
//// it as internal, as grice does by its default patterns for a package
//// named `grice`. Nothing here runs.

/// Called as `referenced.qualified()`.
pub fn qualified() -> Int {
  helper()
}

/// Called through an alias, as `named.aliased()`.
pub fn aliased() -> Int {
  2
}

/// Imported unqualified.
pub fn unqualified() -> Int {
  3
}

/// Imported unqualified under another name.
pub fn renamed() -> Int {
  4
}

/// Named in a constant.
pub fn in_constant() -> Int {
  5
}

/// Called only in code compiled for JavaScript.
pub fn other_target() -> Int {
  6
}

/// Called from a test module.
pub fn from_test() -> Int {
  7
}

/// Called from a development module.
pub fn from_dev() -> Int {
  8
}

/// Called from Erlang, by the module's Erlang name.
pub fn from_erlang() -> Int {
  9
}

/// Called from JavaScript, through the module's file.
pub fn from_javascript() -> Int {
  10
}

/// What `gleam run -m` runs.
pub fn main() -> Int {
  11
}

/// What the Erlang runtime calls, as `application_start_module` names this
/// module.
pub fn start() -> Int {
  12
}

/// Called through this module's own Erlang name, by `through_external`,
/// which needs it exported.
pub fn via_external() -> Int {
  13
}

/// Calls `via_external` through an `@external` that names this module, on
/// Erlang; its body calls it on JavaScript.
@external(erlang, "grice@internal@rules@samples@referenced", "via_external")
pub fn through_external() -> Int {
  via_external()
}

/// A private function, which the rule doesn't read.
fn helper() -> Int {
  1
}
