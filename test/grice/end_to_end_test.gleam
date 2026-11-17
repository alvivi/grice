//// grice run the way a client runs it: through `gleam run`, on a fixture
//// project whose target is JavaScript, with an entry module in `dev/`
//// that runs two rules of its own, one syntactic and one typed.
////
//// The fixture lives in `build/fixtures/cli/` and keeps its build and its
//// manifest between runs, so only the first run resolves its dependencies,
//// which needs the network. Each test writes the files it needs over it.
//// The first scenario of a test run builds it, which resolves the
//// dependencies and compiles grice for the compiler in use, so no
//// scenario's standard error holds that output. A later rebuild of a
//// changed file prints nothing, as the fixture has no warnings, so each
//// scenario's standard error holds only what grice writes. Each snapshot is
//// the exit code and both streams, with the fixture's absolute path as
//// `<root>`.
////
//// The compiler never checks a definition for the other target, so the
//// `@target(javascript)` function with a type error compiles on Erlang,
//// while grice lints for the configured JavaScript target, where girard
//// can't type it: a coverage gap from code `gleam run` accepts.

import birdie
import gleam/int
import gleam/string
import grice/support

// Scenarios
//
// One real run each, with the exit code and both streams snapshotted.

pub fn human_output_from_a_subdirectory_test() {
  run(toml, in: "dev", module: "lint", flags: [])
  |> birdie.snap(title: "end to end: human output from a subdirectory")
}

pub fn json_output_test() {
  run(toml, in: "", module: "lint", flags: ["--format", "json"])
  |> birdie.snap(title: "end to end: json output")
}

pub fn strict_fails_over_a_coverage_gap_test() {
  run(toml, in: "", module: "lint", flags: ["--strict"])
  |> birdie.snap(title: "end to end: strict fails over a coverage gap")
}

pub fn warnings_as_errors_fails_over_a_warning_test() {
  run(toml, in: "", module: "lint", flags: ["--warnings-as-errors"])
  |> birdie.snap(title: "end to end: warnings as errors fails over a warning")
}

pub fn an_invalid_configuration_has_no_result_test() {
  run(toml <> "\n[tools.grice]\nnope = 1\n", in: "", module: "lint", flags: [])
  |> birdie.snap(title: "end to end: an invalid configuration has no result")
}

pub fn an_unknown_option_is_a_usage_error_test() {
  run(toml, in: "", module: "lint", flags: ["--nope"])
  |> birdie.snap(title: "end to end: an unknown option is a usage error")
}

// The built-in rule set is empty, so the suppression has nothing to hide.
pub fn the_built_in_rules_run_with_gleam_run_m_grice_test() {
  run(toml, in: "", module: "grice", flags: [])
  |> birdie.snap(title: "end to end: the built-in rules")
}

// A JavaScript client's own build still compiles the entry module, which
// calls `grice.run`, with no warnings.
pub fn the_fixture_builds_for_javascript_test() {
  support.write_files(support.fixture_directory("cli"), [
    #("gleam.toml", toml),
    #("src/app.gleam", app_without_the_gap),
    #("dev/lint.gleam", lint),
  ])
  let #(status, stdout, stderr) =
    gleam("", ["build", "--target", "javascript", "--warnings-as-errors"])
  assert status == 0 as { stdout <> stderr }
}

// Helpers
//
// The fixture's files, and running `gleam` on it.

const toml =
  "name = \"cli_fixture\"
version = \"1.0.0\"
target = \"javascript\"

[dependencies]
gleam_stdlib = \">= 0.44.0 and < 2.0.0\"

