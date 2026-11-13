//// Tests for the human renderer: the layout of a few typical diagnostics,
//// then the errors, which are tested directly: missing sources, invalid
//// spans and their precedence, and the rules for a fix's edits.

import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import grice/diagnostic.{
  type Diagnostic, Diagnostic, Edit, Fix, Label, Location, Span,
}
import grice/internal/line_index.{
  OutOfBounds, Reversed, SplitsCodepoint, SplitsLineEnding,
}
import grice/internal/render/human.{
  InvalidSpan, MissingSource, Options, OverlappingEdits,
}

// Layout

const app = "import gleam/int\n\npub fn main() {\n  int.parse(\"1\")\n  Nil\n}\n"

const numbers =
  "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\neleven\ntwelve\n"

pub fn render_located_diagnostic_test() {
  let diagnostic =
    Diagnostic(
      ..located(
        label(app, "int.parse(\"1\")", "This value is never used"),
        [],
        None,
      ),
      title: "Unused value",
      message: ["The value is computed and then thrown away."],
      hint: Some("Assign it to `_` if you don't need it."),
    )
  assert render_in(app, [diagnostic])
    == output([
      "warning[test/example]: Unused value",
      "  ┌─ src/app.gleam:4:3",
      "  │",
      "4 │   int.parse(\"1\")",
      "  │   ^^^^^^^^^^^^^^ This value is never used",
      "",
      "The value is computed and then thrown away.",
      "",
      "Hint: Assign it to `_` if you don't need it.",
    ])
}

pub fn render_labels_on_one_line_get_a_row_each_test() {
  let diagnostic =
    located(
      label(app, "parse(\"1\")", "this call"),
      [label(app, "int.", "this module")],
      None,
    )
  assert render_in(app, [diagnostic])
    == output([
      "warning[test/example]: Something is wrong",
      "  ┌─ src/app.gleam:4:7",
      "  │",
      "4 │   int.parse(\"1\")",
      "  │   ---- this module",
      "  │       ^^^^^^^^^^ this call",
    ])
}

pub fn render_distant_lines_are_separated_test() {
  let diagnostic =
    located(
      label(numbers, "eleven", "used here"),
      [label(numbers, "two", "defined here")],
      None,
    )
  assert render_in(numbers, [diagnostic])
    == output([
      "warning[test/example]: Something is wrong",
      "   ┌─ src/app.gleam:11:1",
      "   │",
      " 2 │ two",
      "   │ --- defined here",
      "   ·",
      "11 │ eleven",
      "   │ ^^^^^^ used here",
    ])
}

pub fn render_adjacent_lines_are_not_separated_test() {
  let diagnostic =
    located(
      label(numbers, "four", "second"),
      [label(numbers, "three", "first")],
      None,
    )
  assert render_in(numbers, [diagnostic])
    == output([
      "warning[test/example]: Something is wrong",
      "  ┌─ src/app.gleam:4:1",
      "  │",
      "3 │ three",
      "  │ ----- first",
      "4 │ four",
      "  │ ^^^^ second",
    ])
}

pub fn render_multiline_label_shows_its_first_line_test() {
  let Label(span:, ..) = label(app, "pub fn", "")
  let primary = Label(Span(span.start, string.byte_size(app) - 1), "this one")
  assert render_in(app, [located(primary, [], None)])
    == output([
      "warning[test/example]: Something is wrong",
      "  ┌─ src/app.gleam:3:1",
      "  │",
      "3 │ pub fn main() {",
      "  │ ^^^^^^^^^^^^^^^ this one",
    ])
}

pub fn render_empty_span_gets_one_caret_test() {
  let Label(span:, ..) = label(app, "Nil", "")
  let primary = Label(Span(span.start, span.start), "")
  assert render_in(app, [located(primary, [], None)])
    == output([
      "warning[test/example]: Something is wrong",
      "  ┌─ src/app.gleam:5:3",
      "  │",
      "5 │   Nil",
      "  │   ^",
    ])
}

pub fn render_tabs_expand_to_stops_of_four_test() {
  let source = "\tab\tcd\n"
  let diagnostic = located(label(source, "cd", "after a tab"), [], None)
  assert render_in(source, [diagnostic])
    == output([
      "warning[test/example]: Something is wrong",
      "  ┌─ src/app.gleam:1:5",
      "  │",
      "1 │     ab  cd",
      "  │         ^^ after a tab",
    ])
}

