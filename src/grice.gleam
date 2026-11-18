//// grice, a type-aware linter for Gleam.
////
//// `gleam run -m grice` runs grice's built-in rules over the project, with
//// `main`. A project with rules of its own gives grice a module of its own,
//// such as `dev/lint.gleam`, whose `main` calls `run` with them:
////
//// ```gleam
//// import grice
//// import my_app/lint/no_io_in_view
////
//// pub fn main() -> Nil {
////   grice.run([no_io_in_view.rule()])
//// }
//// ```
////
//// and runs it with `gleam run -m lint -- [OPTIONS]`; `--help` lists the
//// options.
////
//// The rest of this module is the library API, for tools that lint a
//// project themselves, such as an editor integration or a script:
////
//// ```gleam
//// import gleam/io
//// import grice
//// import grice/rule.{type Rule}
////
//// pub fn report(rules: List(Rule)) -> Nil {
////   let assert Ok(project) = grice.load_project(".")
////   let assert Ok(linted) = grice.lint(project, rules)
////   grice.render(linted, format: grice.Human(colour: False, directory: ""))
////   |> io.print
//// }
//// ```
////
//// `load_project` reads everything a run needs from disk, and `lint` then
//// works only on that value, so the same project and rules always give
//// the same result, wherever it runs from. `diagnostics` and `coverage`
//// give what the run found as values to pattern-match on; `render` gives
//// the text grice prints.

import gleam/bool
import gleam/io
import gleam/option.{None}
import gleam/result
import gleam/string
import grice/coverage.{type Coverage}
import grice/diagnostic.{type Diagnostic}
import grice/internal/cli
import grice/internal/loader
import grice/internal/path
import grice/internal/platform
import grice/internal/render/human
import grice/internal/render/json
import grice/internal/runner
import grice/rule.{type Rule}
import simplifile

// Running
//
// The command line: the arguments, the environment and the terminal are
// read here, everything else is `cli.execute`, and the process exits with
// its code.

/// Run grice's built-in rules from the command line: `gleam run -m grice`.
pub fn main() -> Nil {
  run(built_in_rules())
}

/// The rules `main` runs. There are none yet.
@internal
pub fn built_in_rules() -> List(Rule) {
  []
}

/// Run `rules` from the command line, as the `main` of an entry module, and
/// exit with the run's exit code: 0 when no error is shown, 1 when one is
/// or an option counts a warning or a coverage gap as one, and 2 when the
/// run has no result.
///
/// grice runs on the Erlang target for now. An entry module still compiles
/// for JavaScript, so a JavaScript project's builds keep working, but there
/// this panics before it reads anything: run it with
/// `gleam run --target erlang -m <module>`.
pub fn run(rules: List(Rule)) -> Nil {
  use <- bool.lazy_guard(when: !platform.is_supported(), return: fn() {
    panic as "grice runs on the Erlang target for now: run gleam run --target erlang -m <module> -- …"
  })
  // A working directory that's gone has no project to find, and the
  // diagnostic about that names it as `.`.
  let directory = simplifile.current_directory() |> result.unwrap(".")
  let environment =
    cli.Environment(
      directory:,
      root: cli.find_root(directory, fn(path) {
        simplifile.is_file(path) == Ok(True)
      }),
      no_color: platform.variable("NO_COLOR") |> result.unwrap("") != "",
      terminal: platform.stdout_is_terminal(),
    )
  let outcome =
    cli.execute(
      platform.arguments(),
      environment,
      loader.load_project,
      rules,
      platform.sample,
    )
  io.print(outcome.stdout)
  io.print_error(outcome.stderr)
  platform.exit(outcome.exit_code)
}

// Loading
//
// Reading a project from disk: its configuration, the modules to lint and
// every project module they import, and its dependencies' sources.

/// A loaded project: what rules run on.
pub opaque type Project {
  Project(project: loader.Project)
}

