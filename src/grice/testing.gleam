//// Testing rules: `module` or `project` builds a project in memory, `run`
//// runs rules over it, and `expect_none` and `expect_codes` check it. A
//// fixture is loaded and linted the way grice lints a project on disk, so
//// its `gleam.toml`, its target, the modules its linted modules import,
//// ignores and suppression comments all apply:
////
//// ```gleam
//// import grice/testing
//// import my_rules/no_echo
////
//// pub fn no_echo_reports_each_echo_test() {
////   testing.module("pub fn main() {\n  echo 1\n  echo 2\n}\n")
////   |> testing.run([no_echo.rule()])
////   |> testing.expect_codes(["my_rules/no-echo", "my_rules/no-echo"])
//// }
//// ```
////
//// When the codes don't match, `expect_none` and `expect_codes` panic with
//// the fixture and what grice printed for it, and every test runner reports
//// the panic as a failure. A test can also check the run's `diagnostics`
//// itself, or snapshot its `render` with a library such as birdie. The kit
//// depends on no test runner and no snapshot library.
////
//// A run with a typed rule reads the dependencies installed for the
//// project through `manifest.toml` in the working directory, so a fixture
//// can import `gleam/list`, or any module the project's own code can, and
//// girard answers from the same sources as in a real run. `gleam test`
//// runs in the directory it's started from, so start it from the project
//// root. A run with no typed rule reads nothing from disk.
////
//// Where girard has no answer, a typed rule should stay silent, and grice
//// adds a note on the code girard couldn't type. A test of that silence
//// expects exactly that note, which shows both that the rule stayed silent
//// and why:
////
//// ```gleam
//// pub fn discarded_result_is_silent_over_a_gap_test() {
////   testing.module("pub fn main() {\n  let _ = 1 + \"one\"\n}\n")
////   |> testing.run([discarded_result.rule()])
////   |> testing.expect_codes(["grice/untyped-definition"])
//// }
//// ```
////
//// [Testing rules](https://github.com/alvivi/grice/blob/main/docs/TESTING.md)
//// covers each way to check a run, with examples.

import gleam/bool
import gleam/dict.{type Dict}
import gleam/list
import gleam/result
import gleam/string
import grice/diagnostic.{type Diagnostic}
import grice/internal/cli
import grice/internal/config
import grice/internal/loader.{type LoadError, type Package}
import grice/internal/render/human
import grice/internal/runner
import grice/rule.{type Rule}

// Fixtures
//
// A fixture is the files of a project, as written in the test, and the
// dependency modules it adds.

