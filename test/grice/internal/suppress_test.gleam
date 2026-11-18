//// Tests for hiding diagnostics, over facts built in memory and
//// diagnostics made by hand. First the grammar of a suppression, then
//// where it may stand and what it reaches, the file form, unused and
//// turned-off suppressions, the ignores of `gleam.toml` and what can never
//// be hidden, and last how many diagnostics were hidden.

import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/order
import gleam/result
import gleam/set
import gleam/string
import grice/diagnostic.{type Diagnostic, Diagnostic, Label, Location, Span}
import grice/facts
import grice/internal/line_index
import grice/internal/suppress
import grice/support

// Grammar

pub fn a_well_formed_suppression_hides_the_next_line_test() {
  let hidden = fn(directive) { under(directive) == [] }
  assert hidden("// grice-ignore fixture/no-echo: Printing is the point.")
  // Spaces and tabs are both whitespace, around every part.
  assert hidden("//\tgrice-ignore\tfixture/no-echo:\twhy")
  assert hidden("//   grice-ignore   fixture/no-echo  :  why  ")
  // The first colon ends the code, so the reason may hold more.
  assert hidden("// grice-ignore fixture/no-echo: see: #12")
  // Doc comments are never suppressions.
  assert under("/// grice-ignore fixture/no-echo: why")
    == ["3 fixture/no-echo: found"]
  assert under("//// grice-ignore-file fixture/no-echo: why")
    == ["3 fixture/no-echo: found"]
}

// Whitespace in a suppression is spaces and tabs only, so a comment whose
// text starts with any other whitespace is an ordinary comment: vertical
// tab, form feed, next line, the two direction marks, and the line and
// paragraph separators.
pub fn other_whitespace_before_grice_ignore_makes_no_suppression_test() {
  let whitespace = [
    "\u{000B}", "\u{000C}", "\u{0085}", "\u{200E}", "\u{200F}", "\u{2028}",
    "\u{2029}",
  ]
  let mismatches =
    list.filter(whitespace, fn(character) {
      under("//" <> character <> "grice-ignore fixture/no-echo: why")
      != ["3 fixture/no-echo: found"]
    })
  assert mismatches == []
}

pub fn a_malformed_suppression_is_invalid_and_hides_nothing_test() {
  let table = [
    #("// grice-ignore fixture/no-echo", "This gives no reason"),
    #("// grice-ignore fixture/no-echo:", "This gives no reason"),
    #("// grice-ignore fixture/no-echo: \t ", "This gives no reason"),
    #("// grice-ignore : why", "This names no rule"),
    #("// grice-ignore", "This names no rule"),
    #("// grice-ignore-file", "This names no rule"),
    #("// grice-ignore: why", "This names no rule"),
    #("// grice-ignore Fixture/No-Echo: why", "This isn't a rule code"),
    #("// grice-ignore fixture/no-echo extra: why", "This isn't a rule code"),
    // Form feed isn't whitespace after the code either.
    #("// grice-ignore fixture/no-echo\u{000C}: why", "This isn't a rule code"),
    #(
      "// grice-ignore grice/parse-error: why",
      "This names one of grice's own diagnostics",
    ),
    #(
      "// grice-ignore-next-line fixture/no-echo: why",
      "grice doesn't know `grice-ignore-next-line`",
    ),
    #(
      "// grice-ignore-files fixture/no-echo: why",
      "grice doesn't know `grice-ignore-files`",
    ),
    #("// grice-ignored, as said above", "grice doesn't know `grice-ignored,`"),
    // After code on its line, and a file suppression after the first line
    // of code.
    #("1 // grice-ignore fixture/no-echo: why", "This comes after code"),
    #("// grice-ignore-file fixture/no-echo: why", "This comes after code"),
  ]
  let mismatches =
    list.filter(table, fn(row) {
      let #(directive, label) = row
      under(directive)
      != ["2 grice/invalid-suppression: " <> label, "3 fixture/no-echo: found"]
    })
  assert mismatches == []
}

// Placement and reach

// Blank lines, comments, doc comments and other suppressions are skipped,
// so suppressions stack. Each is matched against the same diagnostics, so
// two that cover one diagnostic are both used.
pub fn suppressions_skip_blank_lines_and_comments_test() {
  let source =
    "// grice-ignore fixture/no-echo: one

// A plain comment.
// grice-ignore fixture/other: two
// grice-ignore fixture/other: three
/// Docs.
pub fn main() { echo 1 }
"
  assert run(source, [
      #("fixture/no-echo", "pub fn main"),
      #("fixture/other", "echo 1"),
      #("fixture/third", "echo 1"),
    ])
    == ["7 fixture/third: found"]
}

