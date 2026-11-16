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
////
//// A run also says how much of the lint set it covered, and every gap in
//// that coverage is a diagnostic.

import girard
import glance
import gleam/bool
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order.{type Order}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import grice/diagnostic.{type Diagnostic, type Label, Diagnostic}
import grice/facts.{type ModuleFacts, type Syntax}
import grice/internal/config.{type Config}
import grice/internal/line_index.{type LineIndex, type SpanProblem}
import grice/internal/loader.{type Project}
import grice/internal/parallel
import grice/internal/typing.{type ModuleTypes}
import grice/rule.{type Report, type Rule, ModuleCheck, ProjectCheck}

/// What a run found, and how much of the lint set it covered.
pub type Linted {
  Linted(
    /// Every diagnostic of the run, the project's parse errors and the
    /// coverage notes included: first those with no location, in the order
    /// they were made, then the rest by path, start, end and code.
    diagnostics: List(Diagnostic),
    coverage: Coverage,
  )
}

/// Run `rules` over the project. `Error` holds every problem with the rule
/// set and with the rule codes the ignores in `gleam.toml` name, and means
/// no rule ran.
pub fn run(
  project: Project,
  rules: List(Rule),
) -> Result(Linted, List(Diagnostic)) {
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
) -> Result(Linted, List(Diagnostic)) {
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
) -> Linted {
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
  let #(covered, type_gaps) = type_coverage(project, linted, types)
  let #(type_gaps, notes) = list.unzip(type_gaps)
  let diagnostics =
    [project.diagnostics, notes, from_module_rules, from_project_rules]
    |> list.flatten
    |> list.sort(compare)
  let coverage =
    Coverage(
      modules: list.length(project.lint_set),
      parsed: list.length(linted),
      types: covered,
      gaps: list.append(unparsed_modules(project), type_gaps),
    )
  Linted(diagnostics:, coverage:)
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

// Coverage
//
// What the run couldn't analyse. A lint-set module that doesn't parse is a
// gap in every run, reported by the loader's `grice/parse-error`. Gaps in
// the types are reported only when a rule asked for types, and only for
// the lint set: an excluded module's own gaps reach the modules that
// import it as a use girard couldn't type or a module it couldn't use.
// Each is a note, since it's a limit of grice's analysis rather than a
// problem in the code.

/// How much of the lint set a run analysed.
pub type Coverage {
  Coverage(
    /// The number of modules in the lint set.
    modules: Int,
    /// The number of lint-set modules that parse.
    parsed: Int,
    /// How much of the parsed lint-set modules girard typed.
    types: TypeCoverage,
    /// Everything the run couldn't analyse, each matching one diagnostic:
    /// first the modules that don't parse, then the gaps of each module in
    /// lint-set order, then the missing packages.
    gaps: List(Gap),
  )
}

/// How much of the parsed lint-set modules girard typed.
pub type TypeCoverage {
  /// No rule of the run is typed, so girard didn't run.
  NotRequested
  /// How many modules girard typed completely, how many it typed with
  /// gaps, and how many it returned nothing for. Together they are the
  /// parsed lint-set modules.
  Requested(full: Int, partial: Int, none: Int)
}

/// Something the run couldn't analyse, and the diagnostic that reports it.
pub type Gap {
  /// A lint-set module that doesn't parse: a `grice/parse-error`.
  UnparsedModule(path: String)
  /// A definition girard couldn't type: a `grice/untyped-definition`.
  UntypedDefinition(path: String, definition: String)
  /// A lint-set module girard returned nothing for: a
  /// `grice/uninferred-module`.
  UninferredModule(path: String)
  /// A module girard couldn't use, which the lint-set module at `path`
  /// imports directly or reaches through other modules: a
  /// `grice/unavailable-import`.
  UnavailableImport(path: String, module: String, cause: Cause)
  /// A manifest package whose sources are missing: a
  /// `grice/missing-package`.
  MissingPackage(package: String)
}

/// Why girard couldn't use a module.
pub type Cause {
  /// It's a project module glance can't parse.
  ProjectModuleUnparsable
  /// It's a project module that parses, which girard couldn't use.
  ProjectModuleUnusable
  /// It's a dependency module glance can't parse.
  DependencyUnparsable
  /// No project or dependency module has its name.
  NoSuchModule
}

fn unparsed_modules(project: Project) -> List(Gap) {
  use name <- list.filter_map(project.lint_set)
  case dict.get(project.modules, name) {
    Ok(loader.Module(path:, parsed: Error(_), ..)) -> Ok(UnparsedModule(path))
    Ok(loader.Module(parsed: Ok(_), ..)) | Error(Nil) -> Error(Nil)
  }
}

// How much of the lint set girard typed, and the gaps in its types, each
// with its note: each module's in lint-set order, then each missing
// package's.
fn type_coverage(
  project: Project,
  linted: List(ModuleFacts(Syntax)),
  types: Option(Dict(String, ModuleTypes)),
) -> #(TypeCoverage, List(#(Gap, Diagnostic))) {
  case types {
    None -> #(NotRequested, [])
    Some(types) -> {
      let complete =
        list.map(linted, fn(module_facts) {
          dict.get(types, facts.module_name(module_facts))
          |> result.map(fn(module_types) { module_types.complete })
        })
      let coverage =
        Requested(
          full: list.count(complete, fn(state) { state == Ok(True) }),
          partial: list.count(complete, fn(state) { state == Ok(False) }),
          none: list.count(complete, fn(state) { state == Error(Nil) }),
        )
      let gaps =
        list.flat_map(linted, module_gaps(project, _, types))
        |> list.append(list.map(project.missing_dependencies, missing_package))
      #(coverage, gaps)
    }
  }
}

