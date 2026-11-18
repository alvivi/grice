//// grice run the way a client runs it: through `gleam run`, on fixture
//// projects whose target is JavaScript, with an entry module in `dev/`
//// that runs two rules of their own, one syntactic and one typed.
////
//// There are two clients, written from the same constants, with the same
//// `gleam.toml` and `src/`. `build/fixtures/cli/` runs grice on Erlang,
//// and `build/fixtures/cli-javascript/` on JavaScript: its `dev/` also
//// calls a function only its own `.mjs` file implements, so it can only
//// run there. Each scenario runs on both, the test checks that both give
//// the same exit code and streams once each fixture's absolute path is
//// `<root>`, and the snapshot holds that outcome. The JavaScript client
//// runs its own entry module as its own command does, on the project's
//// configured target; every other run names its target: the Erlang
//// client's, which isn't the project's, and the built-in rules', a module
//// of grice's, which would otherwise run on Erlang.
////
//// Each fixture keeps its build and its manifest between runs, so only its
//// first run resolves its dependencies, which needs the network. Each test
//// writes the files it needs over them. The first scenario of a test run
//// builds each fixture, which resolves the dependencies and compiles grice
//// for the compiler in use, so no scenario's standard error holds that
//// output; the JavaScript one is built with `--warnings-as-errors`, so a
//// JavaScript client's build of grice stays clean. A later rebuild of a
//// changed file prints nothing, as the fixtures have no warnings, so each
//// scenario's standard error holds only what grice writes.
////
//// The compiler never checks a definition for the other target, so on
//// Erlang the `@target(javascript)` function with a type error compiles,
//// while grice lints for the configured JavaScript target, where girard
//// can't type it: a coverage gap from code `gleam run` accepts. On
//// JavaScript the compiler rejects it, so the `--strict` scenario, which
//// fails over that gap, runs on Erlang only.

import birdie
import gleam/int
import gleam/list
import gleam/string
import grice/support

// Scenarios
//
// One real run each on both runtimes, with the exit code and both streams
// snapshotted.

pub fn human_output_from_a_subdirectory_test() {
  on_both(toml, in: "dev", module: "lint", flags: [])
  |> birdie.snap(title: "end to end: human output from a subdirectory")
}

pub fn json_output_test() {
  on_both(toml, in: "", module: "lint", flags: ["--format", "json"])
  |> birdie.snap(title: "end to end: json output")
}

pub fn warnings_as_errors_fails_over_a_warning_test() {
  on_both(toml, in: "", module: "lint", flags: ["--warnings-as-errors"])
  |> birdie.snap(title: "end to end: warnings as errors fails over a warning")
}

pub fn an_invalid_configuration_has_no_result_test() {
  on_both(
    toml <> "\n[tools.grice]\nnope = 1\n",
    in: "",
    module: "lint",
    flags: [],
  )
  |> birdie.snap(title: "end to end: an invalid configuration has no result")
}

pub fn an_unknown_option_is_a_usage_error_test() {
  on_both(toml, in: "", module: "lint", flags: ["--nope"])
  |> birdie.snap(title: "end to end: an unknown option is a usage error")
}

// The built-in rule set is empty, so the suppression has nothing to hide.
pub fn the_built_in_rules_run_with_gleam_run_m_grice_test() {
  on_both(toml, in: "", module: "grice", flags: [])
  |> birdie.snap(title: "end to end: the built-in rules")
}

pub fn strict_fails_over_a_coverage_gap_test() {
  run(erlang, toml, app <> gap, in: "", module: "lint", flags: ["--strict"])
  |> birdie.snap(title: "end to end: strict fails over a coverage gap")
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

const app =
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

// The entry module's imports, which come before `main`.
const lint_imports =
  "import girard
import glance
import grice
import grice/facts
import grice/rule
"

// The entry module's rules, which come after `main`.
const lint_rules =
  "
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

// A client of grice: its fixture's name, the target `gleam run` compiles
// it for, and its `dev/` files.
type Client {
  Client(name: String, target: String, dev: List(#(String, String)))
}

// The client that runs grice on Erlang.
const erlang =
  Client(
    name: "cli",
    target: "erlang",
    dev: [
      #("dev/lint.gleam", lint_imports <> "
pub fn main() -> Nil {
  grice.run([no_panic(), discarded_result()])
}
" <> lint_rules),
    ],
  )

// The client that runs grice on JavaScript. Its entry module calls a
// function only its `.mjs` file implements first, so `gleam run` can't
// compile it for Erlang.
const javascript =
  Client(
    name: "cli-javascript",
    target: "javascript",
    dev: [
      #("dev/lint.gleam", "import native\n" <> lint_imports <> "
pub fn main() -> Nil {
  let _ = native.greeting()
  grice.run([no_panic(), discarded_result()])
}
" <> lint_rules),
      #(
        "dev/native.gleam",
        "@external(javascript, \"./native_ffi.mjs\", \"greeting\")
pub fn greeting() -> String
",
      ),
      #(
        "dev/native_ffi.mjs",
        "export function greeting() {\n  return \"Hello from JavaScript\";\n}\n",
      ),
    ],
  )

// Run a scenario on both clients, with `src/app.gleam` holding `app`,
// check that they agree, and describe the outcome.
fn on_both(
  gleam_toml: String,
  in directory: String,
  module module: String,
  flags flags: List(String),
) -> String {
  let on_erlang = run(erlang, gleam_toml, app, directory, module, flags)
  let on_javascript = run(javascript, gleam_toml, app, directory, module, flags)
  assert on_javascript == on_erlang
  on_erlang
}

// Write `client`'s fixture with `gleam_toml` and `app`, build it, run
// `gleam run -m <module> -- <flags>` in its directory `directory`, and
// describe the outcome. Only the JavaScript client's own entry module runs
// on the configured target; every other run names the client's.
fn run(
  client: Client,
  gleam_toml: String,
  app: String,
  in directory: String,
  module module: String,
  flags flags: List(String),
) -> String {
  let fixture = support.fixture_directory(client.name)
  support.write_files(fixture, [
    #("gleam.toml", gleam_toml),
    #("src/app.gleam", app),
    ..client.dev
  ])
  support.once("build the end-to-end fixture " <> client.name, fn() {
    let #(status, stdout, stderr) =
      gleam(client, "", [
        "build",
        "--target",
        client.target,
        "--warnings-as-errors",
      ])
    assert status == 0 as { stdout <> stderr }
  })
  let target = case client.target, module {
    "javascript", "lint" -> []
    _, _ -> ["--target", client.target]
  }
  let #(status, stdout, stderr) =
    gleam(client, directory, [
      "run",
      "--no-print-progress",
      ..list.append(target, ["-m", module, "--", ..flags])
    ])
  [
    "exit: " <> int.to_string(status),
    "stdout:\n" <> stdout,
    "stderr:\n" <> stderr,
  ]
  |> string.join("\n\n")
  |> string.replace(support.absolute(fixture), "<root>")
}

// Run `gleam` in the directory `directory` of `client`'s fixture.
fn gleam(
  client: Client,
  directory: String,
  arguments: List(String),
) -> #(Int, String, String) {
  let fixture = support.absolute(support.fixture_directory(client.name))
  let directory = case directory {
    "" -> fixture
    _ -> fixture <> "/" <> directory
  }
  let assert Ok(outcome) =
    support.run_gleam(
      directory,
      arguments,
      support.stderr_file(client.name <> "-stderr"),
    )
    as "The end-to-end tests run the gleam on PATH, and there's none."
  outcome
}
