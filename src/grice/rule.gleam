//// The API that writes rules, and the reports they make. For the rules
//// grice ships, see `grice/rules`.
////
//// A rule has a code, such as `my_app/no-echo`, by which ignores in
//// `gleam.toml` name it, and a title, the one-line summary printed with
//// each of its diagnostics. A code is a package-style prefix, a slash and a
//// kebab-case name. The `grice/` prefix is reserved for grice's own
//// diagnostics. Rules can't be run from the command line yet.
////
//// A module rule looks at one module at a time. It's built in stages:
//// `module` names it, `with_context` gives it the context it threads
//// through its hooks, the `on_*` functions add hooks, and `build` makes the
//// `Rule`. Each hook gets the context, the node it's called for and the
//// module's facts, and returns the new context with what it reports. A rule
//// that keeps no context passes `initial: Nil`:
////
//// ```gleam
//// import glance
//// import grice/rule
////
//// pub fn no_echo() -> rule.Rule {
////   rule.module("my_app/no-echo", title: "Echo left in the code")
////   |> rule.with_context(initial: Nil)
////   |> rule.on_expression(fn(context, expression, _module_facts) {
////     case expression {
////       glance.Echo(location:, ..) -> #(context, [
////         rule.report(at: location, label: "This prints when it runs")
////         |> rule.with_hint("Remove it once you're done debugging."),
////       ])
////       _ -> #(context, [])
////     }
////   })
////   |> rule.build
//// }
//// ```
////
//// The hooks are called during a `grice/visit` walk of the module: in
//// source order, each node's hook before its children and an exit hook
//// after them. Hooks of one kind run in the order they were added, and
//// every module starts from the `initial` context.
////
//// A project rule looks at every linted module together, in two steps.
//// `per_module` summarises each module on its own, and those summaries
//// are made in parallel. `final` then gets every summary, keyed by module
//// name in the order of the modules' paths, and returns its reports, each
//// keyed by the name of the module it's about:
////
//// ```gleam
//// import glance
//// import gleam/list
//// import grice/facts
//// import grice/rule
////
//// pub fn too_many_modules() -> rule.Rule {
////   rule.project("my_app/too-many-modules", title: "Too many modules")
////   |> rule.per_module(fn(module_facts) { facts.module_name(module_facts) })
////   |> rule.final(fn(summaries) {
////     list.drop(summaries, 100)
////     |> list.map(fn(summary) {
////       let #(module_name, _) = summary
////       #(module_name, rule.report(at: glance.Span(0, 0), label: "One too many"))
////     })
////   })
//// }
//// ```
////
//// A rule of either kind that needs types says so with `typed`, right
//// after `module` or `project`. Its hooks, or its `per_module` function,
//// then get `Typed` facts, which also answer what girard found: the type
//// of an expression, what a name resolved to and the type of a definition
//// (see `grice/facts`). girard runs once per run, and only when a rule in
//// the set is typed. This rule finds calls to `io.println` however it was
//// imported:
////
//// ```gleam
//// import girard
//// import glance
//// import grice/facts
//// import grice/rule
////
//// pub fn no_println() -> rule.Rule {
////   rule.module("my_app/no-println", title: "Printing to stdout")
////   |> rule.typed
////   |> rule.with_context(initial: Nil)
////   |> rule.on_expression(fn(context, expression, module_facts) {
////     let callee = case expression {
////       glance.Call(function:, ..) ->
////         facts.resolution_of(module_facts, function.location)
////       _ -> Error(facts.NotRecorded)
////     }
////     case callee {
////       Ok(girard.ModuleFn(module: "gleam/io", name: "println")) -> #(context, [
////         rule.report(at: expression.location, label: "This prints"),
////       ])
////       _ -> #(context, [])
////     }
////   })
////   |> rule.build
//// }
//// ```
////
//// Every rule reports with the severity `Warning` unless `with_severity`
//// says otherwise.

