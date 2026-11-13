//// Renders diagnostics as text for a terminal, in a layout modelled on the
//// Gleam compiler's:
////
//// ```text
//// warning[my_app/unused-value]: Unused value
////   ┌─ src/app.gleam:4:3
////   │
//// 4 │   int.parse("1")
////   │   ^^^^^^^^^^^^^^ This value is never used
////
//// The value is computed and then thrown away.
////
//// Hint: Assign it to `_` if you don't need it.
//// ```
////
//// It looks like the compiler's output without copying it exactly. Each
//// label gets its own row of carets, `^` for the primary label and `-` for
//// secondary ones, and a label that spans several lines is shown on its
//// first line, underlined to the end of it. Tabs expand to stops of 4
//// columns, and display widths come from string_width.
////
//// Rendering never guesses. Every source and span is checked first, and
//// any problem is an error with no partial output.

import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import grice/diagnostic.{
  type Diagnostic, type Edit, type Fix, type Label, type Location, type Severity,
  type Span,
}
import grice/internal/line_index.{type LineIndex, type SpanProblem}
import string_width

/// How to render. Whether to colour is decided by the caller, which knows
/// whether it writes to a terminal.
pub type Options {
  Options(colour: Bool)
}

/// Why diagnostics couldn't be rendered. Each one is a bug in whatever
/// built the diagnostic.
pub type RenderError {
  /// A location's path has no source.
  MissingSource(path: String)
  /// A label's or an edit's span isn't valid for the source at `path`.
  InvalidSpan(path: String, span: Span, problem: SpanProblem)
  /// Two edits of a fix overlap: `second` starts before `first` ends, or a
  /// replacement is followed by an insertion at its start.
  OverlappingEdits(path: String, first: Span, second: Span)
}

/// Render diagnostics in order, each followed by an empty line. `sources`
/// maps each location's path to the index of its source.
///
/// Every diagnostic is checked before anything is rendered, and the first
/// problem found is returned: diagnostics in order, and within one the
/// source lookup, the primary label, the secondary labels in order, the fix's
/// edits in order, and then whether any edits overlap.
pub fn render(
  diagnostics: List(Diagnostic),
  sources: Dict(String, LineIndex),
  options: Options,
) -> Result(String, RenderError) {
  use checked <- result.map(list.try_map(diagnostics, check(_, sources)))
  checked
  |> list.map(render_diagnostic(_, options.colour))
  |> string.concat
}

// Validation
//
// Every source and span is checked before anything is written, so a render
// either succeeds whole or returns the first problem.

// A diagnostic whose location, if it has one, has been checked against its
// source.
type Checked {
  Located(diagnostic: Diagnostic, location: Location, source: LineIndex)
  Unlocated(diagnostic: Diagnostic)
}

fn check(
  diagnostic: Diagnostic,
  sources: Dict(String, LineIndex),
) -> Result(Checked, RenderError) {
  case diagnostic.location {
    None -> Ok(Unlocated(diagnostic))
    Some(location) -> {
      let path = location.path
      use source <- result.try(
        dict.get(sources, path) |> result.replace_error(MissingSource(path)),
      )
      use Nil <- result.try(check_label(source, path, location.primary))
      use Nil <- result.try(
        list.try_each(location.secondary, check_label(source, path, _)),
      )
      use Nil <- result.try(check_fix(source, path, location.fix))
      Ok(Located(diagnostic:, location:, source:))
    }
  }
}

fn check_label(
  source: LineIndex,
  path: String,
  label: Label,
) -> Result(Nil, RenderError) {
  line_index.check_span(source, label.span)
  |> result.map_error(InvalidSpan(path, label.span, _))
}

fn check_fix(
  source: LineIndex,
  path: String,
  fix: Option(Fix),
) -> Result(Nil, RenderError) {
  case fix {
    None -> Ok(Nil)
    Some(fix) -> {
      use Nil <- result.try(
        list.try_each(fix.edits, check_edit(source, path, _)),
      )
      check_overlaps(path, fix.edits)
    }
  }
}

