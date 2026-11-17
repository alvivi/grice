//// The command line: a whole run as a pure function of its inputs.
////
//// `execute` parses the arguments, loads the project at the root, lints
//// it, renders the result and picks the exit code, with every effect
//// passed in: the environment as a value, the loader and the clock as
//// functions. `grice.run` gathers them, prints the outcome and exits, and
//// tests pass a project in memory and a clock that counts.
////
//// The report goes to standard output, human or JSON, a failed run's
//// included; only a usage error goes to standard error, since the format
//// may be what's wrong.

import gleam/bool
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import grice/coverage
import grice/diagnostic.{type Diagnostic}
import grice/internal/loader.{type LoadError, type Project}
import grice/internal/path
import grice/internal/render/human.{type RenderError}
import grice/internal/render/json
import grice/internal/runner.{type Linted}
import grice/internal/stats.{type Sample, type Stats}
import grice/rule.{type Rule}

// The run
//
// From the arguments to the outcome: a usage error or the help stop early,
// and otherwise the project is found, loaded, linted and rendered, or the
// run has no result and says why.

/// What a run reads from where it runs.
pub type Environment {
  Environment(
    /// The working directory, as an absolute path.
    directory: String,
    /// The project root: the first directory from `directory` upwards that
    /// holds a `gleam.toml` file, or `Error(Nil)` when there's none.
    root: Result(String, Nil),
    /// Whether `NO_COLOR` is set to something other than an empty string.
    no_color: Bool,
    /// Whether standard output is a terminal.
    terminal: Bool,
  )
}

/// What a run prints, and the status it exits with.
pub type Outcome {
  Outcome(stdout: String, stderr: String, exit_code: Int)
}

/// Run grice with `arguments` and `rules`. `load` reads the project at a
/// root, and `sample` reads the clock and the reduction count: at the
/// start, before and after loading, and after linting, for `--stats`.
pub fn execute(
  arguments: List(String),
  environment: Environment,
  load: fn(String) -> Result(Project, LoadError),
  rules: List(Rule),
  sample: fn() -> Sample,
) -> Outcome {
  let start = sample()
  case parse(arguments) {
    Error(problem) ->
      Outcome(stdout: "", stderr: usage_error(problem), exit_code: 2)
    Ok(Help) -> Outcome(stdout: help, stderr: "", exit_code: 0)
    Ok(Run(options)) ->
      run(options, environment, load:, rules:, sample:, start:)
  }
}

/// The first directory from `directory` upwards, `directory` included, that
/// holds a file named `gleam.toml`, by `is_file`. That's the project
/// `gleam` itself works on there.
pub fn find_root(
  directory: String,
  is_file: fn(String) -> Bool,
) -> Result(String, Nil) {
  use <- bool.guard(
    when: is_file(path.join(directory, "gleam.toml")),
    return: Ok(directory),
  )
  use parent <- result.try(path.parent(directory))
  find_root(parent, is_file)
}

type Format {
  Human(options: human.Options)
  Json
}

// A run that stopped before it had a result: the root, when one was
// found, and grice's own diagnostics saying why.
type Failure {
  Failure(root: Option(String), diagnostics: List(Diagnostic))
}

// Human output is coloured only on a terminal, when neither `NO_COLOR` nor
// `--no-color` says otherwise, and shows paths relative to the working
// directory, which is inside the root.
fn run(
  options: Options,
  environment: Environment,
  load load: fn(String) -> Result(Project, LoadError),
  rules rules: List(Rule),
  sample sample: fn() -> Sample,
  start start: Sample,
) -> Outcome {
  let format = case options.format {
    HumanOutput ->
      Human(human.Options(
        colour: environment.terminal
          && !environment.no_color
          && !options.no_color,
        directory: environment.root
          |> result.map(path.relative(environment.directory, from: _))
          |> result.unwrap(""),
      ))
    JsonOutput -> Json
  }
  case complete(options, environment, format, load:, rules:, sample:, start:) {
    Ok(outcome) -> outcome
    Error(failure) -> failed(failure, format)
  }
}

// The outcome of a run that has a result, or why it has none. A render
// error is a bug in grice, and leaves the run without a result too.
fn complete(
  options: Options,
  environment: Environment,
  format: Format,
  load load: fn(String) -> Result(Project, LoadError),
  rules rules: List(Rule),
  sample sample: fn() -> Sample,
  start start: Sample,
) -> Result(Outcome, Failure) {
  use root <- result.try(
    environment.root
    |> result.replace_error(Failure(None, [no_project(environment.directory)])),
  )
  let before_load = sample()
  use project <- result.try(
    load(root)
    |> result.map_error(fn(error) { Failure(Some(root), load_error(error)) }),
  )
  let after_load = sample()
  use linted <- result.try(
    runner.run(project, rules) |> result.map_error(Failure(Some(root), _)),
  )
  let after_lint = sample()
  let stats = case options.stats {
    True ->
      Some(stats.Stats(
        loaded: dict.size(project.modules),
        dependencies: dict.size(project.dependencies),
        rules: list.length(rules),
        types: linted.coverage.types != coverage.NotRequested,
        load: stats.phase(before_load, after_load),
        lint: stats.phase(after_load, after_lint),
        total: stats.phase(start, after_lint),
      ))
    False -> None
  }
  use text <- result.map(
    render(project, linted, format, options, stats)
    |> result.map_error(fn(error) {
      Failure(Some(root), [internal_error(error)])
    }),
  )
  Outcome(stdout: text, stderr: "", exit_code: exit_code(linted, options))
}

