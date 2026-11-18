//// Tests for the command line, run in memory with `cli.execute`: the
//// arguments and the help, finding the root, what a run prints and the
//// code it exits with, colour, the stats and failed runs, mostly as
//// snapshots.

import birdie
import glance
import gleam/bit_array
import gleam/dict
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/set
import gleam/string
import grice/diagnostic.{Diagnostic, Label, Location, Span}
import grice/fixture_rules
import grice/internal/cli
import grice/internal/config
import grice/internal/line_index
import grice/internal/loader.{type LoadError, type Project}
import grice/internal/stats
import grice/rule.{type Rule}
import grice/support

// Arguments
//
// What the command line accepts, and how it says what it doesn't.

pub fn help_shows_the_options_and_exit_codes_test() {
  let outcome = execute(["--help"], echo_project())
  assert outcome.stderr == ""
  assert outcome.exit_code == 0
  assert execute(["-h"], echo_project()) == outcome
  // Help wins over the other options, given once each.
  assert execute(["--strict", "-h", "--format", "json"], echo_project())
    == outcome
  birdie.snap(outcome.stdout, title: "cli: help")
}

pub fn usage_errors_go_to_stderr_with_exit_code_2_test() {
  let cases = [
    ["--nope"],
    ["-x"],
    ["--strict=yes"],
    ["src/app.gleam"],
    [""],
    ["--"],
    ["--strict", "--", "--stats"],
    ["--format"],
    ["--format="],
    ["--format", "xml"],
    ["--format=JSON"],
    ["--strict", "--strict"],
    ["--format", "json", "--format=human"],
    ["-h", "--help"],
  ]
  let errors =
    list.map(cases, fn(arguments) {
      let outcome = execute(arguments, echo_project())
      assert outcome.stdout == ""
      assert outcome.exit_code == 2
      string.inspect(arguments) <> "\n" <> outcome.stderr
    })
  birdie.snap(string.join(errors, "\n"), title: "cli: usage errors")
}

pub fn options_are_accepted_in_any_order_test() {
  let options = [
    "--warnings-as-errors", "--strict", "--no-color", "--stats", "--format=json",
  ]
  let outcomes =
    [
      options,
      list.reverse(options),
      [
        "--stats", "--format", "json", "--strict", "--no-color",
        "--warnings-as-errors",
      ],
    ]
    |> list.map(execute(_, echo_project()))
  let assert [first, ..rest] = outcomes
  assert first.exit_code == 1
  assert list.all(rest, fn(outcome) { outcome == first })
}

// The root
//
// Where a run finds its project.

pub fn the_root_is_the_nearest_directory_with_a_gleam_toml_test() {
  let files = set.from_list(["/home/me/app/gleam.toml", "/gleam.toml"])
  let is_file = set.contains(files, _)
  assert cli.find_root("/home/me/app", is_file) == Ok("/home/me/app")
  assert cli.find_root("/home/me/app/test/deep", is_file) == Ok("/home/me/app")
  assert cli.find_root("/home/me", is_file) == Ok("/")
  assert cli.find_root("/home/me", fn(_) { False }) == Error(Nil)
  // At the top, the path checked is `/gleam.toml`, not `//gleam.toml`.
  assert cli.find_root("/", fn(path) { path == "/gleam.toml" }) == Ok("/")
}

// Runs
//
// What a completed run prints, its stats included.

pub fn a_clean_run_test() {
  let clean = Ok(project_of("pub fn main() { 1 }\n"))
  assert execute([], clean)
    == cli.Outcome(
      stdout: "No diagnostics in 1 module.\n",
      stderr: "",
      exit_code: 0,
    )
}

pub fn paths_are_relative_to_the_working_directory_test() {
  let environment =
    cli.Environment(..environment(), directory: root <> "/test/unit")
  let outcome = execute_in(environment, [], echo_project(), echo_rules())
  birdie.snap(outcome.stdout, title: "cli: paths from a subdirectory")
}

// One warning and one coverage gap, and nothing else.
pub fn options_that_fail_the_run_say_so_test() {
  let project =
    project_of(
      "pub fn main() {\n  echo 1\n}\n\npub fn skipped() {\n  1 + \"one\"\n}\n",
    )
  let rules = [fixture_rules.no_echo(), fixture_rules.discarded_result()]
  let summaries =
    [
      [],
      ["--warnings-as-errors"],
      ["--strict"],
      ["--strict", "--warnings-as-errors"],
    ]
    |> list.map(fn(arguments) {
      let outcome = execute_in(environment(), arguments, Ok(project), rules)
      let assert Ok(summary) = list.last(string.split(outcome.stdout, "\n\n"))
      string.inspect(arguments)
      <> " exits with "
      <> int.to_string(outcome.exit_code)
      <> "\n"
      <> summary
    })
  birdie.snap(
    string.join(summaries, "\n"),
    title: "cli: options that fail the run",
  )
}

