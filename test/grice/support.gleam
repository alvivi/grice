//// What the tests share: fixture projects, the sources and rules more
//// than one test module runs, ways to read diagnostics, and running the
//// `gleam` on `PATH`. Most projects are built in memory with `project`.
//// The tests that read from disk write the tree they need under
//// `build/fixtures/<test>/`, which git ignores and the compiler doesn't
//// read, and delete it afterwards, except the end-to-end fixture, which
//// keeps its build between runs.

import glance
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import grice/diagnostic.{type Diagnostic, Diagnostic, Span}
import grice/facts.{type ModuleFacts, type Syntax, type Typed}
import grice/fixture_rules
import grice/internal/cli
import grice/internal/config
import grice/internal/line_index
import grice/internal/loader.{type Project}
import grice/internal/runner.{type Linted}
import grice/internal/stats
import grice/internal/typing
import grice/rule.{type Report, type Rule}
import simplifile

// Projects in memory
//
// Projects loaded with `loader.load` from files the test gives, and the
// sources that tests in more than one module run rules over.

/// The project with the `gleam.toml` text `toml`, the files of `files`,
/// `#(path, source)` with root-relative paths, and the dependency modules
/// of `dependencies`, `#(module name, source)`, loaded with `loader.load`.
pub fn project(
  toml: String,
  files: List(#(String, String)),
  dependencies: List(#(String, String)),
) -> Project {
  let assert Ok(parsed) = config.parse(toml)
  let sources = dict.from_list(files)
  let assert Ok(project) =
    loader.load(
      root: "app",
      config: parsed,
      paths: list.map(files, fn(file) { file.0 }),
      read: fn(path) {
        dict.get(sources, path) |> result.replace_error("No such file")
      },
      dependencies: dict.from_list(dependencies),
      missing_dependencies: [],
    )
  project
}

/// The diagnostics of a run of `rules` over the project of `files`, with
/// the default configuration.
pub fn run_files(
  files: List(#(String, String)),
  rules: List(Rule),
) -> List(Diagnostic) {
  run_files_with("", files, rules)
}

/// The diagnostics of a run of `rules` over the project with the
/// `gleam.toml` text `toml` and the files of `files`.
pub fn run_files_with(
  toml: String,
  files: List(#(String, String)),
  rules: List(Rule),
) -> List(Diagnostic) {
  let assert Ok(runner.Linted(diagnostics:, ..)) =
    runner.run(project(toml, files, []), rules)
  diagnostics
}

/// A package where `a` imports `b` on Erlang and `b` imports `a` on
/// JavaScript, which the compiler accepts on both targets. On each target,
/// `from_other` calls into the other module, and is left out of the
/// module the other target compiles it for.
pub const crossed = [
  #(
    "src/a.gleam",
    "@target(erlang)\nimport b\npub type A {\n  A\n}\n@target(erlang)\npub fn from_other() { b.make() }\npub fn make() { A }\n",
  ),
  #(
    "src/b.gleam",
    "@target(javascript)\nimport a\npub type B {\n  B\n}\n@target(javascript)\npub fn from_other() { a.make() }\npub fn make() { B }\n",
  ),
]

/// A module with two `echo`s, the second with a message.
pub const echoes = "pub fn main() {\n  echo 1\n  echo 2 as \"two\"\n}\n"

/// A module that discards a prelude `Result` twice, with a function girard
/// can't type.
pub const discards =
  "fn parse() -> Result(Int, Nil) {
  Ok(1)
}

pub fn main() {
  let _ = parse()
  let _ = 1
  let _ = Ok(\"two\")
  Nil
}

// girard can't type this function, and neither could the compiler.
pub fn skipped() {
  let _ = parse()
  1 + \"one\"
}
"

/// The dependency module `dep/box`.
pub const box =
  "pub type Box {\n  Box(content: String)\n}\n\npub fn shout(text: String) -> String {\n  text\n}\n"

/// A module with something for every type query to answer, which imports
/// `dep/box`.
pub const queried =
  "import dep/box

pub type Point {
  Point(x: Int, y: Int)
}

pub const origin = Point(0, 0)

pub fn identity(value) {
  value
}

pub fn main() {
  let n = 42
  let loud = box.shout(\"hi\")
  let same = identity(n)
  let piped = \"hey\" |> box.shout
  let point = Point(1, 2)
  let x = point.x
  let f = fn(v) { v }
  f(same)
}
"

/// A typed run, in memory, that shows every kind of diagnostic and gap a
/// completed run can: `fixture/no-echo` findings, one of them hidden, both
/// suppression warnings, a parse error, a definition girard couldn't type,
/// a module it returned nothing for, an import it couldn't use directly
/// and one reached through a dependency, and a missing package.
pub fn showcase() -> #(Project, Linted) {
  let project =
    loader.Project(
      ..project("", showcase_files, showcase_dependencies),
      missing_dependencies: [
        loader.Package("hexdep", loader.Hex, "build/packages/hexdep"),
      ],
    )
  let assert Ok(linted) =
    runner.run_with(
      project,
      [fixture_rules.no_echo(), fixture_rules.discarded_result()],
      infer: fn(project) {
        typing.infer(project, typing.resolver(project)) |> dict.delete("lonely")
      },
    )
  #(project, linted)
}

const showcase_files = [
  #(
    "src/app.gleam",
    "pub fn main() {
  // grice-ignore fixture/no-echo: The test shows a hidden diagnostic.
  echo 1
  echo 2
}

// grice-ignore fixture/no-echo: Nothing here prints.
pub fn quiet() {
  1
}

// grice-ignore fixture/no-echo
pub fn skipped() {
  1 + \"one\"
}
",
  ),
  #("src/broken.gleam", "pub fn ("),
  #(
    "src/dependent.gleam",
    "import dep/outer\n\npub fn main() {\n  outer.value()\n}\n",
  ),
  #("src/lonely.gleam", "pub fn main() {\n  2\n}\n"),
  #("src/nameless.gleam", "import nowhere\n"),
]