fn check_edit(
  source: LineIndex,
  path: String,
  edit: Edit,
) -> Result(Nil, RenderError) {
  line_index.check_edit_span(source, edit.span)
  |> result.map_error(InvalidSpan(path, edit.span, _))
}

// Edits follow LSP's `TextEdit` rules. Sorted by start, keeping list order
// among equal starts, each edit must start at or after the end of the one
// before. That allows insertions at one position in list order, followed by
// at most one replacement, and rejects anything else that shares bytes.
// `list.sort` doesn't document that it's stable, so ties are broken on list
// position explicitly.
fn check_overlaps(path: String, edits: List(Edit)) -> Result(Nil, RenderError) {
  let sorted =
    edits
    |> list.index_map(fn(edit, position) { #(edit, position) })
    |> list.sort(by: fn(a, b) {
      int.compare({ a.0 }.span.start, { b.0 }.span.start)
      |> order.break_tie(int.compare(a.1, b.1))
    })
    |> list.map(fn(entry) { entry.0 })
  case
    list.find(list.window_by_2(sorted), fn(pair) {
      { pair.1 }.span.start < { pair.0 }.span.end
    })
  {
    Ok(#(first, second)) ->
      Error(OverlappingEdits(path, first.span, second.span))
    Error(Nil) -> Ok(Nil)
  }
}

// Writing
//
// A diagnostic is blocks separated by empty lines: the header, with the
// snippet when there is a location, then each message paragraph, then the
// hint.

fn render_diagnostic(checked: Checked, colour: Bool) -> String {
  let diagnostic = checked.diagnostic
  let head = case checked {
    Located(diagnostic:, location:, source:) ->
      header(diagnostic, colour)
      <> "\n"
      <> snippet(diagnostic.severity, location, source, colour)
    Unlocated(diagnostic:) -> header(diagnostic, colour)
  }
  let hint = case diagnostic.hint {
    Some(hint) -> ["Hint: " <> hint]
    None -> []
  }
  [head, ..list.map(list.append(diagnostic.message, hint), wrap)]
  |> string.join("\n\n")
  |> string.append("\n\n")
}

fn header(diagnostic: Diagnostic, colour: Bool) -> String {
  let name = case diagnostic.code {
    "" -> severity_name(diagnostic.severity)
    code -> severity_name(diagnostic.severity) <> "[" <> code <> "]"
  }
  paint(name, "1;" <> severity_colour(diagnostic.severity), colour)
  <> paint(": " <> diagnostic.title, "1", colour)
}

fn severity_name(severity: Severity) -> String {
  case severity {
    diagnostic.Error -> "error"
    diagnostic.Warning -> "warning"
    diagnostic.Note -> "note"
  }
}

// ANSI colour codes: red, yellow and green.
fn severity_colour(severity: Severity) -> String {
  case severity {
    diagnostic.Error -> "31"
    diagnostic.Warning -> "33"
    diagnostic.Note -> "32"
  }
}

// For the gutter and secondary labels.
const cyan = "36"

fn paint(text: String, style: String, colour: Bool) -> String {
  case colour {
    True -> "\u{1b}[" <> style <> "m" <> text <> "\u{1b}[0m"
    False -> text
  }
}

// The snippet
//
// The location line, then each labelled line in order with a row of carets
// for each of its labels. A `·` stands for the lines skipped between two.

// A label as drawn: its line, and the column its carets start at and how
// many there are, in display columns.
type Mark {
  Mark(line: Int, column: Int, width: Int, primary: Bool, message: String)
}

fn snippet(
  severity: Severity,
  location: Location,
  source: LineIndex,
  colour: Bool,
) -> String {
  // By line, then column, then list order, which puts the primary first.
  let marks =
    [
      mark(source, location.primary, True),
      ..list.map(location.secondary, mark(source, _, False))
    ]
    |> list.index_map(fn(mark, index) { #(mark, index) })
    |> list.sort(fn(a, b) {
      int.compare({ a.0 }.line, { b.0 }.line)
      |> order.break_tie(int.compare({ a.0 }.column, { b.0 }.column))
      |> order.break_tie(int.compare(a.1, b.1))
    })
    |> list.map(fn(entry) { entry.0 })
  let lines = marks |> list.map(fn(mark) { mark.line }) |> list.unique
  let width =
    lines |> list.last |> result.unwrap(1) |> int.to_string |> string.length
  let pad = string.repeat(" ", width + 1)
  let gutter = paint(_, cyan, colour)
  let start = line_index.position(source, location.primary.span.start)
  let header =
    pad
    <> gutter("┌─")
    <> " "
    <> location.path
    <> ":"
    <> int.to_string(start.line)
    <> ":"
    <> int.to_string(start.column)
  let rows =
    list.zip(lines, [0, ..lines])
    |> list.flat_map(fn(pair) {
      let #(line, previous) = pair
      let skipped = case previous > 0 && line > previous + 1 {
        True -> [pad <> gutter("·")]
        False -> []
      }
      let number = string.pad_start(int.to_string(line), to: width, with: " ")
      let carets =
        marks
        |> list.filter(fn(mark) { mark.line == line })
        |> list.map(fn(mark) {
          row(pad <> gutter("│"), carets(mark, severity, colour))
        })
      list.flatten([
        skipped,
        [row(gutter(number <> " │"), line_text(source, line))],
        carets,
      ])
    })
  string.join([header, pad <> gutter("│"), ..rows], "\n")
}

fn mark(source: LineIndex, label: Label, primary: Bool) -> Mark {
  let start = label.span.start
  let line = line_index.line_number(source, start)
  let #(line_start, line_end) = line_index.line_bytes(source, line)
  // A label that runs past its line is underlined to the end of the line.
  let end = int.max(start, int.min(label.span.end, line_end))
  let column = measure(slice(source, line_start, start))
  let width = measure(slice(source, line_start, end)) - column
  Mark(
    line:,
    column:,
    width: int.max(width, 1),
    primary:,
    message: label.message,
  )
}

fn carets(mark: Mark, severity: Severity, colour: Bool) -> String {
  let #(caret, style) = case mark.primary {
    True -> #("^", severity_colour(severity))
    False -> #("-", cyan)
  }
  let underline = string.repeat(caret, mark.width)
  let text = case mark.message {
    "" -> underline
    message -> underline <> " " <> message
  }
  string.repeat(" ", mark.column) <> paint(text, style, colour)
}

fn line_text(source: LineIndex, line: Int) -> String {
  let #(start, end) = line_index.line_bytes(source, line)
  slice(source, start, end)
  |> string_width.tabs_to_spaces_with(width_options())
}

// A row after the gutter, with no trailing space when the row is empty.
fn row(gutter: String, content: String) -> String {
  case content {
    "" -> gutter
    _ -> gutter <> " " <> content
  }
}

// Spans have been checked to fall on codepoint boundaries, so the bytes are
// valid UTF-8.
fn slice(source: LineIndex, start: Int, end: Int) -> String {
  line_index.source(source)
  |> bit_array.from_string
  |> bit_array.slice(start, end - start)
  |> result.try(bit_array.to_string)
  |> result.unwrap("")
}

// Widths are terminal columns, with a tab stop every 4 columns. Escape
// sequences in a source are measured like any other text.
fn width_options() -> string_width.Options {
  string_width.new()
  |> string_width.with_tab_width(4)
  |> string_width.count_ansi_codes
}

fn measure(text: String) -> Int {
  string_width.line_with(text, width_options())
}

// Wrapping
//
// Each line of a paragraph is filled greedily up to 75 columns, the width
// the compiler wraps its text to. Words are never cut, so one longer than
// that gets a line of its own.

const wrap_width = 75

fn wrap(text: String) -> String {
  text
  |> string.split("\n")
  |> list.map(fn(line) {
    let #(lines, current) = list.fold(string.split(line, " "), #([], ""), fill)
    string.join(list.reverse([current, ..lines]), "\n")
  })
  |> string.join("\n")
}

fn fill(
  state: #(List(String), String),
  word: String,
) -> #(List(String), String) {
  let #(lines, current) = state
  case current, measure(current <> " " <> word) > wrap_width {
    "", _ -> #(lines, word)
    _, True -> #([current, ..lines], word)
    _, False -> #(lines, current <> " " <> word)
  }
}
