//// Tests for the library API in `grice`, over fixture projects on disk:
//// the root as given and made absolute, a root through a symbolic link,
//// the load errors, the rule set's problems, a rule that sees the whole
//// project, and rendering, whose document is the command line's.

import gleam/list
import gleam/string
import grice
import grice/coverage
import grice/diagnostic
import grice/fixture_rules
import grice/internal/cli
import grice/internal/loader
import grice/rule
import grice/support

const app =
  "pub fn main() {
  echo 1
}

pub fn skipped() {
  1 + \"one\"
}
"

// The root
//
// Where the project is read from, however the root is written.

// The relative and the absolute root load the same project, and the
// document's root is absolute either way.
pub fn a_relative_root_is_made_absolute_test() {
  let directory = write_app("library-root", app)
  let absolute = support.absolute(directory)
  let outputs =
    list.map([directory, "./" <> directory <> "/.", absolute], fn(root) {
      let linted = lint(root)
      #(
        grice.diagnostics(linted),
        grice.coverage(linted),
        grice.render(linted, format: grice.Human(colour: False, directory: "")),
        grice.render(linted, format: grice.Json),
      )
    })
  let assert [first, ..rest] = outputs
  assert list.all(rest, fn(output) { output == first })
  assert string.contains(first.3, "\"root\": \"" <> absolute <> "\",")
  let assert [_, _] = first.0
  support.cleanup(directory)
}