pub fn the_stats_come_after_the_summary_test() {
  let outcome = execute(["--stats"], echo_project())
  birdie.snap(outcome.stdout, title: "cli: stats")
}

// The counting clock's n-th reading is `Sample(n * n, Some(n * n * n))`:
// the run starts at the first, loads from the second to the third and
// lints until the fourth, so each phase differs in both counters.
pub fn stats_measure_loading_linting_and_the_whole_run_test() {
  let outcome = execute(["--stats", "--format", "json"], echo_project())
  let phase = fn(name) {
    use milliseconds <- decode.subfield([name, "milliseconds"], decode.int)
    use reductions <- decode.subfield([name, "reductions"], decode.int)
    decode.success(#(milliseconds, reductions))
  }
  assert json.parse(outcome.stdout, phases(phase))
    == Ok([#(5, 19), #(7, 37), #(15, 63)])
}

// On a runtime that counts no reductions, such as JavaScript, the stats
// have no reductions column, and the document's reductions are `null`.
pub fn stats_without_reductions_test() {
  let run = fn(arguments) {
    execute_with(
      environment(),
      arguments,
      echo_project(),
      echo_rules(),
      support.counting_clock(),
    )
  }
  let reductions =
    phases(fn(name) {
      decode.subfield(
        [name, "reductions"],
        decode.optional(decode.int),
        decode.success,
      )
    })
  assert json.parse(run(["--stats", "--format", "json"]).stdout, reductions)
    == Ok([None, None, None])
  birdie.snap(run(["--stats"]).stdout, title: "cli: stats without reductions")
}

// `app` imports `helper`, which is excluded but still loaded, and a
// dependency module, so a lint set of one module loads two, with one
// dependency module, for two rules, one of them typed.
pub fn stats_count_the_load_set_dependencies_and_rules_test() {
  let project =
    support.project(
      "[tools.grice]\nexclude = [\"src/helper.gleam\"]\n",
      [
        #(
          "src/app.gleam",
          "import dep/box\nimport helper\n\npub fn main() {\n  helper.one() + box.two()\n}\n",
        ),
        #("src/helper.gleam", "pub fn one() {\n  1\n}\n"),
      ],
      [#("dep/box", "pub fn two() {\n  2\n}\n")],
    )
  let rules = [fixture_rules.no_echo(), fixture_rules.discarded_result()]
  let run = execute_in(environment(), _, Ok(project), rules)
  let counts = {
    use loaded <- decode.subfield(["stats", "modules", "loaded"], decode.int)
    use dependencies <- decode.subfield(
      ["stats", "modules", "dependencies"],
      decode.int,
    )
    use rules <- decode.subfield(["stats", "rules"], decode.int)
    use types <- decode.subfield(["stats", "types"], decode.bool)
    decode.success(#(loaded, dependencies, rules, types))
  }
  assert json.parse(run(["--stats", "--format", "json"]).stdout, counts)
    == Ok(#(2, 1, 2, True))
  assert string.contains(
    run(["--stats"]).stdout,
    "\n  2 project modules, 1 dependency module, 2 rules, types inferred.\n",
  )
}

// Exit codes
//
// Which runs exit with 0, 1 or 2.

pub fn exit_codes_follow_what_the_run_shows_test() {
  let echo_at = fn(severity) {
    #(project_of("pub fn main() { echo 1 }\n"), [
      fixture_rules.no_echo() |> rule.with_severity(severity),
    ])
  }
  let gap = #(project_of("pub fn f() { 1 + \"one\" }\n"), [
    fixture_rules.discarded_result(),
  ])
  let unused = #(
    project_of("// grice-ignore fixture/no-echo: why\npub fn main() { 1 }\n"),
    echo_rules(),
  )
  let invalid = #(
    project_of("// grice-ignore fixture/no-echo\npub fn main() { 1 }\n"),
    echo_rules(),
  )
  let clean = #(project_of("pub fn main() { 1 }\n"), [])
  let out_of_bounds = #(project_of("pub fn main() { 1 }\n"), [
    rule.module("fixture/out-of-bounds", title: "Out of bounds")
    |> rule.with_context(initial: Nil)
    |> rule.on_module_end(fn(_context, _facts) {
      [rule.report(at: glance.Span(0, 99), label: "Past the end")]
    })
    |> rule.build,
  ])
  let ignore =
    "[[tools.grice.ignore]]\npaths = [\"src/\"]\nrules = [\"fixture/nope\"]\nreason = \"why\"\n"
  let table = [
    #(clean, [], 0),
    #(clean, ["--strict", "--warnings-as-errors"], 0),
    #(#(project_of("pub fn ("), []), [], 1),
    #(echo_at(diagnostic.Error), [], 1),
    #(echo_at(diagnostic.Warning), [], 0),
    #(echo_at(diagnostic.Warning), ["--warnings-as-errors"], 1),
    #(echo_at(diagnostic.Note), ["--warnings-as-errors", "--strict"], 0),
    #(unused, [], 0),
    #(unused, ["--warnings-as-errors"], 1),
    #(invalid, ["--warnings-as-errors"], 1),
    #(gap, [], 0),
    #(gap, ["--warnings-as-errors"], 0),
    #(gap, ["--strict"], 1),
    // A rule's report with a bad span is shown as a `grice/invalid-report`
    // error, and the run completes.
    #(out_of_bounds, [], 1),
    // An invalid rule set, or an ignore of a rule that isn't in the run,
    // leaves no result.
    #(
      #(project_of(""), [fixture_rules.no_echo(), fixture_rules.no_echo()]),
      [],
      2,
    ),
    #(#(support.project(ignore, [#("src/app.gleam", "")], []), []), [], 2),
  ]
  let wrong =
    list.filter(table, fn(entry) {
      let #(#(project, rules), arguments, expected) = entry
      execute_in(environment(), arguments, Ok(project), rules).exit_code
      != expected
    })
  assert wrong == []
  let #(project, rules) = out_of_bounds
  assert string.starts_with(
    execute_in(environment(), [], Ok(project), rules).stdout,
    "error[grice/invalid-report]",
  )
}

