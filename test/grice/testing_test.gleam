//// Tests for the testing kit in `grice/testing`: the builders and the
//// checks of their paths, what a fixture's configuration does, the
//// installed dependencies of a typed run and when they're read, the
//// failures that stop a run, the assertions, and the render, as snapshots
//// titled `testing: …`.

import birdie
import girard
import gleam/bool
import gleam/dict
import gleam/list
import gleam/option.{Some}
import gleam/string
import grice/diagnostic.{Diagnostic}
import grice/facts
import grice/fixture_rules
import grice/internal/cli
import grice/internal/loader
import grice/internal/render/human
import grice/rule.{type Rule}
import grice/support
import grice/testing

const echo_in_main = "pub fn main() {\n  echo 1\n}\n"

const quiet_main = "pub fn main() {\n  1\n}\n"

// Builders
//
// `module` is one file at `src/app.gleam`, and `project` takes the files
// of a project tree. A path the loader would skip panics.

pub fn module_is_one_file_at_src_app_test() {
  testing.module(echo_in_main)
  |> testing.run([fixture_rules.no_echo()])
  |> testing.render
  |> birdie.snap(title: "testing: a finding")
}

pub fn project_takes_modules_under_src_test_and_dev_test() {
  let paths =
    testing.project([
      #(
        "gleam.toml",
        "[tools.grice]\ninclude = [\"src/\", \"test/\", \"dev/\"]\n",
      ),
      #("src/app.gleam", echo_in_main),
      #("test/app/view_test.gleam", echo_in_main),
      #("dev/tool.gleam", echo_in_main),
    ])
    |> testing.run([fixture_rules.no_echo()])
    |> testing.diagnostics
    |> list.map(fn(found) {
      let assert Some(location) = found.location
      location.path
    })
  assert paths
    == ["dev/tool.gleam", "src/app.gleam", "test/app/view_test.gleam"]
}