fn render(
  project: Project,
  linted: Linted,
  format: Format,
  options: Options,
  stats: Option(Stats),
) -> Result(String, RenderError) {
  case format {
    Human(options: human_options) -> {
      use text <- result.map(human.run(project, linted, human_options))
      text
      <> failing_sentence(linted, options)
      <> option.map(stats, human.stats) |> option.unwrap("")
    }
    Json -> json.run(project, linted, stats)
  }
}

fn failed(failure: Failure, format: Format) -> Outcome {
  let stdout = case format {
    Human(options:) ->
      human.failure(failure.diagnostics, colour: options.colour)
    Json -> json.failure(failure.root, failure.diagnostics)
  }
  Outcome(stdout:, stderr: "", exit_code: 2)
}

// Arguments
//
// Six options need no library. Each may be given once, in any order, and
// anything else is a usage error, so every accepted command means what it
// says. Positional arguments are rejected for now: `include` and `exclude`
// choose what's linted.

const help =
  "grice, a type-aware linter for Gleam

Usage:
  gleam run -m grice -- [OPTIONS]
  gleam run -m <entry module> -- [OPTIONS]

grice lints the project of the nearest gleam.toml, from the working
directory upwards. `gleam run -m grice` runs grice's built-in rules; an
entry module of your own, such as dev/lint.gleam, runs yours by calling
grice.run. The `--` ends gleam's own options, so the options after it reach
grice.

Options:
  --format <FORMAT>     human (the default) or json
  --warnings-as-errors  Fail the run when it shows a warning
  --strict              Fail the run when coverage has a gap
  --no-color            Don't colour the output
  --stats               Show how long loading and linting took
  -h, --help            Show this help

Exit codes:
  0  No error shown
  1  An error shown, or a warning or a coverage gap an option counts as one
  2  No result: a usage error, or the project or the rules couldn't be used
"

const defaults =
  Options(
    format: HumanOutput,
    warnings_as_errors: False,
    strict: False,
    no_color: False,
    stats: False,
  )

type Request {
  Help
  Run(Options)
}

type Options {
  Options(
    format: OutputFormat,
    warnings_as_errors: Bool,
    strict: Bool,
    no_color: Bool,
    stats: Bool,
  )
}

type OutputFormat {
  HumanOutput
  JsonOutput
}

type UsageError {
  UnknownOption(option: String)
  Positional(argument: String)
  SecondSeparator
  MissingFormat
  UnknownFormat(format: String)
  Repeated(option: String)
}

fn parse(arguments: List(String)) -> Result(Request, UsageError) {
  parse_loop(arguments, defaults, set.new())
}

// `seen` holds the options given so far, `--help` for either of its forms.
fn parse_loop(
  arguments: List(String),
  options: Options,
  seen: Set(String),
) -> Result(Request, UsageError) {
  let seen_help = set.contains(seen, "--help")
  case arguments {
    [] if seen_help -> Ok(Help)
    [] -> Ok(Run(options))
    [argument, ..rest] -> {
      use #(name, options, rest) <- result.try(parse_option(
        argument,
        rest,
        options,
      ))
      use <- bool.guard(
        when: set.contains(seen, name),
        return: Error(Repeated(name)),
      )
      parse_loop(rest, options, set.insert(seen, name))
    }
  }
}

