//// grice's configuration, read from a project's `gleam.toml`: the `target`
//// and the `[tools.grice]` table.
////
//// ```toml
//// target = "erlang"
////
//// [tools.grice]
//// include = ["src/"]
//// exclude = ["src/app/generated/"]
////
//// [[tools.grice.ignore]]
//// paths = ["test/**"]
//// rules = ["my_app/no-panic"]
//// reason = "Tests may panic."
//// ```
////
//// `include` and `exclude` choose the modules rules run on. Each
//// `[[tools.grice.ignore]]` entry hides the diagnostics of its `rules` in
//// the files its `paths` match, only inside the top-level definitions its
//// optional `definitions` name, and says why in `reason`.
//// `suppression_comments = false` turns off `grice-ignore` comments in the
//// source. Validation is strict, and every problem is a
//// `grice/invalid-config` diagnostic with no location: the TOML parser gives
//// no positions, so each message names `gleam.toml` and the key instead.
//// Rule codes under `rules` aren't checked here, because that needs the rule
//// set of a run.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import grice/diagnostic.{type Diagnostic, Diagnostic}
import grice/internal/glob.{type Glob, type GlobError, type Name}
import tom.{type Toml}

/// The target the project is linted for. It decides which `@target`
/// imports are followed.
pub type Target {
  Erlang
  JavaScript
}

/// A validated configuration.
pub type Config {
  Config(
    target: Target,
    /// The modules to lint, before `exclude`. Defaults to `src/`.
    include: List(Glob),
    /// The modules not to lint, even when an `include` selects them.
    exclude: List(Glob),
    /// The ignores, in the order `gleam.toml` lists them.
    ignore: List(Ignore),
    /// Whether `grice-ignore` comments in the source can hide diagnostics.
    suppression_comments: Bool,
  )
}

/// One `[[tools.grice.ignore]]` entry. It hides the diagnostics of `rules`
/// in the files `paths` matches. With `definitions`, it hides only those
/// whose primary span starts inside a top-level function, constant, custom
/// type or type alias whose name a pattern matches.
pub type Ignore {
  Ignore(
    paths: List(Glob),
    definitions: Option(List(Name)),
    rules: List(String),
    /// Why the rules don't apply there, trimmed.
    reason: String,
  )
}

/// Read the configuration from the text of a `gleam.toml`. Missing keys get
/// their defaults: the Erlang target, `include = ["src/"]`, no exclusions,
/// no ignores and suppression comments on.
///
/// Every problem is reported, in a fixed order: `target`, then `include`,
/// `exclude`, `ignore` (entry by entry: `paths`, `definitions`, `rules`,
/// `reason`, then its unknown keys in alphabetical order) and
/// `suppression_comments`, then unknown keys in alphabetical order. A file
/// that isn't valid TOML gives one diagnostic alone.
pub fn parse(gleam_toml: String) -> Result(Config, List(Diagnostic)) {
  use toml <- result.try(
    tom.parse(gleam_toml)
    |> result.map_error(fn(error) { [syntax_error(error)] }),
  )
  let target = parse_target(dict.get(toml, "target"))
  case grice_table(toml) {
    Ok(grice) -> parse_grice(target, grice)
    Error(found) -> Error(list.append(problems(target), found))
  }
}

/// A `grice/invalid-config` diagnostic: an error with no location.
pub fn diagnostic(
  title title: String,
  message message: String,
  hint hint: Option(String),
) -> Diagnostic {
  Diagnostic(
    code: "grice/invalid-config",
    severity: diagnostic.Error,
    title:,
    location: None,
    message: [message],
    hint:,
  )
}

/// How messages name the key `key` of the ignore entry at the 0-based
/// `index`, such as "`rules` in entry 2 of `tools.grice.ignore`".
pub fn ignore_key(index: Int, key: String) -> String {
  "`"
  <> key
  <> "` in entry "
  <> int.to_string(index + 1)
  <> " of `tools.grice.ignore`"
}

/// Why the TOML parser rejected a file, for a message that names the file.
pub fn describe_toml_error(error: tom.ParseError) -> String {
  case error {
    tom.Unexpected(got:, expected:) ->
      "expected `" <> expected <> "` but found " <> describe_token(got)
    tom.KeyAlreadyInUse(key:) ->
      "the key `" <> string.join(key, ".") <> "` is set more than once"
  }
}

// Keys and values
//
// Each key is checked on its own and gives either its value or its
// problems, so one bad key never hides another. Messages name a key with a
// subject: the dotted key in backticks, or a phrase that names an ignore
// entry's key.

const known_keys = ["include", "exclude", "ignore", "suppression_comments"]

const ignore_keys = ["paths", "definitions", "rules", "reason"]