fn module_gaps(
  project: Project,
  module_facts: ModuleFacts(Syntax),
  types: Dict(String, ModuleTypes),
) -> List(#(Gap, Diagnostic)) {
  case dict.get(types, facts.module_name(module_facts)) {
    Error(Nil) -> [uninferred_module(module_facts)]
    Ok(module_types) ->
      list.append(
        list.map(module_types.skipped, untyped_definition(module_facts, _)),
        list.map(module_types.unavailable, unavailable_import(
          project,
          module_facts,
          _,
        )),
      )
  }
}

const girard_hint =
  "If `gleam build` accepts this code, it's a gap in girard, the type inference grice uses, so please report it at https://github.com/alvivi/girard/issues."

fn untyped_definition(
  module_facts: ModuleFacts(Syntax),
  skipped: typing.Skipped,
) -> #(Gap, Diagnostic) {
  let path = facts.path(module_facts)
  note(
    UntypedDefinition(path:, definition: skipped.name),
    code: "grice/untyped-definition",
    title: "Can't infer the types of this definition",
    at: Some(#(path, skipped.span, "girard couldn't type this definition")),
    message: "girard couldn't type `"
      <> skipped.name
      <> "`: "
      <> girard.describe_error(skipped.error)
      <> ". Typed rules get no answers about the code inside it, so they may miss problems there.",
    hint: girard_hint,
  )
}

fn uninferred_module(module_facts: ModuleFacts(Syntax)) -> #(Gap, Diagnostic) {
  let path = facts.path(module_facts)
  note(
    UninferredModule(path),
    code: "grice/uninferred-module",
    title: "Can't infer the types of a module",
    at: None,
    message: "girard, the type inference grice uses, returned no types for the module `"
      <> facts.module_name(module_facts)
      <> "`, at `"
      <> path
      <> "`. Rules still ran on it, but typed rules got no answers about it, so they may have missed problems there.",
    hint: girard_hint,
  )
}

// The label sits on the import of the module girard couldn't use when
// there is one. A module reached through other modules has nothing to
// point at, since grice doesn't keep the imports of dependency modules.
fn unavailable_import(
  project: Project,
  module_facts: ModuleFacts(Syntax),
  unavailable: girard.UnavailableModule,
) -> #(Gap, Diagnostic) {
  let path = facts.path(module_facts)
  let module = unavailable.module
  let #(cause, why, hint) = find_cause(project, unavailable)
  let #(at, subject) = case
    list.find(facts.module(module_facts).imports, fn(definition) {
      definition.definition.module == module
    })
  {
    Ok(definition) -> #(
      Some(#(path, definition.definition.location, "girard couldn't use this")),
      "girard, the type inference grice uses, couldn't use the module `"
        <> module
        <> "`, which this module imports.",
    )
    Error(Nil) -> #(
      None,
      "The module `"
        <> facts.module_name(module_facts)
        <> "`, at `"
        <> path
        <> "`, reaches the module `"
        <> module
        <> "` through the modules it imports, and girard, the type inference grice uses, couldn't use it.",
    )
  }
  note(
    UnavailableImport(path:, module:, cause:),
    code: "grice/unavailable-import",
    title: "Can't use the types of an imported module",
    at:,
    message: subject
      <> " "
      <> why
      <> " Types that depend on it may be incomplete, so typed rules get no answers in this module.",
    hint:,
  )
}

