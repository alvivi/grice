//// Hiding rule diagnostics with the ignores of `gleam.toml` and with
//// suppression comments, and warning about each suppression that hides
//// nothing or can't be used.
////
//// A suppression is a regular `//` comment that names one rule by its code
//// and gives a reason after a colon:
////
//// ```gleam
//// // grice-ignore-file my_app/no-panic: This module is a test fixture.
////
//// pub fn main() {
////   // grice-ignore my_app/no-echo: Printing is what this tool does.
////   echo 1
//// }
//// ```
////
//// `grice-ignore` stands alone on its line and covers the diagnostics whose
//// primary span starts on the next line holding code, so blank lines and
//// comments in between are skipped and suppressions stack.
//// `grice-ignore-file` comes before the module's first line of code and
//// covers the whole module. Ignores apply first, and every suppression is
//// matched against what they left. grice's own diagnostics are never
//// hidden.

import glance
import gleam/bit_array
import gleam/bool
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/pair
import gleam/result
import gleam/set.{type Set}
import gleam/string
import grice/diagnostic.{type Diagnostic, type Location, Diagnostic}
import grice/facts.{type Comment, type ModuleFacts, type Syntax}
import grice/internal/config.{type Config, type Ignore}
import grice/internal/glob
import grice/internal/line_index.{type LineIndex}
import grice/rule

/// Drop the diagnostics that the ignores of `config` and the suppressions
/// in the comments of `modules`, the linted modules, hide, and add a warning
/// for each suppression that hid nothing or can't be used. `codes` are the
/// codes of the run's rules. The diagnostics kept stay in order, and the
/// warnings come after them.
///
/// Also returns how many of `diagnostics` were dropped. Two identical
/// diagnostics count twice, and one covered by several suppressions or
/// ignores counts once.
pub fn apply(
  diagnostics: List(Diagnostic),
  modules: List(ModuleFacts(Syntax)),
  config: Config,
  codes: Set(String),
) -> #(List(Diagnostic), Int) {
  // Only rule diagnostics, which have a location, can be hidden.
  let by_path =
    diagnostics
    |> list.filter_map(fn(diagnostic) {
      case
        diagnostic.location,
        string.starts_with(diagnostic.code, rule.reserved_prefix)
      {
        Some(location), False -> Ok(#(diagnostic, location))
        Some(_), True | None, _ -> Error(Nil)
      }
    })
    |> list.group(fn(candidate) { candidate.1.path })
  let #(hidden, warnings) =
    modules
    |> list.map(fn(module_facts) {
      dict.get(by_path, facts.path(module_facts))
      |> result.unwrap([])
      |> suppress_module(module_facts, config, codes)
    })
    |> list.unzip
  let hidden = set.from_list(list.flatten(hidden))
  let kept =
    list.filter(diagnostics, fn(diagnostic) {
      !set.contains(hidden, diagnostic)
    })
  #(
    list.append(kept, list.flatten(warnings)),
    list.length(diagnostics) - list.length(kept),
  )
}

// What the ignores and then the suppressions of one module hide among its
// rule diagnostics, and the warnings about its suppressions.
fn suppress_module(
  candidates: List(#(Diagnostic, Location)),
  module_facts: ModuleFacts(Syntax),
  config: Config,
  codes: Set(String),
) -> #(List(Diagnostic), List(Diagnostic)) {
  let path = facts.path(module_facts)
  let index = facts.line_index(module_facts)
  let definitions = case
    list.any(config.ignore, fn(ignore) { ignore.definitions != None })
  {
    True -> byte_definitions(module_facts, index)
    False -> []
  }
  let #(ignored, left) =
    list.partition(candidates, fn(candidate) {
      list.any(config.ignore, hides(_, candidate, definitions))
    })
  let #(suppressions, problems) =
    byte_comments(module_facts, index)
    |> read(index, config.suppression_comments)
    |> result.partition
  let covered =
    list.map(suppressions, fn(suppression) {
      #(suppression, list.filter(left, covers(suppression, _, index)))
    })
  let warnings =
    list.append(
      list.map(problems, fn(problem) {
        warning(invalid, path, problem.0, invalid_text(problem.1))
      }),
      list.filter_map(covered, fn(entry) {
        case entry {
          #(suppression, []) ->
            Ok(warning(
              unused,
              path,
              suppression.comment,
              unused_text(suppression, codes),
            ))
          #(_, [_, ..]) -> Error(Nil)
        }
      }),
    )
  let hidden = list.append(ignored, list.flat_map(covered, pair.second))
  #(list.map(hidden, pair.first), warnings)
}

