//// Tests for reading `[tools.grice]` and `target` from `gleam.toml`: the
//// defaults, each key, and then each invalid case, whose diagnostics are
//// compared as text.

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import grice/diagnostic.{Diagnostic}
import grice/internal/config.{Erlang, JavaScript}
import grice/internal/glob

// Defaults and keys

pub fn parse_gives_the_defaults_test() {
  let defaults = #(Erlang, ["src/"], [], [])
  assert summary("name = \"app\"\n") == defaults
  assert summary("[tools.grice]\n") == defaults
  assert summary("[tools.other]\nanything = 1\n") == defaults
}

pub fn parse_reads_the_target_test() {
  assert summary("target = \"javascript\"\n").0 == JavaScript
  assert summary("target = \"erlang\"\n").0 == Erlang
}

pub fn parse_reads_include_and_exclude_test() {
  let toml =
    "[tools.grice]\ninclude = [\"src/\", \"test/\"]\nexclude = [\"src/gen/**\"]\n"
  assert summary(toml) == #(Erlang, ["src/", "test/"], ["src/gen/**"], [])
}

pub fn parse_reads_an_empty_include_test() {
  // An empty lint set is an error, but discovery reports it: the key itself
  // is well formed.
  assert summary("[tools.grice]\ninclude = []\n").1 == []
}

