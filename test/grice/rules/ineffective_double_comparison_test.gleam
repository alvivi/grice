//// Tests for `grice_rules/ineffective-double-comparison`, over its samples
//// and sources the compiler or the formatter won't let be samples, each
//// linted for both targets.

import birdie
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/string
import grice/rules
import grice/support
import grice/testing

const code = "grice_rules/ineffective-double-comparison"

// Samples

pub fn ineffective_double_comparison_flagged_samples_test() {
  let run =
    support.sample("ineffective_double_comparison_flagged")
    |> support.on_both_targets([rules.ineffective_double_comparison()])
  testing.expect_codes(run, list.repeat(code, 17))
  testing.render(run)
  |> birdie.snap(
    title: "built-in ineffective-double-comparison: flagged samples",
  )
}

pub fn ineffective_double_comparison_clean_samples_test() {
  support.sample("ineffective_double_comparison_clean")
  |> support.on_both_targets([rules.ineffective_double_comparison()])
  |> testing.expect_none
}

// Literals

// `gleam format` prints `- 5` as `-5`, so a sample can't hold it. One minus
// around an unsigned literal is a literal, so the second equality is
// decided by the first.
pub fn ineffective_double_comparison_reads_a_spaced_sign_test() {
  "pub fn negative(count: Int) -> Bool {\n  count == - 5 && count == -5\n}\n"
  |> support.on_both_targets([rules.ineffective_double_comparison()])
  |> testing.expect_codes([code])
}

// The oldest compiler grice supports, 1.15.4, reads `-0x10` as `-0`
// followed by a name, so a sample can't hold a negative literal in another
// base.
pub fn ineffective_double_comparison_reads_a_negative_hexadecimal_test() {
  "pub fn negative(count: Int) -> Bool {\n  count < -0x10 && count < -1\n}\n"
  |> support.on_both_targets([rules.ineffective_double_comparison()])
  |> testing.expect_codes([code])
}

// The compiler warns on stacked signs, so a sample can't hold them. They
// aren't a literal, so the first equality is opaque.
pub fn ineffective_double_comparison_skips_stacked_signs_test() {
  "pub fn negative(count: Int) -> Bool {\n  count == - -5 && count == 5\n}\n"
  |> support.on_both_targets([rules.ineffective_double_comparison()])
  |> testing.expect_none
}

// The compiler warns, on JavaScript, on an Int literal outside
// JavaScript's safe integers, so a sample can't hold one. Such a literal
// is opaque, so the verdict can't depend on the runtime.
pub fn ineffective_double_comparison_skips_unsafe_integers_test() {
  "pub fn large(count: Int) -> Bool {
  count > 9_007_199_254_740_993 && count > 9_007_199_254_740_992
}
"
  |> support.on_both_targets([rules.ineffective_double_comparison()])
  |> testing.expect_none
}

// Long chains

// Two comparisons set both bounds, and each of the 298 equalities after
// them is decided by the two: one report each, with both as its witness.
pub fn ineffective_double_comparison_judges_a_long_and_chain_test() {
  let equalities = list.repeat("count == 5", 298)
  let found =
    chain(["count >= 5", "count <= 5", ..equalities], " && ")
    |> support.on_both_targets([rules.ineffective_double_comparison()])
    |> testing.diagnostics
  assert list.length(found) == 298
  assert list.all(found, fn(found) {
    let assert Some(location) = found.location
    list.length(location.secondary) == 2
  })
}

// Each equality of the second half repeats one of the first, which
// excluded its point: one report each, with that equality as its witness.
pub fn ineffective_double_comparison_judges_a_long_or_chain_test() {
  let equalities =
    int.range(from: 0, to: 150, with: [], run: fn(found, value) {
      ["count == " <> int.to_string(value), ..found]
    })
  let found =
    chain(list.append(equalities, equalities), " || ")
    |> support.on_both_targets([rules.ineffective_double_comparison()])
    |> testing.diagnostics
  assert list.length(found) == 150
  assert list.all(found, fn(found) {
    let assert Some(location) = found.location
    list.length(location.secondary) == 1
  })
}

// A function whose body is the comparisons joined by `operator`.
fn chain(comparisons: List(String), operator: String) -> String {
  "pub fn long(count: Int) -> Bool {\n  "
  <> string.join(comparisons, operator)
  <> "\n}\n"
}