// The `[tools.grice]` table, empty when there is none.
fn grice_table(
  toml: Dict(String, Toml),
) -> Result(Dict(String, Toml), List(Diagnostic)) {
  use tools <- result.try(table_at(toml, "tools", "tools"))
  table_at(tools, "grice", "tools.grice")
}

fn table_at(
  table: Dict(String, Toml),
  key: String,
  name: String,
) -> Result(Dict(String, Toml), List(Diagnostic)) {
  case dict.get(table, key) {
    Error(Nil) -> Ok(dict.new())
    Ok(tom.Table(found)) | Ok(tom.InlineTable(found)) -> Ok(found)
    Ok(other) -> Error([wrong_type(quoted(name), "a table", other)])
  }
}

fn parse_grice(
  target: Result(Target, List(Diagnostic)),
  grice: Dict(String, Toml),
) -> Result(Config, List(Diagnostic)) {
  let value = fn(key, default) {
    dict.get(grice, key) |> result.unwrap(default)
  }
  let include =
    value("include", tom.Array([tom.String("src/")]))
    |> parse_globs(quoted("tools.grice.include"))
  let exclude =
    value("exclude", tom.Array([]))
    |> parse_globs(quoted("tools.grice.exclude"))
  let ignore = value("ignore", tom.Array([])) |> parse_ignore
  let suppression_comments =
    value("suppression_comments", tom.Bool(True))
    |> parse_suppression_comments
  let unknown =
    dict.drop(grice, known_keys)
    |> dict.keys
    |> list.sort(string.compare)
    |> list.map(fn(key) {
      unknown_key(quoted("tools.grice." <> key), grice_keys)
    })
  case target, include, exclude, ignore, suppression_comments, unknown {
    Ok(target),
      Ok(include),
      Ok(exclude),
      Ok(ignore),
      Ok(suppression_comments),
      []
    -> Ok(Config(target:, include:, exclude:, ignore:, suppression_comments:))
    _, _, _, _, _, _ ->
      Error(
        list.flatten([
          problems(target),
          problems(include),
          problems(exclude),
          problems(ignore),
          problems(suppression_comments),
          unknown,
        ]),
      )
  }
}

fn parse_target(value: Result(Toml, Nil)) -> Result(Target, List(Diagnostic)) {
  case value {
    Error(Nil) -> Ok(Erlang)
    Ok(tom.String("erlang")) -> Ok(Erlang)
    Ok(tom.String("javascript")) -> Ok(JavaScript)
    Ok(tom.String(other)) -> Error([unknown_target(other)])
    Ok(other) -> Error([wrong_type(quoted("target"), "a string", other)])
  }
}

fn parse_globs(
  value: Toml,
  subject: String,
) -> Result(List(Glob), List(Diagnostic)) {
  parse_patterns(value, subject, "glob", glob.parse, glob_hint)
}

fn parse_suppression_comments(value: Toml) -> Result(Bool, List(Diagnostic)) {
  case value {
    tom.Bool(enabled) -> Ok(enabled)
    other ->
      Error([
        wrong_type(
          quoted("tools.grice.suppression_comments"),
          "a boolean",
          other,
        ),
      ])
  }
}

// Ignores
//
// `[[tools.grice.ignore]]` gives a list of tables, and
// `ignore = [{ .. }, ..]` a list of inline tables: both are read the same
// way. The table of globs grice used to read gets an error of its own,
// which shows the shape to write instead.

fn parse_ignore(value: Toml) -> Result(List(Ignore), List(Diagnostic)) {
  let subject = quoted("tools.grice.ignore")
  case value {
    tom.ArrayOfTables(entries) ->
      entries |> list.index_map(parse_ignore_entry) |> collect
    tom.Array(items) ->
      items
      |> list.index_map(fn(item, index) {
        case item {
          tom.Table(entry) | tom.InlineTable(entry) ->
            parse_ignore_entry(entry, index)
          other -> Error([wrong_item_type(subject, index, "a table", other)])
        }
      })
      |> collect
    tom.Table(_) | tom.InlineTable(_) -> Error([old_ignore_table()])
    other -> Error([wrong_type(subject, "a list of tables", other)])
  }
}