pub fn parse_reads_the_ignore_table_sorted_by_pattern_test() {
  let toml =
    "[tools.grice.ignore]\n\"test/**\" = [\"a/b\", \"c/d\"]\n\"src/gen\" = []\n"
  assert summary(toml).3 == [#("src/gen", []), #("test/**", ["a/b", "c/d"])]
}

pub fn parse_reads_an_inline_ignore_table_test() {
  let toml = "[tools.grice]\nignore = { \"**\" = [\"a/b\"] }\n"
  assert summary(toml).3 == [#("**", ["a/b"])]
}

// The configuration with each glob back as its pattern.
fn summary(
  toml: String,
) -> #(config.Target, List(String), List(String), List(#(String, List(String)))) {
  let assert Ok(parsed) = config.parse(toml)
  #(
    parsed.target,
    list.map(parsed.include, glob.to_string),
    list.map(parsed.exclude, glob.to_string),
    list.map(parsed.ignore, fn(entry) { #(glob.to_string(entry.0), entry.1) }),
  )
}

// Invalid configurations

pub fn parse_rejects_an_unknown_key_test() {
  assert problems("[tools.grice]\nincludes = [\"src/\"]\n")
    == [
      "Unknown key in `gleam.toml`: `gleam.toml` sets `tools.grice.includes`, which grice doesn't read. The keys of `[tools.grice]` are `include`, `exclude` and `ignore`. Hint: Remove the key, or fix its spelling.",
    ]
}

pub fn parse_rejects_a_wrong_top_level_type_test() {
  assert problems(
      "target = 1\n[tools.grice]\ninclude = \"src/\"\nexclude = {}\nignore = [\"src/\"]\n",
    )
    == [
      "Wrong type in `gleam.toml`: `target` in `gleam.toml` must be a string, but it's an integer.",
      "Wrong type in `gleam.toml`: `tools.grice.include` in `gleam.toml` must be a list of glob strings, but it's a string.",
      "Wrong type in `gleam.toml`: `tools.grice.exclude` in `gleam.toml` must be a list of glob strings, but it's a table.",
      "Wrong type in `gleam.toml`: `tools.grice.ignore` in `gleam.toml` must be a table from globs to lists of rule codes, but it's a list.",
    ]
}

pub fn parse_rejects_a_tools_grice_that_isnt_a_table_test() {
  assert problems("[tools]\ngrice = true\n")
    == [
      "Wrong type in `gleam.toml`: `tools.grice` in `gleam.toml` must be a table, but it's a boolean.",
    ]
}

pub fn parse_rejects_a_wrong_type_inside_a_list_test() {
  assert problems("[tools.grice]\ninclude = [\"src/\", 1]\nexclude = [[]]\n")
    == [
      "Wrong type in `gleam.toml`: Every item of `tools.grice.include` in `gleam.toml` must be a glob string, but item 2 is an integer.",
      "Wrong type in `gleam.toml`: Every item of `tools.grice.exclude` in `gleam.toml` must be a glob string, but item 1 is a list.",
    ]
}

pub fn parse_rejects_a_wrong_type_inside_the_ignore_table_test() {
  assert problems(
      "[tools.grice.ignore]\n\"src/a\" = \"a/b\"\n\"src/b\" = [\"a/b\", 1.5]\n",
    )
    == [
      "Wrong type in `gleam.toml`: `tools.grice.ignore.\"src/a\"` in `gleam.toml` must be a list of rule code strings, but it's a string.",
      "Wrong type in `gleam.toml`: Every item of `tools.grice.ignore.\"src/b\"` in `gleam.toml` must be a rule code string, but item 2 is a float.",
    ]
}

pub fn parse_rejects_a_malformed_glob_in_include_test() {
  assert problems("[tools.grice]\ninclude = [\"/src\"]\n")
    == [
      "Malformed glob in `gleam.toml`: `tools.grice.include` in `gleam.toml` holds `/src`, which isn't a glob grice reads: it starts with `/`, but patterns are relative to the project root. Hint: "
      <> glob_hint,
    ]
}

pub fn parse_rejects_a_malformed_glob_in_exclude_test() {
  assert problems("[tools.grice]\nexclude = [\"src/{a,b}\"]\n")
    == [
      "Malformed glob in `gleam.toml`: `tools.grice.exclude` in `gleam.toml` holds `src/{a,b}`, which isn't a glob grice reads: grice's globs don't support `{`. Hint: "
      <> glob_hint,
    ]
}

pub fn parse_rejects_a_malformed_glob_in_an_ignore_key_test() {
  assert problems("[tools.grice.ignore]\n\"src//gen\" = [\"a/b\"]\n")
    == [
      "Malformed glob in `gleam.toml`: `tools.grice.ignore` in `gleam.toml` has the key `src//gen`, which isn't a glob grice reads: it has an empty segment, `//`. Hint: "
      <> glob_hint,
    ]
}

pub fn parse_describes_every_malformed_glob_test() {
  let toml = "[tools.grice]\nexclude = [\"\", \"src/..\", \"src/a**\"]\n"
  assert problems(toml)
    == [
      "Malformed glob in `gleam.toml`: `tools.grice.exclude` in `gleam.toml` holds ``, which isn't a glob grice reads: it's empty. Hint: "
        <> glob_hint,
      "Malformed glob in `gleam.toml`: `tools.grice.exclude` in `gleam.toml` holds `src/..`, which isn't a glob grice reads: it has a `.` or `..` segment. Hint: "
        <> glob_hint,
      "Malformed glob in `gleam.toml`: `tools.grice.exclude` in `gleam.toml` holds `src/a**`, which isn't a glob grice reads: `**` must be a whole segment on its own. Hint: "
        <> glob_hint,
    ]
}

pub fn parse_rejects_an_unknown_target_test() {
  assert problems("target = \"wasm\"\n")
    == [
      "Unknown target in `gleam.toml`: `target` in `gleam.toml` is `wasm`, but the targets are `erlang` and `javascript`.",
    ]
}

// tom names a key set twice as its parser saw it, here `include` alone
// rather than its full path.
pub fn parse_rejects_a_toml_syntax_error_test() {
  assert problems("name = \"app\"\n[tools.grice]\ninclude = [\"src/\"\n")
    == [
      "Can't parse `gleam.toml`: `gleam.toml` isn't valid TOML: expected `]` but found the end of the file.",
    ]
  assert problems("[tools.grice]\ninclude = []\ninclude = []\n")
    == [
      "Can't parse `gleam.toml`: `gleam.toml` isn't valid TOML: the key `include` is set more than once.",
    ]
}

pub fn parse_reports_two_problems_as_two_diagnostics_test() {
  assert problems("target = \"wasm\"\n[tools.grice]\nwibble = 1\n")
    == [
      "Unknown target in `gleam.toml`: `target` in `gleam.toml` is `wasm`, but the targets are `erlang` and `javascript`.",
      "Unknown key in `gleam.toml`: `gleam.toml` sets `tools.grice.wibble`, which grice doesn't read. The keys of `[tools.grice]` are `include`, `exclude` and `ignore`. Hint: Remove the key, or fix its spelling.",
    ]
}

const glob_hint =
  "Patterns are relative to the project root, with `/` between segments. `*` matches within one segment, `?` matches one character, and `**` as a whole segment matches any number of segments."

// Each diagnostic as one line of text, after checking that it's a
// location-less `grice/invalid-config` error.
fn problems(toml: String) -> List(String) {
  let assert Error(diagnostics) = config.parse(toml)
  list.map(diagnostics, fn(found) {
    let assert Diagnostic(
      code: "grice/invalid-config",
      severity: diagnostic.Error,
      location: None,
      title:,
      message:,
      hint:,
    ) = found
    let hint = case hint {
      Some(hint) -> [" Hint: " <> hint]
      None -> []
    }
    string.concat([title, ": ", string.join(message, " "), ..hint])
  })
}