pub fn a_path_outside_the_source_directories_panics_test() {
  assert panic_of(fn() { testing.project([#("scr/app.gleam", echo_in_main)]) })
    == "The fixture path `scr/app.gleam` is neither `gleam.toml` nor a module path. A module path is under `src/`, `test/` or `dev/` and ends in `.gleam`, and each of its segments is a lowercase letter followed by lowercase letters, digits and `_`. grice would skip this file, so no rule would see it."
}

pub fn an_invalid_module_name_panics_test() {
  let message =
    panic_of(fn() {
      testing.project([
        #("src/app.gleam", quiet_main),
        #("src/Bad.gleam", echo_in_main),
      ])
    })
  assert string.starts_with(
    message,
    "The fixture path `src/Bad.gleam` is neither `gleam.toml` nor a module path.",
  )
}

pub fn a_path_given_twice_panics_test() {
  assert panic_of(fn() {
      testing.project([
        #("src/app.gleam", quiet_main),
        #("src/app.gleam", echo_in_main),
      ])
    })
    == "The fixture path `src/app.gleam` is given twice. A project has one file at each path, so only one of them would be used."
}

pub fn two_paths_with_one_module_name_panic_test() {
  let message =
    panic_of(fn() {
      testing.project([
        #("gleam.toml", "[tools.grice]\ninclude = [\"src/\", \"test/\"]\n"),
        #("src/app.gleam", quiet_main),
        #("test/other.gleam", quiet_main),
        #("test/app.gleam", echo_in_main),
      ])
    })
  assert message
    == "The fixture paths `src/app.gleam` and `test/app.gleam` give one module name, `app`, which the compiler rejects. grice would load only the first, so no rule would see the second."
}

pub fn a_dependency_added_twice_panics_test() {
  assert panic_of(fn() {
      testing.module(quiet_main)
      |> testing.with_dependency(module: "dep/box", source: "")
      |> testing.with_dependency(module: "dep/box", source: "pub fn f() { 1 }")
    })
    == "The dependency module `dep/box` is added twice. A module has one source, so only one of them would be used."
}

// Configuration
//
// A fixture is loaded as the project it describes: the defaults without
// `gleam.toml`, its `include`, `exclude` and target with one.

pub fn without_gleam_toml_the_defaults_apply_test() {
  // The defaults lint `src/` on Erlang, so neither the JavaScript function
  // nor the test module is linted.
  let source =
    "@target(javascript)\npub fn javascript() {\n  echo 1\n}\n\npub fn erlang() {\n  echo 2\n}\n"
  let assert [Diagnostic(location: Some(location), ..)] =
    testing.project([
      #("src/app.gleam", source),
      #("test/app_test.gleam", echo_in_main),
    ])
    |> testing.run([fixture_rules.no_echo()])
    |> testing.diagnostics
  assert location.path == "src/app.gleam"
  assert location.primary.span == support.span_of(source, "echo 2")
}

pub fn a_javascript_target_is_the_view_rules_see_test() {
  testing.project([
    #("gleam.toml", "target = \"javascript\"\n"),
    #(
      "src/app.gleam",
      "@target(erlang)\npub fn erlang() {\n  echo 1\n}\n\n@target(javascript)\npub fn javascript() {\n  echo 2\n}\n",
    ),
  ])
  |> testing.run([fixture_rules.no_echo()])
  |> testing.render
  |> birdie.snap(title: "testing: a JavaScript target")
}

// `gen/answer` echoes, but isn't linted, and its types still reach `app`.
pub fn an_excluded_module_is_loaded_but_not_linted_test() {
  let diagnostics =
    testing.project([
      #("gleam.toml", "[tools.grice]\nexclude = [\"src/gen/\"]\n"),
      #(
        "src/app.gleam",
        "import gen/answer\n\npub fn main() {\n  answer.value()\n}\n",
      ),
      #("src/gen/answer.gleam", "pub fn value() {\n  echo 42\n}\n"),
    ])
    |> testing.run([fixture_rules.no_echo(), main_signature()])
    |> testing.diagnostics
  assert support.describe(diagnostics)
    == ["fixture/main-signature src/app.gleam: fn() -> Int"]
}

// It's how a test gives girard an import it can't use.
pub fn an_excluded_module_that_doesnt_parse_is_no_failure_test() {
  testing.project([
    #("gleam.toml", "[tools.grice]\nexclude = [\"src/gen/\"]\n"),
    #("src/app.gleam", "import gen/broken\n\npub fn main() {\n  1\n}\n"),
    #("src/gen/broken.gleam", "pub fn ("),
  ])
  |> testing.run([fixture_rules.discarded_result()])
  |> testing.expect_codes(["grice/unavailable-import"])
}

// Installed dependencies
//
// A typed run reads the dependencies installed for the project from the
// working directory, grice's own here, and only a typed run does.

pub fn a_typed_run_answers_from_the_installed_standard_library_test() {
  let labels =
    testing.module(
      "import gleam/int\n\npub fn main() {\n  int.to_string(42)\n}\n",
    )
    |> testing.run([main_signature()])
    |> testing.diagnostics
    |> support.labels
  assert labels == ["fn() -> String"]
}

pub fn a_dependency_takes_the_place_of_an_installed_module_test() {
  testing.module(
    "import gleam/int\n\npub fn main() {\n  int.to_string(42)\n}\n",
  )
  |> testing.with_dependency(
    module: "gleam/int",
    source: "pub fn to_string(_number: Int) -> Bool {\n  True\n}",
  )
  |> testing.run([main_signature()])
  |> testing.render
  |> birdie.snap(title: "testing: a dependency in place of an installed module")
}

pub fn a_syntax_only_run_never_reads_the_installed_dependencies_test() {
  testing.module(quiet_main)
  |> testing.run_with(
    [fixture_rules.no_echo(), fixture_rules.duplicate_public_function()],
    installed: fn() {
      panic as "a syntax-only run read the installed dependencies"
    },
  )
  |> testing.expect_none
}

pub fn a_typed_run_reads_the_installed_dependencies_once_test() {
  let reads = support.new_counter()
  testing.module(quiet_main)
  |> testing.run_with(
    [
      fixture_rules.discarded_result(),
      fixture_rules.no_echo(),
      main_signature(),
    ],
    installed: fn() {
      support.increment(reads)
      Ok(#(dict.new(), []))
    },
  )
  |> testing.expect_codes(["fixture/main-signature"])
  assert support.count(reads) == 1
}

// The directory is never created, so it has no `manifest.toml`, as when
// the tests run from outside the project.
pub fn a_typed_run_without_a_manifest_says_where_to_run_the_tests_test() {
  panic_of(fn() {
    testing.module(quiet_main)
    |> testing.run_with([fixture_rules.discarded_result()], installed: fn() {
      loader.installed(support.fixture_directory("testing_no_project"))
    })
  })
  |> birdie.snap(title: "testing: a typed run without a manifest")
}

pub fn a_typed_run_over_an_invalid_manifest_shows_the_problem_test() {
  let error = loader.InvalidManifest("`manifest.toml` has no `packages` list")
  assert panic_of(fn() {
      testing.module(quiet_main)
      |> testing.run_with([fixture_rules.discarded_result()], installed: fn() {
        Error(error)
      })
    })
    == human.failure(cli.load_error(error), colour: False)
}

// A package whose sources are missing gets its note, as in a real run.
pub fn a_package_the_reader_finds_missing_is_noted_test() {
  testing.module(quiet_main)
  |> testing.run_with([fixture_rules.discarded_result()], installed: fn() {
    Ok(
      #(dict.new(), [loader.Package("lost", loader.Hex, "build/packages/lost")]),
    )
  })
  |> testing.expect_codes(["grice/missing-package"])
}

// Failures
//
// A run that couldn't prove anything panics with the problem as grice
// shows it.

pub fn an_invalid_gleam_toml_fails_the_run_test() {
  panic_of(fn() {
    testing.project([
      #("gleam.toml", "[tools.grice]\nincluded = [\"src/\"]\n"),
      #("src/app.gleam", quiet_main),
    ])
    |> testing.run([fixture_rules.no_echo()])
  })
  |> birdie.snap(title: "testing: an invalid gleam.toml fails the run")
}

pub fn nothing_to_lint_fails_the_run_test() {
  panic_of(fn() {
    testing.project([
      #("gleam.toml", "[tools.grice]\nexclude = [\"src/app.gleam\"]\n"),
      #("src/app.gleam", echo_in_main),
    ])
    |> testing.run([fixture_rules.no_echo()])
  })
  |> birdie.snap(title: "testing: nothing to lint fails the run")
}

pub fn a_module_to_lint_that_doesnt_parse_fails_the_run_test() {
  panic_of(fn() {
    testing.module("pub fn main() {\n  let x =\n}\n")
    |> testing.run([fixture_rules.no_echo()])
  })
  |> birdie.snap(title: "testing: a module to lint that doesn't parse")
}

pub fn an_invalid_rule_set_fails_the_run_test() {
  panic_of(fn() {
    testing.project([
      #(
        "gleam.toml",
        "[[tools.grice.ignore]]\npaths = [\"src/**\"]\nrules = [\"fixture/no-ecko\"]\nreason = \"Generated code.\"\n",
      ),
      #("src/app.gleam", echo_in_main),
    ])
    |> testing.run([fixture_rules.no_echo(), support.named("fixture/No-echo")])
  })
  |> birdie.snap(title: "testing: an invalid rule set fails the run")
}

// Assertions
//
// grice's own diagnostics count, and a failed assertion shows the run.

pub fn expect_none_passes_over_a_run_with_no_diagnostic_test() {
  testing.module(quiet_main)
  |> testing.run([fixture_rules.no_echo()])
  |> testing.expect_none
}

pub fn expect_none_panics_with_the_codes_and_the_run_test() {
  let run =
    testing.module(echo_in_main) |> testing.run([fixture_rules.no_echo()])
  assert panic_of(fn() { testing.expect_none(run) })
    == "Expected no diagnostics, got [\"fixture/no-echo\"]:\n\n"
    <> testing.render(run)
}

pub fn expect_none_counts_grices_own_diagnostics_test() {
  let run = untyped() |> testing.run([fixture_rules.discarded_result()])
  assert panic_of(fn() { testing.expect_none(run) })
    == "Expected no diagnostics, got [\"grice/untyped-definition\"]:\n\n"
    <> testing.render(run)
}

// The rule stays silent where girard couldn't type the code, and the note
// says why.
pub fn a_typed_rule_silent_over_a_gap_expects_the_note_test() {
  untyped()
  |> testing.run([fixture_rules.discarded_result()])
  |> testing.expect_codes(["grice/untyped-definition"])
}

pub fn expect_codes_compares_the_codes_in_order_test() {
  let run =
    testing.module(
      "pub fn main() {\n  echo 1\n  echo 2\n}\n\npub fn skipped() {\n  let _ = 1 + \"one\"\n}\n",
    )
    |> testing.run([fixture_rules.no_echo(), fixture_rules.discarded_result()])
  testing.expect_codes(run, [
    "fixture/no-echo", "fixture/no-echo", "grice/untyped-definition",
  ])
  assert panic_of(fn() {
      testing.expect_codes(run, [
        "grice/untyped-definition", "fixture/no-echo", "fixture/no-echo",
      ])
    })
    == "Expected the codes [\"grice/untyped-definition\", \"fixture/no-echo\", \"fixture/no-echo\"], got [\"fixture/no-echo\", \"fixture/no-echo\", \"grice/untyped-definition\"]:\n\n"
    <> testing.render(run)
}

pub fn expect_codes_compares_how_often_each_code_occurs_test() {
  let run =
    testing.module("pub fn main() {\n  echo 1\n  echo 2\n}\n")
    |> testing.run([fixture_rules.no_echo()])
  let got =
    ", got [\"fixture/no-echo\", \"fixture/no-echo\"]:\n\n"
    <> testing.render(run)
  assert panic_of(fn() { testing.expect_codes(run, ["fixture/no-echo"]) })
    == "Expected the codes [\"fixture/no-echo\"]" <> got
  assert panic_of(fn() {
      testing.expect_codes(run, [
        "fixture/no-echo", "fixture/no-echo", "fixture/no-echo",
      ])
    })
    == "Expected the codes [\"fixture/no-echo\", \"fixture/no-echo\", \"fixture/no-echo\"]"
    <> got
}

// Render
//
// Each file of the fixture, each dependency module, then the output with
// its summary.

pub fn render_shows_a_silent_rule_with_its_input_test() {
  testing.module(quiet_main)
  |> testing.run([fixture_rules.no_echo()])
  |> testing.render
  |> birdie.snap(title: "testing: a silent rule")
}

// `two` has no newline at its end, and gets one.
pub fn render_shows_every_file_in_the_order_given_test() {
  testing.project([
    #("src/two.gleam", "pub fn shared() {\n  2\n}"),
    #("src/one.gleam", "pub fn shared() {\n  1\n}\n"),
  ])
  |> testing.run([fixture_rules.duplicate_public_function()])
  |> testing.render
  |> birdie.snap(title: "testing: a project rule over two modules")
}

pub fn render_shows_the_dependencies_in_the_order_added_test() {
  let headings =
    testing.module(quiet_main)
    |> testing.with_dependency(
      module: "dep/b",
      source: "pub fn b() {\n  1\n}\n",
    )
    |> testing.with_dependency(
      module: "dep/a",
      source: "pub fn a() {\n  2\n}\n",
    )
    |> testing.run([fixture_rules.no_echo()])
    |> testing.render
    |> string.split("\n")
    |> list.filter(string.starts_with(_, "-- "))
  assert headings
    == [
      "-- src/app.gleam", "-- dependency dep/b", "-- dependency dep/a",
      "-- output",
    ]
}

pub fn render_shows_the_coverage_of_a_typed_run_test() {
  untyped()
  |> testing.run([fixture_rules.discarded_result()])
  |> testing.render
  |> birdie.snap(
    title: "testing: a typed rule silent over a definition girard couldn't type",
  )
}

// Helpers
//
// The fixture and the rule several tests run, and the test FFI: a panic's
// message, and the mailbox the reader counts its calls in.

// A module with a definition girard can't type, and neither could the
// compiler.
fn untyped() -> testing.Fixture {
  testing.module("pub fn main() {\n  let _ = 1 + \"one\"\n}\n")
}

// Reports, on each function named `main`, the type girard gave it.
fn main_signature() -> Rule {
  rule.module("fixture/main-signature", title: "Made in a test")
  |> rule.typed
  |> rule.with_context(initial: Nil)
  |> rule.on_function(fn(context, function, module_facts) {
    use <- bool.guard(
      when: function.definition.name != "main",
      return: #(context, []),
    )
    let label = case facts.signature(module_facts, "main") {
      Ok(scheme) -> girard.type_to_string(scheme.type_)
      Error(unknown) -> support.describe_unknown(unknown)
    }
    #(context, [rule.report(at: function.definition.location, label:)])
  })
  |> rule.build
}

// The message of the panic `run` raises.
fn panic_of(run: fn() -> a) -> String {
  let assert Ok(message) = support.panic_message(run)
    as "expected a Gleam panic"
  message
}
