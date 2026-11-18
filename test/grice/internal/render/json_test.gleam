//// Tests for the JSON document, mostly as snapshots: a run with every kind
//// of gap, a run that didn't ask for types, a fix, the stats, and a failed
//// run's `null` root. Then escaping, checked by decoding a document back,
//// and the render errors it shares with the human renderer.

import birdie
import gleam/dynamic/decode
import gleam/json as gleam_json
import gleam/option.{None, Some}
import grice/diagnostic.{Diagnostic, Edit, Fix, Label, Location, Span}
import grice/fixture_rules
import grice/internal/config
import grice/internal/line_index
import grice/internal/loader
import grice/internal/render/human
import grice/internal/render/json
import grice/internal/runner
import grice/internal/stats
import grice/support

// Runs
//
// Completed runs and a failed one, as documents.

pub fn a_run_with_every_kind_of_gap_test() {
  let #(project, linted) = support.showcase()
  let assert Ok(document) = json.run(project, linted, None)
  birdie.snap(document, title: "json: a run with every kind of gap")
}

pub fn a_run_without_types_test() {
  let #(project, linted) = echo_run()
  let assert Ok(document) = json.run(project, linted, None)
  birdie.snap(document, title: "json: a run without types")
}

// Columns count codepoints, so `é` is one column and two bytes.
pub fn a_fix_test() {
  let source = "pub fn main() {\n  \"café\" <> x\n}\n"
  let project = support.project("", [#("src/app.gleam", source)], [])
  let assert Ok(linted) = runner.run(project, [])
  let span = support.span_of(source, _)
  let fixed =
    Diagnostic(
      code: "fixture/concatenation",
      severity: diagnostic.Warning,
      title: "Concatenation of a literal",
      location: Some(Location(
        path: "src/app.gleam",
        primary: Label(span("\"café\" <> x"), "This could be one string"),
        secondary: [Label(span("x"), "")],
        fix: Some(
          Fix(title: "Swap the operands", edits: [
            Edit(span("\"café\""), "x"),
            Edit(span("x\n"), "\"café\"\n"),
          ]),
        ),
      )),
      message: ["A made-up rule with a fix."],
      hint: None,
    )
  let linted = runner.Linted(..linted, diagnostics: [fixed])
  let assert Ok(document) = json.run(project, linted, None)
  birdie.snap(document, title: "json: a fix")
}

pub fn a_failed_run_without_a_root_test() {
  let assert Error(problems) = config.parse("target = \"beam\"\n")
  let document = json.failure(None, problems)
  assert decode_root(document) == None
}

pub fn stats_come_last_test() {
  let #(project, linted) = echo_run()
  let stats =
    stats.Stats(
      loaded: 1,
      dependencies: 0,
      rules: 1,
      types: False,
      load: stats.Phase(milliseconds: 5, reductions: 19),
      lint: stats.Phase(milliseconds: 7, reductions: 37),
      total: stats.Phase(milliseconds: 15, reductions: 63),
    )
  let assert Ok(document) = json.run(project, linted, Some(stats))
  birdie.snap(document, title: "json: stats")
}

// Escaping
//
// Every string goes through gleam_json, so the document stays valid JSON.

const tricky = "quotes \" backslash \\ bell \u{0007} tab \t newline \n café 🙂"

pub fn strings_are_escaped_test() {
  let diagnostic =
    Diagnostic(
      code: "fixture/tricky",
      severity: diagnostic.Note,
      title: tricky,
      location: None,
      message: [tricky, "second"],
      hint: Some(tricky),
    )
  let document = json.failure(Some(tricky), [diagnostic])
  let decoder = {
    use root <- decode.field("root", decode.string)
    use diagnostics <- decode.field(
      "diagnostics",
      decode.list({
        use title <- decode.field("title", decode.string)
        use message <- decode.field("message", decode.list(decode.string))
        use hint <- decode.field("hint", decode.string)
        decode.success([title, hint, ..message])
      }),
    )
    decode.success(#(root, diagnostics))
  }
  assert gleam_json.parse(document, decoder)
    == Ok(#(tricky, [[tricky, tricky, tricky, "second"]]))
  birdie.snap(document, title: "json: escaping")
}

// Render errors
//
// The JSON document checks spans as the human renderer does.

// A diagnostic the runner didn't check, as a hand-made one is, fails as it
// would in the human renderer.
pub fn a_span_outside_the_source_is_a_render_error_test() {
  let project = support.project("", [#("src/app.gleam", "x\n")], [])
  let assert Ok(linted) = runner.run(project, [])
  let outside =
    Diagnostic(
      code: "fixture/outside",
      severity: diagnostic.Warning,
      title: "Outside",
      location: Some(Location(
        path: "src/app.gleam",
        primary: Label(Span(0, 9), "here"),
        secondary: [],
        fix: None,
      )),
      message: [],
      hint: None,
    )
  let linted = runner.Linted(..linted, diagnostics: [outside])
  assert json.run(project, linted, None)
    == Error(human.InvalidSpan(
      "src/app.gleam",
      Span(0, 9),
      line_index.OutOfBounds,
    ))
}

// Helpers
//
// A small run to render.

// A syntax-only run over one module with an `echo`.
fn echo_run() -> #(loader.Project, runner.Linted) {
  let project =
    support.project(
      "",
      [#("src/app.gleam", "pub fn main() {\n  echo 1\n}\n")],
      [],
    )
  let assert Ok(linted) = runner.run(project, [fixture_rules.no_echo()])
  #(project, linted)
}

fn decode_root(document: String) -> option.Option(String) {
  let assert Ok(root) =
    gleam_json.parse(document, {
      use root <- decode.field("root", decode.optional(decode.string))
      decode.success(root)
    })
  root
}
