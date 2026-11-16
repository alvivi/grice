//// Runs rules over a loaded project and turns what they report into
//// diagnostics.
////
//// The rule set is checked before anything runs, together with the rule
//// codes `gleam.toml` ignores. When a rule of the set is typed, girard then
//// infers the project's types, once for every rule. Rules run on the lint
//// set's modules that parse, and only on those: module rules as one task
//// per module, in parallel, and each project rule by summarising every
//// module in parallel and evaluating the summaries once. Each report is
//// checked against the source of the module it's about before it becomes
//// a diagnostic, so a rule with a bad span is reported on its own and
//// every other finding still comes through.

import gleam/bool
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/order.{type Order}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import grice/diagnostic.{type Diagnostic, type Label, Diagnostic}
import grice/facts.{type ModuleFacts, type Syntax}
import grice/internal/config.{type Config}
import grice/internal/glob
import grice/internal/line_index.{type LineIndex, type SpanProblem}
import grice/internal/loader.{type Project}
import grice/internal/parallel
import grice/internal/typing.{type ModuleTypes}
import grice/rule.{type Report, type Rule, ModuleCheck, ProjectCheck}

/// Run `rules` over the project. `Error` holds every problem with the rule
/// set and with the rule codes under `[tools.grice.ignore]`, and means no
/// rule ran. `Ok` holds every diagnostic of the run, the project's parse
/// errors included: first those with no location, in the order they were
/// made, then the rest by path, start, end and code.
pub fn run(
  project: Project,
  rules: List(Rule),
) -> Result(List(Diagnostic), List(Diagnostic)) {
  run_with(project, rules, infer: fn(project) {
    typing.infer(project, typing.resolver(project))
  })
}

/// Run `rules` as `run` does, with `infer` standing in for girard: it's
/// called once when a rule of the set is typed, and never otherwise, and
/// gives the types of the lint-set modules it inferred.
@internal
pub fn run_with(
  project: Project,
  rules: List(Rule),
  infer infer: fn(Project) -> Dict(String, ModuleTypes),
) -> Result(List(Diagnostic), List(Diagnostic)) {
  case list.append(check_rules(rules), check_ignores(project.config, rules)) {
    [] -> Ok(lint(project, rules, infer))
    problems -> Error(problems)
  }
}

// Running
//
// girard runs only when a rule needs types, and then once for all of them.
// Facts are built once per module, with the module's types when they were
// inferred, and shared by every rule, typed or not. A module task gets only
// the module's facts, which hold everything its reports are resolved
// against.

