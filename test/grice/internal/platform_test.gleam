//// Tests for what a run reads from the runtime, on both targets: the
//// environment and the clock.

import gleam/option
import grice/internal/platform
import grice/support

pub fn a_variable_that_is_set_has_its_value_test() {
  // Every test run has a `PATH`.
  let assert Ok(_path) = platform.variable("PATH")
}

// On JavaScript, the environment is an object, whose inherited properties
// such as `toString` aren't variables.
pub fn a_variable_that_isnt_set_is_an_error_test() {
  assert platform.variable("GRICE_TEST_NEVER_SET") == Error(Nil)
  assert platform.variable("toString") == Error(Nil)
}

pub fn only_erlang_counts_reductions_test() {
  let first = platform.sample()
  let second = platform.sample()
  assert second.milliseconds >= first.milliseconds
  assert option.is_some(first.reductions) == support.is_erlang()
}
