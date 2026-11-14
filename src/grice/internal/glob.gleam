//// Globs over project paths, for the `include`, `exclude` and `ignore` keys
//// of `[tools.grice]`.
////
//// A pattern is relative to the project root and uses `/` separators. `*`
//// matches any run of characters within one path segment, `?` matches one
//// character within a segment, and `**` as a whole segment matches zero or
//// more segments. Every other character matches itself.
////
//// A pattern matches a path or any of the directories above it, so
//// `src/gen`, `src/gen/` and `src/gen/**` all select everything under
//// `src/gen`.
////
//// Syntax from richer glob dialects is rejected, not read literally, so a
//// pattern copied from elsewhere fails loudly instead of quietly matching
//// nothing.

import gleam/bool
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// A parsed pattern. Build one with `parse`.
pub opaque type Glob {
  // `segments` are the pattern's `/`-separated segments, as `parse` checked
  // them, followed by a `**`: matching a path or any directory above it is
  // the same as matching the whole path with that segment appended.
  Glob(pattern: String, segments: List(String))
}

/// Why a pattern isn't a valid glob.
pub type GlobError {
  /// The pattern is empty.
  Empty
  /// The pattern starts with `/`. Patterns are relative to the project root.
  Absolute
  /// A segment is `.` or `..`.
  DotSegment
  /// Two `/` are next to each other, as in `a//b`.
  EmptySegment
  /// `**` shares a segment with other characters, as in `a**` or `**.gleam`.
  MixedDoubleStar
  /// The pattern holds a character from a richer glob syntax: `[`, `]`, `{`,
  /// `}` or `\`.
  Unsupported(character: String)
}

/// Parse a pattern. Problems are checked in order: an empty pattern, a
/// leading `/`, an unsupported character, and then each segment in turn. A
/// single trailing `/` is allowed and changes nothing.
pub fn parse(pattern: String) -> Result(Glob, GlobError) {
  use <- bool.guard(when: pattern == "", return: Error(Empty))
  use <- bool.guard(
    when: string.starts_with(pattern, "/"),
    return: Error(Absolute),
  )
  use Nil <- result.try(check_characters(pattern))
  let body = case string.ends_with(pattern, "/") {
    True -> string.drop_end(pattern, 1)
    False -> pattern
  }
  let segments = string.split(body, "/")
  use Nil <- result.map(list.try_each(segments, check_segment))
  Glob(pattern:, segments: list.append(segments, ["**"]))
}

/// Whether the glob matches a root-relative path or any of the directories
/// above it.
pub fn matches(glob: Glob, path: String) -> Bool {
  wildcard(glob.segments, string.split(path, "/"), "**", segment_matches, None)
}

/// The pattern as it was written.
pub fn to_string(glob: Glob) -> String {
  glob.pattern
}

fn check_characters(pattern: String) -> Result(Nil, GlobError) {
  let unsupported = ["[", "]", "{", "}", "\\"]
  case list.find(string.to_graphemes(pattern), list.contains(unsupported, _)) {
    Ok(character) -> Error(Unsupported(character:))
    Error(Nil) -> Ok(Nil)
  }
}

fn check_segment(segment: String) -> Result(Nil, GlobError) {
  use <- bool.guard(
    when: segment != "**" && string.contains(segment, "**"),
    return: Error(MixedDoubleStar),
  )
  case segment {
    "" -> Error(EmptySegment)
    "." | ".." -> Error(DotSegment)
    _ -> Ok(Nil)
  }
}

// The classic wildcard match: `pattern` matches `items` one for one through
// `matches`, except that `star` matches any run of items. Only the most
// recent star is kept to backtrack to, as `#(pattern after it, items it
// hasn't taken yet)`, so a match takes at most about
// `length(pattern) * length(items)` steps. That's enough because every item
// of the pattern other than `star` matches exactly one item.
fn wildcard(
  pattern: List(String),
  items: List(String),
  star: String,
  matches: fn(String, String) -> Bool,
  backtrack: Option(#(List(String), List(String))),
) -> Bool {
  case pattern, items {
    [first, ..rest], _ if first == star ->
      wildcard(rest, items, star, matches, Some(#(rest, items)))
    [], [] -> True
    [first, ..rest], [item, ..items_rest] -> {
      use <- bool.lazy_guard(when: !matches(first, item), return: fn() {
        retry(star, matches, backtrack)
      })
      wildcard(rest, items_rest, star, matches, backtrack)
    }
    [], [_, ..] | [_, ..], [] -> retry(star, matches, backtrack)
  }
}

// Go back to the most recent star and let it take one more item.
fn retry(
  star: String,
  matches: fn(String, String) -> Bool,
  backtrack: Option(#(List(String), List(String))),
) -> Bool {
  case backtrack {
    Some(#(after_star, [_, ..items])) ->
      wildcard(after_star, items, star, matches, Some(#(after_star, items)))
    Some(#(_, [])) | None -> False
  }
}

// One segment of a pattern against one segment of a path: `*` matches any
// run of characters and `?` any one character.
fn segment_matches(segment: String, name: String) -> Bool {
  let character_matches = fn(expected, found) {
    expected == "?" || expected == found
  }
  wildcard(
    string.to_graphemes(segment),
    string.to_graphemes(name),
    "*",
    character_matches,
    None,
  )
}
