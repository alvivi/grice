//// Renders a run as a JSON document, schema version 1, for tools.
////
//// ```json
//// {
////   "version": 1,
////   "root": "/home/me/app",
////   "summary": { "errors": 0, "warnings": 1, "notes": 0, "hidden": 2 },
////   "coverage": { "complete": true, "modules": 4, ... },
////   "diagnostics": [ ... ]
//// }
//// ```
////
//// The same run gives the same document: nothing in it depends on the time
//// or on the working directory, unless the stats are asked for. Paths are
//// relative to the absolute `root`, spans are byte offsets with their line
//// and column positions alongside, and keys come in a fixed order. A run
//// that couldn't complete gives the same document with `coverage: null`.
////
//// The document is pretty-printed with two-space indentation and ends with
//// a newline, so a person can read it and a snapshot shows its changes line
//// by line.

import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string_tree.{type StringTree}
import grice/coverage.{type Cause, type Coverage, type Gap}
import grice/diagnostic.{type Diagnostic, type Location, type Span}
import grice/internal/line_index.{type LineIndex}
import grice/internal/loader.{type Project}
import grice/internal/render/human.{
  type Checked, type RenderError, Located, Unlocated,
}
import grice/internal/runner.{type Linted}
import grice/internal/stats.{type Phase, type Stats}

// Documents
//
// The two documents grice writes: a completed run, and a run that stopped
// before it had a result.

/// The document for a completed run of `project`, with the stats when they
/// were asked for. Every diagnostic is checked against its source first, as
/// the human renderer checks it, and the first problem is returned.
pub fn run(
  project: Project,
  linted: Linted,
  stats: Option(Stats),
) -> Result(String, RenderError) {
  use checked <- result.map(human.check(
    linted.diagnostics,
    loader.sources(project),
  ))
  document(
    root: Text(project.root),
    checked:,
    hidden: linted.hidden,
    coverage: coverage_value(linted.coverage),
    stats: option.map(stats, stats_value),
  )
}

/// The document for a run that couldn't complete: `root` when a project was
/// found, and grice's own diagnostics saying why. Those have no location,
/// since they're about the run rather than the code, so one given a
/// location anyway is written with none.
pub fn failure(root: Option(String), diagnostics: List(Diagnostic)) -> String {
  document(
    root: nullable(root, Text),
    checked: list.map(diagnostics, Unlocated),
    hidden: 0,
    coverage: Null,
    stats: None,
  )
}

// `stats` is left out when it's `None`, while every other key is always
// there.
fn document(
  root root: Value,
  checked checked: List(Checked),
  hidden hidden: Int,
  coverage coverage: Value,
  stats stats: Option(Value),
) -> String {
  let count = fn(severity) {
    Number(
      list.count(checked, fn(found) { found.diagnostic.severity == severity }),
    )
  }
  let fields = [
    #("version", Number(1)),
    #("root", root),
    #(
      "summary",
      Object([
        #("errors", count(diagnostic.Error)),
        #("warnings", count(diagnostic.Warning)),
        #("notes", count(diagnostic.Note)),
        #("hidden", Number(hidden)),
      ]),
    ),
    #("coverage", coverage),
    #("diagnostics", Array(list.map(checked, diagnostic_value))),
  ]
  let fields = case stats {
    Some(stats) -> list.append(fields, [#("stats", stats)])
    None -> fields
  }
  Object(fields)
  |> write("")
  |> string_tree.append("\n")
  |> string_tree.to_string
}

// Coverage
//
// `complete`, the counts, the types, and each gap with its fields.

fn coverage_value(coverage: Coverage) -> Value {
  let types = case coverage.types {
    coverage.NotRequested -> Object([#("requested", Boolean(False))])
    coverage.Requested(full:, partial:, none:) ->
      Object([
        #("requested", Boolean(True)),
        #("full", Number(full)),
        #("partial", Number(partial)),
        #("none", Number(none)),
      ])
  }
  Object([
    #("complete", Boolean(coverage.gaps == [])),
    #("modules", Number(coverage.modules)),
    #("parsed", Number(coverage.parsed)),
    #("types", types),
    #("gaps", Array(list.map(coverage.gaps, gap_value))),
  ])
}

// A gap is its kind and its fields, which are all strings.
fn gap_value(gap: Gap) -> Value {
  let #(kind, fields) = case gap {
    coverage.UnparsedModule(path:) -> #("unparsed-module", [#("path", path)])
    coverage.UntypedDefinition(path:, definition:) -> #("untyped-definition", [
      #("path", path),
      #("definition", definition),
    ])
    coverage.UninferredModule(path:) -> #("uninferred-module", [
      #("path", path),
    ])
    coverage.UnavailableImport(path:, module:, cause:) -> #(
      "unavailable-import",
      [#("path", path), #("module", module), #("cause", cause_name(cause))],
    )
    coverage.MissingPackage(package:) -> #("missing-package", [
      #("package", package),
    ])
  }
  Object([
    #("kind", Text(kind)),
    ..list.map(fields, fn(field) { #(field.0, Text(field.1)) })
  ])
}

fn cause_name(cause: Cause) -> String {
  case cause {
    coverage.ProjectModuleUnparsable -> "project-module-unparsable"
    coverage.ProjectModuleUnusable -> "project-module-unusable"
    coverage.DependencyUnparsable -> "dependency-unparsable"
    coverage.NoSuchModule -> "no-such-module"
  }
}

// Diagnostics
//
// Each span is written twice: as bytes, which is what grice works in, and
// as 1-based lines and codepoint columns, which is what most editors show.

fn diagnostic_value(checked: Checked) -> Value {
  let location = case checked {
    Located(location:, source:, ..) -> location_value(location, source)
    Unlocated(..) -> Null
  }
  let diagnostic = checked.diagnostic
  Object([
    #("code", Text(diagnostic.code)),
    #("severity", Text(human.severity_name(diagnostic.severity))),
    #("title", Text(diagnostic.title)),
    #("location", location),
    #("message", Array(list.map(diagnostic.message, Text))),
    #("hint", nullable(diagnostic.hint, Text)),
  ])
}

fn location_value(location: Location, source: LineIndex) -> Value {
  let label = fn(label: diagnostic.Label) {
    spanned(label.span, source, "message", label.message)
  }
  let fix =
    nullable(location.fix, fn(fix) {
      Object([
        #("title", Text(fix.title)),
        #(
          "edits",
          Array(
            list.map(fix.edits, fn(edit) {
              spanned(edit.span, source, "replacement", edit.replacement)
            }),
          ),
        ),
      ])
    })
  Object([
    #("path", Text(location.path)),
    #("primary", label(location.primary)),
    #("secondary", Array(list.map(location.secondary, label))),
    #("fix", fix),
  ])
}