pub fn render_wide_characters_take_two_columns_test() {
  let source = "let s = \"日本\" <> x\n"
  let diagnostic =
    located(
      label(source, "x", "after wide text"),
      [label(source, "日本", "wide")],
      None,
    )
  assert render_in(source, [diagnostic])
    == output([
      "warning[test/example]: Something is wrong",
      "  ┌─ src/app.gleam:1:17",
      "  │",
      "1 │ let s = \"日本\" <> x",
      "  │          ---- wide",
      "  │                   ^ after wide text",
    ])
}

pub fn render_crlf_line_is_shown_without_its_line_ending_test() {
  let diagnostic = located(label(source, "héllo", "text"), [], None)
  assert render_in(source, [diagnostic])
    == output([
      "warning[test/example]: Something is wrong",
      "  ┌─ src/app.gleam:1:10",
      "  │",
      "1 │ let x = \"héllo\"",
      "  │          ^^^^^ text",
    ])
}

pub fn render_diagnostics_without_location_test() {
  let note =
    Diagnostic(
      code: "grice/invalid-config",
      severity: diagnostic.Note,
      title: "Invalid configuration",
      location: None,
      message: ["The table isn't valid TOML."],
      hint: Some("Fix it and run grice again."),
    )
  let error =
    Diagnostic(
      ..note,
      code: "",
      severity: diagnostic.Error,
      title: "No code",
      message: [],
      hint: None,
    )
  assert human.render([note, error], dict.new(), plain())
    == Ok(
      output([
        "note[grice/invalid-config]: Invalid configuration",
        "",
        "The table isn't valid TOML.",
        "",
        "Hint: Fix it and run grice again.",
      ])
      <> output(["error: No code"]),
    )
}

pub fn render_wraps_paragraphs_at_75_columns_test() {
  let words = fn(count) { string.join(list.repeat("word", count), " ") }
  let long = string.repeat("x", 80)
  let diagnostic =
    Diagnostic(
      ..located(Label(Span(0, 3), ""), [], None),
      location: None,
      message: [words(20), "a " <> long <> " b", "first\nsecond"],
    )
  assert human.render([diagnostic], dict.new(), plain())
    == Ok(
      output([
        "warning[test/example]: Something is wrong",
        "",
        words(15),
        words(5),
        "",
        "a",
        long,
        "b",
        "",
        "first",
        "second",
      ]),
    )
}

