//// Tests for reading `[tools.grice]` and `target` from `gleam.toml`: the
//// defaults, each key, and then each invalid case, whose diagnostics are
//// compared as text.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import grice/diagnostic.{Diagnostic}
import grice/internal/config.{Erlang, Ignore, JavaScript}
import grice/internal/glob

// Defaults and keys

pub fn parse_gives_the_defaults_test() {
  let defaults = #(Erlang, ["src/"], [], [], True)
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
  assert summary(toml) == #(Erlang, ["src/", "test/"], ["src/gen/**"], [], True)
}

pub fn parse_reads_an_empty_include_test() {
  // An empty lint set is an error, but discovery reports it: the key itself
  // is well formed.
  assert summary("[tools.grice]\ninclude = []\n").1 == []
}

pub fn parse_reads_ignores_as_an_array_of_tables_in_order_test() {
  let toml =
    "[[tools.grice.ignore]]
paths = [\"test/**\", \"dev/\"]
rules = [\"a/b\", \"c/d\"]
reason = \"  Tests may panic.\\n\"

[[tools.grice.ignore]]
paths = [\"src/view.gleam\"]
definitions = [\"render_*\", \"?\"]
rules = [\"a/b\"]
reason = \"Views are generated.\"
"
  assert summary(toml).3
    == [
      #(["test/**", "dev/"], None, ["a/b", "c/d"], "Tests may panic."),
      #(
        ["src/view.gleam"],
        Some(["render_*", "?"]),
        ["a/b"],
        "Views are generated.",
      ),
    ]
}

pub fn parse_reads_ignores_as_an_inline_array_of_inline_tables_test() {
  let toml =
    "[tools.grice]
ignore = [
  { paths = [\"**\"], rules = [\"a/b\"], reason = \"one\" },
  { paths = [\"src\"], definitions = [\"main\"], rules = [\"c/d\"], reason = \"two\" },
]
"
  assert summary(toml).3
    == [
      #(["**"], None, ["a/b"], "one"),
      #(["src"], Some(["main"]), ["c/d"], "two"),
    ]
}

pub fn parse_reads_suppression_comments_test() {
  assert summary("[tools.grice]\nsuppression_comments = false\n").4 == False
  assert summary("[tools.grice]\nsuppression_comments = true\n").4 == True
}

// The configuration with each glob and name pattern back as written.
fn summary(
  toml: String,
) -> #(
  config.Target,
  List(String),
  List(String),
  List(#(List(String), Option(List(String)), List(String), String)),
  Bool,
) {
  let assert Ok(parsed) = config.parse(toml)
  #(
    parsed.target,
    list.map(parsed.include, glob.to_string),
    list.map(parsed.exclude, glob.to_string),
    list.map(parsed.ignore, fn(entry) {
      let Ignore(paths:, definitions:, rules:, reason:) = entry
      #(
        list.map(paths, glob.to_string),
        option.map(definitions, list.map(_, glob.name_to_string)),
        rules,
        reason,
      )
    }),
    parsed.suppression_comments,
  )
}

// Invalid configurations

pub fn parse_rejects_an_unknown_key_test() {
  assert problems("[tools.grice]\nincludes = [\"src/\"]\n")
    == [
      "Unknown key in `gleam.toml`: `gleam.toml` sets `tools.grice.includes`, which grice doesn't read. The keys of `[tools.grice]` are `include`, `exclude`, `ignore` and `suppression_comments`. Hint: Remove the key, or fix its spelling.",
    ]
}

pub fn parse_rejects_a_wrong_top_level_type_test() {
  assert problems(
      "target = 1\n[tools.grice]\ninclude = \"src/\"\nexclude = {}\nignore = \"src/\"\nsuppression_comments = \"no\"\n",
    )
    == [
      "Wrong type in `gleam.toml`: `target` in `gleam.toml` must be a string, but it's an integer.",
      "Wrong type in `gleam.toml`: `tools.grice.include` in `gleam.toml` must be a list of glob strings, but it's a string.",
      "Wrong type in `gleam.toml`: `tools.grice.exclude` in `gleam.toml` must be a list of glob strings, but it's a table.",
      "Wrong type in `gleam.toml`: `tools.grice.ignore` in `gleam.toml` must be a list of tables, but it's a string.",
      "Wrong type in `gleam.toml`: `tools.grice.suppression_comments` in `gleam.toml` must be a boolean, but it's a string.",
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
      "Unknown key in `gleam.toml`: `gleam.toml` sets `tools.grice.wibble`, which grice doesn't read. The keys of `[tools.grice]` are `include`, `exclude`, `ignore` and `suppression_comments`. Hint: Remove the key, or fix its spelling.",
    ]
}

// Invalid ignores

pub fn parse_rejects_the_old_table_of_globs_test() {
  let expected = [
    "Outdated ignores in `gleam.toml`: `tools.grice.ignore` in `gleam.toml` is a table from globs to rule codes, which grice no longer reads. Each ignore is now an entry of its own, which says why it's there and can cover only some definitions. Hint: "
    <> ignore_hint,
  ]
  assert problems("[tools.grice.ignore]\n\"test/**\" = [\"a/b\"]\n") == expected
  assert problems("[tools.grice]\nignore = {}\n") == expected
}

pub fn parse_rejects_an_ignore_entry_that_isnt_a_table_test() {
  let toml =
    "[tools.grice]\nignore = [{ paths = [\"src\"], rules = [\"a/b\"], reason = \"r\" }, \"src/\"]\n"
  assert problems(toml)
    == [
      "Wrong type in `gleam.toml`: Every item of `tools.grice.ignore` in `gleam.toml` must be a table, but item 2 is a string.",
    ]
}

// Every entry is checked, with every other key, and each problem names its
// entry by position.
pub fn parse_rejects_missing_and_empty_ignore_keys_test() {
  let toml =
    "[tools.grice]
exclude = [\"\"]

[[tools.grice.ignore]]
definitions = [\"main\"]

[[tools.grice.ignore]]
paths = []
definitions = []
rules = []
reason = \" \\t\\n\"
"
  let incomplete = fn(key, entry, problem) {
    "Incomplete ignore in `gleam.toml`: `"
    <> key
    <> "` in entry "
    <> entry
    <> " of `tools.grice.ignore` in `gleam.toml` "
    <> problem
    <> ". Every ignore says which paths it covers, which rules it hides and why. Hint: "
    <> ignore_hint
  }
  assert problems(toml)
    == [
      "Malformed glob in `gleam.toml`: `tools.grice.exclude` in `gleam.toml` holds ``, which isn't a glob grice reads: it's empty. Hint: "
        <> glob_hint,
      incomplete("paths", "1", "is missing"),
      incomplete("rules", "1", "is missing"),
      incomplete("reason", "1", "is missing"),
      incomplete("paths", "2", "is empty"),
      incomplete("definitions", "2", "is empty"),
      incomplete("rules", "2", "is empty"),
      incomplete("reason", "2", "is empty"),
    ]
}

pub fn parse_rejects_wrong_types_in_an_ignore_entry_test() {
  let toml =
    "[[tools.grice.ignore]]\npaths = \"src/\"\ndefinitions = [1]\nrules = [\"a/b\", 1.5]\nreason = false\n"
  assert problems(toml)
    == [
      "Wrong type in `gleam.toml`: `paths` in entry 1 of `tools.grice.ignore` in `gleam.toml` must be a list of glob strings, but it's a string.",
      "Wrong type in `gleam.toml`: Every item of `definitions` in entry 1 of `tools.grice.ignore` in `gleam.toml` must be a name pattern string, but item 1 is an integer.",
      "Wrong type in `gleam.toml`: Every item of `rules` in entry 1 of `tools.grice.ignore` in `gleam.toml` must be a rule code string, but item 2 is a float.",
      "Wrong type in `gleam.toml`: `reason` in entry 1 of `tools.grice.ignore` in `gleam.toml` must be a string, but it's a boolean.",
    ]
}

// Unknown keys come last, in alphabetical order.
pub fn parse_rejects_malformed_patterns_and_unknown_keys_in_an_entry_test() {
  let toml =
    "[[tools.grice.ignore]]
paths = [\"src//gen\"]
definitions = [\"\", \"render_[ab]\", \"{a,b}\", \"app/render\", \"render-x\", \"ok_*\"]
rules = [\"a/b\"]
reason = \"r\"
rule = \"a/b\"
path = \"src\"
"
  let malformed_name = fn(pattern, why) {
    "Malformed name pattern in `gleam.toml`: `definitions` in entry 1 of `tools.grice.ignore` in `gleam.toml` holds `"
    <> pattern
    <> "`, which isn't a name pattern grice reads: "
    <> why
    <> ". Hint: "
    <> name_hint
  }
  let unknown = fn(key) {
    "Unknown key in `gleam.toml`: `gleam.toml` sets `"
    <> key
    <> "` in entry 1 of `tools.grice.ignore`, which grice doesn't read. The keys of an ignore are `paths`, `definitions`, `rules` and `reason`. Hint: Remove the key, or fix its spelling."
  }
  assert problems(toml)
    == [
      "Malformed glob in `gleam.toml`: `paths` in entry 1 of `tools.grice.ignore` in `gleam.toml` holds `src//gen`, which isn't a glob grice reads: it has an empty segment, `//`. Hint: "
        <> glob_hint,
      malformed_name("", "it's empty"),
      malformed_name("render_[ab]", "grice's name patterns don't support `[`"),
      malformed_name("{a,b}", "grice's name patterns don't support `{`"),
      malformed_name("app/render", "grice's name patterns don't support `/`"),
      malformed_name("render-x", "grice's name patterns don't support `-`"),
      unknown("path"),
      unknown("rule"),
    ]
}

const glob_hint =
  "Patterns are relative to the project root, with `/` between segments. `*` matches within one segment, `?` matches one character, and `**` as a whole segment matches any number of segments."

const name_hint =
  "A name pattern matches the whole name of a top-level function, constant, custom type or type alias. It holds letters, digits and `_`, with `*` for any run of characters and `?` for one character."

const ignore_hint =
  "Write each ignore as a `[[tools.grice.ignore]]` entry with `paths`, `rules` and `reason`, such as `paths = [\"test/**\"]`, `rules = [\"my_app/no-panic\"]` and `reason = \"Tests may panic.\"`. Add `definitions = [\"render_*\"]` to cover only the top-level definitions with matching names."

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
