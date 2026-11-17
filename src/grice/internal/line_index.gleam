//// A line index over one file's source, built once and shared.
////
//// Diagnostics carry byte offsets. This module turns them into line and
//// column positions, finds the bytes of each line, and checks that a span
//// is valid for the source before anything relies on it.
////
//// Lines are separated by `\n`, so a `\r\n` line ends with a `\r` byte
//// before its terminator. Columns count Unicode codepoints, not graphemes
//// or display cells: `e` followed by a combining accent is two columns, as
//// the Gleam compiler counts them. Everything works on the source's UTF-8
//// bytes; nothing goes through `string.length` or `string.slice`, which
//// count graphemes.

import gleam/bit_array
import gleam/bool
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/result
import grice/diagnostic.{type Span}

/// The source of one file, with the byte offset at which each of its lines
/// starts. Build it once per file with `new` and reuse it.
pub opaque type LineIndex {
  LineIndex(
    source: String,
    bytes: BitArray,
    size: Int,
    // Line `i` (0-based) starts at `starts[i]`. Line 0 starts at 0, and every
    // `\n` starts a new line after it, so a source ending in `\n` has a final
    // empty line.
    starts: Dict(Int, Int),
    line_count: Int,
  )
}

/// A position in a source: a 1-based line and a 1-based column, where
/// columns count codepoints from the start of the line.
pub type Position {
  Position(line: Int, column: Int)
}

/// Why a span isn't valid for a source.
pub type SpanProblem {
  /// One end is negative or past the end of the source.
  OutOfBounds
  /// The start comes after the end.
  Reversed
  /// One end falls inside a multi-byte UTF-8 codepoint.
  SplitsCodepoint
  /// One end falls between a `\r` and the `\n` after it. Only edits are
  /// held to this rule, because editor positions can't address that byte.
  SplitsLineEnding
}

/// What a span problem says about the span, for a sentence about it, such
/// as "starts after it ends".
pub fn describe_problem(problem: SpanProblem) -> String {
  case problem {
    OutOfBounds -> "isn't inside the source"
    Reversed -> "starts after it ends"
    SplitsCodepoint -> "has an end inside a multi-byte character"
    SplitsLineEnding ->
      "has an end between a carriage return and the line feed after it"
  }
}