[dev_dependencies]
grice = { path = \"../../..\" }
glance = \">= 7.0.0 and < 8.0.0\"
girard = \">= 4.0.1 and < 5.0.0\"
"

const app_without_the_gap =
  "import gleam/int

pub fn main() -> Nil {
  let _ = int.parse(\"1\")
  Nil
}

pub fn unreachable() -> Nil {
  panic as \"This never runs.\"
}

pub fn hidden() -> Nil {
  // grice-ignore cli_fixture/no-panic: The tests show a hidden finding.
  panic as \"Neither does this.\"
}
"

const gap =
  "
@target(javascript)
pub fn broken() -> Int {
  \"not an int\"
}
"

const lint =
  "import girard
import glance
import grice
import grice/facts
import grice/rule

pub fn main() -> Nil {
  grice.run([no_panic(), discarded_result()])
}

fn no_panic() -> rule.Rule {
  rule.module(\"cli_fixture/no-panic\", title: \"Panic in the code\")
  |> rule.with_context(initial: Nil)
  |> rule.on_expression(fn(context, expression, _facts) {
    case expression {
      glance.Panic(location:, ..) -> #(context, [
        rule.report(at: location, label: \"This panics\"),
      ])
      _ -> #(context, [])
    }
  })
  |> rule.build
}

fn discarded_result() -> rule.Rule {
  rule.module(\"cli_fixture/discarded-result\", title: \"Result discarded\")
  |> rule.typed
  |> rule.with_context(initial: Nil)
  |> rule.on_statement(fn(context, statement, module_facts) {
    case statement {
      glance.Assignment(
        location:,
        kind: glance.Let,
        pattern: glance.PatternDiscard(..),
        value:,
        ..,
      ) ->
        case facts.type_of(module_facts, value.location) {
          Ok(girard.Named(module: \"gleam\", name: \"Result\", ..)) -> #(
            context,
            [rule.report(at: location, label: \"This discards a `Result`\")],
          )
          Ok(_) | Error(_) -> #(context, [])
        }
      _ -> #(context, [])
    }
  })
  |> rule.build
}
"

// Write the fixture with `gleam_toml`, build it, run
// `gleam run -m <module> -- <flags>` in its directory `directory`, and
// describe the outcome.
fn run(
  gleam_toml: String,
  in directory: String,
  module module: String,
  flags flags: List(String),
) -> String {
  support.write_files(support.fixture_directory("cli"), [
    #("gleam.toml", gleam_toml),
    #("src/app.gleam", app_without_the_gap <> gap),
    #("dev/lint.gleam", lint),
  ])
  once("build the end-to-end fixture", fn() {
    let #(status, stdout, stderr) = gleam("", ["build", "--target", "erlang"])
    assert status == 0 as { stdout <> stderr }
  })
  let #(status, stdout, stderr) =
    gleam(directory, [
      "run",
      "--no-print-progress",
      "--target",
      "erlang",
      "-m",
      module,
      "--",
      ..flags
    ])
  let root = support.absolute(support.fixture_directory("cli"))
  [
    "exit: " <> int.to_string(status),
    "stdout:\n" <> stdout,
    "stderr:\n" <> stderr,
  ]
  |> string.join("\n\n")
  |> string.replace(root, "<root>")
}

// Run `gleam` in the fixture's directory `directory`.
fn gleam(directory: String, arguments: List(String)) -> #(Int, String, String) {
  let fixture = support.absolute(support.fixture_directory("cli"))
  let directory = case directory {
    "" -> fixture
    _ -> fixture <> "/" <> directory
  }
  let assert Ok(outcome) =
    run_gleam(
      directory,
      arguments,
      support.absolute(support.fixture_directory("cli-stderr")),
    )
    as "The end-to-end tests run the gleam on PATH, and there's none."
  outcome
}

@external(erlang, "grice_test_ffi", "run_gleam")
fn run_gleam(
  directory: String,
  arguments: List(String),
  stderr_file: String,
) -> Result(#(Int, String, String), String)

// Call `f` the first time `once` is called with `key` in this test run.
@external(erlang, "grice_test_ffi", "once")
fn once(key: String, f: fn() -> Nil) -> Nil
