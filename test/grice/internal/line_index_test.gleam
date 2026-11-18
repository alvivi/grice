//// Tests for the line index: line counts, positions, line ranges and span
//// checks, in that order, then turning glance's offsets into bytes, and
//// decoding. Sources with `\r` are written as string literals with
//// escapes, because the repository forces LF line endings on committed
//// files.

import glance
import gleam/list
import gleam/string
import grice/diagnostic.{Span}
import grice/internal/line_index.{
  OutOfBounds, Position, Reversed, SplitsCodepoint, SplitsLineEnding,
}

// Line counts
//
// A line starts at byte 0 and after every `\n`, so a trailing newline adds
// an empty last line, as the compiler's diagnostics count them.

pub fn line_count_empty_source_is_one_test() {
  assert line_index.line_count(line_index.new("")) == 1
}

pub fn line_count_without_trailing_newline_counts_lines_test() {
  assert line_index.line_count(line_index.new("a\nb")) == 2
}

pub fn line_count_trailing_newline_adds_empty_line_test() {
  assert line_index.line_count(line_index.new("a\nb\n")) == 3
}

pub fn line_count_crlf_counts_one_break_per_pair_test() {
  assert line_index.line_count(line_index.new("a\r\nb\r\n")) == 3
}

pub fn source_returns_the_indexed_source_test() {
  assert line_index.source(line_index.new("a\nb")) == "a\nb"
}

// Positions
//
// Lines and columns are 1-based, and columns count codepoints: not bytes,
// not graphemes and not display cells.

pub fn position_empty_source_is_first_column_test() {
  assert line_index.position(line_index.new(""), 0) == Position(1, 1)
}

pub fn position_start_of_file_is_first_column_test() {
  assert line_index.position(line_index.new("ab\ncd"), 0) == Position(1, 1)
}

pub fn position_end_of_file_without_newline_is_past_last_char_test() {
  assert line_index.position(line_index.new("ab\ncd"), 5) == Position(2, 3)
}

pub fn position_end_of_file_after_newline_is_on_empty_line_test() {
  assert line_index.position(line_index.new("ab\n"), 3) == Position(2, 1)
}

pub fn position_on_newline_is_end_of_its_line_test() {
  assert line_index.position(line_index.new("ab\ncd"), 2) == Position(1, 3)
}

pub fn position_after_lf_starts_next_line_test() {
  assert line_index.position(line_index.new("ab\ncd"), 3) == Position(2, 1)
}

pub fn position_after_crlf_starts_next_line_test() {
  assert line_index.position(line_index.new("ab\r\ncd"), 4) == Position(2, 1)
}

pub fn position_between_cr_and_lf_counts_the_cr_test() {
  let index = line_index.new("ab\r\ncd")
  assert line_index.position(index, 2) == Position(1, 3)
  assert line_index.position(index, 3) == Position(1, 4)
}

pub fn position_after_empty_lines_counts_lines_test() {
  assert line_index.position(line_index.new("\n\n\nx"), 3) == Position(4, 1)
}

pub fn position_after_two_byte_char_counts_one_column_test() {
  // `é` is two bytes.
  assert line_index.position(line_index.new("héllo"), 3) == Position(1, 3)
}

pub fn position_after_combining_mark_counts_two_columns_test() {
  // `e` followed by U+0301 is one grapheme but two codepoints.
  assert line_index.position(line_index.new("e\u{301}x"), 3) == Position(1, 3)
}

pub fn position_after_wide_chars_counts_codepoints_test() {
  // Each CJK character is three bytes and one column.
  assert line_index.position(line_index.new("日本x"), 6) == Position(1, 3)
}

pub fn position_after_emoji_counts_one_column_test() {
  // A four-byte emoji followed by a skin-tone modifier: two codepoints.
  assert line_index.position(line_index.new("👍🏽x"), 8) == Position(1, 3)
}

pub fn position_on_later_line_with_multibyte_text_test() {
  let index = line_index.new("日\n本語x")
  assert line_index.position(index, 4) == Position(2, 1)
  assert line_index.position(index, 10) == Position(2, 3)
}

pub fn position_out_of_range_is_clamped_test() {
  let index = line_index.new("ab\ncd")
  assert line_index.position(index, -4) == Position(1, 1)
  assert line_index.position(index, 99) == Position(2, 3)
}

pub fn line_number_matches_position_test() {
  let index = line_index.new("日\nab\r\n\nx")
  assert line_index.line_number(index, 0) == 1
  assert line_index.line_number(index, 3) == 1
  assert line_index.line_number(index, 4) == 2
  assert line_index.line_number(index, 7) == 2
  assert line_index.line_number(index, 8) == 3
  assert line_index.line_number(index, 9) == 4
  assert line_index.line_number(index, 99) == 4
}

// Line ranges
//
// The bytes of a line, without its `\n` or `\r\n` terminator.

