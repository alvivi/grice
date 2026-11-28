//// Tests for `grice_rules/needlessly-public-function`, over its samples
//// and small projects, each linted for both targets unless what it reads
//// depends on the target. The samples are linted at their module names'
//// paths, as modules of a package named `grice`, whose default patterns
//// make `unreferenced` and `referenced` internal, with the modules that
//// refer to `referenced` under `src/`, `test/` and `dev/`. Each project
//// the rule must leave alone has a reporting control beside it, so a test
//// can't pass because the rule reads nothing.

import birdie
import gleam/bit_array
import gleam/list
import gleam/option.{Some}
import gleam/string
import grice/diagnostic.{type Diagnostic}
import grice/internal/loader
import grice/internal/runner
import grice/rules
import grice/support
import grice/testing

const code = "grice_rules/needlessly-public-function"

// Samples

// Each finding is at its function's name. `marked_too` is marked
// `@internal` in an internal module, and gets the internal module's
// wording; the wording test below shows both wordings in full.
pub fn needlessly_public_function_flagged_samples_test() {
  let files = [
    #(
      "src/grice/internal/rules/samples/unreferenced.gleam",
      support.internal_sample("unreferenced"),
    ),
    #(
      "src/grice/rules/samples/needlessly_public_function_flagged.gleam",
      support.sample("needlessly_public_function_flagged"),
    ),
  ]
  let diagnostics = testing.diagnostics(lint("name = \"grice\"\n", files))
  assert list.map(diagnostics, name_of)
    == [
      "unused", "marked_too", "external", "start", "used_inside", "calls_inside",
      "marked",
    ]
  list.each(diagnostics, fn(found) {
    let assert Some(location) = found.location
    let assert Ok(source) = list.key_find(files, location.path)
    let span = location.primary.span
    assert bit_array.slice(<<source:utf8>>, span.start, span.end - span.start)
      == Ok(<<{ name_of(found) }:utf8>>)
  })
  let assert [_, marked_too, ..] = diagnostics
  let assert [message] = marked_too.message
  assert string.starts_with(
    message,
    "The public function `marked_too` is in the internal module",
  )
}

// The finding as a user sees it, once for each reason a function isn't
// public API: it's marked `@internal`, or its module is internal.
pub fn needlessly_public_function_wording_test() {
  lint(toml, [
    #("src/app.gleam", "@internal\npub fn helper() -> Int {\n  1\n}\n"),
    #("src/app/internal/parser.gleam", "pub fn parse() -> Int {\n  1\n}\n"),
  ])
  |> testing.render
  |> birdie.snap(title: "built-in needlessly-public-function: wording")
}

pub fn needlessly_public_function_clean_samples_test() {
  lint(start_module, [referenced(), ..users()])
  |> testing.expect_none
}

// Without the modules and foreign sources that refer to `referenced`, each
// function they refer to is reported, but `main` and `start`, and
// `via_external`, which `referenced` itself calls through an `@external`;
// without `application_start_module`, `start` is reported too. A plain
// call in the same module doesn't count, as `used_inside` shows above.
pub fn needlessly_public_function_clean_samples_control_test() {
  let referred = [
    "qualified", "aliased", "unqualified", "renamed", "in_constant",
    "other_target", "from_test", "from_dev", "from_erlang", "from_javascript",
  ]
  assert names(lint(start_module, [referenced()]))
    == list.append(referred, ["through_external"])
  assert names(lint("name = \"grice\"\n", [referenced()]))
    == list.append(referred, ["start", "through_external"])
}

const start_module =
  "name = \"grice\"

[erlang]
application_start_module = \"grice/internal/rules/samples/referenced\"
"

fn referenced() -> #(String, String) {
  #(
    "src/grice/internal/rules/samples/referenced.gleam",
    support.internal_sample("referenced"),
  )
}

// The clean samples that refer to `referenced`, each at its path.
fn users() -> List(#(String, String)) {
  let module = fn(directory, name) {
    #(
      directory <> "/grice/rules/samples/" <> name <> ".gleam",
      support.sample(name),
    )
  }
  let foreign = fn(file) {
    #("test/grice/rules/samples/" <> file, support.foreign_sample(file))
  }
  [
    module("src", "needlessly_public_function_clean"),
    module("src", "needlessly_public_function_aliased"),
    module("src", "needlessly_public_function_other_target"),
    module("test", "needlessly_public_function_test_use"),
    module("dev", "needlessly_public_function_dev_use"),
    foreign("needlessly_public_function_ffi.erl"),
    foreign("needlessly_public_function_ffi.mjs"),
  ]
}

