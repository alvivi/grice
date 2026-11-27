//// Tests for the simplify pack as a whole: its rules, running them beside
//// the default set, and hiding what they report like any rule's.

import gleam/list
import grice/diagnostic
import grice/rule
import grice/rules
import grice/support
import grice/testing

// The pack

pub fn simplify_has_each_rule_once_as_a_warning_test() {
  let codes = list.map(rules.simplify(), rule.code)
  assert codes
    == [
      "grice_rules/map-then-flatten",
      "grice_rules/list-map-then-flatten",
      "grice_rules/filter-then-length",
    ]
  let found =
    one_finding_each
    |> support.on_both_targets(rules.simplify())
    |> testing.diagnostics
  assert list.map(found, fn(found) { found.code }) == codes
  assert list.all(found, fn(found) { found.severity == diagnostic.Warning })
}

// The runner rejects a rule set with a code twice, so the run shows that
// the two sets share none.
pub fn simplify_runs_beside_the_default_set_test() {
  let both = list.append(rules.default(), rules.simplify())
  let codes = list.map(both, rule.code)
  assert list.unique(codes) == codes
  one_finding_each
  |> support.on_both_targets(both)
  |> testing.expect_codes(list.map(rules.simplify(), rule.code))
}

// A module with one finding for each rule of the pack, in the order of the
// pack, and none for the default set.
const one_finding_each =
  "import gleam/list
import gleam/result

pub fn parsed(text: Result(Int, Nil), check: fn(Int) -> Result(Int, Nil)) -> Result(Int, Nil) {
  text |> result.map(check) |> result.flatten
}

pub fn cells(rows: List(Int), cells: fn(Int) -> List(Int)) -> List(Int) {
  rows |> list.map(cells) |> list.flatten
}

pub fn adults(ages: List(Int), adult: fn(Int) -> Bool) -> Int {
  ages |> list.filter(adult) |> list.length
}
"

// Hiding

// A module with one finding of the pack.
const one_finding =
  "import gleam/result

pub fn parsed(text: Result(Int, Nil), check: fn(Int) -> Result(Int, Nil)) -> Result(Int, Nil) {
  text |> result.map(check) |> result.flatten
}
"

pub fn a_simplify_finding_is_hidden_by_an_ignore_test() {
  support.project_on_both_targets(
    "[[tools.grice.ignore]]
paths = [\"src/app.gleam\"]
rules = [\"grice_rules/map-then-flatten\"]
reason = \"This module keeps the two steps apart.\"
",
    [#("src/app.gleam", one_finding)],
    rules.simplify(),
  )
  |> testing.expect_none
}

pub fn a_simplify_finding_is_hidden_by_a_suppression_test() {
  "import gleam/result

pub fn parsed(text: Result(Int, Nil), check: fn(Int) -> Result(Int, Nil)) -> Result(Int, Nil) {
  // grice-ignore grice_rules/map-then-flatten: The two steps read better apart.
  text |> result.map(check) |> result.flatten
}
"
  |> support.on_both_targets(rules.simplify())
  |> testing.expect_none
}

// In a pipe written over several lines, the label starts at the first call
// it covers, after the piped value, so the suppression goes above that
// call's line. One above the pipe's first line hides nothing, and is
// reported as unused.
pub fn a_simplify_finding_in_a_multi_line_pipe_is_hidden_above_its_label_test() {
  "import gleam/result

pub fn parsed(text: Result(Int, Nil), check: fn(Int) -> Result(Int, Nil)) -> Result(Int, Nil) {
  text
  // grice-ignore grice_rules/map-then-flatten: The two steps read better apart.
  |> result.map(check)
  |> result.flatten
}
"
  |> support.on_both_targets(rules.simplify())
  |> testing.expect_none
  "import gleam/result

pub fn parsed(text: Result(Int, Nil), check: fn(Int) -> Result(Int, Nil)) -> Result(Int, Nil) {
  // grice-ignore grice_rules/map-then-flatten: The two steps read better apart.
  text
  |> result.map(check)
  |> result.flatten
}
"
  |> support.on_both_targets(rules.simplify())
  |> testing.expect_codes([
    "grice/unused-suppression",
    "grice_rules/map-then-flatten",
  ])
}
