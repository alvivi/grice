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
//// Location paths are shown relative to the working directory, so they
//// work as `file:line:column` where the output is read.
////
//// A whole run is its diagnostics and then a summary: the counts by
//// severity, how many diagnostics the ignores and suppressions hid, and,
//// when the run didn't cover all of the code, each kind of gap it left, so
//// a clean result never hides code grice didn't analyse.
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
import gleam/set
import gleam/string
import grice/coverage.{type Gap}
import grice/diagnostic.{
  type Diagnostic, type Edit, type Fix, type Label, type Location, type Severity,
  type Span,
}
import grice/internal/line_index.{type LineIndex, type SpanProblem}
import grice/internal/loader.{type Project}
import grice/internal/path
import grice/internal/runner.{type Linted}
import grice/internal/stats.{type Phase, type Stats}
import string_width

/// How to render. Whether to colour is decided by the caller, which knows
/// whether it writes to a terminal.
pub type Options {
  Options(
    colour: Bool,
    /// The directory, relative to the project root, that location paths are
    /// shown relative to: the working directory, so a path works as
    /// `file:line:column` where the output is read. `""` and `.` are the
    /// root itself. It can't hold a `..`, which isn't resolved.
    directory: String,
  )
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
/// problem found is returned, as `check` returns it.
pub fn render(
  diagnostics: List(Diagnostic),
  sources: Dict(String, LineIndex),
  options: Options,
) -> Result(String, RenderError) {
  use checked <- result.map(check(diagnostics, sources))
  write(checked, options)
}

/// Render a completed run of `project`: its diagnostics, then the summary.
pub fn run(
  project: Project,
  linted: Linted,
  options: Options,
) -> Result(String, RenderError) {
  use text <- result.map(render(
    linted.diagnostics,
    loader.sources(project),
    options,
  ))
  text <> summary(linted)
}

/// Render a run that has no result: grice's own diagnostics saying why,
/// which have no location, and a line saying the run didn't complete.
pub fn failure(diagnostics: List(Diagnostic), colour colour: Bool) -> String {
  write(list.map(diagnostics, Unlocated), Options(colour:, directory: ""))
  <> "grice couldn't complete the run. Fix the problems above and run it again.\n"
}

/// The message of a panic over a render error, which is a bug in grice:
/// every span of a run's diagnostics is checked while linting.
pub fn bug_report(error: RenderError) -> String {
  "grice couldn't render this run: "
  <> describe_error(error)
  <> ". This is a bug in grice, so please report it at https://github.com/alvivi/grice/issues."
}

/// What a render error says is wrong, as a clause for a sentence that
/// reports it, such as "the span from byte 4 to byte 2 in `src/app.gleam`
/// starts after it ends".
pub fn describe_error(error: RenderError) -> String {
  case error {
    MissingSource(path:) ->
      "a diagnostic points into `" <> path <> "`, which has no source"
    InvalidSpan(path:, span:, problem:) ->
      "the span from byte "
      <> int.to_string(span.start)
      <> " to byte "
      <> int.to_string(span.end)
      <> " in `"
      <> path
      <> "` "
      <> line_index.describe_problem(problem)
    OverlappingEdits(path:, first:, second:) ->
      "two edits of a fix in `"
      <> path
      <> "` overlap: one from byte "
      <> int.to_string(second.start)
      <> " starts before the one from byte "
      <> int.to_string(first.start)
      <> " to byte "
      <> int.to_string(first.end)
      <> " ends"
  }
}

// Validation
//
// Every source and span is checked before anything is written, so a render
// either succeeds whole or returns the first problem.

/// A diagnostic whose location, if it has one, has been checked against its
/// source, ready to write.
pub type Checked {
  Located(diagnostic: Diagnostic, location: Location, source: LineIndex)
  Unlocated(diagnostic: Diagnostic)
}

/// Check each diagnostic against the source its location points into, and
/// return the first problem: diagnostics in order, and within one the
/// source lookup, the primary label, the secondary labels in order, the
/// fix's edits in order, and then whether any edits overlap.
pub fn check(
  diagnostics: List(Diagnostic),
  sources: Dict(String, LineIndex),
) -> Result(List(Checked), RenderError) {
  list.try_map(diagnostics, check_one(_, sources))
}

fn check_one(
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

/// The word for a severity, as diagnostics start with it: "error",
/// "warning" or "note".
pub fn severity_name(severity: Severity) -> String {
  case severity {
    diagnostic.Error -> "error"
    diagnostic.Warning -> "warning"
    diagnostic.Note -> "note"
  }
}

fn write(checked: List(Checked), options: Options) -> String {
  checked
  |> list.map(write_diagnostic(_, options))
  |> string.concat
}

fn write_diagnostic(checked: Checked, options: Options) -> String {
  let diagnostic = checked.diagnostic
  let colour = options.colour
  let head = case checked {
    Located(diagnostic:, location:, source:) ->
      header(diagnostic, colour)
      <> "\n"
      <> snippet(diagnostic.severity, location, source, options)
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
  options: Options,
) -> String {
  let colour = options.colour
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
    <> path.relative(location.path, from: options.directory)
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
// valid UTF-8. They're decoded keeping a leading byte order mark, which
// the source row shows as the file holds it.
fn slice(source: LineIndex, start: Int, end: Int) -> String {
  line_index.source(source)
  |> bit_array.from_string
  |> bit_array.slice(start, end - start)
  |> result.try(line_index.decode)
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

// The summary
//
// Plain sentences, one per line, wrapped as message paragraphs are: the
// counts, then the coverage when it's incomplete.

fn summary(linted: Linted) -> String {
  let hidden = case linted.hidden {
    0 -> ""
    hidden ->
      ", " <> int.to_string(hidden) <> " hidden by ignores and suppressions"
  }
  let counts =
    counts(linted.diagnostics)
    <> " in "
    <> plural(linted.coverage.modules, "module", "modules")
    <> hidden
    <> "."
  [counts, ..coverage_sentence(linted.coverage.gaps)]
  |> list.map(fn(sentence) { wrap(sentence) <> "\n" })
  |> string.concat
}

// "1 error, 2 warnings and 1 note", leaving out the severities with none, or
// "No diagnostics".
fn counts(diagnostics: List(Diagnostic)) -> String {
  let count = fn(severity) {
    list.count(diagnostics, fn(found) { found.severity == severity })
  }
  result.values([
    clause(count(diagnostic.Error), "error", "errors"),
    clause(count(diagnostic.Warning), "warning", "warnings"),
    clause(count(diagnostic.Note), "note", "notes"),
  ])
  |> enumerate
  |> string.to_option
  |> option.unwrap("No diagnostics")
}

// One sentence naming each kind of gap present, in the order of `Gap`'s
// variants, or nothing when coverage is complete. A module that doesn't
// parse is one no rule saw; every other gap only limits typed rules.
fn coverage_sentence(gaps: List(Gap)) -> List(String) {
  let tally = list.fold(gaps, Tally(0, [], 0, [], 0), count_gap)
  let in_modules = fn(definitions) {
    definitions
    <> " in "
    <> plural(distinct(tally.untyped), "module", "modules")
    <> " couldn't be typed"
  }
  let clauses =
    result.values([
      clause(tally.unparsed, "module doesn't parse", "modules don't parse"),
      clause(list.length(tally.untyped), "definition", "definitions")
        |> result.map(in_modules),
      clause(tally.uninferred, "module got no types", "modules got no types"),
      clause(
        distinct(tally.unavailable),
        "module can't use the types of a module it imports",
        "modules can't use the types of modules they import",
      ),
      clause(
        tally.missing,
        "package is missing its sources",
        "packages are missing their sources",
      ),
    ])
  let reach = case tally.unparsed {
    0 -> "typed rules"
    _ -> "rules"
  }
  case clauses {
    [] -> []
    [_, ..] -> [
      "Coverage is incomplete: "
      <> enumerate(clauses)
      <> ", so "
      <> reach
      <> " didn't see all of the code.",
    ]
  }
}

// The gaps of a run by kind: how many of each, with the paths of the
// modules where a module can hold several.
type Tally {
  Tally(
    unparsed: Int,
    untyped: List(String),
    uninferred: Int,
    unavailable: List(String),
    missing: Int,
  )
}

fn count_gap(tally: Tally, gap: Gap) -> Tally {
  case gap {
    coverage.UnparsedModule(..) -> Tally(..tally, unparsed: tally.unparsed + 1)
    coverage.UntypedDefinition(path:, ..) ->
      Tally(..tally, untyped: [path, ..tally.untyped])
    coverage.UninferredModule(..) ->
      Tally(..tally, uninferred: tally.uninferred + 1)
    coverage.UnavailableImport(path:, ..) ->
      Tally(..tally, unavailable: [path, ..tally.unavailable])
    coverage.MissingPackage(..) -> Tally(..tally, missing: tally.missing + 1)
  }
}

fn distinct(paths: List(String)) -> Int {
  set.size(set.from_list(paths))
}

// `count` with the singular or plural form, or nothing when it's 0.
fn clause(count: Int, one: String, many: String) -> Result(String, Nil) {
  case count {
    0 -> Error(Nil)
    _ -> Ok(plural(count, one, many))
  }
}

// `count` followed by the singular or plural form: "1 module", "2 modules".
fn plural(count: Int, one: String, many: String) -> String {
  int.to_string(count)
  <> " "
  <> case count {
    1 -> one
    _ -> many
  }
}

// "a", "a and b", "a, b and c".
fn enumerate(items: List(String)) -> String {
  case list.reverse(items) {
    [] -> ""
    [only] -> only
    [last, ..rest] -> string.join(list.reverse(rest), ", ") <> " and " <> last
  }
}

// Stats
//
// The block `--stats` adds after the summary: one row per phase, then the
// counts.

/// The `--stats` block, for after the summary: what loading, linting and
/// the whole run cost, and how much there was to load and lint.
pub fn stats(stats: Stats) -> String {
  // `total` spans `load` and `lint`, on a monotonic clock and a growing
  // reduction count, so its numbers are the widest.
  let milliseconds = string.length(int.to_string(stats.total.milliseconds))
  let reductions = string.length(int.to_string(stats.total.reductions))
  let row = fn(name: String, phase: Phase) {
    "  "
    <> string.pad_end(name, to: 5, with: " ")
    <> "  "
    <> string.pad_start(int.to_string(phase.milliseconds), milliseconds, " ")
    <> " ms  "
    <> string.pad_start(int.to_string(phase.reductions), reductions, " ")
    <> " reductions\n"
  }
  let types = case stats.types {
    True -> "types inferred"
    False -> "types not inferred"
  }
  "\nStats:\n"
  <> row("load", stats.load)
  <> row("lint", stats.lint)
  <> row("total", stats.total)
  <> "  "
  <> plural(stats.loaded, "project module", "project modules")
  <> ", "
  <> plural(stats.dependencies, "dependency module", "dependency modules")
  <> ", "
  <> plural(stats.rules, "rule", "rules")
  <> ", "
  <> types
  <> ".\n"
}

// Wrapping
//
// Each line of a paragraph is filled greedily up to 75 columns, the width
// the compiler wraps its text to. Words are never cut, so one longer than
// that gets a line of its own.

/// Fill each line of `text` up to 75 columns, as message paragraphs are.
pub fn wrap(text: String) -> String {
  text
  |> string.split("\n")
  |> list.map(fn(line) {
    let #(lines, current) = list.fold(string.split(line, " "), #([], ""), fill)
    string.join(list.reverse([current, ..lines]), "\n")
  })
  |> string.join("\n")
}

const wrap_width = 75

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
