//// Tests for `grice_rules/no-length-for-emptiness`, over its samples and
//// sources the compiler or the formatter won't let be samples, each linted
//// for both targets.

import birdie
import gleam/list
import grice/rules
import grice/support
import grice/testing

const code = "grice_rules/no-length-for-emptiness"

// Samples

pub fn no_length_for_emptiness_flagged_samples_test() {
  let run =
    support.sample("no_length_for_emptiness_flagged")
    |> support.on_both_targets([rules.no_length_for_emptiness()])
  testing.expect_codes(run, list.repeat(code, 25))
  testing.render(run)
  |> birdie.snap(title: "built-in no-length-for-emptiness: flagged samples")
}

pub fn no_length_for_emptiness_clean_samples_test() {
  support.sample("no_length_for_emptiness_clean")
  |> support.on_both_targets([rules.no_length_for_emptiness()])
  |> testing.expect_none
}

// The compiler's own forms

// The compiler warns on each of these (InefficientEmptyListCheck), so a
// sample can't hold them, and the rule leaves them to it: a direct
// `list.length` call through a module access, under any alias, compared
// with a literal written exactly `0` or `-0` as `== 0`, `!= 0`, `> 0` or
// `<= 0`, or exactly `1` as `< 1`, with the literal on either side.
pub fn no_length_for_emptiness_leaves_the_compiler_its_forms_test() {
  "import gleam/list
import gleam/list as l

pub fn equal(items: List(Int)) -> List(Bool) {
  [list.length(items) == 0, list.length(items) == -0, 0 == list.length(items), -0 == list.length(items)]
}

pub fn not_equal(items: List(Int)) -> List(Bool) {
  [list.length(items) != 0, list.length(items) != -0, 0 != list.length(items), -0 != list.length(items)]
}

pub fn greater(items: List(Int)) -> List(Bool) {
  [list.length(items) > 0, list.length(items) > -0, 0 < list.length(items), -0 < list.length(items)]
}

pub fn at_most(items: List(Int)) -> List(Bool) {
  [list.length(items) <= 0, list.length(items) <= -0, 0 >= list.length(items), -0 >= list.length(items)]
}

pub fn less_than_one(items: List(Int)) -> List(Bool) {
  [list.length(items) < 1, 1 > list.length(items)]
}

pub fn labelled(items: List(Int)) -> Bool {
  list.length(of: items) == 0
}

pub fn aliased(items: List(Int)) -> Bool {
  l.length(items) == 0
}
"
  |> support.on_both_targets([rules.no_length_for_emptiness()])
  |> testing.expect_none
}

// Signs

// `gleam format` prints `- 0` as `-0`, the compiler's own form, so a
// sample can't hold the spaced sign, on which the compiler is silent.
pub fn no_length_for_emptiness_reports_a_spaced_sign_test() {
  "import gleam/list\n\npub fn empty(items: List(Int)) -> Bool {\n  list.length(items) == - 0\n}\n"
  |> support.on_both_targets([rules.no_length_for_emptiness()])
  |> testing.expect_codes([code])
}

// The compiler warns on stacked signs, so a sample can't hold them. They
// aren't a literal, so the rule is silent.
pub fn no_length_for_emptiness_skips_stacked_signs_test() {
  "import gleam/string\n\npub fn empty(name: String) -> Bool {\n  string.length(name) == - -0\n}\n"
  |> support.on_both_targets([rules.no_length_for_emptiness()])
  |> testing.expect_none
}

// Gaps

// girard can't type `broken`, so the rule has no answer there and stays
// silent, and the run has only the note on the gap.
pub fn no_length_for_emptiness_is_silent_over_a_gap_test() {
  "import gleam/string

pub fn broken(name: String) -> Bool {
  let _ = 1 + \"one\"
  string.length(name) == 0
}
"
  |> support.on_both_targets([rules.no_length_for_emptiness()])
  |> testing.expect_codes(["grice/untyped-definition"])
}