// The name and byte span of each top-level definition but the imports,
// for the ignores that name definitions. A definition whose span can't be
// turned into bytes is left out, so no ignore hides a diagnostic by it.
fn byte_definitions(
  module_facts: ModuleFacts(Syntax),
  index: LineIndex,
) -> List(#(String, diagnostic.Span)) {
  use #(name, span) <- list.filter_map(
    facts.definitions(facts.module(module_facts)),
  )
  line_index.span_to_bytes(index, span)
  |> result.map(pair.new(name, _))
  |> result.replace_error(Nil)
}

// An entry hides a diagnostic when one of its globs matches the path, the
// code is one of its rules, and, when it names definitions, the primary
// span starts inside a top-level definition whose name matches.
fn hides(
  ignore: Ignore,
  candidate: #(Diagnostic, Location),
  definitions: List(#(String, diagnostic.Span)),
) -> Bool {
  let #(diagnostic, location) = candidate
  let start = location.primary.span.start
  use <- bool.guard(
    when: !list.contains(ignore.rules, diagnostic.code),
    return: False,
  )
  use <- bool.guard(
    when: !list.any(ignore.paths, glob.matches(_, location.path)),
    return: False,
  )
  case ignore.definitions {
    None -> True
    Some(patterns) ->
      list.any(definitions, fn(definition) {
        let #(name, span) = definition
        span.start <= start
        && start < span.end
        && list.any(patterns, glob.matches_name(_, name))
      })
  }
}

// Suppressions
//
// A comment is a suppression when it's a regular `//` comment whose text,
// after leading spaces and tabs, starts with `grice-ignore`. Placement and
// reach are worked out over the source's bytes and the comments the facts
// keep, their spans turned into bytes, so one inside a definition left out
// for the other target isn't there: skipping whitespace and comments finds
// the next byte of code.

// A suppression grice can use: the rule it names and what it covers.
type Suppression {
  Suppression(comment: Comment, code: String, reach: Reach)
}

type Reach {
  // The diagnostics whose primary span starts on this 1-based line.
  Line(line: Int)
  // Nothing: a `grice-ignore` with no code after it.
  NoLine
  // Every diagnostic in the module.
  WholeModule
}

// Why grice can't use a suppression.
type Problem {
  UnknownWord(word: String)
  NoCode
  NoReason
  InvalidCode(code: String)
  GriceCode(code: String)
  Misplaced
  TurnedOff
}

fn covers(
  suppression: Suppression,
  candidate: #(Diagnostic, Location),
  index: LineIndex,
) -> Bool {
  let #(diagnostic, location) = candidate
  use <- bool.guard(when: diagnostic.code != suppression.code, return: False)
  case suppression.reach {
    Line(line:) ->
      line_index.line_number(index, location.primary.span.start) == line
    NoLine -> False
    WholeModule -> True
  }
}

// The module's comments, in source order, with byte spans. A comment
// whose span can't be turned into bytes is left out, so a suppression in
// it hides nothing.
fn byte_comments(
  module_facts: ModuleFacts(Syntax),
  index: LineIndex,
) -> List(Comment) {
  let comments = facts.comments(module_facts)
  use <- bool.guard(
    when: line_index.units(index) == line_index.Bytes,
    return: comments,
  )
  use comment <- list.filter_map(comments)
  line_index.span_to_bytes(index, comment.span)
  |> result.map(fn(span) {
    facts.Comment(..comment, span: glance.Span(span.start, span.end))
  })
  |> result.replace_error(Nil)
}

// Every suppression among `comments`, those of the module, or its comment
// with why grice can't use it, in source order.
fn read(
  comments: List(Comment),
  index: LineIndex,
  enabled: Bool,
) -> List(Result(Suppression, #(Comment, Problem))) {
  use comment <- list.filter_map(comments)
  case comment.kind, trim_start(comment.text), enabled {
    facts.Regular, "grice-ignore" <> _ as text, True ->
      parse(comment, text, index, comments)
      |> result.map_error(pair.new(comment, _))
      |> Ok
    facts.Regular, "grice-ignore" <> _, False ->
      Ok(Error(#(comment, TurnedOff)))
    facts.Regular, _, _ | facts.Doc, _, _ | facts.ModuleDoc, _, _ -> Error(Nil)
  }
}

// `grice-ignore` or `grice-ignore-file`, whitespace, a rule code, a colon
// and a reason that isn't blank, placed as each needs. The first colon ends
// the code, so the reason may hold more.
fn parse(
  comment: Comment,
  text: String,
  index: LineIndex,
  comments: List(Comment),
) -> Result(Suppression, Problem) {
  let #(word, rest) = split_word(text, "")
  use place <- result.try(case word {
    "grice-ignore" -> Ok(next_line)
    "grice-ignore-file" -> Ok(whole_module)
    _ -> Error(UnknownWord(word))
  })
  use <- bool.guard(when: is_blank(rest), return: Error(NoCode))
  use #(code, reason) <- result.try(
    string.split_once(rest, ":") |> result.replace_error(NoReason),
  )
  let code = trim_end(trim_start(code))
  use <- bool.guard(when: code == "", return: Error(NoCode))
  use <- bool.guard(
    when: !rule.is_valid_code(code),
    return: Error(InvalidCode(code)),
  )
  use <- bool.guard(
    when: string.starts_with(code, rule.reserved_prefix),
    return: Error(GriceCode(code)),
  )
  use <- bool.guard(when: is_blank(reason), return: Error(NoReason))
  use reach <- result.map(place(comment, index, comments))
  Suppression(comment:, code:, reach:)
}

// A `grice-ignore` must be alone on its line, and covers the next line
// holding code.
fn next_line(
  comment: Comment,
  index: LineIndex,
  comments: List(Comment),
) -> Result(Reach, Problem) {
  let bytes = bit_array.from_string(line_index.source(index))
  let start = comment.span.start
  let #(line_start, _) =
    line_index.line_bytes(index, line_index.line_number(index, start))
  use <- bool.guard(
    when: skip_whitespace(bytes, line_start) != start,
    return: Error(Misplaced),
  )
  case next_code(bytes, comment.span.end, comments) {
    Ok(byte) -> Ok(Line(line_index.line_number(index, byte)))
    Error(Nil) -> Ok(NoLine)
  }
}

// A `grice-ignore-file` must come before the first line of code, and
// covers the whole module.
fn whole_module(
  comment: Comment,
  index: LineIndex,
  comments: List(Comment),
) -> Result(Reach, Problem) {
  let bytes = bit_array.from_string(line_index.source(index))
  case next_code(bytes, 0, comments) {
    Ok(first) if first < comment.span.start -> Error(Misplaced)
    Ok(_) | Error(Nil) -> Ok(WholeModule)
  }
}

// The offset of the first byte at or after `offset` that's neither
// whitespace nor inside one of `comments`, which are in source order.
// `Error` when the source ends first.
fn next_code(
  bytes: BitArray,
  offset: Int,
  comments: List(Comment),
) -> Result(Int, Nil) {
  let offset = skip_whitespace(bytes, offset)
  case comments, offset < bit_array.byte_size(bytes) {
    [comment, ..rest], _ if comment.span.start < offset ->
      next_code(bytes, offset, rest)
    [comment, ..rest], _ if comment.span.start == offset ->
      next_code(bytes, comment.span.end, rest)
    _, True -> Ok(offset)
    _, False -> Error(Nil)
  }
}

fn skip_whitespace(bytes: BitArray, offset: Int) -> Int {
  case bit_array.slice(bytes, offset, 1) {
    Ok(<<" ":utf8>>)
    | Ok(<<"\t":utf8>>)
    | Ok(<<"\n":utf8>>)
    | Ok(<<"\r":utf8>>) -> skip_whitespace(bytes, offset + 1)
    _ -> offset
  }
}

// `text` split before its first space, tab or colon.
fn split_word(text: String, word: String) -> #(String, String) {
  case text, string.pop_grapheme(text) {
    " " <> _, _ | "\t" <> _, _ | ":" <> _, _ -> #(word, text)
    _, Ok(#(first, rest)) -> split_word(rest, word <> first)
    _, Error(Nil) -> #(word, text)
  }
}

// Whitespace in a suppression is spaces and tabs only, so the standard
// library's trimming, which also takes other Unicode whitespace, won't do.
fn trim_start(text: String) -> String {
  case text {
    " " <> rest | "\t" <> rest -> trim_start(rest)
    _ -> text
  }
}

fn trim_end(text: String) -> String {
  text |> string.reverse |> trim_start |> string.reverse
}

fn is_blank(text: String) -> Bool {
  trim_start(text) == ""
}

// Warnings
//
// Both warnings point at the suppression's comment, say what's wrong with
// it, and hint at the fix. Neither can be hidden, since their codes are
// grice's.

const unused = #("grice/unused-suppression", "Unused suppression")

const invalid = #("grice/invalid-suppression", "Invalid suppression")

const syntax_hint =
  "Write `// grice-ignore <rule code>: <reason>` on its own line, above the code it covers, or `// grice-ignore-file <rule code>: <reason>` before the module's first line of code to cover the whole module."

// The label, message and hint of a suppression that hid nothing.
fn unused_text(
  suppression: Suppression,
  codes: Set(String),
) -> #(String, String, String) {
  let Suppression(code:, reach:, ..) = suppression
  let where = case reach {
    Line(line:) ->
      "on line " <> int.to_string(line) <> ", the next line of code"
    WholeModule -> "in this module"
    NoLine -> "below it, where no code follows"
  }
  let hint = "Fix the suppression, or remove it. " <> syntax_hint
  case set.contains(codes, code) {
    True -> #(
      "This hides nothing",
      "This suppression hides nothing: no diagnostic of the rule `"
        <> code
        <> "` is left to hide "
        <> where
        <> ".",
      hint,
    )
    False -> #(
      "No rule of this run has this code",
      "This suppression names `"
        <> code
        <> "`, but no rule of this run has that code, so it hides nothing. It's most likely a typo, a rule that was removed, or a rule of another rule set.",
      hint,
    )
  }
}

