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
////
//// glance's spans aren't always bytes. glexer, the lexer glance uses,
//// counts bytes on Erlang and UTF-16 code units on JavaScript, so the
//// syntax tree, comments and girard's answers count those there. The index
//// also converts such an offset to bytes, where it leaves the syntax tree
//// to become part of a diagnostic.

import glance
import gleam/bit_array
import gleam/bool
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import grice/diagnostic.{type Span, Span}

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
    // How glance's offsets into the source map to its bytes.
    drift: Drift,
  )
}

// How glance's offsets into a source map to its bytes.
type Drift {
  // They are bytes: on Erlang, or in a source that is all ASCII, where
  // every character is one byte and one UTF-16 code unit.
  NoDrift
  // They count UTF-16 code units. `length` is the source's length in
  // them, and `wide` holds each character outside ASCII by its index in
  // source order, so a lookup is a binary search, as for lines.
  Drift(length: Int, wide: Dict(Int, Wide))
}

// A character outside ASCII: where it starts in code units and in bytes,
// and how many of each it takes.
type Wide {
  Wide(start: Int, units: Int, byte: Int, bytes: Int)
}

/// What glance's offsets count on a target.
pub type Units {
  /// UTF-8 bytes, as on Erlang.
  Bytes
  /// UTF-16 code units, as on JavaScript.
  CodeUnits
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

/// Index a source whose syntax tree glance built on this target. This
/// scans it once for line breaks, and on JavaScript once more for the
/// characters outside ASCII, where glance's offsets drift from bytes.
pub fn new(source: String) -> LineIndex {
  new_for(source, tree_units())
}

/// Index a source whose syntax tree counts `units`, whatever the target.
@internal
pub fn new_for(source: String, units: Units) -> LineIndex {
  let bytes = bit_array.from_string(source)
  let size = bit_array.byte_size(bytes)
  let starts = list.reverse(scan_lines(bytes, 0, [0]))
  // A source is all ASCII when its UTF-16 length is its byte size.
  let drift = case units == CodeUnits && utf16_length(source) != size {
    False -> NoDrift
    True -> {
      let #(length, wide) = scan_wide(bytes, 0, 0, [])
      let wide =
        list.index_map(list.reverse(wide), fn(wide, at) { #(at, wide) })
      Drift(length:, wide: dict.from_list(wide))
    }
  }
  LineIndex(
    source:,
    bytes:,
    size:,
    starts: dict.from_list(
      list.index_map(starts, fn(start, line) { #(line, start) }),
    ),
    line_count: list.length(starts),
    drift:,
  )
}

/// What glance's offsets count on the target grice runs on, as glexer 2.5
/// documents.
pub fn tree_units() -> Units {
  case counts_code_units() {
    True -> CodeUnits
    False -> Bytes
  }
}

@external(erlang, "grice_ffi", "counts_code_units")
fn counts_code_units() -> Bool {
  True
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

/// The text of the UTF-8 `bytes`, or `Error(Nil)` when they aren't UTF-8.
/// Every byte is kept, a leading byte order mark included, on every
/// target.
pub fn decode(bytes: BitArray) -> Result(String, Nil) {
  case bytes {
    // JavaScript's decoder drops a byte order mark at the very start of
    // its input, so the bytes are decoded behind a NUL, which is then
    // dropped, and every U+FEFF stays.
    <<0xEF, 0xBB, 0xBF, _:bytes>> -> {
      use text <- result.map(bit_array.to_string(<<0, bytes:bits>>))
      case text {
        "\u{0}" <> text -> text
        _ -> text
      }
    }
    _ -> bit_array.to_string(bytes)
  }
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

/// What glance's offsets into the source count: bytes always on Erlang,
/// and on JavaScript for a source that's all ASCII, where they're the
/// same; UTF-16 code units otherwise.
pub fn units(index: LineIndex) -> Units {
  case index.drift {
    NoDrift -> Bytes
    Drift(..) -> CodeUnits
  }
}

/// The byte offset at glance's offset `offset` into the source.
///
/// Where glance's offsets are bytes, this is `offset`, unchecked, as
/// `check_span` checks bytes. Otherwise it's `OutOfBounds` before the start
/// of the source or past its end, and `SplitsCodepoint` between the two
/// code units of a character outside the Basic Multilingual Plane, which
/// fall inside one character in bytes.
pub fn to_bytes(index: LineIndex, offset: Int) -> Result(Int, SpanProblem) {
  case index.drift {
    NoDrift -> Ok(offset)
    Drift(length:, ..) if offset < 0 || offset > length -> Error(OutOfBounds)
    Drift(wide:, ..) -> {
      let last =
        search(-1, dict.size(wide) - 1, fn(at) {
          case dict.get(wide, at) {
            Ok(Wide(start:, ..)) -> start <= offset
            Error(Nil) -> False
          }
        })
      case dict.get(wide, last) {
        // Only ASCII comes before it.
        Error(Nil) -> Ok(offset)
        Ok(Wide(start:, units:, byte:, bytes:)) ->
          case offset - start {
            0 -> Ok(byte)
            inside if inside < units -> Error(SplitsCodepoint)
            after -> Ok(byte + bytes + after - units)
          }
      }
    }
  }
}

/// Why a span of glance's offsets can't be a diagnostic's: the problem,
/// and the span's ends in the units they're best given in, bytes when the
/// span could be turned into bytes, and glance's units when it couldn't.
pub type InvalidSpan {
  InvalidSpan(problem: SpanProblem, start: Int, end: Int, units: Units)
}

/// A span of glance's offsets, such as a rule reports, as a valid span of
/// bytes. It's checked in `check_span`'s order on every target: both ends
/// inside the source, then in order, in glance's units, and then on
/// character boundaries.
pub fn check_tree_span(
  index: LineIndex,
  span: glance.Span,
) -> Result(Span, InvalidSpan) {
  case span_to_bytes(index, span) {
    Ok(bytes) ->
      check_span(index, bytes)
      |> result.replace(bytes)
      |> result.map_error(InvalidSpan(_, bytes.start, bytes.end, Bytes))
    // Only an offset outside the source or inside a surrogate pair fails
    // to convert, so bounds and order come first here too.
    Error(problem) -> {
      let size = tree_size(index)
      let problem = case
        span.start < 0 || span.end < 0 || span.start > size || span.end > size,
        span.start > span.end
      {
        True, _ -> OutOfBounds
        False, True -> Reversed
        False, False -> problem
      }
      Error(InvalidSpan(problem, span.start, span.end, units(index)))
    }
  }
}

/// A span of glance's offsets as a span of bytes, as `to_bytes` converts
/// each end.
pub fn span_to_bytes(
  index: LineIndex,
  span: glance.Span,
) -> Result(Span, SpanProblem) {
  use start <- result.try(to_bytes(index, span.start))
  use end <- result.map(to_bytes(index, span.end))
  Span(start:, end:)
}

/// The source's length in glance's offsets.
pub fn tree_size(index: LineIndex) -> Int {
  case index.drift {
    NoDrift -> index.size
    Drift(length:, ..) -> length
  }
}

/// The length of `text` in `units`.
pub fn length(text: String, in units: Units) -> Int {
  case units {
    Bytes -> string.byte_size(text)
    CodeUnits -> utf16_length(text)
  }
}

/// The number of UTF-16 code units of `text`, on every target.
@external(javascript, "../../grice_ffi.mjs", "utf16_length")
pub fn utf16_length(text: String) -> Int {
  let #(length, _wide) = scan_wide(bit_array.from_string(text), 0, 0, [])
  length
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

// The length of UTF-8 `bytes` in UTF-16 code units, and each character
// outside ASCII, newest first. `byte` and `unit` are where `bytes` starts
// in each. A lead byte gives a character's size, and its continuation
// bytes are then skipped one by one.
fn scan_wide(
  bytes: BitArray,
  byte: Int,
  unit: Int,
  wide: List(Wide),
) -> #(Int, List(Wide)) {
  case bytes {
    <<lead, rest:bytes>> if lead < 0x80 ->
      scan_wide(rest, byte + 1, unit + 1, wide)
    <<0b11110:size(5), _:size(3), rest:bytes>> ->
      scan_wide(rest, byte + 1, unit + 2, [Wide(unit, 2, byte, 4), ..wide])
    <<0b1110:size(4), _:size(4), rest:bytes>> ->
      scan_wide(rest, byte + 1, unit + 1, [Wide(unit, 1, byte, 3), ..wide])
    <<0b110:size(3), _:size(5), rest:bytes>> ->
      scan_wide(rest, byte + 1, unit + 1, [Wide(unit, 1, byte, 2), ..wide])
    <<_, rest:bytes>> -> scan_wide(rest, byte + 1, unit, wide)
    _ -> #(unit, wide)
  }
}

// The 0-based line holding a byte offset: the last line starting at or
// before it.
fn line_of(index: LineIndex, byte: Int) -> Int {
  search(0, index.line_count - 1, fn(line) { line_start(index, line) <= byte })
}

// The last of the indexes from `low` to `high` that `is_before` holds for,
// where it holds for every index up to some point and none after it, and
// is taken to hold for `low`. A binary search.
fn search(low: Int, high: Int, is_before: fn(Int) -> Bool) -> Int {
  case low >= high {
    True -> low
    False -> {
      let middle = { low + high + 1 } / 2
      case is_before(middle) {
        True -> search(middle, high, is_before)
        False -> search(low, middle - 1, is_before)
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