pub fn severities_print_unchanged_under_warnings_as_errors_test() {
  let outcome = execute(["--warnings-as-errors"], echo_project())
  assert string.starts_with(outcome.stdout, "warning[fixture/no-echo]")
  assert outcome.exit_code == 1
}

// Colour
//
// When human output is coloured.

pub fn colour_needs_a_terminal_no_no_color_and_human_output_test() {
  let table = [
    #(True, False, [], True),
    #(False, False, [], False),
    #(True, True, [], False),
    #(True, False, ["--no-color"], False),
    #(True, False, ["--format", "json"], False),
  ]
  let wrong =
    list.filter(table, fn(entry) {
      let #(terminal, no_color, arguments, coloured) = entry
      let environment = cli.Environment(..environment(), terminal:, no_color:)
      let outcome =
        execute_in(environment, arguments, echo_project(), echo_rules())
      string.contains(outcome.stdout, "\u{1b}[") != coloured
    })
  assert wrong == []
}

pub fn colour_test() {
  let environment = cli.Environment(..environment(), terminal: True)
  let outcome = execute_in(environment, [], echo_project(), echo_rules())
  birdie.snap(outcome.stdout, title: "cli: colour")
}

// Failed runs
//
// Each reason a run has no result gives the document of a failed run. The
// catalogue shows each diagnostic as a person sees it, and one run here
// shows the line that closes a failed run.

pub fn a_failed_run_says_it_didnt_complete_test() {
  let environment = cli.Environment(..environment(), root: Error(Nil))
  let outcome = execute_in(environment, [], echo_project(), echo_rules())
  assert outcome.exit_code == 2
  birdie.snap(outcome.stdout, title: "cli: a failed run in human output")
}

pub fn a_run_without_a_project_test() {
  let environment = cli.Environment(..environment(), root: Error(Nil))
  snap_failure(environment, echo_project(), echo_rules(), "without a project")
}

pub fn a_run_with_an_invalid_configuration_test() {
  let assert Error(problems) =
    config.parse("[tools.grice]\nincludes = [\"src/\"]\n")
  let loaded = Error(loader.InvalidConfig(problems))
  snap_failure(
    environment(),
    loaded,
    echo_rules(),
    "with an invalid configuration",
  )
}

pub fn a_run_with_an_unreadable_file_test() {
  let loaded = Error(loader.CannotRead("src/app.gleam", "Permission denied"))
  snap_failure(environment(), loaded, echo_rules(), "with an unreadable file")
}

pub fn a_run_with_an_invalid_manifest_test() {
  let loaded =
    Error(loader.InvalidManifest("`packages` in `manifest.toml` isn't a list"))
  snap_failure(environment(), loaded, echo_rules(), "with an invalid manifest")
}

pub fn a_run_with_an_invalid_rule_set_test() {
  let rules = [fixture_rules.no_echo(), fixture_rules.no_echo()]
  snap_failure(environment(), echo_project(), rules, "with an invalid rule set")
}

// The runner checks what rules report, but takes the loader's parse errors
// as they are, so a broken one stands in for a bug in grice.
pub fn a_run_that_cant_render_test() {
  let broken =
    Diagnostic(
      code: "grice/parse-error",
      severity: diagnostic.Error,
      title: "Broken",
      location: Some(Location(
        path: "src/app.gleam",
        primary: Label(Span(0, 9), "here"),
        secondary: [],
        fix: None,
      )),
      message: [],
      hint: None,
    )
  let project = loader.Project(..project_of("x\n"), diagnostics: [broken])
  snap_failure(environment(), Ok(project), echo_rules(), "with a render error")
}