// A diagnostic is on the line its primary span starts on, wherever it
// ends and whatever its secondary labels point at.
pub fn a_suppression_reaches_primary_spans_starting_on_its_line_test() {
  let source =
    "pub fn main() {
  let x = [
    1,
  ]
  // grice-ignore fixture/no-echo: why
  echo [
    x,
  ]
  echo 2
}
"
  let start = fn(needle) { support.span_of(source, needle).start }
  let end = fn(needle) { support.span_of(source, needle).end }
  let span = fn(from, to) { Span(start(from), end(to)) }
  let diagnostics = [
    // Starts on the line, ends below it: hidden.
    found("fixture/no-echo", span("echo [", "    x,\n  ]"), []),
    // Starts above, ends on the line: kept.
    found("fixture/no-echo", span("let x", "echo ["), []),
    // Points at the line with a secondary label only: kept.
    found("fixture/no-echo", span("echo 2", "echo 2"), [
      span("echo [", "echo ["),
    ]),
    // Another rule on the line: kept.
    found("fixture/other", span("echo [", "echo ["), []),
  ]
  assert describe(source, apply_to("", source, diagnostics, codes))
    == [
      "2 fixture/no-echo: found",
      "6 fixture/other: found",
      "9 fixture/no-echo: found",
    ]
}

// Above the attribute of a definition left out for the other target, a
// suppression covers the attribute's line, the first line of code.
pub fn a_suppression_above_an_other_target_attribute_covers_its_line_test() {
  let source =
    "// grice-ignore fixture/no-echo: why
@target(javascript)
pub fn javascript() {
  1
}
"
  assert run(source, [
      #("fixture/no-echo", "@target(javascript)"),
      #("fixture/no-echo", "pub fn javascript()"),
    ])
    == ["3 fixture/no-echo: found"]
}

// File suppressions

pub fn a_file_suppression_hides_the_rule_everywhere_in_the_module_test() {
  let source =
    "//// The module.
// grice-ignore-file fixture/no-echo: why
// Another comment.

pub fn main() {
  echo 1
}

pub fn other() { echo 2 }
"
  assert run(source, [
      #("fixture/no-echo", "echo 1"),
      #("fixture/no-echo", "echo 2"),
      #("fixture/other", "echo 2"),
    ])
    == ["9 fixture/other: found"]
}

pub fn a_file_suppression_only_covers_its_own_module_test() {
  let files = [
    #("src/app.gleam", "// grice-ignore-file fixture/no-echo: why\n"),
    #("src/other.gleam", "pub fn main() { echo 1 }\n"),
  ]
  let echo_span = support.span_of("pub fn main() { echo 1 }\n", "echo 1")
  let assert Diagnostic(location: Some(location), ..) as other =
    found("fixture/no-echo", echo_span, [])
  let other =
    Diagnostic(
      ..other,
      location: Some(Location(..location, path: "src/other.gleam")),
    )
  assert apply_files("", files, [other], codes)
    |> list.map(fn(diagnostic) { diagnostic.code })
    == ["fixture/no-echo", "grice/unused-suppression"]
}

// Unused suppressions