// `origin/link` points at `actual/inner`, so `origin/link/../project` is
// `actual/project` on disk, while cancelling `..` in the text would name
// `origin/project`. Each project has its own number of `echo`s. On
// JavaScript, simplifile cancels `..` in the text, so this holds on Erlang
// only.
@target(erlang)
pub fn a_root_through_a_symbolic_link_keeps_its_parent_segments_test() {
  let directory = support.fixture_directory("library-link")
  let project = fn(echoes) {
    app_files(
      "pub fn main() {\n" <> string.repeat("  echo 1\n", echoes) <> "}\n",
    )
  }
  let files =
    list.flatten([
      prefix("origin/project/", project(1)),
      prefix("actual/project/", project(2)),
      [#("actual/inner/.keep", "")],
    ])
  support.write_linked_fixture(directory, files, [
    #("origin/link", "../actual/inner"),
  ])
  let root = directory <> "/origin/link/../project"
  let linted = lint(root)
  assert list.length(grice.diagnostics(linted)) == 2
  assert string.contains(
    grice.render(linted, format: grice.Json),
    "\"root\": \"" <> support.absolute(root) <> "\",",
  )
  support.cleanup(directory)
}

// Load errors
//
// Each way loading fails, as a structured `LoadError`.

pub fn load_errors_say_what_went_wrong_test() {
  let directory = support.fixture_directory("library-errors")
  support.write_fixture(directory, [#("src/app.gleam", app)])
  let assert Error(grice.CannotRead(path: "gleam.toml", reason: _)) =
    grice.load_project(directory)
  support.write_fixture(directory, [
    #("gleam.toml", "name = \"app\"\n[tools.grice]\nnope = 1\n"),
    #("manifest.toml", "packages = []\n"),
    #("src/app.gleam", app),
  ])
  let assert Error(grice.InvalidConfig(diagnostics: [problem])) =
    grice.load_project(directory)
  assert problem.code == "grice/invalid-config"
  support.write_fixture(directory, [
    #("gleam.toml", "name = \"app\"\n"),
    #("manifest.toml", "packages = 1\n"),
    #("src/app.gleam", app),
  ])
  assert grice.load_project(directory)
    == Error(grice.InvalidManifest("`packages` in `manifest.toml` isn't a list"))
  support.cleanup(directory)
}

// Linting
//
// Running rules over a loaded project, and the coverage that comes back.

pub fn an_invalid_rule_set_runs_nothing_test() {
  let directory = write_app("library-rules", app)
  let assert Ok(project) = grice.load_project(directory)
  let assert Error([problem]) =
    grice.lint(project, [fixture_rules.no_echo(), fixture_rules.no_echo()])
  assert problem.code == "grice/invalid-rule"
  assert problem.title == "Rule code used more than once"
  support.cleanup(directory)
}

// A rule that sees the whole project needs it loaded with
// `load_whole_project`, which reads the test and dev modules and the
// foreign sources. A foreign source is read for its ASCII words, so one
// that isn't UTF-8 is read too; one that can't be read leaves the project
// incomplete, which stops the rule rather than the load.
pub fn a_whole_project_rule_needs_load_whole_project_test() {
  let directory = support.fixture_directory("library-whole-project")
  support.write_fixture(directory, [
    #("dev/tool.gleam", "pub fn main() {\n  1\n}\n"),
    #("src/app_ffi.erl", "-module(app_ffi).\n"),
    #("test/app_test.gleam", "pub fn main_test() {\n  1\n}\n"),
    ..app_files(app)
  ])
  support.write_not_utf8(directory <> "/src/blob.mjs")
  let rules = [support.whole_project_view()]
  let assert Ok(project) = grice.load_project(directory)
  let assert Error([problem]) = grice.lint(project, rules)
  assert problem.code == "grice/invalid-rule"
  assert problem.title == "Rule needs the whole project"
  let assert Ok(project) = grice.load_whole_project(directory)
  let assert Ok(linted) = grice.lint(project, rules)
  assert support.labels(grice.diagnostics(linted))
    == ["tool (not linted), app, app_test (not linted)"]
  support.with_file_mode(directory <> "/src/app_ffi.erl", 0o000, fn() {
    let assert Ok(project) = grice.load_whole_project(directory)
    let assert Ok(linted) = grice.lint(project, rules)
    let assert coverage.Coverage(
      gaps: [
        coverage.IncompleteProject(
          rules: ["fixture/whole-project-view"],
          paths: ["src/app_ffi.erl"],
        ),
      ],
      ..,
    ) = grice.coverage(linted)
    Nil
  })
  support.cleanup(directory)
}

// Users can pattern-match on the coverage, its gaps and their causes.
pub fn coverage_is_a_value_to_match_on_test() {
  let directory = write_app("library-coverage", "import gone\n\n" <> app)
  let linted = lint(directory)
  let assert coverage.Coverage(
    modules: 1,
    parsed: 1,
    types: coverage.Requested(full: 0, partial: 1, none: 0),
    gaps: [
      coverage.UntypedDefinition(path: "src/app.gleam", definition: "skipped"),
      coverage.UnavailableImport(
        path: "src/app.gleam",
        module: "gone",
        cause: coverage.NoSuchModule,
      ),
    ],
  ) = grice.coverage(linted)
  support.cleanup(directory)
}

// Rendering
//
// The text the library gives, and where its paths point.

pub fn human_output_has_the_summary_and_relative_paths_test() {
  let directory = write_app("library-render", app)
  let linted = lint(directory)
  let render = fn(directory) {
    grice.render(linted, format: grice.Human(colour: False, directory:))
  }
  let text = render("dev")
  assert string.contains(text, "┌─ ../src/app.gleam:2:3\n")
  assert string.contains(render(""), "┌─ src/app.gleam:2:3\n")
  // A `.` segment names nothing.
  assert render("./dev") == text
  assert render(".") == render("")
  assert string.ends_with(
    text,
    "1 warning and 1 note in 1 module.\nCoverage is incomplete: 1 definition in 1 module couldn't be typed, so\ntyped rules didn't see all of the code.\n",
  )
  let assert [_, note] = grice.diagnostics(linted)
  assert note.severity == diagnostic.Note
  support.cleanup(directory)
}

// The library's document is the command line's for the same run, without
// `--stats`.
pub fn the_document_is_the_command_lines_test() {
  let directory = write_app("library-document", app)
  let outcome =
    cli.execute(
      ["--format", "json"],
      support.environment(support.absolute(directory)),
      loader.load_project,
      rules(),
      support.counting_sample(),
    )
  assert outcome.stdout == grice.render(lint(directory), format: grice.Json)
  support.cleanup(directory)
}

// Helpers
//
// Fixture projects on disk and the rules they're linted with.

// The files of a project whose only module, `src/app.gleam`, holds
// `source`.
fn app_files(source: String) -> List(#(String, String)) {
  [
    #("gleam.toml", "name = \"app\"\n"),
    #("manifest.toml", "packages = []\n"),
    #("src/app.gleam", source),
  ]
}

// Write `app_files(source)` as the fixture of the test `name`, and return
// its directory.
fn write_app(name: String, source: String) -> String {
  let directory = support.fixture_directory(name)
  support.write_fixture(directory, app_files(source))
  directory
}

// The project at `root`, linted with a syntax rule and a typed one.
fn lint(root: String) -> grice.Linted {
  let assert Ok(project) = grice.load_project(root)
  let assert Ok(linted) = grice.lint(project, rules())
  linted
}

fn rules() -> List(rule.Rule) {
  [fixture_rules.no_echo(), fixture_rules.discarded_result()]
}

@target(erlang)
fn prefix(
  directory: String,
  files: List(#(String, String)),
) -> List(#(String, String)) {
  list.map(files, fn(file) { #(directory <> file.0, file.1) })
}
