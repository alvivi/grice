//// The corpus: pinned Hex packages that the corpus gate and the benchmark
//// run grice over. `test/corpus/` holds its pins: a `gleam.toml` that pins
//// each package, and a committed `manifest.toml` that pins them with their
//// own dependencies and checksums. They're copied into
//// `build/fixtures/corpus/`, a Gleam project with no modules, and
//// `gleam deps download` there fetches the packages under `build/`, which
//// git ignores and the compiler doesn't read. Downloaded into `test/`,
//// they'd be compiled as grice's tests.
////
//// Each package is loaded from its downloaded directory, with its own
//// `gleam.toml` and its `src/` as the lint set, and with every module of
//// the corpus as its dependencies. Those are read once and shared by
//// every load, as one project with those dependencies would read them.
//// What can't be loaded or run panics, described as grice describes a
//// run with no result.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import grice/coverage.{type Coverage, NotRequested, Requested}
import grice/diagnostic.{type Diagnostic}
import grice/internal/cli
import grice/internal/line_index
import grice/internal/loader
import grice/internal/render/human
import grice/internal/runner
import grice/rule.{type Rule}
import grice/rules
import grice/support
import simplifile
import tom

/// Every built-in rule, the default set, the simplify pack and the library
/// pack, which the gate and the benchmark both run.
pub fn built_in_rules() -> List(Rule) {
  rules.default()
  |> list.append(rules.simplify())
  |> list.append(rules.library())
}

/// The corpus project's directory, relative to grice's root, where the
/// packages are downloaded.
pub const root = "build/fixtures/corpus"

// Where the corpus's pins are committed. Never run gleam there.
const pins = "test/corpus"

/// The Gleam core team's packages in the corpus, by name: the gate and the
/// benchmark run over them.
pub const core = [
  "gleam_crypto", "gleam_erlang", "gleam_fetch", "gleam_http", "gleam_httpc",
  "gleam_javascript", "gleam_json", "gleam_otp", "gleam_regexp", "gleam_stdlib",
  "gleam_time", "gleam_yielder",
]

/// The community packages in the corpus, by name: only the benchmark runs
/// over them.
pub const community = ["girard", "glance", "lustre", "mist", "wisp"]

/// The corpus's installed modules, as `loader.installed` reads them: the
/// source of every module, by name, and the packages with no `src/`.
pub type Installed =
  #(Dict(String, String), List(loader.Package))

