//// Tests for `grice_rules/reverse-then-first`, over its samples, each
//// linted for both targets.

import birdie
import gleam/list
import grice/rules
import grice/support
import grice/testing

const code = "grice_rules/reverse-then-first"

// Samples

pub fn reverse_then_first_flagged_samples_test() {
  let run =
    support.sample("reverse_then_first_flagged")
    |> support.on_both_targets([rules.reverse_then_first()])
  testing.expect_codes(run, list.repeat(code, 7))
  testing.render(run)
  |> birdie.snap(title: "built-in reverse-then-first: flagged samples")
}

pub fn reverse_then_first_clean_samples_test() {
  support.sample("reverse_then_first_clean")
  |> support.on_both_targets([rules.reverse_then_first()])
  |> testing.expect_none
}

// Gaps

// girard can't type `broken`, so the rule has no answer there and stays
// silent, and the run has only the note on the gap.
pub fn reverse_then_first_is_silent_over_a_gap_test() {
  "import gleam/list

pub fn broken(scores: List(Int)) -> Result(Int, Nil) {
  let _ = 1 + \"one\"
  list.first(list.reverse(scores))
}
"
  |> support.on_both_targets([rules.reverse_then_first()])
  |> testing.expect_codes(["grice/untyped-definition"])
}
