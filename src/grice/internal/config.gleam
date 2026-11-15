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
//// [tools.grice.ignore]
//// "test/**" = ["my_app/no-panic"]
//// ```
////
//// `include` and `exclude` choose the modules rules run on, and `ignore` maps
//// a glob to the rule codes silenced under it. Validation is strict, and
//// every problem is a `grice/invalid-config` diagnostic with no location:
//// the TOML parser gives no positions, so each message names `gleam.toml` and
//// the key instead. Rule codes under `ignore` aren't checked here, because
//// that needs the rule set of a run.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import grice/diagnostic.{type Diagnostic, Diagnostic}
import grice/internal/glob.{type Glob, type GlobError}
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
    /// Each glob with the rule codes silenced under it, sorted by pattern.
    ignore: List(#(Glob, List(String))),
  )
}

/// Read the configuration from the text of a `gleam.toml`. Missing keys get
/// their defaults: the Erlang target, `include = ["src/"]`, no exclusions
/// and no ignores.
///
/// Every problem is reported, in a fixed order: `target`, then `include`,
/// `exclude` and `ignore` (its entries sorted by pattern), then unknown keys
/// in alphabetical order. A file that isn't valid TOML gives one diagnostic
/// alone.
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

/// The dotted key of the rule codes ignored under `pattern`, as messages
/// name it, such as `tools.grice.ignore."test/**"`.
pub fn ignore_key(pattern: String) -> String {
  "tools.grice.ignore." <> string.inspect(pattern)
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
// problems, so one bad key never hides another.

const known_keys = ["include", "exclude", "ignore"]

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
    Ok(other) -> Error([wrong_type(name, "a table", other)])
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
    |> parse_globs("tools.grice.include")
  let exclude =
    value("exclude", tom.Array([])) |> parse_globs("tools.grice.exclude")
  let ignore = value("ignore", tom.Table(dict.new())) |> parse_ignore
  let unknown =
    dict.drop(grice, known_keys)
    |> dict.keys
    |> list.sort(string.compare)
    |> list.map(unknown_key)
  case target, include, exclude, ignore, unknown {
    Ok(target), Ok(include), Ok(exclude), Ok(ignore), [] ->
      Ok(Config(target:, include:, exclude:, ignore:))
    _, _, _, _, _ ->
      Error(
        list.flatten([
          problems(target),
          problems(include),
          problems(exclude),
          problems(ignore),
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
    Ok(other) -> Error([wrong_type("target", "a string", other)])
  }
}

fn parse_globs(
  value: Toml,
  key: String,
) -> Result(List(Glob), List(Diagnostic)) {
  parse_strings(value, key, "glob", parse_glob(_, key, "holds"))
}

fn parse_ignore(
  value: Toml,
) -> Result(List(#(Glob, List(String))), List(Diagnostic)) {
  case value {
    tom.Table(entries) | tom.InlineTable(entries) ->
      entries
      |> dict.to_list
      |> list.sort(fn(left, right) { string.compare(left.0, right.0) })
      |> list.map(parse_ignore_entry)
      |> collect
    other ->
      Error([
        wrong_type(
          "tools.grice.ignore",
          "a table from globs to lists of rule codes",
          other,
        ),
      ])
  }
}

fn parse_ignore_entry(
  entry: #(String, Toml),
) -> Result(#(Glob, List(String)), List(Diagnostic)) {
  let #(pattern, value) = entry
  let pattern_glob = parse_glob(pattern, "tools.grice.ignore", "has the key")
  let key = ignore_key(pattern)
  let codes = parse_strings(value, key, "rule code", Ok)
  case pattern_glob, codes {
    Ok(pattern_glob), Ok(codes) -> Ok(#(pattern_glob, codes))
    _, _ -> Error(list.append(problems(pattern_glob), problems(codes)))
  }
}

// A list of strings, each a `noun` that `parse_item` reads.
fn parse_strings(
  value: Toml,
  key: String,
  noun: String,
  parse_item: fn(String) -> Result(a, List(Diagnostic)),
) -> Result(List(a), List(Diagnostic)) {
  case value {
    tom.Array(items) ->
      items
      |> list.index_map(fn(item, index) {
        tom.as_string(item)
        |> result.replace_error([
          wrong_item_type(key, index, "a " <> noun <> " string", item),
        ])
        |> result.try(parse_item)
      })
      |> collect
    other -> Error([wrong_type(key, "a list of " <> noun <> " strings", other)])
  }
}

// `holds` says where the pattern sits in `key`, for the message.
fn parse_glob(
  pattern: String,
  key: String,
  holds: String,
) -> Result(Glob, List(Diagnostic)) {
  glob.parse(pattern)
  |> result.map_error(fn(error) { [malformed_glob(key, holds, pattern, error)] })
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
// The wording of each problem. Messages name `gleam.toml` and the full
// dotted key, since there is no location to point at.

const glob_hint =
  "Patterns are relative to the project root, with `/` between segments. `*` matches within one segment, `?` matches one character, and `**` as a whole segment matches any number of segments."

fn syntax_error(error: tom.ParseError) -> Diagnostic {
  diagnostic(
    title: "Can't parse `gleam.toml`",
    message: "`gleam.toml` isn't valid TOML: "
      <> describe_toml_error(error)
      <> ".",
    hint: None,
  )
}

fn unknown_key(key: String) -> Diagnostic {
  diagnostic(
    title: "Unknown key in `gleam.toml`",
    message: "`gleam.toml` sets `tools.grice."
      <> key
      <> "`, which grice doesn't read. The keys of `[tools.grice]` are `include`, `exclude` and `ignore`.",
    hint: Some("Remove the key, or fix its spelling."),
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

fn wrong_type(key: String, expected: String, value: Toml) -> Diagnostic {
  diagnostic(
    title: "Wrong type in `gleam.toml`",
    message: "`"
      <> key
      <> "` in `gleam.toml` must be "
      <> expected
      <> ", but it's "
      <> describe_value(value)
      <> ".",
    hint: None,
  )
}

fn wrong_item_type(
  key: String,
  index: Int,
  expected: String,
  value: Toml,
) -> Diagnostic {
  diagnostic(
    title: "Wrong type in `gleam.toml`",
    message: "Every item of `"
      <> key
      <> "` in `gleam.toml` must be "
      <> expected
      <> ", but item "
      <> int.to_string(index + 1)
      <> " is "
      <> describe_value(value)
      <> ".",
    hint: None,
  )
}

fn malformed_glob(
  key: String,
  holds: String,
  pattern: String,
  error: GlobError,
) -> Diagnostic {
  diagnostic(
    title: "Malformed glob in `gleam.toml`",
    message: "`"
      <> key
      <> "` in `gleam.toml` "
      <> holds
      <> " `"
      <> pattern
      <> "`, which isn't a glob grice reads: "
      <> describe_glob_error(error)
      <> ".",
    hint: Some(glob_hint),
  )
}

fn describe_glob_error(error: GlobError) -> String {
  case error {
    glob.Empty -> "it's empty"
    glob.Absolute ->
      "it starts with `/`, but patterns are relative to the project root"
    glob.DotSegment -> "it has a `.` or `..` segment"
    glob.EmptySegment -> "it has an empty segment, `//`"
    glob.MixedDoubleStar -> "`**` must be a whole segment on its own"
    glob.Unsupported(character:) ->
      "grice's globs don't support `" <> character <> "`"
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
