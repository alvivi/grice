//// Tests for `grice_rules/no-echo`, over its samples and small projects,
//// each linted for both targets.

import birdie
import gleam/list
import grice/rules
import grice/support
import grice/testing

const code = "grice_rules/no-echo"

// Samples

pub fn no_echo_flagged_samples_test() {
  let run =
    support.sample("no_echo_flagged")
    |> support.on_both_targets([rules.no_echo()])
  testing.expect_codes(run, list.repeat(code, 9))
  testing.render(run)
  |> birdie.snap(title: "built-in no-echo: flagged samples")
}

pub fn no_echo_clean_samples_test() {
  support.sample("no_echo_clean")
  |> support.on_both_targets([rules.no_echo()])
  |> testing.expect_none
}

// Paths

// `include` selects all three directories, and only the `echo` in `src/`
// is reported: tests and development tools may print as they like.
pub fn no_echo_is_silent_in_test_and_dev_test() {
  let module = "pub fn main() -> Int {\n  echo 1\n}\n"
  let run =
    support.project_on_both_targets(
      "[tools.grice]\ninclude = [\"src/\", \"test/\", \"dev/\"]\n",
      [
        #("src/app.gleam", module),
        #("test/app_test.gleam", module),
        #("dev/tool.gleam", module),
      ],
      [rules.no_echo()],
    )
  assert support.describe(testing.diagnostics(run))
    == [code <> " src/app.gleam: This prints debug output when it runs"]
}

// The default set

// With the whole default set, girard types a pipe into `echo` as the piped
// value. glance reads an operator after an `as` message into the message,
// so the second `echo`'s span runs to the end of its line.
pub fn no_echo_pipes_with_the_default_set_test() {
  let run =
    "import gleam/int

pub fn piped(count: Int) -> Int {
  count |> echo
}

pub fn piped_on_with_a_message(count: Int) -> String {
  count |> echo as \"count\" |> int.to_string
}
"
    |> support.on_both_targets(rules.default())
  testing.render(run)
  |> birdie.snap(title: "built-in no-echo: pipes with the default set")
}
