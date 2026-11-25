//// Tests for the default rule set as a whole: its rules, and hiding what
//// they report like any rule's.

import gleam/list
import grice/diagnostic
import grice/rule
import grice/rules
import grice/support
import grice/testing

// The set

pub fn default_has_each_built_in_rule_once_as_a_warning_test() {
  let codes = list.map(rules.default(), rule.code)
  assert codes
    == [
      "grice_rules/no-echo",
      "grice_rules/ineffective-double-comparison",
      "grice_rules/no-length-for-emptiness",
      "grice_rules/check-then-assert",
    ]
  let found =
    one_finding_each
    |> support.on_both_targets(rules.default())
    |> testing.diagnostics
  assert list.map(found, fn(found) { found.code }) == codes
  assert list.all(found, fn(found) { found.severity == diagnostic.Warning })
}

// A module with one finding for each rule of the default set, in the
// order of the set.
const one_finding_each =
  "import gleam/result
import gleam/string

pub fn printed(count: Int) -> Int {
  echo count
}

pub fn decided(count: Int) -> Bool {
  count > 5 && count > 0
}

pub fn counted(name: String) -> Bool {
  string.length(name) == 0
}

pub fn asserted(parsed: Result(Int, Nil)) -> Int {
  case result.is_ok(parsed) {
    True -> {
      let assert Ok(value) = parsed
      value
    }
    False -> 0
  }
}
"

// Hiding

const echo_module = "pub fn main() -> Int {\n  echo 1\n}\n"

pub fn a_built_in_finding_is_hidden_by_an_ignore_test() {
  support.project_on_both_targets(
    "[[tools.grice.ignore]]
paths = [\"src/app.gleam\"]
rules = [\"grice_rules/no-echo\"]
reason = \"This module prints on purpose.\"
",
    [#("src/app.gleam", echo_module)],
    rules.default(),
  )
  |> testing.expect_none
}

pub fn a_built_in_finding_is_hidden_by_a_suppression_test() {
  "pub fn main() -> Int {
  // grice-ignore grice_rules/no-echo: This prints on purpose.
  echo 1
}
"
  |> support.on_both_targets(rules.default())
  |> testing.expect_none
}

pub fn a_built_in_finding_is_hidden_by_a_file_suppression_test() {
  {
    "// grice-ignore-file grice_rules/no-echo: This prints on purpose.\n\n"
    <> echo_module
  }
  |> support.on_both_targets(rules.default())
  |> testing.expect_none
}