import glance
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import grice/diagnostic.{
  type Diagnostic, type Label, type Severity, Diagnostic, Location,
}
import grice/facts.{type ModuleFacts, type Syntax, type Typed}
import grice/internal/parallel
import grice/visit.{type Visitor}

// Rules
//
// A built rule, module or project, with its code, title and severity. What
// it runs is a closure over the facts, so a rule's context or summary type
// doesn't appear in `Rule`, and one list can hold any rules.

/// The prefix of grice's own diagnostic codes, which no rule may use and
/// nothing can hide.
@internal
pub const reserved_prefix = "grice/"

/// A rule, ready to be run. Build one with `build` or `final`.
pub opaque type Rule {
  Rule(
    code: String,
    title: String,
    severity: Severity,
    typed: Bool,
    check: Check,
  )
}

/// What running a rule does: a module rule's reports on one module, or a
/// project rule's reports on every linted module, each keyed by module
/// name.
@internal
pub type Check {
  ModuleCheck(run: fn(ModuleFacts(Syntax)) -> List(Report))
  ProjectCheck(run: fn(List(ModuleFacts(Syntax))) -> List(#(String, Report)))
}

/// Set the severity of the rule's diagnostics, which is `Warning` unless
/// set. Use it where the rule is built to choose its default, and in the
/// module that lists the rules to run to override it. The last severity set
/// is the one used.
pub fn with_severity(rule: Rule, severity: Severity) -> Rule {
  Rule(..rule, severity:)
}

/// The rule's code.
@internal
pub fn code(rule: Rule) -> String {
  rule.code
}

/// The rule's title.
@internal
pub fn title(rule: Rule) -> String {
  rule.title
}

/// Whether the rule was built with `typed`, so its facts need girard's
/// types.
@internal
pub fn is_typed(rule: Rule) -> Bool {
  rule.typed
}

/// What running the rule does.
@internal
pub fn check(rule: Rule) -> Check {
  rule.check
}

/// Whether `code` follows the syntax of rule codes, which rules, ignores
/// and suppressions all use: it matches
/// `[a-z][a-z0-9_]*/[a-z][a-z0-9]*(-[a-z0-9]+)*`, so the name is words
/// joined by single hyphens, none of them empty.
@internal
pub fn is_valid_code(code: String) -> Bool {
  case string.split(code, "/") {
    [prefix, name] ->
      is_word(prefix, rest: lowercase <> digits <> "_")
      && is_word(name, rest: lowercase <> digits <> "-")
      && !list.contains(string.split(name, "-"), "")
    _ -> False
  }
}

const lowercase = "abcdefghijklmnopqrstuvwxyz"

const digits = "0123456789"

// A lowercase letter followed by characters of `allowed`.
fn is_word(word: String, rest allowed: String) -> Bool {
  case string.to_graphemes(word) {
    [first, ..rest] ->
      string.contains(lowercase, first)
      && list.all(rest, string.contains(allowed, _))
    [] -> False
  }
}

// Schemas
//
// A rule of either kind starts as a schema: its code and title, and
// whether it needs types. The phantom `form` keeps module and project
// schemas apart, and the phantom `kind` is the kind of facts the rule will
// get. `typed` takes a `Syntax` schema, so it can't be applied twice, and
// the context or summary comes after it.

/// A rule that has a code and a title, but nothing to run yet. `form` is
/// `ModuleForm` for a module rule, which takes its context with
/// `with_context`, and `ProjectForm` for a project rule, which takes its
/// summary with `per_module`. `kind` is the kind of facts the rule gets:
/// `Syntax`, or `Typed` once `typed` has been applied.
pub opaque type Schema(form, kind) {
  Schema(code: String, title: String, typed: Bool)
}

/// The form of a module rule's schema, made by `module`.
pub type ModuleForm

/// The form of a project rule's schema, made by `project`.
pub type ProjectForm

/// Give the rule `Typed` facts, which answer what girard found about each
/// module, as well as everything `Syntax` facts hold. Apply it right after
/// `module` or `project`.
pub fn typed(schema: Schema(form, Syntax)) -> Schema(form, Typed) {
  Schema(code: schema.code, title: schema.title, typed: True)
}

// The rule a schema becomes once it has something to run, reporting
// warnings until `with_severity` says otherwise.
fn from_schema(schema: Schema(form, kind), check: Check) -> Rule {
  let Schema(code:, title:, typed:) = schema
  Rule(code:, title:, severity: diagnostic.Warning, typed:, check:)
}

// Module rules
//
// A module rule is named first, then given its context, and only then
// hooks, so every hook has the context's type. Each hook adds itself to the
// rule's `grice/visit` visitor, which is built once and walks every module.

/// A module rule with its context, ready to take hooks. Make it a `Rule`
/// with `build`.
pub opaque type ModuleRule(context, kind) {
  ModuleRule(
    schema: Schema(ModuleForm, kind),
    initial: context,
    visitor: Visitor(Walk(context, kind)),
    end: fn(context, ModuleFacts(kind)) -> List(Report),
  )
}

// The accumulator of a module rule's walk: the context, the reports of each
// hook call that made any, the latest first, and the module's facts.
type Walk(context, kind) {
  Walk(
    context: context,
    reports: List(List(Report)),
    module_facts: ModuleFacts(kind),
  )
}

/// Start a module rule with its code and title.
pub fn module(code: String, title title: String) -> Schema(ModuleForm, Syntax) {
  Schema(code:, title:, typed: False)
}

/// Give a module rule the context its hooks thread through a module, and
/// the value each module starts from. A rule that needs none passes
/// `initial: Nil`.
pub fn with_context(
  schema: Schema(ModuleForm, kind),
  initial initial: context,
) -> ModuleRule(context, kind) {
  ModuleRule(
    schema:,
    initial:,
    visitor: visit.new(),
    end: fn(_context, _module_facts) { [] },
  )
}

/// Call `hook` on each import, with its attributes.
pub fn on_import(
  rule: ModuleRule(context, kind),
  hook: fn(context, glance.Definition(glance.Import), ModuleFacts(kind)) ->
    #(context, List(Report)),
) -> ModuleRule(context, kind) {
  add_hook(rule, visit.on_import, hook)
}

/// Call `hook` on each custom type, with its attributes.
pub fn on_custom_type(
  rule: ModuleRule(context, kind),
  hook: fn(context, glance.Definition(glance.CustomType), ModuleFacts(kind)) ->
    #(context, List(Report)),
) -> ModuleRule(context, kind) {
  add_hook(rule, visit.on_custom_type, hook)
}

/// Call `hook` on each type alias, with its attributes.
pub fn on_type_alias(
  rule: ModuleRule(context, kind),
  hook: fn(context, glance.Definition(glance.TypeAlias), ModuleFacts(kind)) ->
    #(context, List(Report)),
) -> ModuleRule(context, kind) {
  add_hook(rule, visit.on_type_alias, hook)
}

/// Call `hook` on each constant, with its attributes.
pub fn on_constant(
  rule: ModuleRule(context, kind),
  hook: fn(context, glance.Definition(glance.Constant), ModuleFacts(kind)) ->
    #(context, List(Report)),
) -> ModuleRule(context, kind) {
  add_hook(rule, visit.on_constant, hook)
}

/// Call `hook` on each function, with its attributes, before anything
/// inside it.
pub fn on_function(
  rule: ModuleRule(context, kind),
  hook: fn(context, glance.Definition(glance.Function), ModuleFacts(kind)) ->
    #(context, List(Report)),
) -> ModuleRule(context, kind) {
  add_hook(rule, visit.on_function, hook)
}

/// Call `hook` on each function after everything inside it.
pub fn on_function_exit(
  rule: ModuleRule(context, kind),
  hook: fn(context, glance.Definition(glance.Function), ModuleFacts(kind)) ->
    #(context, List(Report)),
) -> ModuleRule(context, kind) {
  add_hook(rule, visit.on_function_exit, hook)
}

/// Call `hook` on each statement.
pub fn on_statement(
  rule: ModuleRule(context, kind),
  hook: fn(context, glance.Statement, ModuleFacts(kind)) ->
    #(context, List(Report)),
) -> ModuleRule(context, kind) {
  add_hook(rule, visit.on_statement, hook)
}

/// Call `hook` on each expression, before the expressions inside it.
pub fn on_expression(
  rule: ModuleRule(context, kind),
  hook: fn(context, glance.Expression, ModuleFacts(kind)) ->
    #(context, List(Report)),
) -> ModuleRule(context, kind) {
  add_hook(rule, visit.on_expression, hook)
}

/// Call `hook` on each expression after the expressions inside it.
pub fn on_expression_exit(
  rule: ModuleRule(context, kind),
  hook: fn(context, glance.Expression, ModuleFacts(kind)) ->
    #(context, List(Report)),
) -> ModuleRule(context, kind) {
  add_hook(rule, visit.on_expression_exit, hook)
}

/// Call `hook` on each pattern.
pub fn on_pattern(
  rule: ModuleRule(context, kind),
  hook: fn(context, glance.Pattern, ModuleFacts(kind)) ->
    #(context, List(Report)),
) -> ModuleRule(context, kind) {
  add_hook(rule, visit.on_pattern, hook)
}

/// Call `hook` on each type annotation and each type inside one.
pub fn on_type(
  rule: ModuleRule(context, kind),
  hook: fn(context, glance.Type, ModuleFacts(kind)) -> #(context, List(Report)),
) -> ModuleRule(context, kind) {
  add_hook(rule, visit.on_type, hook)
}

/// Call `hook` once the whole module has been walked, with the final
/// context.
pub fn on_module_end(
  rule: ModuleRule(context, kind),
  hook: fn(context, ModuleFacts(kind)) -> List(Report),
) -> ModuleRule(context, kind) {
  let previous = rule.end
  ModuleRule(..rule, end: fn(context, module_facts) {
    list.append(previous(context, module_facts), hook(context, module_facts))
  })
}

/// Make the module rule a `Rule`.
pub fn build(rule: ModuleRule(context, kind)) -> Rule {
  let ModuleRule(schema:, initial:, visitor:, end:) = rule
  let run = fn(module_facts: ModuleFacts(Syntax)) {
    let module_facts = facts.change_kind(module_facts)
    let Walk(context:, reports:, ..) =
      visit.module(
        facts.module(module_facts),
        from: Walk(context: initial, reports: [], module_facts:),
        with: visitor,
      )
    reports
    |> list.reverse
    |> list.flatten
    |> list.append(end(context, module_facts))
  }
  from_schema(schema, ModuleCheck(run))
}

// Add `hook` to the rule's visitor with `on`, the `grice/visit` function for
// its kind of node.
fn add_hook(
  rule: ModuleRule(context, kind),
  on: fn(
    Visitor(Walk(context, kind)),
    fn(Walk(context, kind), node) -> Walk(context, kind),
  ) -> Visitor(Walk(context, kind)),
  hook: fn(context, node, ModuleFacts(kind)) -> #(context, List(Report)),
) -> ModuleRule(context, kind) {
  ModuleRule(
    ..rule,
    visitor: on(rule.visitor, fn(walk, node) {
      case hook(walk.context, node, walk.module_facts) {
        #(context, []) -> Walk(..walk, context:)
        #(context, found) ->
          Walk(..walk, context:, reports: [found, ..walk.reports])
      }
    }),
  )
}

// Project rules
//
// A project rule is named first, then given the function that summarises
// one module, and `final` makes the `Rule`. The summary type only lives
// inside the closure `final` builds.

/// A project rule that summarises each module. Make it a `Rule` with
/// `final`.
pub opaque type ProjectRule(summary, kind) {
  ProjectRule(
    schema: Schema(ProjectForm, kind),
    summarise: fn(ModuleFacts(kind)) -> summary,
  )
}

/// Start a project rule with its code and title.
pub fn project(
  code: String,
  title title: String,
) -> Schema(ProjectForm, Syntax) {
  Schema(code:, title:, typed: False)
}

/// Summarise each linted module. The modules are summarised in parallel, so
/// `summarise` sees one module and nothing else.
pub fn per_module(
  schema: Schema(ProjectForm, kind),
  summarise: fn(ModuleFacts(kind)) -> summary,
) -> ProjectRule(summary, kind) {
  ProjectRule(schema:, summarise:)
}

/// Make the project rule a `Rule` that reports with `evaluate`. It gets
/// every module's summary, keyed by module name in the order of the
/// modules' paths, and returns each report keyed by the name of the module
/// it's about, which must be one of the modules it was given.
pub fn final(
  rule: ProjectRule(summary, kind),
  evaluate: fn(List(#(String, summary))) -> List(#(String, Report)),
) -> Rule {
  let ProjectRule(schema:, summarise:) = rule
  let run = fn(modules: List(ModuleFacts(Syntax))) {
    modules
    |> parallel.map(fn(module_facts) {
      #(
        facts.module_name(module_facts),
        summarise(facts.change_kind(module_facts)),
      )
    })
    |> evaluate
  }
  from_schema(schema, ProjectCheck(run))
}

// Reports
//
// What a rule found: where, and what to say about it. A report points into
// the module it's about with spans taken from that module's syntax tree.
// The diagnostic it becomes takes its code, title and severity from the
// rule.

/// One problem a rule found, which becomes one diagnostic.
pub opaque type Report {
  Report(
    // Each label's span, in glance's units, and its message.
    primary: #(glance.Span, String),
    secondary: List(#(glance.Span, String)),
    message: List(String),
    hint: Option(String),
  )
}

/// A report about the code at `span`, with `label` printed under it. The
/// label is a single line, and may be empty.
///
/// Spans count glance's units, as every span in the module's facts does:
/// bytes on Erlang and UTF-16 code units on JavaScript. grice turns them
/// into the byte offsets of the diagnostic. Every span of a report must be
/// a valid range of the module's source, as glance's spans are. grice drops
/// a report with an invalid span and reports a `grice/invalid-report` error
/// about the rule instead.
pub fn report(at span: glance.Span, label label: String) -> Report {
  Report(primary: #(span, label), secondary: [], message: [], hint: None)
}

/// Add a secondary label: related code that helps explain the problem.
/// The diagnostic keeps secondary labels in the order they were added, and
/// the human renderer shows them in source order.
pub fn with_label(
  report: Report,
  at span: glance.Span,
  label label: String,
) -> Report {
  Report(..report, secondary: list.append(report.secondary, [#(span, label)]))
}

/// Set the explanation, as paragraphs of plain, unwrapped text: what is
/// wrong and why it matters.
pub fn with_message(report: Report, paragraphs: List(String)) -> Report {
  Report(..report, message: paragraphs)
}

/// Set the hint: one suggestion on how to fix the problem.
pub fn with_hint(report: Report, hint: String) -> Report {
  Report(..report, hint: Some(hint))
}

/// The report's primary label and its secondary labels, in order, each as
/// its span in glance's units and its message.
@internal
pub fn report_labels(
  report: Report,
) -> #(#(glance.Span, String), List(#(glance.Span, String))) {
  #(report.primary, report.secondary)
}

/// The diagnostic a report by `rule` becomes, on the module at `path`,
/// with `labels`: the report's primary and secondary labels, their spans
/// turned into bytes.
@internal
pub fn to_diagnostic(
  rule: Rule,
  report: Report,
  path path: String,
  labels labels: #(Label, List(Label)),
) -> Diagnostic {
  let #(primary, secondary) = labels
  Diagnostic(
    code: rule.code,
    severity: rule.severity,
    title: rule.title,
    location: Some(Location(path:, primary:, secondary:, fix: None)),
    message: report.message,
    hint: report.hint,
  )
}