// Byte order marks
//
// A file is read as its bytes, with every leading U+FEFF, on both targets,
// so a module starting with one doesn't parse, as glance stops at it. The
// files are written to disk byte by byte and loaded from there, since a
// project in memory starts after decoding.

pub fn leading_byte_order_marks_are_kept_test() {
  let directory = support.fixture_directory("byte_order_marks")
  let root = support.absolute(directory)
  let mark = <<0xEF, 0xBB, 0xBF>>
  let module = <<"pub fn main() {\n  1\n}\n":utf8>>
  let cases = [
    #("One mark", <<mark:bits, module:bits>>, 1),
    #("Two marks", <<mark:bits, mark:bits, module:bits>>, 1),
    #("Only a mark", mark, 1),
    #("A mark and bytes that aren't UTF-8", <<mark:bits, 0xFF>>, 2),
  ]
  let outputs =
    list.map(cases, fn(entry) {
      let #(name, bytes, exit_code) = entry
      support.write_fixture(directory, [
        #("gleam.toml", "name = \"app\"\n"),
        #("manifest.toml", "packages = []\n"),
      ])
      support.write_bytes(directory <> "/src/app.gleam", bytes)
      let outcome =
        cli.execute(
          [],
          support.environment(root),
          loader.load_project,
          [],
          support.counting_sample(),
        )
      assert outcome.exit_code == exit_code
      assert outcome.stderr == ""
      // The source is every byte of the file.
      case loader.load_project(root) {
        Ok(project) -> {
          let assert Ok(loaded) = dict.get(project.modules, "app")
          assert bit_array.from_string(line_index.source(loaded.source))
            == bytes
        }
        Error(_cannot_read) -> Nil
      }
      name
      <> ", exit code "
      <> int.to_string(outcome.exit_code)
      <> ":\n\n"
      <> outcome.stdout
    })
  support.cleanup(directory)
  birdie.snap(
    string.join(outputs, "\n"),
    title: "cli: leading byte order marks",
  )
}

// Helpers
//
// Running in memory with a counting clock, and small projects to run on.

const root = "/home/me/app"

fn environment() -> cli.Environment {
  support.environment(root)
}

fn echo_rules() -> List(Rule) {
  [fixture_rules.no_echo()]
}

// Run in the root with `fixture/no-echo`.
fn execute(
  arguments: List(String),
  loaded: Result(Project, LoadError),
) -> cli.Outcome {
  execute_in(environment(), arguments, loaded, echo_rules())
}

// Run with `rules` and a counting clock, loading `loaded`, at the root it's
// asked for.
fn execute_in(
  environment: cli.Environment,
  arguments: List(String),
  loaded: Result(Project, LoadError),
  rules: List(Rule),
) -> cli.Outcome {
  execute_with(environment, arguments, loaded, rules, support.counting_sample())
}

// Run as `execute_in` does, with `clock` as the clock.
fn execute_with(
  environment: cli.Environment,
  arguments: List(String),
  loaded: Result(Project, LoadError),
  rules: List(Rule),
  clock: fn() -> stats.Sample,
) -> cli.Outcome {
  let load = fn(root) {
    result.map(loaded, fn(project) { loader.Project(..project, root:) })
  }
  cli.execute(arguments, environment, load, rules, clock)
}

// The load, lint and total phases of a document's stats, each read with
// `phase`.
fn phases(phase: fn(String) -> decode.Decoder(a)) -> decode.Decoder(List(a)) {
  use load <- decode.field("stats", phase("load"))
  use lint <- decode.field("stats", phase("lint"))
  use total <- decode.field("stats", phase("total"))
  decode.success([load, lint, total])
}

// A project whose only module, `src/app.gleam`, holds `source`.
fn project_of(source: String) -> Project {
  support.project("", [#("src/app.gleam", source)], [])
}

fn echo_project() -> Result(Project, LoadError) {
  Ok(project_of("pub fn main() {\n  echo 1\n}\n"))
}

// A failed run's document. Its human output exits the same way and ends
// with the closing line.
fn snap_failure(
  environment: cli.Environment,
  loaded: Result(Project, LoadError),
  rules: List(Rule),
  name: String,
) -> Nil {
  let human = execute_in(environment, [], loaded, rules)
  let document = execute_in(environment, ["--format", "json"], loaded, rules)
  assert human.exit_code == 2 && document.exit_code == 2
  assert human.stderr == "" && document.stderr == ""
  assert string.ends_with(
    human.stdout,
    "grice couldn't complete the run. Fix the problems above and run it again.\n",
  )
  birdie.snap(document.stdout, title: "cli: a failed run " <> name)
}
