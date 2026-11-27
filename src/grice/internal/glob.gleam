//// Globs over project paths, for the `include` and `exclude` keys of
//// `[tools.grice]` and the `paths` of its ignores, name patterns over
//// definition names, for the `definitions` of its ignores, and module
//// patterns over module names, for the compiler's `internal_modules`.
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
//// A name pattern matches a whole name. It holds letters, digits and `_`,
//// with `*` for any run of characters (`**` means the same) and `?` for one
//// character.
////
//// A module pattern matches a whole module name, as the compiler matches
//// the patterns of `internal_modules`: `*` matches any run of characters
//// and `?` any one character, `/` included in both, and every other
//// character matches itself.
////
//// Syntax from richer glob dialects is rejected, not read literally, so a
//// pattern copied from elsewhere fails loudly instead of quietly matching
//// nothing.

import gleam/bool
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

// Paths
//
// Globs over root-relative paths, matched segment by segment.

/// A parsed pattern. Build one with `parse`.
pub opaque type Glob {
  // `segments` are the pattern's `/`-separated segments, as `parse` checked
  // them, followed by a `**`: matching a path or any directory above it is
  // the same as matching the whole path with that segment appended.
  Glob(pattern: String, segments: List(String))
}

/// Why a pattern isn't a valid glob or name pattern.
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
  /// `}` or `\`. In a name pattern, any character other than a letter, a
  /// digit, `_`, `*` or `?`.
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

// The characters of richer glob syntax, which neither a glob nor a module
// pattern reads.
const richer_syntax = ["[", "]", "{", "}", "\\"]

fn check_characters(pattern: String) -> Result(Nil, GlobError) {
  case
    list.find(string.to_graphemes(pattern), list.contains(richer_syntax, _))
  {
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

// Names
//
// Name patterns over the names of top-level definitions. A name has no
// segments, so a pattern is matched as one segment of a path is.

/// A parsed name pattern. Build one with `parse_name`.
pub opaque type Name {
  Name(pattern: String)
}

/// Parse a name pattern: an empty pattern is `Empty`, and the first
/// character that isn't a letter, a digit, `_`, `*` or `?` is
/// `Unsupported`.
pub fn parse_name(pattern: String) -> Result(Name, GlobError) {
  use <- bool.guard(when: pattern == "", return: Error(Empty))
  let unsupported =
    list.find(string.to_graphemes(pattern), fn(character) {
      !string.contains(name_characters, character)
    })
  case unsupported {
    Ok(character) -> Error(Unsupported(character:))
    Error(Nil) -> Ok(Name(pattern:))
  }
}

/// Whether the name pattern matches the whole of `name`.
pub fn matches_name(pattern: Name, name: String) -> Bool {
  segment_matches(pattern.pattern, name)
}

/// The name pattern as it was written.
pub fn name_to_string(pattern: Name) -> String {
  pattern.pattern
}

const name_characters =
  "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_*?"

// Module names
//
// Patterns over whole module names, for `internal_modules`. The compiler
// matches them with the globset crate's default options, where `*` and `?`
// cross `/`. Only `*`, `?` and literal characters are read: the rest of
// globset's syntax is read by context, so it's rejected rather than read
// approximately. A pattern that can match no module name, such as `a,b`,
// `A` or the empty one, is still a pattern, as it is for the compiler, and
// matches nothing.

/// A parsed module pattern. Build one with `parse_module`.
pub opaque type ModulePattern {
  ModulePattern(pattern: String, form: ModuleForm)
}

/// Why a module pattern isn't one grice reads: it holds `syntax`, the first
/// `[`, `]`, `{`, `}`, `\` or `**` in it.
pub type UnreadSyntax {
  UnreadSyntax(syntax: String)
}

/// Parse a module pattern: any text of literal characters, `*` and `?`, the
/// empty one included.
pub fn parse_module(pattern: String) -> Result(ModulePattern, UnreadSyntax) {
  let code_points =
    string.to_utf_codepoints(pattern)
    |> list.map(fn(code_point) { string.from_utf_codepoints([code_point]) })
  case first_unread(code_points) {
    Ok(syntax) -> Error(UnreadSyntax(syntax:))
    Error(Nil) ->
      Ok(ModulePattern(
        pattern:,
        form: module_form(pattern, string.to_graphemes(pattern)),
      ))
  }
}

/// Whether the module pattern matches the whole of the module name `name`.
pub fn matches_module(pattern: ModulePattern, name: String) -> Bool {
  case pattern.form {
    Literal -> name == pattern.pattern
    Prefix(prefix:) -> string.starts_with(name, prefix)
    Wildcard(characters:) ->
      wildcard(
        characters,
        string.to_graphemes(name),
        "*",
        character_matches,
        None,
      )
  }
}

/// The module pattern as it was written.
pub fn module_pattern_to_string(pattern: ModulePattern) -> String {
  pattern.pattern
}

// How a module pattern is matched, worked out once when it's parsed: one
// with no wildcard by comparing it with the name, one whose only wildcard
// is a final `*` by its prefix, such as the compiler's default
// `<name>/internal/*`, and any other character by character.
type ModuleForm {
  Literal
  Prefix(prefix: String)
  Wildcard(characters: List(String))
}

fn module_form(pattern: String, characters: List(String)) -> ModuleForm {
  let wildcards =
    list.count(characters, fn(character) {
      character == "*" || character == "?"
    })
  case wildcards, string.ends_with(pattern, "*") {
    0, _ -> Literal
    1, True -> Prefix(string.drop_end(pattern, 1))
    _, _ -> Wildcard(characters)
  }
}

// The first syntax a module pattern doesn't read, in the pattern's code
// points, each as a string. The compiler reads code points, so a combining
// mark after a `{` doesn't hide it, as it would inside one grapheme. Module
// names are ASCII, so matching graphemes gives the compiler's answers.
fn first_unread(code_points: List(String)) -> Result(String, Nil) {
  case code_points {
    [] -> Error(Nil)
    ["*", "*", ..] -> Ok("**")
    [code_point, ..rest] -> {
      use <- bool.guard(
        when: list.contains(richer_syntax, code_point),
        return: Ok(code_point),
      )
      first_unread(rest)
    }
  }
}

// Matching
//
// The wildcard match that paths, their segments, names and module names
// share.

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
  wildcard(
    string.to_graphemes(segment),
    string.to_graphemes(name),
    "*",
    character_matches,
    None,
  )
}

// One character of a pattern against one of a name: `?` matches any.
fn character_matches(expected: String, found: String) -> Bool {
  expected == "?" || expected == found
}