fn parse_ignore_entry(
  entry: Dict(String, Toml),
  index: Int,
) -> Result(Ignore, List(Diagnostic)) {
  let paths =
    entry_key(entry, index, "paths", None, fn(value, subject) {
      parse_globs(value, subject) |> non_empty(subject)
    })
  let definitions =
    entry_key(entry, index, "definitions", Some(None), fn(value, subject) {
      parse_patterns(value, subject, "name pattern", glob.parse_name, name_hint)
      |> non_empty(subject)
      |> result.map(Some)
    })
  let rules =
    entry_key(entry, index, "rules", None, fn(value, subject) {
      parse_strings(value, subject, "rule code", Ok) |> non_empty(subject)
    })
  let reason = entry_key(entry, index, "reason", None, parse_reason)
  let unknown =
    dict.drop(entry, ignore_keys)
    |> dict.keys
    |> list.sort(string.compare)
    |> list.map(fn(key) {
      unknown_key(ignore_key(index, key), ignore_keys_sentence)
    })
  case paths, definitions, rules, reason, unknown {
    Ok(paths), Ok(definitions), Ok(rules), Ok(reason), [] ->
      Ok(Ignore(paths:, definitions:, rules:, reason:))
    _, _, _, _, _ ->
      Error(
        list.flatten([
          problems(paths),
          problems(definitions),
          problems(rules),
          problems(reason),
          unknown,
        ]),
      )
  }
}

// The key `key` of the entry at `index`, read with `parse`, which gets its
// subject. A missing key is `default`, or a problem when it has none.
fn entry_key(
  entry: Dict(String, Toml),
  index: Int,
  key: String,
  default: Option(a),
  parse: fn(Toml, String) -> Result(a, List(Diagnostic)),
) -> Result(a, List(Diagnostic)) {
  let subject = ignore_key(index, key)
  case dict.get(entry, key), default {
    Ok(value), _ -> parse(value, subject)
    Error(Nil), Some(default) -> Ok(default)
    Error(Nil), None -> Error([incomplete_ignore(subject, "is missing")])
  }
}

fn parse_reason(
  value: Toml,
  subject: String,
) -> Result(String, List(Diagnostic)) {
  use reason <- result.try(
    tom.as_string(value)
    |> result.replace_error([wrong_type(subject, "a string", value)]),
  )
  case string.trim(reason) {
    "" -> Error([incomplete_ignore(subject, "is empty")])
    trimmed -> Ok(trimmed)
  }
}

// A list that must hold at least one item.
fn non_empty(
  parsed: Result(List(a), List(Diagnostic)),
  subject: String,
) -> Result(List(a), List(Diagnostic)) {
  case parsed {
    Ok([]) -> Error([incomplete_ignore(subject, "is empty")])
    Ok([_, ..]) | Error(_) -> parsed
  }
}

// Shared readers
//
// What every key is read with: lists of strings, patterns, and the
// collection of every value or every problem.

// A list of strings, each a `noun` that `parse_item` reads.
fn parse_strings(
  value: Toml,
  subject: String,
  noun: String,
  parse_item: fn(String) -> Result(a, List(Diagnostic)),
) -> Result(List(a), List(Diagnostic)) {
  case value {
    tom.Array(items) ->
      items
      |> list.index_map(fn(item, index) {
        tom.as_string(item)
        |> result.replace_error([
          wrong_item_type(subject, index, "a " <> noun <> " string", item),
        ])
        |> result.try(parse_item)
      })
      |> collect
    other ->
      Error([wrong_type(subject, "a list of " <> noun <> " strings", other)])
  }
}

// A list of patterns, each a `noun` that `parse` reads, with `hint` for a
// malformed one.
fn parse_patterns(
  value: Toml,
  subject: String,
  noun: String,
  parse: fn(String) -> Result(a, GlobError),
  hint: String,
) -> Result(List(a), List(Diagnostic)) {
  use pattern <- parse_strings(value, subject, noun)
  parse(pattern)
  |> result.map_error(fn(error) {
    [malformed(subject, noun, pattern, error, hint)]
  })
}

fn quoted(key: String) -> String {
  "`" <> key <> "`"
}

// Every value, in order, or every problem, in order.
fn collect(
  results: List(Result(a, List(Diagnostic))),
) -> Result(List(a), List(Diagnostic)) {
  case list.flat_map(results, problems) {
    [] -> Ok(result.values(results))
    found -> Error(found)
  }
}

fn problems(checked: Result(a, List(Diagnostic))) -> List(Diagnostic) {
  result.unwrap_error(checked, [])
}

// Diagnostics
//
// The wording of each problem. Messages name `gleam.toml` and the key,
// since there is no location to point at.

const glob_hint =
  "Patterns are relative to the project root, with `/` between segments. `*` matches within one segment, `?` matches one character, and `**` as a whole segment matches any number of segments."

const name_hint =
  "A name pattern matches the whole name of a top-level function, constant, custom type or type alias. It holds letters, digits and `_`, with `*` for any run of characters and `?` for one character."

const ignore_hint =
  "Write each ignore as a `[[tools.grice.ignore]]` entry with `paths`, `rules` and `reason`, such as `paths = [\"test/**\"]`, `rules = [\"my_app/no-panic\"]` and `reason = \"Tests may panic.\"`. Add `definitions = [\"render_*\"]` to cover only the top-level definitions with matching names."