// Uses the compiler warns on, or the samples can't show

// The internal module the projects below read.
const parser = #(
  "src/app/internal/parser.gleam",
  "pub fn parse() -> Int {\n  1\n}\n\npub fn other() -> Int {\n  2\n}\n",
)

const toml = "name = \"app\"\n"

// Each project, with the functions of `parser` still reported, linted on
// both targets, so a use compiled for one target only counts on the other.
// The first is the control, with no use.
pub fn each_form_of_use_test() {
  let app = fn(source) { [parser, #("src/app.gleam", source)] }
  let variable = fn(name) {
    "import app/internal/parser\n\npub type Config {\n  Config(parse: Int)\n}\n\npub fn main() {\n  let read = fn("
    <> name
    <> ": Config) { "
    <> name
    <> ".parse }\n  read(Config(parser.other()))\n}\n"
  }
  let external = fn(module) {
    "@external(erlang, \"app@internal@"
    <> module
    <> "\", \"parse\")\n@external(javascript, \"./app/internal/"
    <> module
    <> ".mjs\", \"other\")\npub fn read() -> Int\n"
  }
  let erlang = fn(module, function) {
    [
      parser,
      #(
        "src/app_ffi.erl",
        "-module(app_ffi).\n-export([call/0]).\n\ncall() -> '"
          <> module
          <> "':"
          <> function
          <> "().\n",
      ),
    ]
  }
  let cases = [
    #(app(""), ["parse", "other"]),
    // An unqualified import, though nothing uses it, which the compiler
    // warns about.
    #(app("import app/internal/parser.{other, parse}\n"), []),
    // An import for one target, in a module with no definition so marked.
    #(app("@target(javascript)\nimport app/internal/parser.{parse}\n"), [
      "other",
    ]),
    #(app("@target(erlang)\nimport app/internal/parser.{other}\n"), ["parse"]),
    // A parameter named like the qualifier, which shadows it, counts; one
    // named otherwise doesn't.
    #(app(variable("parser")), []),
    #(app(variable("config")), ["parse"]),
    // A discarded alias qualifies nothing, so `parser.parse` is a field.
    #(
      app(
        "import app/internal/parser.{other} as _parser\n\npub type Config {\n  Config(parse: Int)\n}\n\npub fn main() {\n  let read = fn(parser: Config) { parser.parse }\n  read(Config(other()))\n}\n",
      ),
      ["parse"],
    ),
    // An `@external` naming the module by its Erlang name or its
    // JavaScript file, and one naming another module.
    #(app(external("parser")), []),
    #(app(external("lexer")), ["parse", "other"]),
    // An Erlang module written `*` is just a module name.
    #(app("@external(erlang, \"*\", \"parse\")\npub fn read() -> Int\n"), [
      "parse",
      "other",
    ]),
    // A JavaScript module that isn't a relative path to a `.mjs` file may
    // be any module, so the name is a use of every candidate so named.
    #(
      app(
        "@external(javascript, \"app/parser-api\", \"parse\")\npub fn read() -> Int\n",
      ),
      ["other"],
    ),
    // A foreign source naming the module and holding the name, and two
    // that miss one of them.
    #(erlang("app@internal@parser", "parse"), ["other"]),
    // Elixir, which the compiler builds too.
    #(
      [
        parser,
        #(
          "src/interop.ex",
          "defmodule Interop do\n  def read(), do: :'app@internal@parser'.parse()\nend\n",
        ),
      ],
      ["other"],
    ),
    #(erlang("app@internal@lexer", "parse"), ["parse", "other"]),
    #(erlang("app@internal@parser", "parsed"), ["parse", "other"]),
  ]
  list.each(cases, fn(entry) {
    let #(files, expected) = entry
    assert names(lint(toml, files)) == expected as string.inspect(files)
  })
}

// Candidates