const showcase_dependencies = [
  #("dep/outer", "import dep/inner\n\npub fn value() {\n  3\n}\n"),
  #("dep/inner", "pub const x = 1\npub fn ("),
]

// Rules
//
// Rules made for the tests, with the `fixture/` prefix of the fixture
// rules. Most report at the start of the module, where any source has a
// valid span.

/// Reports how many functions the module has once it has been walked.
pub fn count_functions() -> Rule {
  rule.module("fixture/count-functions", title: "Made in a test")
  |> rule.with_context(initial: 0)
  |> rule.on_function(fn(count, _function, _facts) { #(count + 1, []) })
  |> rule.on_module_end(fn(count, _facts) {
    [at_start(int.to_string(count) <> " functions")]
  })
  |> rule.build
}

/// Reports, on the first module it's given, the names of every module in
/// the order its summaries came in.
pub fn module_order() -> Rule {
  rule.project("fixture/module-order", title: "Made in a test")
  |> rule.per_module(facts.module_name)
  |> rule.final(fn(summaries) {
    let names = list.map(summaries, fn(summary) { summary.1 })
    case names {
      [first, ..] -> [#(first, at_start(string.join(names, ", ")))]
      [] -> []
    }
  })
}

/// Reports each call with what `type_of` answers for it.
pub fn typed_calls() -> Rule {
  rule.module("fixture/typed-calls", title: "Made in a test")
  |> rule.typed
  |> rule.with_context(initial: Nil)
  |> rule.on_expression(fn(context, expression, module_facts) {
    case expression {
      glance.Call(location:, ..) -> #(context, [
        rule.report(
          at: location,
          label: string.inspect(facts.type_of(module_facts, location)),
        ),
      ])
      _ -> #(context, [])
    }
  })
  |> rule.build
}

/// A module rule that reports what `reports` gives once each module has
/// been walked.
pub fn on_module_end(
  code: String,
  reports: fn(ModuleFacts(Syntax)) -> List(Report),
) -> Rule {
  rule.module(code, title: "Made in a test")
  |> rule.with_context(initial: Nil)
  |> rule.on_module_end(fn(_context, module_facts) { reports(module_facts) })
  |> rule.build
}

/// A typed module rule that reports what `reports` gives once each module
/// has been walked.
pub fn typed_on_module_end(
  code: String,
  reports: fn(ModuleFacts(Typed)) -> List(Report),
) -> Rule {
  rule.module(code, title: "Made in a test")
  |> rule.typed
  |> rule.with_context(initial: Nil)
  |> rule.on_module_end(fn(_context, module_facts) { reports(module_facts) })
  |> rule.build
}

/// A rule with the code `code` that reports nothing.
pub fn named(code: String) -> Rule {
  rule.module(code, title: "Made in a test")
  |> rule.with_context(initial: Nil)
  |> rule.build
}

/// A report at the start of the module, labelled `label`.
pub fn at_start(label: String) -> Report {
  rule.report(at: glance.Span(0, 0), label:)
}

// The command line
//
// What `cli.execute` is given besides the arguments.

/// A working directory at the root of the project in `root`, an absolute
/// path, with standard output not a terminal and `NO_COLOR` unset.
pub fn environment(root: String) -> cli.Environment {
  cli.Environment(
    directory: root,
    root: Ok(root),
    no_color: False,
    terminal: False,
  )
}

/// A clock for `cli.execute` whose n-th reading is `Sample(n * n, n * n * n)`,
/// so loading, linting and the total each cost a different amount, in both
/// counters.
@external(erlang, "grice_test_ffi", "counting_sample")
pub fn counting_sample() -> fn() -> stats.Sample

// Diagnostics
//
// What a run reported, as text that's short to compare, and the spans its
// locations are compared with.

/// Each diagnostic as its code, then its path and primary label if it has
/// a location.
pub fn describe(diagnostics: List(Diagnostic)) -> List(String) {
  list.map(diagnostics, fn(found) {
    case found.location {
      Some(location) ->
        found.code <> " " <> location.path <> ": " <> location.primary.message
      None -> found.code
    }
  })
}

/// The primary label of each diagnostic, which must all have a location.
pub fn labels(diagnostics: List(Diagnostic)) -> List(String) {
  list.map(diagnostics, fn(found) {
    let assert Some(location) = found.location
    location.primary.message
  })
}

/// The span of the first `needle` in `source`, as the syntax tree counts
/// it: bytes on Erlang and UTF-16 code units on JavaScript. It's what a
/// rule gets from the tree and gives to `rule.report` and the type queries.
pub fn glance_span(source: String, needle: String) -> glance.Span {
  let #(start, end) = locate(source, needle, tree_length)
  glance.Span(start:, end:)
}

/// The length of `text` as the syntax tree counts it: bytes on Erlang and
/// UTF-16 code units on JavaScript.
pub fn tree_length(text: String) -> Int {
  line_index.length(text, in: line_index.tree_units())
}

/// The span of the first `needle` in `source`, in bytes, as a diagnostic's
/// on every target.
pub fn span_of(source: String, needle: String) -> diagnostic.Span {
  let #(start, end) = locate(source, needle, string.byte_size)
  Span(start:, end:)
}

/// A warning on `src/app.gleam` at `span`, labelled `label`, as a rule
/// made in a test with the code `code` and no message reports it.
pub fn finding(
  code: String,
  span: diagnostic.Span,
  label: String,
) -> Diagnostic {
  Diagnostic(
    code:,
    severity: diagnostic.Warning,
    title: "Made in a test",
    location: Some(diagnostic.Location(
      path: "src/app.gleam",
      primary: diagnostic.Label(span, label),
      secondary: [],
      fix: None,
    )),
    message: [],
    hint: None,
  )
}

// Where the first `needle` in `source` starts and ends, counted by
// `length`.
fn locate(
  source: String,
  needle: String,
  length: fn(String) -> Int,
) -> #(Int, Int) {
  let assert Ok(#(before, _)) = string.split_once(source, needle)
  let start = length(before)
  #(start, start + length(needle))
}

// Projects on disk
//
// Fixture trees written under `build/fixtures/`, and the paths to them.

/// `path`, relative to the working directory, as an absolute path.
pub fn absolute(path: String) -> String {
  let assert Ok(working) = simplifile.current_directory()
  working <> "/" <> path
}

/// The directory a test named `name` writes its fixture in.
pub fn fixture_directory(name: String) -> String {
  "build/fixtures/" <> name
}

/// Write each `#(path, contents)` under `directory`, creating parent
/// directories as needed, after deleting whatever was there.
pub fn write_fixture(directory: String, files: List(#(String, String))) -> Nil {
  cleanup(directory)
  write_files(directory, files)
}

/// Write each `#(path, contents)` under `directory` as `write_fixture` does,
/// but over whatever is there, deleting nothing: a fixture project keeps
/// its build and its manifest between tests.
pub fn write_files(directory: String, files: List(#(String, String))) -> Nil {
  list.each(files, fn(file) {
    let #(path, contents) = file
    write_file(directory <> "/" <> path, contents)
  })
}

/// Write `files` as `write_fixture` does, then create each `#(link, target)`
/// symbolic link. `link` is relative to `directory`, and `target` is what
/// the link holds, so a relative target is read from the link's own
/// directory.
pub fn write_linked_fixture(
  directory: String,
  files: List(#(String, String)),
  links: List(#(String, String)),
) -> Nil {
  write_fixture(directory, files)
  list.each(links, fn(link) {
    let #(at, target) = link
    let path = directory <> "/" <> at
    create_parent(path)
    let assert Ok(Nil) = simplifile.create_symlink(to: target, from: path)
      as { "can't create the link " <> path }
  })
}

/// Write bytes that aren't UTF-8 at `path`.
pub fn write_not_utf8(path: String) -> Nil {
  write_bytes(path, <<255, 254, 255>>)
}

/// Write `bytes` at `path` as they are, creating parent directories as
/// needed.
pub fn write_bytes(path: String, bytes: BitArray) -> Nil {
  create_parent(path)
  let assert Ok(Nil) = simplifile.write_bits(path, bytes)
    as { "can't write " <> path }
  Nil
}

/// Run `check` with the directory at `path` set to `mode`, a mode that
/// denies listing it, then restore mode `0o755`. `check` is skipped where the
/// directory can still be listed: a process that reads past the mode, as
/// root does, proves nothing.
pub fn with_directory_mode(path: String, mode: Int, check: fn() -> Nil) -> Nil {
  let assert Ok(Nil) = simplifile.set_permissions_octal(path, mode)
    as { "can't change the mode of " <> path }
  case simplifile.read_directory(path) {
    Error(_) -> check()
    Ok(_) -> Nil
  }
  let assert Ok(Nil) = simplifile.set_permissions_octal(path, 0o755)
    as { "can't restore the mode of " <> path }
  Nil
}

/// Delete a fixture directory and everything in it.
pub fn cleanup(directory: String) -> Nil {
  // A missing directory is already clean.
  let _ = simplifile.delete(directory)
  Nil
}

fn write_file(path: String, contents: String) -> Nil {
  create_parent(path)
  let assert Ok(Nil) = simplifile.write(path, contents)
    as { "can't write " <> path }
  Nil
}

fn create_parent(path: String) -> Nil {
  let segments = string.split(path, "/")
  let parent =
    segments
    |> list.take(list.length(segments) - 1)
    |> string.join("/")
  let assert Ok(Nil) = simplifile.create_directory_all(parent)
    as { "can't create " <> parent }
  Nil
}

// Running gleam
//
// The `gleam` on `PATH`, run as a program, and work done once per runtime,
// such as building a fixture or downloading the corpus.

/// Run the `gleam` on `PATH` with `arguments` in `directory`, and return
/// its exit status, standard output and standard error, or `Error` when
/// there's no `gleam`. Standard error is written to `stderr_file`, an
/// absolute path, and read back once the program exits.
@external(erlang, "grice_test_ffi", "run_gleam")
pub fn run_gleam(
  directory: String,
  arguments: List(String),
  stderr_file: String,
) -> Result(#(Int, String, String), String)

/// The absolute path of `build/fixtures/<name>`, for `run_gleam`'s
/// standard error, with its directory created.
pub fn stderr_file(name: String) -> String {
  let path = fixture_directory(name)
  create_parent(path)
  absolute(path)
}

/// Call `f` the first time `once` is called with `key` in this runtime, and
/// do nothing after that.
@external(erlang, "grice_test_ffi", "once")
pub fn once(key: String, f: fn() -> Nil) -> Nil
