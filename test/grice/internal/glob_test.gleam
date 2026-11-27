//// Tests for globs: a table of patterns against paths, then each malformed
//// form and the reason it's rejected for. Then the same for name patterns
//// and for module patterns.

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

// Name patterns

pub fn matches_name_table_test() {
  let table = [
    // A pattern matches the whole name.
    #("main", "main", True),
    #("main", "main_test", False),
    #("main", "domain", False),
    // `*` matches any run of characters, none included.
    #("render_*", "render_page", True),
    #("render_*", "render_", True),
    #("render_*", "page_render_x", False),
    #("*_test", "main_test", True),
    #("*", "Anything_1", True),
    // `**` means the same as `*`.
    #("**", "anything", True),
    #("a**b", "axyzb", True),
    #("a**b", "ab", True),
    // `?` matches exactly one character.
    #("?", "a", True),
    #("?", "ab", False),
    #("Wib?le", "Wibble", True),
    #("Wib?le", "Wible", False),
  ]
  let mismatches =
    list.filter(table, fn(row) {
      let #(pattern, name, expected) = row
      let assert Ok(parsed) = glob.parse_name(pattern)
      glob.matches_name(parsed, name) != expected
    })
  assert mismatches == []
}

pub fn parse_name_rejects_malformed_patterns_test() {
  let table = [
    #("", Empty),
    #("render_[ab]", Unsupported("[")),
    #("{a,b}", Unsupported("{")),
    #("app/render", Unsupported("/")),
    #("render-x", Unsupported("-")),
    #("render x", Unsupported(" ")),
    #("a.b", Unsupported(".")),
    #("café", Unsupported("é")),
  ]
  assert list.map(table, fn(row) { glob.parse_name(row.0) })
    == list.map(table, fn(row) { Error(row.1) })
}

// Module patterns

// The compiler's own cases for `internal_modules` (compiler-core's
// `config.rs` in Gleam 1.19.2), whose patterns all use `*` and literal
// names, then `*` and `?` across `/`.
pub fn matches_module_table_test() {
  let table = [
    // The compiler's default patterns for `my_package`.
    #("my_package/internal", "my_package/internal", True),
    #("my_package/internal/*", "my_package/internal", False),
    #("my_package/internal/*", "my_package/internal/wibble", True),
    #("my_package/internal/*", "my_package/internal/wibble/wobble", True),
    #("my_package/internal", "my_package/internallll", False),
    #("my_package/internal/*", "my_package/internallll", False),
    #("my_package/internal", "my_package/other", False),
    #("my_package/internal/*", "my_package/other/wibble", False),
    #("my_package/internal", "other/internal", False),
    // A directory, two directories, a directory and a file, and a file in
    // every directory.
    #("package/internal/*", "package/internal", False),
    #("package/internal/*", "package/internal/module", True),
    #("package/internal1/*", "package/internal1/module", True),
    #("package/internal2/*", "package/internal2/module", True),
    #("package/module", "package/module", True),
    #("package/module", "package/module/inner", False),
    #("package/*/module1", "package/internal1/module1", True),
    #("package/*/module1", "package/internal2/module1", True),
    #("package/*/module1", "package/internal2/module2", False),
    #("package/*/module1", "package/module", False),
    // `*` matches any run of characters, `/` and none included.
    #("*", "app/internal/deep", True),
    #("app/*/x", "app/a/b/x", True),
    #("app*", "app", True),
    #("*/internal", "app/internal", True),
    #("*/internal", "internal", False),
    // `?` matches exactly one character, `/` included.
    #("app?internal", "app/internal", True),
    #("app/?", "app/a", True),
    #("app/?", "app/ab", False),
    // A pattern matches the whole name.
    #("app/internal", "app/internal/x", False),
    #("internal", "app/internal", False),
  ]
  let mismatches =
    list.filter(table, fn(row) {
      let #(pattern, name, expected) = row
      let assert Ok(parsed) = glob.parse_module(pattern)
      glob.matches_module(parsed, name) != expected
    })
  assert mismatches == []
}

// A pattern that can match no module name is still a pattern, as it is
// for the compiler. Every other character matches itself.
pub fn parse_module_accepts_patterns_that_match_no_module_test() {
  let patterns = ["a,b", "a-b", "A", "A*", "", "app/", "caf\u{e9}", "a.b"]
  let parsed =
    list.map(patterns, fn(pattern) {
      let assert Ok(parsed) = glob.parse_module(pattern)
      parsed
    })
  assert list.map(parsed, glob.module_pattern_to_string) == patterns
  let assert [comma, hyphen, upper, upper_star, empty, slash, ..] = parsed
  assert glob.matches_module(comma, "a,b")
  assert !glob.matches_module(comma, "a")
  assert glob.matches_module(hyphen, "a-b")
  assert !glob.matches_module(upper, "a")
  assert !glob.matches_module(upper_star, "app")
  assert !glob.matches_module(empty, "app")
  assert !glob.matches_module(slash, "app")
}

pub fn parse_module_rejects_syntax_beyond_stars_and_question_marks_test() {
  let table = [
    #("app/[ab]", "["),
    #("app/a]", "]"),
    #("app/{x,y}", "{"),
    #("app/x}", "}"),
    #("app/x\\y", "\\"),
    #("app/**", "**"),
    #("**/x", "**"),
    #("a/**/b", "**"),
    #("app/***", "**"),
    // The first piece of syntax is the one reported.
    #("app/*{a,b}/**", "{"),
    // A mark that makes one grapheme with a brace doesn't hide it.
    #("app/{\u{301},internal,\u{600}}/*", "{"),
    #("app/x\u{600}}", "}"),
  ]
  assert list.map(table, fn(row) { glob.parse_module(row.0) })
    == list.map(table, fn(row) { Error(glob.UnreadSyntax(row.1)) })
}