/// A project to run rules over, built in memory.
pub opaque type Fixture {
  Fixture(
    /// `#(path, source)`, in the order given.
    files: List(#(String, String)),
    /// `#(module name, source)`, in the order added.
    dependencies: List(#(String, String)),
  )
}

/// A project with one module, `src/app.gleam`, whose source is `source`,
/// and the default configuration.
///
/// ```gleam
/// testing.module("pub fn main() {\n  echo 1\n}\n")
/// |> testing.run([no_echo.rule()])
/// |> testing.expect_codes(["my_rules/no-echo"])
/// ```
pub fn module(source: String) -> Fixture {
  project([#("src/app.gleam", source)])
}

/// A project with the files of `files`, each a `#(path, source)` with a
/// path relative to the project root.
///
/// `gleam.toml` is the project's configuration: grice reads its
/// `[tools.grice]` table and its `target`, and without one the defaults
/// apply, which lint `src/` on Erlang. Every other file is a module: its
/// path is under `src/`, `test/` or `dev/` and ends in `.gleam`, and each
/// of its segments is a lowercase letter followed by lowercase letters,
/// digits and `_`, as the compiler requires. This panics on any other
/// path, on a path given twice, and on two paths that give one module
/// name, such as `src/app.gleam` and `test/app.gleam`: grice would skip
/// those files, so no rule would see them.
///
/// ```gleam
/// testing.project([
///   #("gleam.toml", "[tools.grice]\nexclude = [\"src/app/generated/\"]\n"),
///   #("src/app.gleam", "import app/generated/sql\n"),
///   #("src/app/generated/sql.gleam", "pub fn query() {\n  echo 1\n}\n"),
/// ])
/// |> testing.run([no_echo.rule()])
/// |> testing.expect_none
/// ```
pub fn project(files: List(#(String, String))) -> Fixture {
  // The fold is there for its panics: what it has seen isn't needed after.
  let _seen = list.fold(files, dict.new(), check_path)
  Fixture(files:, dependencies: [])
}

/// Add the dependency module `module`, such as `gleam/json`, with the
/// source `source`, for typed rules: girard resolves the fixture's imports
/// against it. It takes the place of an installed module of the same name,
/// so a test can stand in for a dependency the project doesn't have, or
/// give one a source of its own. No rule runs on a dependency module. This
/// panics when `module` was already added.
///
/// ```gleam
/// testing.module("import shapes/square\n\npub fn main() {\n  square.new(2)\n}\n")
/// |> testing.with_dependency(
///   module: "shapes/square",
///   source: "pub type Square {\n  Square(Int)\n}\n\npub fn new(size: Int) -> Square {\n  Square(size)\n}\n",
/// )
/// |> testing.run([my_typed_rule.rule()])
/// |> testing.expect_none
/// ```
pub fn with_dependency(
  fixture: Fixture,
  module module: String,
  source source: String,
) -> Fixture {
  case list.key_find(fixture.dependencies, module) {
    Ok(_) ->
      panic as {
        "The dependency module `"
        <> module
        <> "` is added twice. A module has one source, so only one of them would be used."
      }
    Error(Nil) ->
      Fixture(
        ..fixture,
        dependencies: list.append(fixture.dependencies, [#(module, source)]),
      )
  }
}

// Check a file's path against the files before it, which `seen` holds by
// module name, and `gleam.toml` by its path. A path given twice finds
// itself.
fn check_path(
  seen: Dict(String, String),
  file: #(String, String),
) -> Dict(String, String) {
  let path = file.0
  let key = case path {
    "gleam.toml" -> Ok(path)
    _ -> loader.module_name(path)
  }
  case key, result.try(key, dict.get(seen, _)) {
    Error(Nil), _ ->
      panic as {
        "The fixture path `"
        <> path
        <> "` is neither `gleam.toml` nor a module path. A module path is under `src/`, `test/` or `dev/` and ends in `.gleam`, and each of its segments is a lowercase letter followed by lowercase letters, digits and `_`. grice would skip this file, so no rule would see it."
      }
    Ok(_), Ok(other) if other == path ->
      panic as {
        "The fixture path `"
        <> path
        <> "` is given twice. A project has one file at each path, so only one of them would be used."
      }
    Ok(name), Ok(other) ->
      panic as {
        "The fixture paths `"
        <> other
        <> "` and `"
        <> path
        <> "` give one module name, `"
        <> name
        <> "`, which the compiler rejects. grice would load only the first, so no rule would see the second."
      }
    Ok(name), Error(Nil) -> dict.insert(seen, name, path)
  }
}

// Running
//
// A fixture runs through the same loader and runner as a project on disk,
// and only a typed run reads anything: the installed dependencies.

/// What running rules over a fixture found.
pub opaque type Run {
  Run(fixture: Fixture, project: loader.Project, linted: runner.Linted)
}

/// Run `rules` over the fixture, as grice runs them over a project.
///
/// A typed rule in `rules` makes the run read the installed dependencies
/// from the working directory, as the module docs describe. This panics,
/// showing the problem as grice shows it, when `gleam.toml` is invalid or
/// selects no module to lint, a module to lint doesn't parse, the rule
/// set is invalid, or a typed run can't read the installed dependencies.
/// A module that isn't linted may fail to parse, which is how a test gives
/// girard an import it can't use. A rule that panics panics through `run`.
///
/// ```gleam
/// let run = testing.module("pub fn main() {\n  1\n}\n") |> testing.run([no_echo.rule()])
/// ```
pub fn run(fixture: Fixture, rules: List(Rule)) -> Run {
  run_with(fixture, rules, installed: fn() { loader.installed(".") })
}

/// Run `rules` as `run` does, with `installed` reading the installed
/// dependencies: it's called once when a rule of the set is typed, and
/// never otherwise.
@internal
pub fn run_with(
  fixture: Fixture,
  rules: List(Rule),
  installed installed: fn() ->
    Result(#(Dict(String, String), List(Package)), LoadError),
) -> Run {
  let toml = list.key_find(fixture.files, "gleam.toml") |> result.unwrap("")
  let sources = dict.from_list(fixture.files)
  let loaded = {
    use config <- result.try(
      config.parse(toml) |> result.map_error(loader.InvalidConfig),
    )
    let #(dependencies, missing_dependencies) =
      dependencies(fixture, rules, installed)
    loader.load(
      root: ".",
      config:,
      // `gleam.toml` isn't a module path, so the loader skips it.
      paths: list.map(fixture.files, fn(file) { file.0 }),
      read: fn(path) {
        dict.get(sources, path)
        |> result.replace_error("The fixture has no file at this path")
      },
      dependencies:,
      missing_dependencies:,
    )
  }
  let project = case loaded {
    Ok(project) -> project
    Error(error) -> fail(cli.load_error(error))
  }
  use <- bool.lazy_guard(when: project.diagnostics != [], return: fn() {
    unparsed(project)
  })
  case runner.run(project, rules) {
    Ok(linted) -> Run(fixture:, project:, linted:)
    Error(problems) -> fail(problems)
  }
}

const options = human.Options(colour: False, directory: "")

// The dependency modules of a run, with the packages whose sources are
// missing. A typed run gets the installed modules, the fixture's own taking
// the place of any with the same name; any other run only the fixture's.
fn dependencies(
  fixture: Fixture,
  rules: List(Rule),
  installed: fn() -> Result(#(Dict(String, String), List(Package)), LoadError),
) -> #(Dict(String, String), List(Package)) {
  let own = dict.from_list(fixture.dependencies)
  use <- bool.guard(when: !list.any(rules, rule.is_typed), return: #(own, []))
  case installed() {
    Ok(#(modules, missing)) -> #(dict.merge(modules, own), missing)
    Error(error) -> not_installed(error)
  }
}

// A typed run that can't read the installed dependencies. A manifest that
// can't be read most likely means the tests run from another directory.
fn not_installed(error: LoadError) -> a {
  let advice = case error {
    loader.CannotRead(path: "manifest.toml", ..) ->
      human.wrap(
        "Typed tests read the installed dependencies through `manifest.toml` in the working directory, so run `gleam test` from the project root.",
      )
      <> "\n\n"
    loader.CannotRead(..)
    | loader.InvalidConfig(..)
    | loader.InvalidManifest(..) -> ""
  }
  panic as { advice <> human.failure(cli.load_error(error), colour: False) }
}

// A run with no result, shown as grice shows one.
fn fail(diagnostics: List(Diagnostic)) -> a {
  panic as human.failure(diagnostics, colour: False)
}

// A module to lint that doesn't parse: its parse error points into the
// source, so it's shown with it.
fn unparsed(project: loader.Project) -> a {
  let rendered = case
    human.render(project.diagnostics, loader.sources(project), options)
  {
    Ok(text) -> text
    Error(error) -> panic as human.bug_report(error)
  }
  panic as {
    rendered
    <> human.wrap(
      "A test over a module that doesn't parse would prove nothing, so the run stops here. Fix the module, or exclude it in `gleam.toml` if the test needs a linted module to import one that doesn't parse.",
    )
    <> "\n"
  }
}

// Reading a run
//
// A run as a snapshot shows its input with its output, so it reviews on
// its own. The assertions show the same text when they fail.

/// Every diagnostic the run shows, in the order `grice.diagnostics` gives
/// them: what the rules reported that no ignore or suppression hid, and
/// grice's own, such as a note on code girard couldn't type.
///
/// Their spans are byte offsets on every target, while the spans rules see
/// count glance's units, which are UTF-16 code units on JavaScript. In a
/// fixture that's all ASCII, the two are the same.
///
/// ```gleam
/// let assert [found] =
///   testing.module("pub fn main() {\n  echo 1\n}\n")
///   |> testing.run([no_echo.rule()])
///   |> testing.diagnostics
/// assert found.severity == diagnostic.Warning
/// ```
pub fn diagnostics(run: Run) -> List(Diagnostic) {
  run.linted.diagnostics
}

/// The run as text, for a snapshot: each file of the fixture in the order
/// given, under a `-- <path>` line, then each module added with
/// `with_dependency` in the order added, under a `-- dependency <module>`
/// line, then an `-- output` line and what grice prints for the run,
/// without colour and with paths relative to the project root: the
/// diagnostics and the summary. A source that doesn't end in a newline
/// gets one. Installed dependencies aren't shown.
///
/// ```gleam
/// testing.module("pub fn main() {\n  echo 1\n}\n")
/// |> testing.run([no_echo.rule()])
/// |> testing.render
/// |> birdie.snap(title: "no_echo reports each echo")
/// ```
///
/// gives:
///
/// ```text
/// -- src/app.gleam
/// pub fn main() {
///   echo 1
/// }
/// -- output
/// warning[my_rules/no-echo]: Echo left in the code
///   ┌─ src/app.gleam:2:3
///   │
/// 2 │   echo 1
///   │   ^^^^^^ This prints when it runs
///
/// 1 warning in 1 module.
/// ```
///
/// Like `grice.render`, this panics only on a bug in grice, with a message
/// asking for a report.
pub fn render(run: Run) -> String {
  let files = list.map(run.fixture.files, section("-- ", _))
  let dependencies =
    list.map(run.fixture.dependencies, section("-- dependency ", _))
  let output = case human.run(run.project, run.linted, options) {
    Ok(text) -> text
    Error(error) -> panic as human.bug_report(error)
  }
  string.concat(list.flatten([files, dependencies, ["-- output\n", output]]))
}

/// Check that the run shows no diagnostic at all, grice's own included, or
/// panic with the codes it shows and the rendered run.
///
/// ```gleam
/// testing.module("pub fn main() {\n  1\n}\n")
/// |> testing.run([no_echo.rule()])
/// |> testing.expect_none
/// ```
pub fn expect_none(run: Run) -> Nil {
  expect(run, [], "Expected no diagnostics")
}

/// Check that the codes of the run's diagnostics, in the order
/// `diagnostics` gives them, are exactly `codes`, grice's own included, or
/// panic with the codes it shows and the rendered run.
///
/// ```gleam
/// testing.module("pub fn main() {\n  echo 1\n  echo 2\n}\n")
/// |> testing.run([no_echo.rule()])
/// |> testing.expect_codes(["my_rules/no-echo", "my_rules/no-echo"])
/// ```
pub fn expect_codes(run: Run, codes: List(String)) -> Nil {
  expect(run, codes, "Expected the codes " <> string.inspect(codes))
}

// One part of a render: `prefix` and the name on a line, then the text,
// ending in a newline.
fn section(prefix: String, entry: #(String, String)) -> String {
  let #(name, text) = entry
  let text = case string.ends_with(text, "\n") {
    True -> text
    False -> text <> "\n"
  }
  prefix <> name <> "\n" <> text
}

// Panic unless the codes of the run's diagnostics are `codes`, saying what
// was `expected`, the codes found and the rendered run.
fn expect(run: Run, codes: List(String), expected: String) -> Nil {
  let found = list.map(diagnostics(run), fn(shown) { shown.code })
  use <- bool.guard(when: found == codes, return: Nil)
  panic as {
    expected <> ", got " <> string.inspect(found) <> ":\n\n" <> render(run)
  }
}