pub fn line_bytes_excludes_lf_test() {
  let index = line_index.new("ab\ncd\n")
  assert line_index.line_bytes(index, 1) == #(0, 2)
  assert line_index.line_bytes(index, 2) == #(3, 5)
  assert line_index.line_bytes(index, 3) == #(6, 6)
}

pub fn line_bytes_excludes_crlf_test() {
  let index = line_index.new("ab\r\ncd")
  assert line_index.line_bytes(index, 1) == #(0, 2)
  assert line_index.line_bytes(index, 2) == #(4, 6)
}

pub fn line_bytes_keeps_a_lone_cr_test() {
  assert line_index.line_bytes(line_index.new("a\rb\nc"), 1) == #(0, 3)
}

pub fn line_bytes_empty_lines_are_empty_test() {
  let index = line_index.new("\n\r\n")
  assert line_index.line_bytes(index, 1) == #(0, 0)
  assert line_index.line_bytes(index, 2) == #(1, 1)
  assert line_index.line_bytes(index, 3) == #(3, 3)
}

pub fn line_bytes_empty_source_is_empty_test() {
  assert line_index.line_bytes(line_index.new(""), 1) == #(0, 0)
}

pub fn line_slice_is_the_bytes_of_line_bytes_test() {
  let index = line_index.new("ab\r\ncd\n")
  assert line_index.line_slice(index, 1) == <<"ab":utf8>>
  assert line_index.line_slice(index, 2) == <<"cd":utf8>>
  assert line_index.line_slice(index, 3) == <<>>
}

pub fn line_bytes_out_of_range_is_clamped_test() {
  let index = line_index.new("ab\ncd")
  assert line_index.line_bytes(index, 0) == #(0, 2)
  assert line_index.line_bytes(index, 9) == #(3, 5)
}

// Label spans
//
// `check_span` returns the first problem in a fixed order: out of bounds,
// then reversed, then splitting a codepoint.

pub fn check_span_valid_span_is_ok_test() {
  assert line_index.check_span(line_index.new("héllo"), Span(1, 3)) == Ok(Nil)
}

pub fn check_span_whole_source_is_ok_test() {
  assert line_index.check_span(line_index.new("héllo"), Span(0, 6)) == Ok(Nil)
}

pub fn check_span_empty_span_at_end_is_ok_test() {
  assert line_index.check_span(line_index.new("ab"), Span(2, 2)) == Ok(Nil)
}

pub fn check_span_empty_source_empty_span_is_ok_test() {
  assert line_index.check_span(line_index.new(""), Span(0, 0)) == Ok(Nil)
}

pub fn check_span_negative_start_is_out_of_bounds_test() {
  assert line_index.check_span(line_index.new("ab"), Span(-1, 1))
    == Error(OutOfBounds)
}

pub fn check_span_end_past_source_is_out_of_bounds_test() {
  assert line_index.check_span(line_index.new("ab"), Span(0, 3))
    == Error(OutOfBounds)
}

pub fn check_span_start_past_source_is_out_of_bounds_test() {
  assert line_index.check_span(line_index.new("ab"), Span(3, 3))
    == Error(OutOfBounds)
}

pub fn check_span_start_after_end_is_reversed_test() {
  assert line_index.check_span(line_index.new("abc"), Span(2, 1))
    == Error(Reversed)
}

pub fn check_span_start_inside_codepoint_splits_it_test() {
  // Byte 2 is the second byte of `é`.
  assert line_index.check_span(line_index.new("héllo"), Span(2, 4))
    == Error(SplitsCodepoint)
}

pub fn check_span_end_inside_codepoint_splits_it_test() {
  assert line_index.check_span(line_index.new("日本"), Span(0, 4))
    == Error(SplitsCodepoint)
}

pub fn check_span_out_of_bounds_comes_before_reversed_test() {
  assert line_index.check_span(line_index.new("ab"), Span(5, 1))
    == Error(OutOfBounds)
}

pub fn check_span_reversed_comes_before_splits_codepoint_test() {
  assert line_index.check_span(line_index.new("héllo"), Span(4, 2))
    == Error(Reversed)
}

pub fn check_span_end_between_cr_and_lf_is_ok_test() {
  // Labels may point at a `\r` on its own; only edits can't.
  assert line_index.check_span(line_index.new("ab\r\ncd"), Span(0, 3))
    == Ok(Nil)
}

// Edit spans
//
// Edits are held to one more rule than labels: no endpoint between a `\r`
// and its `\n`, which editor positions can't address.

pub fn check_edit_span_valid_span_is_ok_test() {
  assert line_index.check_edit_span(line_index.new("ab\r\ncd"), Span(0, 2))
    == Ok(Nil)
}

pub fn check_edit_span_around_crlf_is_ok_test() {
  assert line_index.check_edit_span(line_index.new("ab\r\ncd"), Span(2, 4))
    == Ok(Nil)
}

pub fn check_edit_span_insertion_between_cr_and_lf_splits_it_test() {
  assert line_index.check_edit_span(line_index.new("ab\r\ncd"), Span(3, 3))
    == Error(SplitsLineEnding)
}

