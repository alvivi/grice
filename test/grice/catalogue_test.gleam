//// One snapshot of each of grice's own diagnostics, rendered as a user sees
//// it, without colour: the configuration's and the rule set's, those about
//// parsing and types, the suppression warnings, and why a run failed.
//// Together they're all the prose grice writes about a run, in one place to
//// review.

import birdie
import glance
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{None}
import gleam/string
import grice/diagnostic.{type Diagnostic}
import grice/internal/cli
import grice/internal/config
import grice/internal/line_index.{type LineIndex}
import grice/internal/loader.{type Project}
import grice/internal/render/human
import grice/internal/runner
import grice/rule
import grice/support

// The configuration and the rule set
//
// What stops a run before any rule reports.

pub fn invalid_config_test() {
  let assert Error([problem]) =
    config.parse("[tools.grice]\nincludes = [\"src/\"]\n")
  snap_alone(problem, "grice/invalid-config")
}

pub fn invalid_rule_test() {
  let project = support.project("", [#("src/app.gleam", "")], [])
  let assert Error([problem]) =
    runner.run(project, [
      rule.module("No-Echo", title: "Echo left in the code")
      |> rule.with_context(initial: Nil)
      |> rule.build,
    ])
  snap_alone(problem, "grice/invalid-rule")
}

pub fn invalid_report_test() {
  let project =
    support.project("", [#("src/app.gleam", "pub fn main() { 1 }\n")], [])
  let out_of_bounds =
    rule.module("fixture/out-of-bounds", title: "Out of bounds")
    |> rule.with_context(initial: Nil)
    |> rule.on_module_end(fn(_context, _facts) {
      [rule.report(at: glance.Span(0, 99), label: "Past the end")]
    })
    |> rule.build
  let assert Ok(runner.Linted(diagnostics: [problem], ..)) =
    runner.run(project, [out_of_bounds])
  snap_alone(problem, "grice/invalid-report")
}

// Parsing and types
//
// What a run couldn't analyse, from the showcase.

pub fn parse_error_test() {
  snap_from_showcase("grice/parse-error", located: True)
}

pub fn untyped_definition_test() {
  snap_from_showcase("grice/untyped-definition", located: True)
}

pub fn uninferred_module_test() {
  snap_from_showcase("grice/uninferred-module", located: False)
}

pub fn unavailable_import_test() {
  snap_from_showcase("grice/unavailable-import", located: True)
}

pub fn unavailable_import_through_other_modules_test() {
  let #(project, linted) = support.showcase()
  let assert [found] =
    pick(linted.diagnostics, "grice/unavailable-import", located: False)
  snap(project, found, "grice/unavailable-import through other modules")
}

pub fn missing_package_test() {
  snap_from_showcase("grice/missing-package", located: False)
}

// Suppressions
//
// Suppressions that can't do their job.

pub fn unused_suppression_test() {
  snap_from_showcase("grice/unused-suppression", located: True)
}

pub fn invalid_suppression_test() {
  snap_from_showcase("grice/invalid-suppression", located: True)
}

// Failed runs
//
// Why a run has no result, as the command line reports it.

pub fn cannot_read_test() {
  let assert [found] =
    cli.load_error(loader.CannotRead("src/app.gleam", "Permission denied"))
  snap_alone(found, "grice/cannot-read")
}

pub fn cannot_read_without_a_project_test() {
  snap_alone(
    cli.no_project("/home/me/app"),
    "grice/cannot-read without a project",
  )
}

pub fn invalid_manifest_test() {
  let assert [found] =
    cli.load_error(loader.InvalidManifest(
      "`packages` in `manifest.toml` isn't a list",
    ))
  snap_alone(found, "grice/invalid-manifest")
}

pub fn internal_error_test() {
  let error =
    human.InvalidSpan(
      "src/app.gleam",
      diagnostic.Span(0, 9),
      line_index.OutOfBounds,
    )
  snap_alone(cli.internal_error(error), "grice/internal-error")
}

// The showcase holds each code the snapshots above pick from it, once,
// except the two forms of `grice/unavailable-import`.
pub fn the_showcase_shows_each_code_once_test() {
  let #(_project, linted) = support.showcase()
  let codes =
    linted.diagnostics
    |> list.map(fn(found) { found.code })
    |> list.filter(fn(code) { code != "fixture/no-echo" })
    |> list.sort(by: string.compare)
  assert codes
    == [
      "grice/invalid-suppression", "grice/missing-package", "grice/parse-error",
      "grice/unavailable-import", "grice/unavailable-import",
      "grice/uninferred-module", "grice/untyped-definition",
      "grice/unused-suppression",
    ]
}

// Helpers
//
// Picking a diagnostic and rendering it alone.

// The only diagnostic of the showcase with `code`, with or without a
// location.
fn snap_from_showcase(code: String, located located: Bool) -> Nil {
  let #(project, linted) = support.showcase()
  let assert [found] = pick(linted.diagnostics, code, located:)
  snap(project, found, code)
}

fn pick(
  diagnostics: List(Diagnostic),
  code: String,
  located located: Bool,
) -> List(Diagnostic) {
  list.filter(diagnostics, fn(found) {
    found.code == code && option.is_some(found.location) == located
  })
}

// A diagnostic with no location, which needs no sources.
fn snap_alone(found: Diagnostic, title: String) -> Nil {
  let assert None = found.location
  render(found, dict.new(), title)
}

fn snap(project: Project, found: Diagnostic, title: String) -> Nil {
  render(found, loader.sources(project), title)
}

fn render(
  found: Diagnostic,
  sources: Dict(String, LineIndex),
  title: String,
) -> Nil {
  let assert Ok(text) =
    human.render([found], sources, human.Options(colour: False, directory: ""))
  birdie.snap(text, title: "catalogue: " <> title)
}