// The option `argument` names, as its canonical name, the options it
// sets, and the arguments after it and its value.
fn parse_option(
  argument: String,
  rest: List(String),
  options: Options,
) -> Result(#(String, Options, List(String)), UsageError) {
  case argument, rest {
    "--format", [value, ..rest] | "--format=" <> value, rest -> {
      use format <- result.map(parse_format(value))
      #("--format", Options(..options, format:), rest)
    }
    "--format", [] -> Error(MissingFormat)
    "--warnings-as-errors", _ ->
      Ok(#(argument, Options(..options, warnings_as_errors: True), rest))
    "--strict", _ -> Ok(#(argument, Options(..options, strict: True), rest))
    "--no-color", _ -> Ok(#(argument, Options(..options, no_color: True), rest))
    "--stats", _ -> Ok(#(argument, Options(..options, stats: True), rest))
    "-h", _ | "--help", _ -> Ok(#("--help", options, rest))
    "--", _ -> Error(SecondSeparator)
    "-" <> name, _ if name != "" -> Error(UnknownOption(argument))
    _, _ -> Error(Positional(argument))
  }
}

fn parse_format(value: String) -> Result(OutputFormat, UsageError) {
  case value {
    "human" -> Ok(HumanOutput)
    "json" -> Ok(JsonOutput)
    "" -> Error(MissingFormat)
    _ -> Error(UnknownFormat(value))
  }
}

fn usage_error(problem: UsageError) -> String {
  let what = case problem {
    UnknownOption(option:) -> "unknown option " <> option
    Positional(argument:) ->
      "unexpected argument "
      <> string.inspect(argument)
      <> ": grice takes no paths"
    SecondSeparator -> "unexpected --, after the one that ends gleam's options"
    MissingFormat -> "--format needs a value: human or json"
    UnknownFormat(format:) ->
      "unknown format " <> string.inspect(format) <> ": use human or json"
    Repeated(option:) -> option <> " is given more than once"
  }
  "error: " <> what <> "\nRun with --help to see the options.\n"
}

// Failures
//
// Every reason a run has no result is a diagnostic with no location, so a
// failed run reads like any other, and its JSON document has them too.

/// The diagnostic for a run in `directory` with no `gleam.toml` there or
/// above it.
pub fn no_project(directory: String) -> Diagnostic {
  runner.error(
    "grice/cannot-read",
    "Can't find the project",
    [
      "grice lints the project of the nearest `gleam.toml`, but there's none in `"
      <> directory
      <> "` or any directory above it.",
    ],
    "Run grice from inside a Gleam project, such as in the directory of its `gleam.toml`.",
  )
}

/// The diagnostics for a project that couldn't be loaded.
pub fn load_error(error: LoadError) -> List(Diagnostic) {
  case error {
    loader.InvalidConfig(diagnostics:) -> diagnostics
    loader.CannotRead(path:, reason:) -> [
      runner.error(
        "grice/cannot-read",
        "Can't read a file",
        [
          "grice couldn't read `"
          <> path
          <> "`, which it needs to lint the project: "
          <> reason
          <> ".",
        ],
        "Check that it's there and that you can read it. Sources must be UTF-8.",
      ),
    ]
    loader.InvalidManifest(reason:) -> [
      runner.error(
        "grice/invalid-manifest",
        "Invalid `manifest.toml`",
        [
          "grice reads `manifest.toml` to find the sources of the project's dependencies, but "
          <> reason
          <> ".",
        ],
        "`gleam deps download` writes it again. If you edited it by hand, undo or fix the edit.",
      ),
    ]
  }
}

/// The diagnostic for a run whose result couldn't be rendered: a bug in
/// grice.
pub fn internal_error(error: RenderError) -> Diagnostic {
  runner.error(
    "grice/internal-error",
    "grice couldn't show its results",
    [
      "The run finished, but grice couldn't render its diagnostics: "
      <> human.describe_error(error)
      <> ". This is a bug in grice, not a problem in your code.",
    ],
    "Please report it at https://github.com/alvivi/grice/issues, with the rules you ran.",
  )
}

// Exit codes
//
// A completed run exits with 1 when it shows an error, or when an option
// counts its warnings or coverage gaps as errors, and with 0 otherwise.
// Notes never fail a run, and severities print as they are either way.

fn exit_code(linted: Linted, options: Options) -> Int {
  let errors =
    list.any(linted.diagnostics, fn(found) {
      found.severity == diagnostic.Error
    })
  let #(warnings, gaps) = counted_as_errors(linted, options)
  case errors || warnings + gaps > 0 {
    True -> 1
    False -> 0
  }
}

// The warnings and the coverage gaps the options count as errors.
fn counted_as_errors(linted: Linted, options: Options) -> #(Int, Int) {
  let warnings = case options.warnings_as_errors {
    True ->
      list.count(linted.diagnostics, fn(found) {
        found.severity == diagnostic.Warning
      })
    False -> 0
  }
  let gaps = case options.strict {
    True -> list.length(linted.coverage.gaps)
    False -> 0
  }
  #(warnings, gaps)
}

// The summary's last sentence, when the options fail the run, whether or
// not an error also fails it.
fn failing_sentence(linted: Linted, options: Options) -> String {
  let #(warnings, gaps) = counted_as_errors(linted, options)
  let reasons =
    [
      #("--warnings-as-errors", warnings, "warning", "warnings"),
      #("--strict", gaps, "coverage gap", "coverage gaps"),
    ]
    |> list.filter_map(fn(entry) {
      case entry {
        #(_, 0, _, _) -> Error(Nil)
        #(option, 1, one, _) ->
          Ok(option <> " counts the " <> one <> " as an error")
        #(option, count, _, many) ->
          Ok(
            option
            <> " counts the "
            <> int.to_string(count)
            <> " "
            <> many
            <> " as errors",
          )
      }
    })
  case reasons {
    [] -> ""
    [_, ..] ->
      human.wrap("The run fails: " <> string.join(reasons, " and ") <> ".")
      <> "\n"
  }
}