// The label, message and hint of a suppression grice can't use.
fn invalid_text(problem: Problem) -> #(String, String, String) {
  let #(label, why, hint) = case problem {
    UnknownWord(word:) -> #(
      "grice doesn't know `" <> word <> "`",
      "This comment starts with `"
        <> word
        <> "`, so grice reads it as a suppression, but the suppressions are `grice-ignore`, for the next line of code, and `grice-ignore-file`, for the whole module.",
      syntax_hint,
    )
    NoCode -> #(
      "This names no rule",
      "A suppression names the rule it hides by its code, but this one names none.",
      syntax_hint,
    )
    NoReason -> #(
      "This gives no reason",
      "A suppression says why the rule doesn't apply, after a colon that follows the rule code, but this one gives no reason.",
      syntax_hint,
    )
    InvalidCode(code:) -> #(
      "This isn't a rule code",
      string.inspect(code)
        <> " isn't a valid rule code. A rule code is a package-style prefix, a slash and a kebab-case name, such as `my_app/no-io-in-view`.",
      syntax_hint,
    )
    GriceCode(code:) -> #(
      "This names one of grice's own diagnostics",
      "This suppression names `"
        <> code
        <> "`, one of grice's own diagnostics rather than a rule. Those report on the run itself, so they can't be hidden.",
      "Remove the suppression, and fix what the diagnostic reports instead.",
    )
    Misplaced -> #(
      "This comes after code",
      "A `grice-ignore` comment must be alone on its line, and a `grice-ignore-file` comment must come before the module's first line of code, but this one comes after code.",
      syntax_hint,
    )
    TurnedOff -> #(
      "grice doesn't read this",
      "`suppression_comments` is `false` in the `[tools.grice]` table of `gleam.toml`, so grice doesn't read suppressions in comments.",
      "Move it to a `[[tools.grice.ignore]]` entry in `gleam.toml` and remove the comment, or set `suppression_comments` to `true`.",
    )
  }
  #(label, why <> " It hides nothing.", hint)
}

// A warning of `kind`, its code and title, at the comment.
fn warning(
  kind: #(String, String),
  path: String,
  comment: Comment,
  text: #(String, String, String),
) -> Diagnostic {
  let glance.Span(start:, end:) = comment.span
  let #(label, message, hint) = text
  Diagnostic(
    code: kind.0,
    severity: diagnostic.Warning,
    title: kind.1,
    location: Some(diagnostic.Location(
      path:,
      primary: diagnostic.Label(
        span: diagnostic.Span(start:, end:),
        message: label,
      ),
      secondary: [],
      fix: None,
    )),
    message: [message],
    hint: Some(hint),
  )
}
