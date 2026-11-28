//// Tests for the library pack as a whole: its rules, running it beside the
//// default set and the simplify pack, and hiding what it reports like any
//// rule's.

import gleam/list
import grice/diagnostic
import grice/rule
import grice/rules
import grice/support
import grice/testing

// The pack

pub fn library_has_its_rules_as_warnings_test() {
  let codes = list.map(rules.library(), rule.code)
  assert codes
    == [
      "grice_rules/internal-type-in-public-api",
      "grice_rules/needlessly-public-function",
    ]
  let found =
    support.project_on_both_targets(toml, one_finding_each(), rules.library())
    |> testing.diagnostics
  assert list.map(found, fn(found) { found.code }) == codes
  assert list.all(found, fn(found) { found.severity == diagnostic.Warning })
}

// The runner rejects a rule set with a code twice, so the run shows that
// the three sets share none.
pub fn library_runs_beside_the_other_sets_test() {
  let all =
    rules.default()
    |> list.append(rules.simplify())
    |> list.append(rules.library())
  let codes = list.map(all, rule.code)
  assert list.unique(codes) == codes
  support.project_on_both_targets(toml, one_finding_each(), all)
  |> testing.expect_codes(list.map(rules.library(), rule.code))
}

const toml = "name = \"app\"\n"

// A module with one finding of the pack.
const app =
  "import app/internal/thing

pub fn make() -> thing.Thing {
  thing.new()
}
"

// A project with one finding of each rule of the pack, in the pack's order:
// `app` names an internal type, and nothing refers to `thing.unused`.
fn one_finding_each() -> List(#(String, String)) {
  [
    #("src/app.gleam", app),
    #(
      "src/app/internal/thing.gleam",
      "pub type Thing {\n  Thing\n}\n\npub fn new() -> Thing {\n  Thing\n}\n\npub fn unused() -> Thing {\n  Thing\n}\n",
    ),
  ]
}

// A project whose `app` is `source`, beside the internal module it imports.
fn one_finding(source: String) -> List(#(String, String)) {
  [
    #("src/app.gleam", source),
    #(
      "src/app/internal/thing.gleam",
      "pub type Thing {\n  Thing\n}\n\npub fn new() -> Thing {\n  Thing\n}\n",
    ),
  ]
}

// Hiding

pub fn a_library_finding_is_hidden_by_an_ignore_test() {
  support.project_on_both_targets(ignored, one_finding(app), rules.library())
  |> testing.expect_none
}

const ignored =
  "name = \"app\"

[[tools.grice.ignore]]
paths = [\"src/app.gleam\"]
rules = [\"grice_rules/internal-type-in-public-api\"]
reason = \"The type is public in the next release.\"
"

pub fn a_library_finding_is_hidden_by_a_suppression_test() {
  "import app/internal/thing

// grice-ignore grice_rules/internal-type-in-public-api: The type is public in the next release.
pub fn make() -> thing.Thing {
  thing.new()
}
"
  |> one_finding
  |> support.project_on_both_targets(toml, _, rules.library())
  |> testing.expect_none
}
