//// Tests for `grice_rules/fold-plus`, over its samples and sources the
//// compiler won't let be samples. What it reports depends on the
//// project's target, so its flagged sample is linted once per target.

import birdie
import gleam/list
import gleam/option.{Some}
import grice/diagnostic.{Diagnostic}
import grice/rules
import grice/support
import grice/testing

const code = "grice_rules/fold-plus"

// Samples

// On Erlang, every form the rule reads.
pub fn fold_plus_flagged_samples_on_erlang_test() {
  let run =
    support.sample("fold_plus_flagged")
    |> support.on_target("erlang", [rules.fold_plus()])
  testing.expect_codes(run, list.repeat(code, 11))
  testing.render(run)
  |> birdie.snap(title: "built-in fold-plus: flagged samples")
}

// On JavaScript, only the function that adds as `int.sum` does there.
pub fn fold_plus_flagged_samples_on_javascript_test() {
  let source = support.sample("fold_plus_flagged")
  let assert [Diagnostic(code: found, location: Some(location), ..)] =
    source
    |> support.on_target("javascript", [rules.fold_plus()])
    |> testing.diagnostics
  assert found == code
  assert location.primary.span
    == support.span_of(
      source,
      "list.fold(numbers, 0, fn(total, number) { number + total })",
    )
}

pub fn fold_plus_clean_samples_test() {
  support.sample("fold_plus_clean")
  |> support.on_both_targets([rules.fold_plus()])
  |> testing.expect_none
}

// Forms the compiler warns on

// The compiler warns that `b` is unused, so a sample can't hold this. The
// function adds a parameter to itself, which isn't a sum of the list.
pub fn fold_plus_skips_a_parameter_added_to_itself_test() {
  "import gleam/list

pub fn doubled(numbers: List(Int)) -> Int {
  list.fold(numbers, 0, fn(a, b) { a + a })
}
"
  |> support.on_both_targets([rules.fold_plus()])
  |> testing.expect_none
}

// Gaps

// girard can't type `broken`, so the rule has no answer there and stays
// silent, and the run has only the note on the gap.
pub fn fold_plus_is_silent_over_a_gap_test() {
  "import gleam/int
import gleam/list

pub fn broken(numbers: List(Int)) -> Int {
  let _ = 1 + \"one\"
  list.fold(numbers, 0, int.add)
}
"
  |> support.on_both_targets([rules.fold_plus()])
  |> testing.expect_codes(["grice/untyped-definition"])
}