// The ignore hides the only `fixture/other` diagnostic, so the file
// suppression of that rule has nothing left to hide.
pub fn an_unused_suppression_says_why_test() {
  let toml =
    "[[tools.grice.ignore]]\npaths = [\"src\"]\nrules = [\"fixture/other\"]\nreason = \"why\"\n"
  let source =
    "// grice-ignore-file fixture/other: why
pub fn main() {
  // grice-ignore fixture/no-echo: why
  1
  // grice-ignore fixture/no-ecko: why
  echo 2
}
// grice-ignore fixture/no-echo: why
"
  let warnings = apply(toml, source, [#("fixture/other", "echo 2")], codes)
  assert list.map(sort(warnings), fn(warning) { warning.message })
    == [
      [
        "This suppression hides nothing: no diagnostic of the rule `fixture/other` is left to hide in this module.",
      ],
      [
        "This suppression hides nothing: no diagnostic of the rule `fixture/no-echo` is left to hide on line 4, the next line of code.",
      ],
      [
        "This suppression names `fixture/no-ecko`, but no rule of this run has that code, so it hides nothing. It's most likely a typo, a rule that was removed, or a rule of another rule set.",
      ],
      [
        "This suppression hides nothing: no diagnostic of the rule `fixture/no-echo` is left to hide below it, where no code follows.",
      ],
    ]
  assert list.unique(list.map(warnings, fn(warning) { warning.title }))
    == ["Unused suppression"]
}

// Turned off

// Ignores still apply.
pub fn turned_off_suppressions_are_each_invalid_and_hide_nothing_test() {
  let toml =
    "[tools.grice]
suppression_comments = false

[[tools.grice.ignore]]
paths = [\"src\"]
rules = [\"fixture/other\"]
reason = \"why\"
"
  let source =
    "// grice-ignore-file fixture/no-echo: why
pub fn main() {
  // grice-ignore fixture/no-echo: why
  // grice-ignore-next-line nonsense
  echo 1
}
"
  let result =
    apply(
      toml,
      source,
      [#("fixture/no-echo", "echo 1"), #("fixture/other", "echo 1")],
      codes,
    )
  assert describe(source, result)
    == [
      "1 grice/invalid-suppression: grice doesn't read this",
      "3 grice/invalid-suppression: grice doesn't read this",
      "4 grice/invalid-suppression: grice doesn't read this",
      "5 fixture/no-echo: found",
    ]
  let assert [warning, ..] = sort(result)
  assert warning.title == "Invalid suppression"
}

// Ignores

const definitions_source =
  "import gleam/list
pub fn render_page() {
  echo 1
}
pub fn other() {
  echo 2
}
const c = 1
type T { T }
type A = Int
"

pub fn an_ignore_hides_its_rules_in_the_files_it_matches_test() {
  let toml =
    "[[tools.grice.ignore]]
paths = [\"src/**\"]
rules = [\"fixture/no-echo\"]
reason = \"why\"

[[tools.grice.ignore]]
paths = [\"test/\"]
rules = [\"fixture/other\"]
reason = \"Matches nothing, which is fine.\"
"
  assert apply(
      toml,
      definitions_source,
      [
        #("fixture/no-echo", "echo 1"),
        #("fixture/other", "echo 2"),
      ],
      codes,
    )
    |> describe(definitions_source, _)
    == ["6 fixture/other: found"]
}

pub fn an_ignore_with_definitions_hides_only_inside_them_test() {
  let toml =
    "[[tools.grice.ignore]]
paths = [\"src/app.gleam\"]
definitions = [\"render_*\", \"?\"]
rules = [\"fixture/no-echo\"]
reason = \"why\"
"
  let source = definitions_source
  let render = support.span_of(source, "pub fn render_page() {\n  echo 1\n}")
  let at = fn(needle) { support.span_of(source, needle) }
  let diagnostics = [
    found("fixture/no-echo", at("echo 1"), []),
    found("fixture/no-echo", at("echo 2"), []),
    found("fixture/no-echo", at("const c = 1"), []),
    found("fixture/no-echo", at("type T { T }"), []),
    found("fixture/no-echo", at("type A = Int"), []),
    // An import isn't a definition an ignore can name.
    found("fixture/no-echo", at("import gleam/list"), []),
    // Starts inside `render_page`, ends past it: hidden.
    found("fixture/no-echo", Span(render.end - 1, render.end + 4), []),
    // Starts right at the end of `render_page`: kept.
    found("fixture/no-echo", Span(render.end, render.end + 4), []),
  ]
  assert describe(source, apply_to(toml, source, diagnostics, codes))
    == [
      "1 fixture/no-echo: found",
      "4 fixture/no-echo: found",
      "6 fixture/no-echo: found",
    ]
}

// What's never hidden

// The configuration doesn't check codes against the rule set, so an
// ignore can name `grice/` codes here, and still hides nothing.
pub fn grices_own_diagnostics_are_never_hidden_test() {
  let toml =
    "[[tools.grice.ignore]]
paths = [\"**\"]
rules = [\"grice/untyped-definition\", \"grice/invalid-suppression\"]
reason = \"why\"
"
  let source =
    "// grice-ignore grice/untyped-definition: why\npub fn main() { 1 }\n"
  let note =
    found(
      "grice/untyped-definition",
      support.span_of(source, "pub fn main() { 1 }"),
      [],
    )
  let global = Diagnostic(..note, location: None)
  let assert [first, second, warning] =
    apply_to(toml, source, [global, note], codes)
  assert [first, second] == [global, note]
  assert warning.code == "grice/invalid-suppression"
  let assert Some(location) = warning.location
  assert location.primary.message == "This names one of grice's own diagnostics"
}

// Hidden count

pub fn a_diagnostic_two_suppressions_cover_counts_once_test() {
  let source =
    "// grice-ignore-file fixture/no-echo: why\npub fn main() {\n  // grice-ignore fixture/no-echo: why\n  echo 1\n}\n"
  let found = found("fixture/no-echo", support.span_of(source, "echo 1"), [])
  assert hidden_count("", source, [found]) == #([], 1)
}

// `apply` can't tell two identical diagnostics apart, and hides both.
pub fn identical_diagnostics_count_once_each_test() {
  let source =
    "pub fn main() {\n  // grice-ignore fixture/no-echo: why\n  echo 1\n}\n"
  let found = found("fixture/no-echo", support.span_of(source, "echo 1"), [])
  assert hidden_count("", source, [found, found]) == #([], 2)
}

pub fn an_unused_suppression_adds_its_warning_and_hides_nothing_test() {
  let source =
    "pub fn main() {\n  // grice-ignore fixture/no-echo: why\n  echo 1\n}\n"
  let other = found("fixture/other", support.span_of(source, "echo 1"), [])
  let assert #([kept, unused], 0) = hidden_count("", source, [other])
  assert kept == other
  assert unused.code == "grice/unused-suppression"
}

pub fn ignores_and_suppressions_count_alike_test() {
  let toml =
    "[[tools.grice.ignore]]\npaths = [\"src/app.gleam\"]\nrules = [\"fixture/other\"]\nreason = \"why\"\n"
  let source =
    "pub fn main() {\n  // grice-ignore fixture/no-echo: why\n  echo 1\n}\n"
  let span = support.span_of(source, "echo 1")
  let reported = [
    found("fixture/no-echo", span, []),
    found("fixture/other", span, []),
  ]
  assert hidden_count(toml, source, reported) == #([], 2)
}

// Helpers

const codes = ["fixture/no-echo", "fixture/other", "fixture/third"]

// What's left of a `fixture/no-echo` diagnostic on line 3 with `directive`
// on the line above it.
fn under(directive: String) -> List(String) {
  let source = "pub fn main() {\n  " <> directive <> "\n  echo 1\n}\n"
  run(source, [#("fixture/no-echo", "echo 1")])
}

// What's left of the diagnostics `#(code, needle)` at the first `needle`
// of `source`, the source of `src/app.gleam`, described.
fn run(source: String, reported: List(#(String, String))) -> List(String) {
  describe(source, apply("", source, reported, codes))
}

fn apply(
  toml: String,
  source: String,
  reported: List(#(String, String)),
  codes: List(String),
) -> List(Diagnostic) {
  let diagnostics =
    list.map(reported, fn(entry) {
      let #(code, needle) = entry
      found(code, support.span_of(source, needle), [])
    })
  apply_to(toml, source, diagnostics, codes)
}

fn apply_to(
  toml: String,
  source: String,
  diagnostics: List(Diagnostic),
  codes: List(String),
) -> List(Diagnostic) {
  apply_files(toml, [#("src/app.gleam", source)], diagnostics, codes)
}

fn apply_files(
  toml: String,
  files: List(#(String, String)),
  diagnostics: List(Diagnostic),
  codes: List(String),
) -> List(Diagnostic) {
  apply_counting(toml, files, diagnostics, codes).0
}

// What's left of `diagnostics` on `src/app.gleam`, holding `source`, and
// how many were hidden.
fn hidden_count(
  toml: String,
  source: String,
  diagnostics: List(Diagnostic),
) -> #(List(Diagnostic), Int) {
  apply_counting(toml, [#("src/app.gleam", source)], diagnostics, codes)
}

fn apply_counting(
  toml: String,
  files: List(#(String, String)),
  diagnostics: List(Diagnostic),
  codes: List(String),
) -> #(List(Diagnostic), Int) {
  let project = support.project(toml, files, [])
  let modules =
    list.filter_map(project.lint_set, fn(name) {
      use module <- result.try(dict.get(project.modules, name))
      facts.new(module, project.config.target, None)
    })
  suppress.apply(diagnostics, modules, project.config, set.from_list(codes))
}

// A diagnostic of `code` on `src/app.gleam` at `span`, with a secondary
// label at each of `secondary`.
fn found(
  code: String,
  span: diagnostic.Span,
  secondary: List(diagnostic.Span),
) -> Diagnostic {
  Diagnostic(
    code:,
    severity: diagnostic.Warning,
    title: "Made in a test",
    location: Some(Location(
      path: "src/app.gleam",
      primary: Label(span, "found"),
      secondary: list.map(secondary, Label(_, "related")),
      fix: None,
    )),
    message: [],
    hint: None,
  )
}

// Each diagnostic as the line its primary span starts on in `source`, its
// code and its primary label, by start and then code.
fn describe(source: String, diagnostics: List(Diagnostic)) -> List(String) {
  let index = line_index.new(source)
  diagnostics
  |> sort
  |> list.map(fn(found) {
    let assert Some(location) = found.location
    int.to_string(line_index.line_number(index, location.primary.span.start))
    <> " "
    <> found.code
    <> ": "
    <> location.primary.message
  })
}

fn sort(diagnostics: List(Diagnostic)) -> List(Diagnostic) {
  list.sort(diagnostics, fn(left, right) {
    let assert Some(left_location) = left.location
    let assert Some(right_location) = right.location
    int.compare(
      left_location.primary.span.start,
      right_location.primary.span.start,
    )
    |> order.break_tie(string.compare(left.code, right.code))
  })
}
