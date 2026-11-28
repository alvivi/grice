//// Tests for reading `[tools.grice]`, `target`, `name`,
//// `internal_modules` and `[erlang]`'s `application_start_module` from
//// `gleam.toml`: the defaults, each key, and then each invalid case, whose
//// diagnostics are compared as text.

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

pub fn parse_reads_the_package_name_test() {
  assert package("") == #(None, [])
  assert package("name = \"my_app_2\"\n").0 == Some("my_app_2")
  assert package("name = 'app'\n").0 == Some("app")
}

// With no `internal_modules`, the compiler's default patterns hold the
// package's name, so without a name there are none.
pub fn parse_gives_the_default_internal_modules_test() {
  assert package("name = \"app\"\n")
    == #(Some("app"), ["app/internal", "app/internal/*"])
  assert package("target = \"erlang\"\n") == #(None, [])
}

pub fn parse_reads_internal_modules_test() {
  assert package("name = \"app\"\ninternal_modules = []\n")
    == #(Some("app"), [])
  let toml =
    "name = \"lustre\"
internal_modules = [\"lustre/vdom/*\", \"lustre/runtime/*\", \"lustre/internals/*\"]
"
  assert package(toml)
    == #(Some("lustre"), [
      "lustre/vdom/*",
      "lustre/runtime/*",
      "lustre/internals/*",
    ])
}

// A pattern that can match no module name is still a pattern, as it is for
// the compiler, and patterns apply without a name too.
pub fn parse_reads_internal_modules_that_match_no_module_test() {
  let toml =
    "internal_modules = [\"a,b\", \"a-b\", \"A\", \"A*\", \"\", 'x?/*', \"caf\u{e9}\"]\n"
  assert package(toml) == #(None, ["a,b", "a-b", "A", "A*", "", "x?/*", "café"])
}

// The compiler reads the other keys of `[erlang]`; grice ignores them. It
// writes the value in the application file without checking it, so grice
// keeps any string as written: a Gleam module name, an Erlang name, or the
// name of a module of Erlang code.
pub fn parse_reads_the_application_start_module_test() {
  let start = fn(toml) {
    let assert Ok(parsed) = config.parse(toml)
    parsed.application_start_module
  }
  assert start("name = \"app\"\n") == None
  assert start("[erlang]\nextra_applications = [\"inets\"]\n") == None
  assert start(
      "[erlang]\napplication_start_module = \"my_app/application\"\nextra_applications = [\"ssl\"]\n",
    )
    == Some("my_app/application")
  assert start("erlang.application_start_module = \"app\"\n") == Some("app")
  assert start("[erlang]\napplication_start_module = \"mist@internal@clock\"\n")
    == Some("mist@internal@clock")
  assert start("[erlang]\napplication_start_module = \"My_app_sup\"\n")
    == Some("My_app_sup")
  assert start("[erlang]\napplication_start_module = \"\"\n") == Some("")
}

// The package's name and its internal module patterns, back as written.
fn package(toml: String) -> #(Option(String), List(String)) {
  let assert Ok(parsed) = config.parse(toml)
  #(
    parsed.name,
    list.map(parsed.internal_modules, glob.module_pattern_to_string),
  )
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

// Invalid package keys

pub fn parse_rejects_a_name_that_isnt_a_string_test() {
  assert problems("name = 1\n")
    == [
      "Wrong type in `gleam.toml`: `name` in `gleam.toml` must be a string, but it's an integer.",
    ]
}

// grice's TOML reader keeps a `\u` escape as it's written, so an escaped
// name, which the compiler reads as `app`, reaches grice as other text.
pub fn parse_rejects_a_name_that_isnt_a_package_name_test() {
  let invalid = fn(name) {
    "Invalid package name in `gleam.toml`: `name` in `gleam.toml` is `"
    <> name
    <> "`, which isn't a package name: a lowercase letter followed by lowercase letters, digits and `_`, all ASCII."
  }
  assert problems("name = \"A\"\n") == [invalid("A")]
  assert problems("name = \"a-b\"\n") == [invalid("a-b")]
  assert problems("name = \"caf\u{e9}\"\n") == [invalid("café")]
  assert problems("name = \"1app\"\n") == [invalid("1app")]
  assert problems("name = \"\"\n") == [invalid("")]
  assert problems("name = \"\\u0061pp\"\n")
    == [
      invalid("\\u0061pp")
      <> " Hint: grice doesn't decode a `\\u` or `\\U` escape in a TOML string, so write the name as plain text.",
    ]
}

pub fn parse_rejects_internal_modules_of_the_wrong_type_test() {
  assert problems("internal_modules = \"app/internal\"\n")
    == [
      "Wrong type in `gleam.toml`: `internal_modules` in `gleam.toml` must be a list of module pattern strings, but it's a string.",
    ]
  assert problems("internal_modules = [\"app/internal\", 1, []]\n")
    == [
      "Wrong type in `gleam.toml`: Every item of `internal_modules` in `gleam.toml` must be a module pattern string, but item 2 is an integer.",
      "Wrong type in `gleam.toml`: Every item of `internal_modules` in `gleam.toml` must be a module pattern string, but item 3 is a list.",
    ]
}