const grice_keys =
  "The keys of `[tools.grice]` are `include`, `exclude`, `ignore` and `suppression_comments`."

const ignore_keys_sentence =
  "The keys of an ignore are `paths`, `definitions`, `rules` and `reason`."

fn syntax_error(error: tom.ParseError) -> Diagnostic {
  diagnostic(
    title: "Can't parse `gleam.toml`",
    message: "`gleam.toml` isn't valid TOML: "
      <> describe_toml_error(error)
      <> ".",
    hint: None,
  )
}

// `keys` is the sentence that lists the keys of the table.
fn unknown_key(subject: String, keys: String) -> Diagnostic {
  diagnostic(
    title: "Unknown key in `gleam.toml`",
    message: "`gleam.toml` sets "
      <> subject
      <> ", which grice doesn't read. "
      <> keys,
    hint: Some("Remove the key, or fix its spelling."),
  )
}

fn incomplete_ignore(subject: String, problem: String) -> Diagnostic {
  diagnostic(
    title: "Incomplete ignore in `gleam.toml`",
    message: subject
      <> " in `gleam.toml` "
      <> problem
      <> ". Every ignore says which paths it covers, which rules it hides and why.",
    hint: Some(ignore_hint),
  )
}

fn old_ignore_table() -> Diagnostic {
  diagnostic(
    title: "Outdated ignores in `gleam.toml`",
    message: "`tools.grice.ignore` in `gleam.toml` is a table from globs to rule codes, which grice no longer reads. Each ignore is now an entry of its own, which says why it's there and can cover only some definitions.",
    hint: Some(ignore_hint),
  )
}

fn unknown_target(target: String) -> Diagnostic {
  diagnostic(
    title: "Unknown target in `gleam.toml`",
    message: "`target` in `gleam.toml` is `"
      <> target
      <> "`, but the targets are `erlang` and `javascript`.",
    hint: None,
  )
}

fn wrong_type(subject: String, expected: String, value: Toml) -> Diagnostic {
  diagnostic(
    title: "Wrong type in `gleam.toml`",
    message: subject
      <> " in `gleam.toml` must be "
      <> expected
      <> ", but it's "
      <> describe_value(value)
      <> ".",
    hint: None,
  )
}

fn wrong_item_type(
  subject: String,
  index: Int,
  expected: String,
  value: Toml,
) -> Diagnostic {
  diagnostic(
    title: "Wrong type in `gleam.toml`",
    message: "Every item of "
      <> subject
      <> " in `gleam.toml` must be "
      <> expected
      <> ", but item "
      <> int.to_string(index + 1)
      <> " is "
      <> describe_value(value)
      <> ".",
    hint: None,
  )
}

fn malformed(
  subject: String,
  noun: String,
  pattern: String,
  error: GlobError,
  hint: String,
) -> Diagnostic {
  diagnostic(
    title: "Malformed " <> noun <> " in `gleam.toml`",
    message: subject
      <> " in `gleam.toml` holds `"
      <> pattern
      <> "`, which isn't a "
      <> noun
      <> " grice reads: "
      <> describe_glob_error(error, noun <> "s")
      <> ".",
    hint: Some(hint),
  )
}

// `patterns` names the kind of pattern, for an unsupported character.
fn describe_glob_error(error: GlobError, patterns: String) -> String {
  case error {
    glob.Empty -> "it's empty"
    glob.Absolute ->
      "it starts with `/`, but patterns are relative to the project root"
    glob.DotSegment -> "it has a `.` or `..` segment"
    glob.EmptySegment -> "it has an empty segment, `//`"
    glob.MixedDoubleStar -> "`**` must be a whole segment on its own"
    glob.Unsupported(character:) ->
      "grice's " <> patterns <> " don't support `" <> character <> "`"
  }
}

fn describe_token(token: String) -> String {
  case token {
    "EOF" -> "the end of the file"
    "\n" | "\r\n" -> "the end of a line"
    _ -> "`" <> token <> "`"
  }
}

fn describe_value(value: Toml) -> String {
  case value {
    tom.Int(_) -> "an integer"
    tom.Float(_) | tom.Infinity(_) | tom.Nan(_) -> "a float"
    tom.Bool(_) -> "a boolean"
    tom.String(_) -> "a string"
    tom.Date(_) -> "a date"
    tom.Time(_) -> "a time"
    tom.DateTime(..) -> "a date-time"
    tom.Array(_) -> "a list"
    tom.ArrayOfTables(_) -> "a list of tables"
    tom.Table(_) | tom.InlineTable(_) -> "a table"
  }
}