/// Why a project couldn't be loaded.
pub type LoadError {
  /// `[tools.grice]` or `target` in `gleam.toml` is invalid, or selects no
  /// module to lint. Each `grice/invalid-config` diagnostic says what's
  /// wrong.
  InvalidConfig(diagnostics: List(Diagnostic))
  /// A file or directory grice needed couldn't be read, or a source isn't
  /// UTF-8. `path` is relative to the project root.
  CannotRead(path: String, reason: String)
  /// `manifest.toml` doesn't have the structure the compiler writes.
  InvalidManifest(reason: String)
}

/// Load the project whose `gleam.toml` is in the directory `root`.
///
/// It reads `gleam.toml` and `manifest.toml`, the sources of every
/// dependency, and the project modules the lint set needs. A relative
/// `root` is joined to the working directory, read once here, and kept as
/// an absolute path, so nothing later depends on where the program runs.
/// Only `.` segments are dropped from it: a `..` stays, since after a
/// symbolic link it names the parent of the link's target, which the text
/// alone can't tell.
pub fn load_project(root: String) -> Result(Project, LoadError) {
  use root <- result.try(absolute_root(root))
  case loader.load_project(root) {
    Ok(project) -> Ok(Project(project))
    Error(loader.InvalidConfig(diagnostics:)) ->
      Error(InvalidConfig(diagnostics:))
    Error(loader.CannotRead(path:, reason:)) ->
      Error(CannotRead(path:, reason:))
    Error(loader.InvalidManifest(reason:)) -> Error(InvalidManifest(reason:))
  }
}

// An absolute root is used as given. The working directory is read only
// for a relative one, and naming it is all a message can do when it can't
// be read.
fn absolute_root(root: String) -> Result(String, LoadError) {
  use <- bool.guard(when: string.starts_with(root, "/"), return: Ok(root))
  simplifile.current_directory()
  |> result.map(path.absolute(root, in: _))
  |> result.map_error(fn(error) {
    CannotRead(path: ".", reason: simplifile.describe_error(error))
  })
}

// Linting
//
// Running a rule set over a loaded project, and what the run found.

/// What a run found in a project.
pub opaque type Linted {
  Linted(project: loader.Project, linted: runner.Linted)
}

/// Run `rules` over `project`.
///
/// `Error` holds every problem with the rule set, such as an invalid or
/// repeated rule code, and with the rule codes the ignores in `gleam.toml`
/// name, and means no rule ran.
pub fn lint(
  project: Project,
  rules: List(Rule),
) -> Result(Linted, List(Diagnostic)) {
  runner.run(project.project, rules)
  |> result.map(Linted(project: project.project, linted: _))
}

/// Every diagnostic the run shows: what the rules reported that no ignore
/// or suppression hid, the parse errors, the coverage notes and the
/// warnings about suppressions. Those with no location come first, then
/// the rest by path and position.
pub fn diagnostics(linted: Linted) -> List(Diagnostic) {
  linted.linted.diagnostics
}

/// How much of the project the run analysed, and every gap it left.
pub fn coverage(linted: Linted) -> Coverage {
  linted.linted.coverage
}

// Rendering
//
// The text grice prints for a run, for a person or for a tool.

/// How `render` writes a run.
pub type Format {
  /// Text for a person, as the command line prints it: the diagnostics,
  /// then a summary of the counts and the coverage. `colour` adds terminal
  /// colours. Paths are shown relative to `directory`, a directory given
  /// relative to the project root, such as the one the output is shown in:
  /// `dev` and `./dev` alike, and `""` or `.` for the root. It can't hold a
  /// `..`: across a symbolic link the text alone can't say where that
  /// leads.
  Human(colour: Bool, directory: String)
  /// The JSON document, schema version 1, as `--format json` prints it
  /// without `--stats`. Its paths are relative to the absolute `root`.
  Json
}

/// Render what a run found.
///
/// Every span of a run's diagnostics was checked against its source while
/// linting, so rendering can't fail. If it does anyway, that's a bug in
/// grice, and this panics with a message asking for a report.
pub fn render(linted: Linted, format format: Format) -> String {
  let rendered = case format {
    Human(colour:, directory:) ->
      human.run(
        linted.project,
        linted.linted,
        human.Options(colour:, directory:),
      )
    Json -> json.run(linted.project, linted.linted, None)
  }
  case rendered {
    Ok(text) -> text
    Error(error) -> panic as human.bug_report(error)
  }
}