// A function the target leaves out isn't one, as its module is compiled.
pub fn a_function_for_the_other_target_isnt_read_test() {
  let files = [
    #(
      "src/app/internal/parser.gleam",
      "@target(javascript)\npub fn parse() -> Int {\n  1\n}\n",
    ),
  ]
  support.project_on_target("erlang", toml, files, [rule()])
  |> testing.expect_none
  support.project_on_target("javascript", toml, files, [rule()])
  |> testing.expect_codes([code])
}

// Only linted modules under `src/` have candidates: an excluded module's
// functions and a test module's aren't read, though both are internal.
pub fn only_linted_modules_under_src_are_read_test() {
  lint(toml <> "[tools.grice]\nexclude = [\"src/app/internal/\"]\n", [
    parser,
    #("src/app.gleam", ""),
  ])
  |> testing.expect_none
  lint(toml <> "[tools.grice]\ninclude = [\"src/\", \"test/\"]\n", [
    #("src/app.gleam", ""),
    #("test/app/internal/helper.gleam", "pub fn unused() -> Int {\n  1\n}\n"),
  ])
  |> testing.expect_none
  assert names(lint(toml, [parser, #("src/app.gleam", "")]))
    == ["parse", "other"]
}

// The compiler writes `application_start_module` in the application file
// with each `/` turned into `@`, so an Erlang name, as mist writes it,
// names the module just as its Gleam name does. A value that names no
// Gleam module, such as a module of Erlang code, exempts no `start`, and
// one written with a `\`, which grice's TOML reader leaves as written,
// exempts every `start`.
pub fn the_start_module_is_compared_by_its_erlang_name_test() {
  let start = "pub fn start() -> Int {\n  1\n}\n"
  let files = [
    #("src/app/internal/supervisor.gleam", start),
    #("src/app/internal/worker.gleam", start),
  ]
  let with_start = fn(module) {
    lint(
      toml <> "\n[erlang]\napplication_start_module = \"" <> module <> "\"\n",
      files,
    )
    |> names
  }
  assert with_start("app/internal/supervisor") == ["start"]
  assert with_start("app@internal@supervisor") == ["start"]
  assert with_start("app_supervisor") == ["start", "start"]
  assert with_start("app\\u002finternal\\u002fsupervisor") == []
}

// An incomplete project

// A test module that doesn't parse might refer to any function, so the
// rule doesn't run, and its note says why.
pub fn a_test_module_that_doesnt_parse_stops_the_rule_test() {
  lint(toml, [parser, #("test/app_test.gleam", "pub fn (")])
  |> testing.expect_codes(["grice/incomplete-project"])
  assert names(lint(toml, [parser, #("test/app_test.gleam", "")]))
    == ["parse", "other"]
}

// So does a foreign source that can't be read, which might name any
// function.
pub fn a_foreign_source_that_cant_be_read_stops_the_rule_test() {
  let run = fn(unreadable) {
    let project =
      support.project_with(
        toml,
        [parser],
        [],
        scope: loader.LoadWholeProject,
        unreadable:,
      )
    let assert Ok(runner.Linted(diagnostics:, ..)) =
      runner.run(project, [rule()])
    list.map(diagnostics, fn(found) { found.code })
  }
  assert run(["src/app_ffi.mjs"]) == ["grice/incomplete-project"]
  assert run([]) == [code, code]
}

// Hiding

pub fn a_finding_is_hidden_by_a_suppression_test() {
  let parser =
    "// grice-ignore grice_rules/needlessly-public-function: Kept for the next release.\npub fn parse() -> Int {\n  1\n}\n"
  lint(toml, [#("src/app/internal/parser.gleam", parser)])
  |> testing.expect_none
}

// Helpers

fn rule() {
  rules.needlessly_public_function()
}

// Run the rule over the project of `files` with the `gleam.toml` text
// `toml`, on both targets.
fn lint(toml: String, files: List(#(String, String))) -> testing.Run {
  support.project_on_both_targets(toml, files, [rule()])
}

// The name of the function each finding of the run is on.
fn names(run: testing.Run) -> List(String) {
  list.map(testing.diagnostics(run), name_of)
}

// The name of the function a finding is on, from its label.
fn name_of(found: Diagnostic) -> String {
  let assert Some(location) = found.location
  string.replace(
    location.primary.message,
    "no other Gleam module refers to `",
    "",
  )
  |> string.drop_end(1)
}
