//// Tests for globs: a table of patterns against paths, then each malformed
//// form and the reason it's rejected for.

import gleam/list
import gleam/string
import grice/internal/glob.{
  Absolute, DotSegment, Empty, EmptySegment, MixedDoubleStar, Unsupported,
}

// Matching

pub fn matches_table_test() {
  let table = [
    // Literal paths, and the directories above them.
    #("src/app.gleam", "src/app.gleam", True),
    #("src/app.gleam", "src/app.gleamx", False),
    #("src", "src/app.gleam", True),
    #("src/gen", "src/gen/deep/schema.gleam", True),
    #("src/gen", "src/generated/schema.gleam", False),
    #("src/gen", "src", False),
    #("test", "src/test.gleam", False),
    // A trailing `/` changes nothing.
    #("src/", "src/app.gleam", True),
    // `*` stays within one segment.
    #("src/*.gleam", "src/app.gleam", True),
    #("src/*.gleam", "src/.gleam", True),
    #("src/*.gleam", "src/app/router.gleam", False),
    #("src/*", "src/app/router.gleam", True),
    #("src/app/*_test.gleam", "src/app/router.gleam", False),
    #("src/*/router.gleam", "src/app/router.gleam", True),
    #("src/*/router.gleam", "src/router.gleam", False),
    #("src/a*p*.gleam", "src/app.gleam", True),
    // `?` matches exactly one character.
    #("src/ap?.gleam", "src/app.gleam", True),
    #("src/ap?.gleam", "src/ap.gleam", False),
    #("src?app.gleam", "src/app.gleam", False),
    // `**` at the start, in the middle and at the end.
    #("**", "src/app.gleam", True),
    #("**/router.gleam", "src/app/router.gleam", True),
    #("**/router.gleam", "router.gleam", True),
    #("**/gen", "src/app/gen/schema.gleam", True),
    #("src/**/router.gleam", "src/router.gleam", True),
    #("src/**/router.gleam", "src/app/web/router.gleam", True),
    #("src/**/router.gleam", "test/app/router.gleam", False),
    #("src/gen/**", "src/gen/schema.gleam", True),
    #("src/gen/**", "src/generated/schema.gleam", False),
    #("src/**/**", "src/app.gleam", True),
    // Many wildcards that can't match: each must fail quickly, not try
    // every way to split the path between them.
    #(
      "src/" <> string.repeat("*a", 18) <> "b.gleam",
      "src/" <> string.repeat("a", 32) <> ".gleam",
      False,
    ),
    #(string.repeat("**/a/", 12) <> "b", string.repeat("a/", 30) <> "c", False),
  ]
  assert mismatches(table) == []
}

pub fn to_string_gives_the_pattern_as_written_test() {
  let assert Ok(pattern) = glob.parse("src/gen/")
  assert glob.to_string(pattern) == "src/gen/"
}

// The rows whose expected result the glob doesn't give.
fn mismatches(
  table: List(#(String, String, Bool)),
) -> List(#(String, String, Bool)) {
  list.filter(table, fn(row) {
    let #(pattern, path, expected) = row
    let assert Ok(parsed) = glob.parse(pattern)
    glob.matches(parsed, path) != expected
  })
}

// Malformed patterns

pub fn parse_rejects_malformed_patterns_test() {
  let table = [
    #("", Empty),
    #("/src", Absolute),
    #("/", Absolute),
    #("./src", DotSegment),
    #("src/.", DotSegment),
    #("src/../test", DotSegment),
    #("src//app", EmptySegment),
    #("src//", EmptySegment),
    #("src/a**", MixedDoubleStar),
    #("**.gleam", MixedDoubleStar),
    #("src/***", MixedDoubleStar),
    #("src/[ab].gleam", Unsupported("[")),
    #("src/a]", Unsupported("]")),
    #("src/{a,b}.gleam", Unsupported("{")),
    #("src/a}", Unsupported("}")),
    #("src\\app", Unsupported("\\")),
  ]
  assert list.map(table, fn(row) { glob.parse(row.0) })
    == list.map(table, fn(row) { Error(row.1) })
}