/// Copy the pins into the corpus project and download the corpus with
/// `gleam deps download`, which checks each package against the manifest,
/// the first time it's called in this runtime. Once gleam's cache has the
/// packages, it needs no network. Panics with gleam's output when the
/// download fails, and when gleam had to resolve the corpus again because
/// the pinned `gleam.toml` no longer matches the pinned manifest.
pub fn download() -> Nil {
  use <- support.once("download the corpus")
  let manifest = read(pins <> "/manifest.toml")
  support.write_files(root, [
    #("gleam.toml", read(pins <> "/gleam.toml")),
    #("manifest.toml", manifest),
  ])
  let assert Ok(#(status, stdout, stderr)) =
    support.run_gleam(
      support.absolute(root),
      ["deps", "download"],
      support.stderr_file("corpus-stderr"),
    )
    as "The corpus is downloaded with the gleam on PATH, and there's none."
  assert status == 0
    as { "gleam deps download failed for the corpus:\n" <> stdout <> stderr }
  assert read(root <> "/manifest.toml") == manifest
    as {
      pins
      <> "/gleam.toml no longer matches "
      <> pins
      <> "/manifest.toml, so gleam resolved the corpus again. After a bump on purpose, copy "
      <> root
      <> "/manifest.toml over "
      <> pins
      <> "/manifest.toml, then check that the gate passes and re-measure the budgets."
    }
}

/// The directory a downloaded package is in.
pub fn directory(package: String) -> String {
  root <> "/build/packages/" <> package
}

/// The version in the `gleam.toml` of the package in `directory`.
pub fn version(directory: String) -> String {
  let path = directory <> "/gleam.toml"
  let assert Ok(toml) = tom.parse(read(path)) as { path <> " isn't valid TOML" }
  let assert Ok(version) = tom.get_string(toml, ["version"])
    as { path <> " has no version" }
  version
}

/// Read the corpus's installed modules, once for every package loaded
/// with them.
pub fn installed() -> Installed {
  case loader.installed(root) {
    Ok(installed) -> installed
    Error(error) ->
      fail("Can't read the corpus's installed modules", cli.load_error(error))
  }
}

/// Load the downloaded `package` with the corpus's `installed` modules as
/// its dependencies, less its own modules, so no module has two sources,
/// as much of it as `rules` need.
pub fn load(
  package: String,
  installed: Installed,
  rules: List(Rule),
) -> loader.Project {
  let loaded =
    loader.load_project_with(
      directory(package),
      runner.scope(rules),
      installed: fn() { Ok(installed) },
    )
  case loaded {
    Ok(project) ->
      loader.Project(
        ..project,
        dependencies: dict.drop(
          project.dependencies,
          dict.keys(project.modules),
        ),
      )
    Error(error) ->
      fail("Can't load the corpus package " <> package, cli.load_error(error))
  }
}

/// Run `rules` over a loaded package.
pub fn lint(project: loader.Project, rules: List(Rule)) -> runner.Linted {
  case runner.run(project, rules) {
    Ok(linted) -> linted
    Error(problems) -> fail("The rule set is invalid", problems)
  }
}

/// How much of a package a run analysed: `<modules> modules, <parsed>
/// parsed, types <full>/<partial>/<none>`.
pub fn describe_coverage(coverage: Coverage) -> String {
  let types = case coverage.types {
    Requested(full:, partial:, none:) ->
      [full, partial, none] |> list.map(int.to_string) |> string.join("/")
    NotRequested -> "not requested"
  }
  int.to_string(coverage.modules)
  <> " modules, "
  <> int.to_string(coverage.parsed)
  <> " parsed, types "
  <> types
}

/// A diagnostic of the run over `package`, loaded as `project`, on one
/// line: `<package> <path>:<line>:<column> <code>: <primary label>`, or
/// `<package> <code>: <title>` when it has no location.
pub fn describe_diagnostic(
  package: String,
  project: loader.Project,
  found: Diagnostic,
) -> String {
  case found.location, position(project, found) {
    Some(location), Ok(#(path, line, column)) ->
      package
      <> " "
      <> describe_position(path, line, column)
      <> " "
      <> found.code
      <> ": "
      <> location.primary.message
    _, _ -> package <> " " <> found.code <> ": " <> found.title
  }
}

/// Where a diagnostic of the run over `project` is: its path, and the
/// line and column, counted from 1, where its primary label starts, or
/// `Error` when it has no location.
pub fn position(
  project: loader.Project,
  found: Diagnostic,
) -> Result(#(String, Int, Int), Nil) {
  case found.location {
    Some(location) -> {
      let assert Ok(source) = dict.get(loader.sources(project), location.path)
        as { "the project has no source at " <> location.path }
      let line_index.Position(line:, column:) =
        line_index.position(source, location.primary.span.start)
      Ok(#(location.path, line, column))
    }
    None -> Error(Nil)
  }
}

/// A position as `<path>:<line>:<column>`.
pub fn describe_position(path: String, line: Int, column: Int) -> String {
  path <> ":" <> int.to_string(line) <> ":" <> int.to_string(column)
}

fn fail(context: String, diagnostics: List(Diagnostic)) -> a {
  panic as { context <> ":\n\n" <> human.failure(diagnostics, colour: False) }
}

fn read(path: String) -> String {
  let assert Ok(text) = simplifile.read(path) as { "can't read " <> path }
  text
}