fn lint(
  project: Project,
  rules: List(Rule),
  infer: fn(Project) -> Dict(String, ModuleTypes),
) -> List(Diagnostic) {
  let types = case list.any(rules, rule.is_typed) {
    True -> Some(infer(project))
    False -> None
  }
  let linted =
    list.filter_map(project.lint_set, fn(name) {
      use module <- result.try(dict.get(project.modules, name))
      let module_types =
        option.then(types, fn(types) {
          option.from_result(dict.get(types, name))
        })
      facts.new(module, project.config.target, module_types)
    })
  let module_rules =
    list.filter_map(rules, fn(lint_rule) {
      case rule.check(lint_rule) {
        ModuleCheck(run:) -> Ok(#(lint_rule, run))
        ProjectCheck(..) -> Error(Nil)
      }
    })
  let project_rules =
    list.filter_map(rules, fn(lint_rule) {
      case rule.check(lint_rule) {
        ProjectCheck(run:) -> Ok(#(lint_rule, run))
        ModuleCheck(..) -> Error(Nil)
      }
    })
  let from_module_rules = case module_rules {
    [] -> []
    [_, ..] ->
      linted
      |> parallel.map(fn(module_facts) {
        use #(lint_rule, run) <- list.flat_map(module_rules)
        list.map(run(module_facts), resolve(lint_rule, module_facts, _))
      })
      |> list.flatten
  }
  let by_name =
    linted
    |> list.map(fn(module_facts) {
      #(facts.module_name(module_facts), module_facts)
    })
    |> dict.from_list
  let from_project_rules = {
    use #(lint_rule, run) <- list.flat_map(project_rules)
    use #(name, report) <- list.map(run(linted))
    case dict.get(by_name, name) {
      Ok(module_facts) -> resolve(lint_rule, module_facts, report)
      Error(Nil) -> not_linted(lint_rule, name)
    }
  }
  [project.diagnostics, from_module_rules, from_project_rules]
  |> list.flatten
  |> list.sort(compare)
}

fn compare(left: Diagnostic, right: Diagnostic) -> Order {
  case left.location, right.location {
    None, None -> order.Eq
    None, Some(_) -> order.Lt
    Some(_), None -> order.Gt
    Some(left_location), Some(right_location) ->
      string.compare(left_location.path, right_location.path)
      |> order.break_tie(int.compare(
        left_location.primary.span.start,
        right_location.primary.span.start,
      ))
      |> order.break_tie(int.compare(
        left_location.primary.span.end,
        right_location.primary.span.end,
      ))
      |> order.break_tie(string.compare(left.code, right.code))
  }
}

// Resolving reports
//
// A report becomes a diagnostic with the rule's code, title and severity
// and the module's path, once every one of its spans is valid for the
// module's source. A report with a bad span becomes one
// `grice/invalid-report` error instead, since the renderer would refuse
// every diagnostic of the run over it.

fn resolve(
  lint_rule: Rule,
  module_facts: ModuleFacts(Syntax),
  report: Report,
) -> Diagnostic {
  let source = facts.line_index(module_facts)
  let #(primary, secondary) = rule.report_labels(report)
  let problems =
    [
      #("primary label", primary),
      ..list.index_map(secondary, fn(label, index) {
        #("secondary label " <> int.to_string(index + 1), label)
      })
    ]
    |> list.filter_map(fn(entry) {
      let #(name, label) = entry
      case line_index.check_span(source, label.span) {
        Ok(Nil) -> Error(Nil)
        Error(problem) -> Ok(describe_span(name, label, problem, source))
      }
    })
  case problems {
    [] -> rule.to_diagnostic(lint_rule, report, path: facts.path(module_facts))
    [_, ..] -> invalid_spans(lint_rule, module_facts, problems)
  }
}

fn describe_span(
  name: String,
  label: Label,
  problem: SpanProblem,
  source: LineIndex,
) -> String {
  let span = label.span
  let why = case problem {
    line_index.OutOfBounds ->
      "isn't inside the source, which is "
      <> int.to_string(string.byte_size(line_index.source(source)))
      <> " bytes long"
    line_index.Reversed -> "starts after it ends"
    line_index.SplitsCodepoint -> "has an end inside a multi-byte character"
    line_index.SplitsLineEnding ->
      "has an end between a carriage return and the line feed after it"
  }
  "The span of the "
  <> name
  <> ", from byte "
  <> int.to_string(span.start)
  <> " to byte "
  <> int.to_string(span.end)
  <> ", "
  <> why
  <> "."
}

const report_hint =
  "This is a bug in the rule, so please report it to the rule's author. The other reports of the run are unaffected."

fn invalid_spans(
  lint_rule: Rule,
  module_facts: ModuleFacts(Syntax),
  problems: List(String),
) -> Diagnostic {
  invalid_report([
    "The rule `"
      <> rule.code(lint_rule)
      <> "` reported a problem in the module `"
      <> facts.module_name(module_facts)
      <> "`, at `"
      <> facts.path(module_facts)
      <> "`, with a span that isn't valid for the module's source. grice can't show where it points, so the report is dropped.",
    ..problems
  ])
}

fn not_linted(lint_rule: Rule, name: String) -> Diagnostic {
  invalid_report([
    "The project rule `"
    <> rule.code(lint_rule)
    <> "` reported a problem in the module `"
    <> name
    <> "`, which isn't one of the modules this run linted: it isn't in the lint set, doesn't parse, or isn't a module of the project. The report is dropped.",
  ])
}

fn invalid_report(message: List(String)) -> Diagnostic {
  error(
    "grice/invalid-report",
    "A rule made an invalid report",
    message,
    report_hint,
  )
}

// One of grice's own errors, with no location.
fn error(
  code: String,
  title: String,
  message: List(String),
  hint: String,
) -> Diagnostic {
  Diagnostic(
    code:,
    severity: diagnostic.Error,
    title:,
    location: None,
    message:,
    hint: Some(hint),
  )
}

// The rule set
//
// Codes name rules in ignores, and later in suppressions, so each must
// follow one syntax, belong to one rule, and stay clear of the `grice/`
// prefix of grice's own diagnostics. Every problem is reported, in the
// order of the rules, then each repeated code once.

const lowercase = "abcdefghijklmnopqrstuvwxyz"

const digits = "0123456789"

const reserved_prefix = "grice/"

fn check_rules(rules: List(Rule)) -> List(Diagnostic) {
  let codes = list.map(rules, rule.code)
  let repeated =
    codes
    |> list.unique
    |> list.filter_map(fn(code) {
      let count = list.count(codes, fn(other) { other == code })
      use <- bool.guard(when: count < 2, return: Error(Nil))
      Ok(repeated_code(code, count))
    })
  list.append(list.flat_map(rules, check_rule), repeated)
}

fn check_rule(lint_rule: Rule) -> List(Diagnostic) {
  let code = rule.code(lint_rule)
  let code_problem = case
    is_valid_code(code),
    string.starts_with(code, reserved_prefix)
  {
    False, _ -> [invalid_code(code)]
    True, True -> [reserved_code(code)]
    True, False -> []
  }
  let title_problem = case string.trim(rule.title(lint_rule)) {
    "" -> [empty_title(code)]
    _ -> []
  }
  list.append(code_problem, title_problem)
}

// A code matches `[a-z][a-z0-9_]*/[a-z][a-z0-9]*(-[a-z0-9]+)*`: the name
// is words joined by single hyphens, so none of them is empty.
fn is_valid_code(code: String) -> Bool {
  case string.split(code, "/") {
    [prefix, name] ->
      is_word(prefix, rest: lowercase <> digits <> "_")
      && is_word(name, rest: lowercase <> digits <> "-")
      && !list.contains(string.split(name, "-"), "")
    _ -> False
  }
}

// A lowercase letter followed by characters of `allowed`.
fn is_word(word: String, rest allowed: String) -> Bool {
  case string.to_graphemes(word) {
    [first, ..rest] ->
      string.contains(lowercase, first)
      && list.all(rest, string.contains(allowed, _))
    [] -> False
  }
}

const code_hint =
  "A rule code is a package-style prefix, a slash and a kebab-case name, such as `my_app/no-io-in-view`. The prefix is a lowercase letter followed by lowercase letters, digits and underscores, and the name is words of lowercase letters and digits joined by single hyphens, starting with a letter."

fn invalid_code(code: String) -> Diagnostic {
  invalid_rule(
    title: "Invalid rule code",
    message: "A rule has the code "
      <> string.inspect(code)
      <> ", which isn't a valid rule code. Codes name rules in `gleam.toml`, so they follow a fixed syntax.",
    hint: code_hint,
  )
}

fn reserved_code(code: String) -> Diagnostic {
  invalid_rule(
    title: "Reserved rule code",
    message: "A rule has the code `"
      <> code
      <> "`, but the `grice/` prefix is reserved for grice's own diagnostics.",
    hint: "Use your package's name as the prefix, such as `my_app/"
      <> string.drop_start(code, string.length(reserved_prefix))
      <> "`.",
  )
}

fn repeated_code(code: String, count: Int) -> Diagnostic {
  invalid_rule(
    title: "Rule code used more than once",
    message: int.to_string(count)
      <> " rules have the code `"
      <> code
      <> "`. Ignores name rules by their code, so each code must belong to one rule.",
    hint: "Give each rule a code of its own, or remove the duplicates from the rule set.",
  )
}

fn empty_title(code: String) -> Diagnostic {
  invalid_rule(
    title: "Rule without a title",
    message: "The rule `"
      <> code
      <> "` has an empty title. The title is the one-line summary printed with each of the rule's diagnostics.",
    hint: "Give the rule a title that says what it reports, such as \"Echo left in the code\".",
  )
}

fn invalid_rule(
  title title: String,
  message message: String,
  hint hint: String,
) -> Diagnostic {
  error("grice/invalid-rule", title, [message], hint)
}

// Ignored codes
//
// Each rule code under `[tools.grice.ignore]` must name a rule of the run.
// A `grice/` code names one of grice's own diagnostics, which report on
// the run itself and can't be ignored, so it gets a message of its own.

fn check_ignores(config: Config, rules: List(Rule)) -> List(Diagnostic) {
  let codes = set.from_list(list.map(rules, rule.code))
  use #(pattern, ignored) <- list.flat_map(config.ignore)
  let key = config.ignore_key(glob.to_string(pattern))
  list.filter_map(ignored, check_ignore(key, _, codes))
}

fn check_ignore(
  key: String,
  code: String,
  codes: Set(String),
) -> Result(Diagnostic, Nil) {
  use <- bool.lazy_guard(
    when: string.starts_with(code, reserved_prefix),
    return: fn() { Ok(ignored_grice_code(key, code)) },
  )
  use <- bool.guard(when: set.contains(codes, code), return: Error(Nil))
  Ok(unknown_ignored_code(key, code))
}

fn unknown_ignored_code(key: String, code: String) -> Diagnostic {
  config.diagnostic(
    title: "Unknown rule in `gleam.toml`",
    message: "`"
      <> key
      <> "` in `gleam.toml` names the rule `"
      <> code
      <> "`, but no rule of this run has that code. An ignore that names no rule silences nothing, so it's most likely a typo or a rule that was removed.",
    hint: Some("Fix the code, or remove it from the list."),
  )
}

fn ignored_grice_code(key: String, code: String) -> Diagnostic {
  config.diagnostic(
    title: "grice's own diagnostics can't be ignored",
    message: "`"
      <> key
      <> "` in `gleam.toml` names `"
      <> code
      <> "`, one of grice's own diagnostics rather than a rule. Those report on the run itself, such as code grice couldn't read or configuration it couldn't use, so they can't be ignored.",
    hint: Some(
      "Remove the code from the list, and fix what it reports instead.",
    ),
  )
}