// Why girard couldn't use a module, with a sentence that says so and a
// hint. The resolver never answers for a project module and answers for
// every dependency module, so a module whose source girard couldn't parse
// is a dependency's, and the project says why girard found no other.
fn find_cause(
  project: Project,
  unavailable: girard.UnavailableModule,
) -> #(Cause, String, String) {
  case unavailable.reason, dict.get(project.modules, unavailable.module) {
    girard.Unparsable(error), _ -> {
      // The resolver gave girard this source, so it's there.
      let source =
        dict.get(project.dependencies, unavailable.module)
        |> result.unwrap("")
      #(
        DependencyUnparsable,
        "It's a dependency module, which glance can't parse: it stopped at "
          <> stop(line_index.new(source), error)
          <> " of its source.",
        "If the package builds, glance doesn't support its syntax yet, so please report it to glance.",
      )
    }
    girard.NotFound, Ok(loader.Module(path:, source:, parsed: Error(error), ..))
    -> #(
      ProjectModuleUnparsable,
      "It's the project module at `"
        <> path
        <> "`, which glance can't parse: it stopped at "
        <> stop(source, error)
        <> ".",
      "If `gleam build` accepts `"
        <> path
        <> "`, glance doesn't support its syntax yet, so please report it to glance.",
    )
    girard.NotFound, Ok(loader.Module(path:, parsed: Ok(_), ..)) -> #(
      ProjectModuleUnusable,
      "It's the project module at `"
        <> path
        <> "`, which parses, but girard couldn't use it.",
      girard_hint,
    )
    girard.NotFound, Error(Nil) -> #(
      NoSuchModule,
      "No module of the project or of its dependencies has that name.",
      "Check the import. If the module belongs to a dependency, `gleam deps download` fetches its sources.",
    )
  }
}

// Where glance stopped parsing a source, as `line L, column C`: where the
// loader's parse error points.
fn stop(source: LineIndex, error: glance.Error) -> String {
  let line_index.Position(line:, column:) =
    line_index.position(source, loader.error_label(source, error).span.start)
  "line " <> int.to_string(line) <> ", column " <> int.to_string(column)
}

fn missing_package(package: loader.Package) -> #(Gap, Diagnostic) {
  note(
    MissingPackage(package.name),
    code: "grice/missing-package",
    title: "A dependency's sources are missing",
    at: None,
    message: "The package `"
      <> package.name
      <> "` is in `manifest.toml`, but `"
      <> package.directory
      <> "/src` isn't a directory, so girard, the type inference grice uses, can't read its modules. Types that come from them may be incomplete.",
    hint: case package.source {
      loader.Hex | loader.Git -> "Run `gleam deps download`."
      loader.Local ->
        "Restore the directory, or fix the path dependency that points to it."
    },
  )
}

// The note that reports `gap`, at a span of the module at a path with a
// label, or with no location.
fn note(
  gap: Gap,
  code code: String,
  title title: String,
  at at: Option(#(String, glance.Span, String)),
  message message: String,
  hint hint: String,
) -> #(Gap, Diagnostic) {
  let location =
    option.map(at, fn(at) {
      let #(path, span, label) = at
      diagnostic.Location(
        path:,
        primary: diagnostic.Label(
          span: diagnostic.Span(start: span.start, end: span.end),
          message: label,
        ),
        secondary: [],
        fix: None,
      )
    })
  #(
    gap,
    Diagnostic(
      code:,
      severity: diagnostic.Note,
      title:,
      location:,
      message: [message],
      hint: Some(hint),
    ),
  )
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
// Each rule code under the `rules` of a `[[tools.grice.ignore]]` entry
// must name a rule of the run. A `grice/` code names one of grice's own
// diagnostics, which report on the run itself and can't be ignored, so it
// gets a message of its own.

fn check_ignores(config: Config, rules: List(Rule)) -> List(Diagnostic) {
  let codes = set.from_list(list.map(rules, rule.code))
  config.ignore
  |> list.index_map(fn(ignore, index) {
    let subject = config.ignore_key(index, "rules")
    list.filter_map(ignore.rules, check_ignore(subject, _, codes))
  })
  |> list.flatten
}

fn check_ignore(
  subject: String,
  code: String,
  codes: Set(String),
) -> Result(Diagnostic, Nil) {
  use <- bool.lazy_guard(
    when: string.starts_with(code, reserved_prefix),
    return: fn() { Ok(ignored_grice_code(subject, code)) },
  )
  use <- bool.guard(when: set.contains(codes, code), return: Error(Nil))
  Ok(unknown_ignored_code(subject, code))
}

fn unknown_ignored_code(subject: String, code: String) -> Diagnostic {
  config.diagnostic(
    title: "Unknown rule in `gleam.toml`",
    message: subject
      <> " in `gleam.toml` names the rule `"
      <> code
      <> "`, but no rule of this run has that code. An ignore that names no rule silences nothing, so it's most likely a typo or a rule that was removed.",
    hint: Some("Fix the code, or remove it from the list."),
  )
}

fn ignored_grice_code(subject: String, code: String) -> Diagnostic {
  config.diagnostic(
    title: "grice's own diagnostics can't be ignored",
    message: subject
      <> " in `gleam.toml` names `"
      <> code
      <> "`, one of grice's own diagnostics rather than a rule. Those report on the run itself, such as code grice couldn't read or configuration it couldn't use, so they can't be ignored.",
    hint: Some(
      "Remove the code from the list, and fix what it reports instead.",
    ),
  )
}