// Each piece of glob syntax beyond `*` and `?`. grice's TOML reader keeps
// a `\u` escape in a basic string as it's written, and a literal string
// never decodes one, so both hold a `\`.
pub fn parse_rejects_module_patterns_beyond_stars_and_question_marks_test() {
  let toml =
    "name = \"app\"
internal_modules = [
  \"app/[ab]\", \"app/a]\", \"app/{x,y}\", \"app/x}\", \"app/**\", \"**/x\",
  \"app/x\\\\y\", \"\\u0061pp/*\", '\\u0061pp/*', \"app/*\",
]
"
  let unsupported = fn(pattern, syntax) {
    "Unsupported module pattern in `gleam.toml`: `internal_modules` in `gleam.toml` holds `"
    <> pattern
    <> "`, which grice can't read: of the glob syntax the compiler reads there, grice reads only `*` and `?`, and this pattern holds `"
    <> syntax
    <> "`. Hint: "
    <> module_pattern_hint
  }
  assert problems(toml)
    == [
      unsupported("app/[ab]", "["),
      unsupported("app/a]", "]"),
      unsupported("app/{x,y}", "{"),
      unsupported("app/x}", "}"),
      unsupported("app/**", "**"),
      unsupported("**/x", "**"),
      unsupported("app/x\\y", "\\"),
      unsupported("\\u0061pp/*", "\\"),
      unsupported("\\u0061pp/*", "\\"),
    ]
}

// The compiler reads a pattern by code point, so a combining mark after
// `{`, or a prepended mark before `}`, doesn't hide the brace, though each
// makes one grapheme with it: the compiler reads an alternation here, with
// the arm `internal`.
pub fn parse_rejects_syntax_that_shares_a_grapheme_test() {
  let pattern = "app/{\u{301},internal,\u{600}}/*"
  assert problems("internal_modules = [\"" <> pattern <> "\"]\n")
    == [
      "Unsupported module pattern in `gleam.toml`: `internal_modules` in `gleam.toml` holds `"
      <> pattern
      <> "`, which grice can't read: of the glob syntax the compiler reads there, grice reads only `*` and `?`, and this pattern holds `{`. Hint: "
      <> module_pattern_hint,
    ]
}

// As the compiler's own reading of `gleam.toml` does, grice refuses a
// value that isn't a string, and an `erlang` that isn't a table.
pub fn parse_rejects_an_application_start_module_of_the_wrong_type_test() {
  assert problems("[erlang]\napplication_start_module = 1\n")
    == [
      "Wrong type in `gleam.toml`: `erlang.application_start_module` in `gleam.toml` must be a string, but it's an integer.",
    ]
  assert problems("erlang = 1\n")
    == [
      "Wrong type in `gleam.toml`: `erlang` in `gleam.toml` must be a table, but it's an integer.",
    ]
}

// grice's TOML reader keeps the escapes of a quoted key as they're
// written, so these keys, which the compiler reads as `internal_modules`
// and `name`, would go unread.
pub fn parse_rejects_an_escaped_top_level_key_test() {
  assert problems("\"\\u0069nternal_modules\" = []\n")
    == [escaped("\\u0069nternal_modules")]
  assert problems("'\\u006eame' = \"app\"\n") == [escaped("\\u006eame")]
  assert problems("[erlang]\n\"application_start\\u005fmodule\" = \"app\"\n")
    == [escaped("erlang.application_start\\u005fmodule")]
}

// The package keys come first, in a fixed order, then `[tools.grice]`'s.
pub fn parse_reports_package_problems_in_order_test() {
  let toml =
    "\"\\u006eame\" = \"app\"
target = \"wasm\"
internal_modules = [\"app/**\"]
name = \"App\"
\"\\u0069nternal_modules\" = []

[erlang]
\"\\u0061pplication_start_module\" = \"app\"
application_start_module = 1

[tools.grice]
wibble = 1
"
  assert list.map(problems(toml), fn(problem) {
      let assert [title, ..] = string.split(problem, ":")
      title
    })
    == [
      "Unknown target in `gleam.toml`",
      "Invalid package name in `gleam.toml`",
      "Unsupported module pattern in `gleam.toml`",
      "Wrong type in `gleam.toml`",
      "Escaped key in `gleam.toml`",
      "Escaped key in `gleam.toml`",
      "Escaped key in `gleam.toml`",
      "Unknown key in `gleam.toml`",
    ]
  let assert [_, _, _, _, start, internal, name, _] = problems(toml)
  assert start == escaped("erlang.\\u0061pplication_start_module")
  assert internal == escaped("\\u0069nternal_modules")
  assert name == escaped("\\u006eame")
}

// A bad `tools.grice` comes after the package keys too.
pub fn parse_reports_package_problems_before_a_bad_tools_grice_test() {
  assert problems("name = 1\n[tools]\ngrice = true\n")
    == [
      "Wrong type in `gleam.toml`: `name` in `gleam.toml` must be a string, but it's an integer.",
      "Wrong type in `gleam.toml`: `tools.grice` in `gleam.toml` must be a table, but it's a boolean.",
    ]
}

fn escaped(key: String) -> String {
  "Escaped key in `gleam.toml`: `gleam.toml` sets the key `"
  <> key
  <> "`, written with a `\\`. grice doesn't decode the escapes of a quoted key, so it can't tell which key this is, and it may be one grice reads. Hint: Write the key as plain text, without escapes."
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

const module_pattern_hint =
  "`*` matches any run of characters and `?` any one character, `/` included in both. A pattern the compiler rejects, such as `app/[`, needs fixing first. Of those it accepts, the compiler reads these the same way on the module names each can match: `x/*` for `x/**`, `x` and `*/x` for `**/x`, `a/b` and `a/*/b` for `a/**/b`, and `a/x` and `a/y` for `a/{x,y}` or `a/[xy]`. For any other pattern it accepts, list by name the modules it treats as internal today: under `src/`, the ones missing from the Modules list of the pages a successful `gleam docs build` writes, and under `test/` and `dev/`, which the documentation never shows, the ones the pattern matches. That keeps today's set, but not the modules added later. If there are none, write `internal_modules = []`, since removing the key brings back the default."

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