/// Index a source. This scans it once for line breaks.
pub fn new(source: String) -> LineIndex {
  let bytes = bit_array.from_string(source)
  let starts = list.reverse(scan_lines(bytes, 0, [0]))
  LineIndex(
    source:,
    bytes:,
    size: bit_array.byte_size(bytes),
    starts: dict.from_list(
      list.index_map(starts, fn(start, line) { #(line, start) }),
    ),
    line_count: list.length(starts),
  )
}

/// The source the index was built from.
pub fn source(index: LineIndex) -> String {
  index.source
}

/// The number of lines. A source always has at least one line, and a
/// trailing `\n` adds a final empty line.
pub fn line_count(index: LineIndex) -> Int {
  index.line_count
}

/// Check that a label's span is valid for the source: both ends within it,
/// in order, and on codepoint boundaries. Problems are checked in that
/// order, and the first one found is returned.
pub fn check_span(index: LineIndex, span: Span) -> Result(Nil, SpanProblem) {
  use <- bool.guard(
    when: is_out_of_bounds(index, span.start)
      || is_out_of_bounds(index, span.end),
    return: Error(OutOfBounds),
  )
  use <- bool.guard(when: span.start > span.end, return: Error(Reversed))
  use <- bool.guard(
    when: splits_codepoint(index, span.start)
      || splits_codepoint(index, span.end),
    return: Error(SplitsCodepoint),
  )
  Ok(Nil)
}

/// Check that an edit's span is valid: everything `check_span` checks, and
/// then that neither end falls between a `\r` and the `\n` after it.
pub fn check_edit_span(
  index: LineIndex,
  span: Span,
) -> Result(Nil, SpanProblem) {
  use Nil <- result.try(check_span(index, span))
  use <- bool.guard(
    when: splits_line_ending(index, span.start)
      || splits_line_ending(index, span.end),
    return: Error(SplitsLineEnding),
  )
  Ok(Nil)
}

/// The line and column of a byte offset.
///
/// The offset should be valid (see `check_span`). Offsets outside the source
/// are clamped to it, and an offset inside a codepoint counts that codepoint
/// as already passed.
pub fn position(index: LineIndex, byte: Int) -> Position {
  let byte = int.clamp(byte, min: 0, max: index.size)
  let line = line_of(index, byte)
  let start = line_start(index, line)
  let column = case bit_array.slice(index.bytes, start, byte - start) {
    Ok(bytes) -> count_codepoints(bytes, 0) + 1
    Error(Nil) -> 1
  }
  Position(line: line + 1, column:)
}

/// The 1-based line holding a byte offset: `position(index, byte).line`,
/// without counting the column. Offsets outside the source are clamped to it.
pub fn line_number(index: LineIndex, byte: Int) -> Int {
  line_of(index, int.clamp(byte, min: 0, max: index.size)) + 1
}

/// The byte range `#(start, end)` of a 1-based line, its terminator (`\n` or
/// `\r\n`) excluded. Line numbers outside the source are clamped to it.
pub fn line_bytes(index: LineIndex, line: Int) -> #(Int, Int) {
  let line = int.clamp(line - 1, min: 0, max: index.line_count - 1)
  let start = line_start(index, line)
  case line + 1 < index.line_count {
    False -> #(start, index.size)
    True -> {
      // The next line starts right after this line's `\n`.
      let newline = line_start(index, line + 1) - 1
      case bit_array.slice(index.bytes, newline - 1, 1) {
        Ok(<<"\r":utf8>>) -> #(start, newline - 1)
        _ -> #(start, newline)
      }
    }
  }
}

/// The bytes of a 1-based line, as `line_bytes` delimits them.
pub fn line_slice(index: LineIndex, line: Int) -> BitArray {
  let #(start, end) = line_bytes(index, line)
  bit_array.slice(index.bytes, start, end - start) |> result.unwrap(<<>>)
}

// The start of every line, newest first: the byte after each `\n`.
fn scan_lines(bytes: BitArray, offset: Int, starts: List(Int)) -> List(Int) {
  case bytes {
    <<"\n":utf8, rest:bytes>> ->
      scan_lines(rest, offset + 1, [offset + 1, ..starts])
    <<_, rest:bytes>> -> scan_lines(rest, offset + 1, starts)
    _ -> starts
  }
}

// The 0-based line holding a byte offset: the last line starting at or
// before it. A binary search over the line starts.
fn line_of(index: LineIndex, byte: Int) -> Int {
  search_line(index, byte, 0, index.line_count - 1)
}

// Invariant: line `low` starts at or before `byte`, and the answer is at
// most `high`.
fn search_line(index: LineIndex, byte: Int, low: Int, high: Int) -> Int {
  case low >= high {
    True -> low
    False -> {
      let middle = { low + high + 1 } / 2
      case line_start(index, middle) <= byte {
        True -> search_line(index, byte, middle, high)
        False -> search_line(index, byte, low, middle - 1)
      }
    }
  }
}

fn line_start(index: LineIndex, line: Int) -> Int {
  case dict.get(index.starts, line) {
    Ok(start) -> start
    Error(Nil) -> index.size
  }
}

// Count the bytes that start a codepoint, that is, every byte except UTF-8
// continuation bytes (`0b10xxxxxx`).
fn count_codepoints(bytes: BitArray, count: Int) -> Int {
  case bytes {
    <<0b10:size(2), _:size(6), rest:bytes>> -> count_codepoints(rest, count)
    <<_, rest:bytes>> -> count_codepoints(rest, count + 1)
    _ -> count
  }
}

fn is_out_of_bounds(index: LineIndex, offset: Int) -> Bool {
  offset < 0 || offset > index.size
}

// An offset splits a codepoint when the byte at it is a continuation byte.
// The end of the source is always a boundary.
fn splits_codepoint(index: LineIndex, offset: Int) -> Bool {
  case bit_array.slice(index.bytes, offset, 1) {
    Ok(<<0b10:size(2), _:size(6)>>) -> True
    _ -> False
  }
}

fn splits_line_ending(index: LineIndex, offset: Int) -> Bool {
  offset > 0
  && case bit_array.slice(index.bytes, offset - 1, 2) {
    Ok(<<"\r\n":utf8>>) -> True
    _ -> False
  }
}