pub fn render_in_colour_test() {
  let diagnostic =
    Diagnostic(
      ..located(
        label(app, "parse(\"1\")", "unused"),
        [label(app, "int.", "")],
        None,
      ),
      severity: diagnostic.Error,
    )
  let sources = dict.from_list([#(path, line_index.new(app))])
  assert human.render([diagnostic], sources, Options(colour: True))
    == Ok(
      output([
        style("1;31", "error[test/example]")
          <> style("1", ": Something is wrong"),
        "  " <> style("36", "┌─") <> " src/app.gleam:4:7",
        "  " <> style("36", "│"),
        style("36", "4 │") <> "   int.parse(\"1\")",
        "  " <> style("36", "│") <> "   " <> style("36", "----"),
        "  "
          <> style("36", "│")
          <> "       "
          <> style("31", "^^^^^^^^^^ unused"),
      ]),
    )
}

// Missing sources and invalid spans
//
// Any problem fails the whole render, with no partial output, and the first
// problem in a fixed order is the one reported.

const source = "let x = \"héllo\"\r\nlet y = 2\n"

const path = "src/app.gleam"

pub fn render_without_source_is_missing_source_test() {
  let diagnostic = located(Label(Span(0, 3), ""), [], None)
  assert human.render([diagnostic], dict.new(), plain())
    == Error(MissingSource(path))
}

pub fn render_without_location_needs_no_source_test() {
  let diagnostic =
    Diagnostic(..located(Label(Span(0, 3), ""), [], None), location: None)
  assert human.render([diagnostic], dict.new(), plain())
    == Ok("warning[test/example]: Something is wrong\n\n")
}

pub fn render_primary_out_of_bounds_is_invalid_span_test() {
  assert render_one(Label(Span(0, 99), ""), [], None)
    == Error(InvalidSpan(path, Span(0, 99), OutOfBounds))
}

pub fn render_negative_start_is_invalid_span_test() {
  assert render_one(Label(Span(-1, 2), ""), [], None)
    == Error(InvalidSpan(path, Span(-1, 2), OutOfBounds))
}

pub fn render_reversed_primary_is_invalid_span_test() {
  assert render_one(Label(Span(5, 2), ""), [], None)
    == Error(InvalidSpan(path, Span(5, 2), Reversed))
}

pub fn render_primary_splitting_codepoint_is_invalid_span_test() {
  // Byte 11 is inside `é`.
  assert render_one(Label(Span(9, 11), ""), [], None)
    == Error(InvalidSpan(path, Span(9, 11), SplitsCodepoint))
}

pub fn render_invalid_secondary_is_invalid_span_test() {
  assert render_one(
      Label(Span(0, 3), ""),
      [Label(Span(4, 5), ""), Label(Span(3, 1), "")],
      None,
    )
    == Error(InvalidSpan(path, Span(3, 1), Reversed))
}

pub fn render_invalid_edit_is_invalid_span_test() {
  let fix = Fix("Fix it", [Edit(Span(0, 3), "var"), Edit(Span(11, 11), "!")])
  assert render_one(Label(Span(0, 3), ""), [], Some(fix))
    == Error(InvalidSpan(path, Span(11, 11), SplitsCodepoint))
}

pub fn render_label_out_of_bounds_comes_before_reversed_test() {
  assert render_one(Label(Span(99, 1), ""), [], None)
    == Error(InvalidSpan(path, Span(99, 1), OutOfBounds))
}

pub fn render_label_reversed_comes_before_splitting_codepoint_test() {
  assert render_one(Label(Span(11, 9), ""), [], None)
    == Error(InvalidSpan(path, Span(11, 9), Reversed))
}

pub fn render_primary_comes_before_secondary_test() {
  assert render_one(Label(Span(5, 2), ""), [Label(Span(0, 99), "")], None)
    == Error(InvalidSpan(path, Span(5, 2), Reversed))
}

pub fn render_secondaries_are_checked_in_order_test() {
  assert render_one(
      Label(Span(0, 3), ""),
      [Label(Span(0, 99), ""), Label(Span(5, 2), "")],
      None,
    )
    == Error(InvalidSpan(path, Span(0, 99), OutOfBounds))
}

pub fn render_labels_come_before_edits_test() {
  let fix = Fix("Fix it", [Edit(Span(0, 99), "")])
  assert render_one(Label(Span(0, 3), ""), [Label(Span(5, 2), "")], Some(fix))
    == Error(InvalidSpan(path, Span(5, 2), Reversed))
}

pub fn render_edits_are_checked_in_order_test() {
  let fix = Fix("Fix it", [Edit(Span(5, 2), ""), Edit(Span(0, 99), "")])
  assert render_one(Label(Span(0, 3), ""), [], Some(fix))
    == Error(InvalidSpan(path, Span(5, 2), Reversed))
}

pub fn render_invalid_edit_comes_before_overlap_test() {
  let fix =
    Fix("Fix it", [
      Edit(Span(0, 4), ""),
      Edit(Span(2, 3), ""),
      Edit(Span(0, 99), ""),
    ])
  assert render_one(Label(Span(0, 3), ""), [], Some(fix))
    == Error(InvalidSpan(path, Span(0, 99), OutOfBounds))
}

pub fn render_missing_source_comes_before_invalid_span_test() {
  let diagnostic = located(Label(Span(5, 2), ""), [], None)
  assert human.render([diagnostic], dict.new(), plain())
    == Error(MissingSource(path))
}

pub fn render_first_invalid_diagnostic_wins_test() {
  let valid = located(Label(Span(0, 3), ""), [], None)
  let reversed = located(Label(Span(5, 2), ""), [], None)
  let out_of_bounds = located(Label(Span(0, 99), ""), [], None)
  assert human.render([valid, reversed, out_of_bounds], sources(), plain())
    == Error(InvalidSpan(path, Span(5, 2), Reversed))
}

pub fn render_valid_then_invalid_gives_no_output_test() {
  let valid = located(Label(Span(0, 3), ""), [], None)
  let invalid = located(Label(Span(0, 99), ""), [], None)
  assert human.render([valid, invalid], sources(), plain())
    == Error(InvalidSpan(path, Span(0, 99), OutOfBounds))
}

// Fix edits
//
// Edits follow LSP's `TextEdit` rules: insertions at one position in list
// order, then at most one replacement, and no shared bytes otherwise.

pub fn render_two_insertions_at_one_position_are_accepted_test() {
  assert render_edits([Edit(Span(4, 4), "a"), Edit(Span(4, 4), "b")]) == Ok(Nil)
}

pub fn render_insertions_then_replacement_at_one_start_are_accepted_test() {
  assert render_edits([
      Edit(Span(4, 4), "a"),
      Edit(Span(4, 4), "b"),
      Edit(Span(4, 5), "z"),
    ])
    == Ok(Nil)
}

pub fn render_replacement_then_insertion_at_its_start_overlap_test() {
  assert render_edits([Edit(Span(4, 5), "z"), Edit(Span(4, 4), "a")])
    == Error(OverlappingEdits(path, Span(4, 5), Span(4, 4)))
}

pub fn render_two_replacements_at_one_start_overlap_test() {
  assert render_edits([Edit(Span(4, 5), "z"), Edit(Span(4, 6), "y")])
    == Error(OverlappingEdits(path, Span(4, 5), Span(4, 6)))
}

pub fn render_insertion_inside_replacement_overlaps_test() {
  assert render_edits([Edit(Span(4, 7), "z"), Edit(Span(5, 5), "a")])
    == Error(OverlappingEdits(path, Span(4, 7), Span(5, 5)))
}

pub fn render_insertion_inside_earlier_listed_replacement_overlaps_test() {
  // Edits are compared in source order, whatever their list order.
  assert render_edits([Edit(Span(5, 5), "a"), Edit(Span(4, 7), "z")])
    == Error(OverlappingEdits(path, Span(4, 7), Span(5, 5)))
}

pub fn render_insertion_at_replacement_end_is_accepted_test() {
  assert render_edits([Edit(Span(4, 7), "z"), Edit(Span(7, 7), "a")]) == Ok(Nil)
}

pub fn render_adjacent_replacements_are_accepted_test() {
  assert render_edits([Edit(Span(4, 5), "z"), Edit(Span(5, 7), "y")]) == Ok(Nil)
}

pub fn render_insertion_between_cr_and_lf_splits_line_ending_test() {
  // Bytes 16 and 17 are the `\r\n` after the first line.
  assert render_edits([Edit(Span(17, 17), ";")])
    == Error(InvalidSpan(path, Span(17, 17), SplitsLineEnding))
}

pub fn render_label_ending_between_cr_and_lf_is_accepted_test() {
  let assert Ok(_) = render_one(Label(Span(8, 17), "up to the \\r"), [], None)
}

pub fn render_fix_is_not_printed_test() {
  let fix = Fix("Fix it", [Edit(Span(0, 3), "var")])
  assert render_one(Label(Span(0, 3), ""), [], Some(fix))
    == render_one(Label(Span(0, 3), ""), [], None)
}

// Helpers
//
// One diagnostic in one source, with a CRLF line and a two-byte `é`, and
// what the layout tests need.

fn located(
  primary: diagnostic.Label,
  secondary: List(diagnostic.Label),
  fix: option.Option(diagnostic.Fix),
) -> Diagnostic {
  Diagnostic(
    code: "test/example",
    severity: diagnostic.Warning,
    title: "Something is wrong",
    location: Some(Location(path:, primary:, secondary:, fix:)),
    message: [],
    hint: None,
  )
}

fn render_one(
  primary: diagnostic.Label,
  secondary: List(diagnostic.Label),
  fix: option.Option(diagnostic.Fix),
) -> Result(String, human.RenderError) {
  human.render([located(primary, secondary, fix)], sources(), plain())
}

fn render_edits(
  edits: List(diagnostic.Edit),
) -> Result(Nil, human.RenderError) {
  render_one(Label(Span(0, 3), ""), [], Some(Fix("Fix it", edits)))
  |> result.replace(Nil)
}

fn sources() -> Dict(String, line_index.LineIndex) {
  dict.from_list([#(path, line_index.new(source))])
}

fn plain() -> human.Options {
  Options(colour: False)
}

// The text of one or more diagnostics rendered in a source at `path`.
fn render_in(source: String, diagnostics: List(Diagnostic)) -> String {
  let sources = dict.from_list([#(path, line_index.new(source))])
  let assert Ok(text) = human.render(diagnostics, sources, plain())
  text
}

// A label on the first occurrence of `needle` in `source`.
fn label(source: String, needle: String, message: String) -> diagnostic.Label {
  let assert Ok(#(before, _)) = string.split_once(source, needle)
  let start = string.byte_size(before)
  Label(Span(start, start + string.byte_size(needle)), message)
}

// One rendered diagnostic: its rows, then the empty line after it.
fn output(rows: List(String)) -> String {
  string.join(rows, "\n") <> "\n\n"
}

fn style(code: String, text: String) -> String {
  "\u{1b}[" <> code <> "m" <> text <> "\u{1b}[0m"
}