pub fn check_edit_span_end_between_cr_and_lf_splits_it_test() {
  assert line_index.check_edit_span(line_index.new("ab\r\ncd"), Span(0, 3))
    == Error(SplitsLineEnding)
}

pub fn check_edit_span_start_between_cr_and_lf_splits_it_test() {
  assert line_index.check_edit_span(line_index.new("ab\r\ncd"), Span(3, 5))
    == Error(SplitsLineEnding)
}

pub fn check_edit_span_lone_cr_is_ok_test() {
  assert line_index.check_edit_span(line_index.new("a\rb"), Span(2, 2))
    == Ok(Nil)
}

pub fn check_edit_span_checks_label_rules_first_test() {
  assert line_index.check_edit_span(line_index.new("ab\r\n"), Span(3, 9))
    == Error(OutOfBounds)
  assert line_index.check_edit_span(line_index.new("ab\r\n"), Span(3, 2))
    == Error(Reversed)
}

// glance's offsets
//
// glance counts bytes on Erlang and UTF-16 code units on JavaScript. An
// index built for code units turns them into bytes on either target: `é`
// is one code unit and two bytes, `€` one and three, and `🙂` two and
// four.

const mixed = "a é b € c 🙂 d"

pub fn to_bytes_is_the_identity_for_bytes_test() {
  let index = line_index.new_for(mixed, line_index.Bytes)
  assert line_index.units(index) == line_index.Bytes
  assert line_index.to_bytes(index, 3) == Ok(3)
  // Unchecked: `check_span` checks bytes.
  assert line_index.to_bytes(index, 99) == Ok(99)
  assert line_index.tree_size(index) == 19
}

pub fn to_bytes_is_the_identity_for_code_units_in_ascii_test() {
  let index = line_index.new_for("ab\ncd", line_index.CodeUnits)
  assert line_index.units(index) == line_index.Bytes
  assert line_index.to_bytes(index, 4) == Ok(4)
}

pub fn to_bytes_counts_every_character_before_an_offset_test() {
  let index = line_index.new_for(mixed, line_index.CodeUnits)
  assert line_index.units(index) == line_index.CodeUnits
  assert line_index.tree_size(index) == 14
  // Each character as code units, then bytes: `a` 0, `é` 2, `b` 4, `€` 6,
  // `c` 8, `🙂` 10, `d` 13, and the end at 14.
  assert list.map([0, 2, 3, 4, 6, 7, 8, 10, 12, 13, 14], line_index.to_bytes(
      index,
      _,
    ))
    == [
      Ok(0),
      Ok(2),
      Ok(4),
      Ok(5),
      Ok(7),
      Ok(10),
      Ok(11),
      Ok(13),
      Ok(17),
      Ok(18),
      Ok(19),
    ]
}

// Offset 11 falls between the two code units of `🙂`.
pub fn to_bytes_rejects_offsets_inside_a_character_or_outside_the_source_test() {
  let index = line_index.new_for(mixed, line_index.CodeUnits)
  assert line_index.to_bytes(index, 11) == Error(SplitsCodepoint)
  assert line_index.to_bytes(index, -1) == Error(OutOfBounds)
  assert line_index.to_bytes(index, 15) == Error(OutOfBounds)
}

pub fn to_bytes_finds_offsets_among_many_characters_test() {
  let source = string.repeat("é🙂\n", 50)
  let index = line_index.new_for(source, line_index.CodeUnits)
  // Each line is four code units and seven bytes.
  assert line_index.to_bytes(index, 4 * 37) == Ok(7 * 37)
  assert line_index.to_bytes(index, 4 * 37 + 1) == Ok(7 * 37 + 2)
  assert line_index.to_bytes(index, 4 * 37 + 2) == Error(SplitsCodepoint)
  assert line_index.to_bytes(index, 4 * 37 + 3) == Ok(7 * 37 + 6)
  assert line_index.to_bytes(index, 200) == Ok(350)
}

pub fn span_to_bytes_converts_both_ends_test() {
  let index = line_index.new_for(mixed, line_index.CodeUnits)
  assert line_index.span_to_bytes(index, glance.Span(2, 14)) == Ok(Span(2, 19))
  assert line_index.span_to_bytes(index, glance.Span(2, 11))
    == Error(SplitsCodepoint)
}

pub fn utf16_length_counts_code_units_on_every_target_test() {
  assert line_index.utf16_length("") == 0
  assert line_index.utf16_length(mixed) == 14
  assert line_index.utf16_length("\u{FEFF}") == 1
}

pub fn length_counts_the_units_given_test() {
  assert line_index.length("é🙂", in: line_index.Bytes) == 6
  assert line_index.length("é🙂", in: line_index.CodeUnits) == 3
}

// Decoding
//
// The leading byte order marks are checked through the loader, on files
// written to disk, in `cli_test`.

pub fn decode_takes_empty_input_and_rejects_bytes_that_arent_utf8_test() {
  assert line_index.decode(<<>>) == Ok("")
  assert line_index.decode(<<0xFF, 0xFE>>) == Error(Nil)
}