// A label or an edit: its span as bytes and as a range, then its text under
// `key`.
fn spanned(span: Span, source: LineIndex, key: String, text: String) -> Value {
  let position = fn(byte) {
    let line_index.Position(line:, column:) = line_index.position(source, byte)
    Object([#("line", Number(line)), #("column", Number(column))])
  }
  Object([
    #(
      "span",
      Object([#("start", Number(span.start)), #("end", Number(span.end))]),
    ),
    #(
      "range",
      Object([#("start", position(span.start)), #("end", position(span.end))]),
    ),
    #(key, Text(text)),
  ])
}

// Stats
//
// Only with `--stats`: the counts and each phase's cost.

fn stats_value(stats: Stats) -> Value {
  Object([
    #(
      "modules",
      Object([
        #("loaded", Number(stats.loaded)),
        #("dependencies", Number(stats.dependencies)),
      ]),
    ),
    #("rules", Number(stats.rules)),
    #("types", Boolean(stats.types)),
    #("load", phase_value(stats.load)),
    #("lint", phase_value(stats.lint)),
    #("total", phase_value(stats.total)),
  ])
}

fn phase_value(phase: Phase) -> Value {
  Object([
    #("milliseconds", Number(phase.milliseconds)),
    #("reductions", Number(phase.reductions)),
  ])
}

// Printing
//
// gleam_json writes a document on one line, so the layout is done here: a
// value type whose objects keep their keys in order, and a printer that
// indents each nested value two spaces deeper. Only strings go through
// gleam_json, for their escaping; keys are fixed names with nothing to
// escape.

type Value {
  Object(fields: List(#(String, Value)))
  Array(items: List(Value))
  Text(value: String)
  Number(value: Int)
  Boolean(value: Bool)
  Null
}

fn nullable(value: Option(a), to_value: fn(a) -> Value) -> Value {
  case value {
    Some(value) -> to_value(value)
    None -> Null
  }
}

// `indent` is the indentation of the line the value starts on.
fn write(value: Value, indent: String) -> StringTree {
  case value {
    Object([]) -> string_tree.from_string("{}")
    Array([]) -> string_tree.from_string("[]")
    Object(fields) -> {
      let inner = indent <> "  "
      fields
      |> list.map(fn(field) {
        string_tree.from_strings(["\"", field.0, "\": "])
        |> string_tree.append_tree(write(field.1, inner))
      })
      |> block("{", "}", indent)
    }
    Array(items) -> {
      let inner = indent <> "  "
      items
      |> list.map(write(_, inner))
      |> block("[", "]", indent)
    }
    Text(value) -> json.to_string_tree(json.string(value))
    Number(value) -> string_tree.from_string(int.to_string(value))
    Boolean(True) -> string_tree.from_string("true")
    Boolean(False) -> string_tree.from_string("false")
    Null -> string_tree.from_string("null")
  }
}

// Entries one per line between `open` and `close`, each two spaces deeper
// than `indent`.
fn block(
  entries: List(StringTree),
  open: String,
  close: String,
  indent: String,
) -> StringTree {
  let inner = "\n" <> indent <> "  "
  entries
  |> string_tree.join("," <> inner)
  |> string_tree.prepend(open <> inner)
  |> string_tree.append("\n" <> indent <> close)
}
