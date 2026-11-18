//// Tests for what rules report, run with `grice/testing` as a rule's author
//// would. Module rules come first, then the facts, target view and
//// comments they see, then project rules. Then typed rules: the types
//// they see, what each query answers, and why a query has no answer. Last,
//// what a report becomes and its severity. Snapshots are titled
//// `rules: …`. Edge cases use small rules built in the test.

import birdie
import girard
import glance
import gleam/bool
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/string
import grice/diagnostic.{Diagnostic, Label}
import grice/facts.{type ModuleFacts, type Syntax, type Typed}
import grice/fixture_rules
import grice/internal/line_index
import grice/internal/typing
import grice/rule.{type Report, type Rule}
import grice/support
import grice/testing

// Module rules
//
// What module rules report, and how their hooks and their context run over
// the walk of each module.

pub fn no_echo_reports_each_echo_with_its_message_and_hint_test() {
  testing.module(support.echoes)
  |> testing.run([fixture_rules.no_echo()])
  |> testing.render
  |> birdie.snap(
    title: "rules: no_echo reports each echo with its message and hint",
  )
}

pub fn many_panics_threads_its_context_and_reports_at_the_function_test() {
  let wild =
    "pub fn wild(x) {\n  case x {\n    1 -> panic as \"one\"\n    _ -> panic\n  }\n}"
  let source = "pub fn calm() {\n  panic\n}\n\n" <> wild <> "\n"
  let assert [Diagnostic(code:, location: Some(location), ..)] =
    testing.module(source)
    |> testing.run([fixture_rules.many_panics()])
    |> testing.diagnostics
  assert code == "fixture/many-panics"
  assert location.primary
    == Label(
      span: support.span_of(source, wild),
      message: "This function panics in 2 places",
    )
}

pub fn on_module_end_sees_the_final_context_test() {
  let source = "pub fn a() { 1 }\npub fn b() { 2 }\nfn c() { 3 }\n"
  let labels =
    testing.module(source)
    |> testing.run([support.count_functions()])
    |> testing.diagnostics
    |> support.labels
  assert labels == ["3 functions"]
}

pub fn every_module_starts_from_the_initial_context_test() {
  let fixture =
    testing.project([
      #("src/one.gleam", "pub fn a() { 1 }\n"),
      #("src/two.gleam", "pub fn a() { 1 }\npub fn b() { 2 }\n"),
    ])
  let rules = [support.count_functions()]
  let first = testing.run(fixture, rules)
  let second = testing.run(fixture, rules)
  assert support.labels(testing.diagnostics(first))
    == ["1 functions", "2 functions"]
  assert second == first
}

pub fn one_rule_list_holds_rules_of_every_kind_test() {
  let diagnostics =
    testing.project([
      #("src/one.gleam", "pub fn shared() {\n  echo 1\n}\n"),
      #("src/two.gleam", "pub fn shared() {\n  panic\n  panic\n}\n"),
    ])
    |> testing.run([
      fixture_rules.no_echo(),
      fixture_rules.many_panics(),
      fixture_rules.duplicate_public_function(),
    ])
    |> testing.diagnostics
  assert support.describe(diagnostics)
    == [
      "fixture/duplicate-public-function src/one.gleam: `two` also defines `shared`",
      "fixture/no-echo src/one.gleam: This prints when it runs",
      "fixture/duplicate-public-function src/two.gleam: `one` also defines `shared`",
      "fixture/many-panics src/two.gleam: This function panics in 2 places",
    ]
}

pub fn every_hook_is_called_during_the_walk_test() {
  let source =
    "import gleam/list\ntype T { T(Int) }\ntype A = Int\nconst c = 1\nfn f(x: Int) { let y = x\n y }\n"
  let every_hook =
    rule.module("fixture/every-hook", title: "Every hook")
    |> rule.with_context(initial: Nil)
    |> rule.on_import(report_as("import"))
    |> rule.on_custom_type(report_as("custom_type"))
    |> rule.on_type_alias(report_as("type_alias"))
    |> rule.on_constant(report_as("constant"))
    |> rule.on_function(report_as("function"))
    |> rule.on_function_exit(report_as("function_exit"))
    |> rule.on_statement(report_as("statement"))
    |> rule.on_expression(report_as("expression"))
    |> rule.on_expression_exit(report_as("expression_exit"))
    |> rule.on_pattern(report_as("pattern"))
    |> rule.on_type(report_as("type"))
    |> rule.on_module_end(fn(_context, _facts) {
      [support.at_start("module_end")]
    })
    |> rule.build
  // Every report is at the same span, so they stay in the order made.
  let labels =
    testing.module(source)
    |> testing.run([every_hook])
    |> testing.diagnostics
    |> support.labels
  assert labels
    == [
      "import", "custom_type", "type", "type_alias", "type", "constant",
      "expression", "expression_exit", "function", "type", "statement",
      "pattern", "expression", "expression_exit", "statement", "expression",
      "expression_exit", "function_exit", "module_end",
    ]
}

pub fn hooks_of_one_kind_run_in_the_order_added_test() {
  let in_order =
    rule.module("fixture/in-order", title: "In order")
    |> rule.with_context(initial: "")
    |> rule.on_expression(fn(context, _expression, _facts) {
      #(context <> "a", [])
    })
    |> rule.on_expression(fn(context, _expression, _facts) {
      #(context <> "b", [support.at_start(context <> "b")])
    })
    |> rule.on_module_end(fn(context, _facts) {
      [support.at_start("end 1 " <> context)]
    })
    |> rule.on_module_end(fn(context, _facts) {
      [support.at_start("end 2 " <> context)]
    })
    |> rule.build
  let labels =
    testing.module("fn f() {\n  x\n  y\n}\n")
    |> testing.run([in_order])
    |> testing.diagnostics
    |> support.labels
  assert labels == ["ab", "abab", "end 1 abab", "end 2 abab"]
}

// Facts
//
// What a rule's facts say about its module, as compiled for the target.

pub fn facts_describe_the_module_as_compiled_for_the_target_test() {
  let source =
    "import gleam/list
@target(javascript)
import gleam/javascript_only
pub const first_constant = 1
pub type FirstType { FirstType }
pub fn first_function() { 1 }
import app/other
type FirstAlias = Int
const second_constant = 2
type SecondType { SecondType }
fn second_function() { 2 }
type SecondAlias = Int
@target(javascript)
fn javascript_function() { 3 }
"
  let assert [Diagnostic(message:, ..)] =
    testing.project([#("src/app.gleam", source), #("src/app/other.gleam", "")])
    |> testing.run([describe_facts("app")])
    |> testing.diagnostics
  assert message
    == [
      "app",
      "src/app.gleam",
      source,
      "gleam/list, app/other",
      "gleam/list, app/other",
      "FirstType, SecondType",
      "FirstAlias, SecondAlias",
      "first_constant, second_constant",
      "first_function, second_function",
    ]
}

// Target
//
// Rules see only the definitions compiled for the configured target, by
// either spelling of its name.

const target_module =
  "pub fn shared() { 1 }
@target(javascript)
pub fn javascript_echo() { echo 1 }
@target(js)
pub fn js_function() { 2 }
@target(erlang)
pub fn erlang_echo() { echo 2 }
@target(erl)
pub fn erl_function() { 3 }
"

const target_other =
  "pub fn javascript_echo() { 4 }
pub fn js_function() { 5 }
pub fn erlang_echo() { 6 }
pub fn erl_function() { 7 }
"

pub fn rules_see_only_erlang_definitions_on_erlang_test() {
  assert findings_on_target("erlang")
    == [
      "fixture/duplicate-public-function src/app.gleam: `other` also defines `erlang_echo`",
      "fixture/no-echo src/app.gleam: This prints when it runs",
      "fixture/duplicate-public-function src/app.gleam: `other` also defines `erl_function`",
      "fixture/duplicate-public-function src/other.gleam: `app` also defines `erlang_echo`",
      "fixture/duplicate-public-function src/other.gleam: `app` also defines `erl_function`",
    ]
}

pub fn rules_see_only_javascript_definitions_on_javascript_test() {
  assert findings_on_target("javascript")
    == [
      "fixture/duplicate-public-function src/app.gleam: `other` also defines `javascript_echo`",
      "fixture/no-echo src/app.gleam: This prints when it runs",
      "fixture/duplicate-public-function src/app.gleam: `other` also defines `js_function`",
      "fixture/duplicate-public-function src/other.gleam: `app` also defines `javascript_echo`",
      "fixture/duplicate-public-function src/other.gleam: `app` also defines `js_function`",
    ]
}

// What the echo and duplicate rules find in the two target modules on
// `target`.
fn findings_on_target(target: String) -> List(String) {
  testing.project([
    #("gleam.toml", "target = \"" <> target <> "\"\n"),
    #("src/app.gleam", target_module),
    #("src/other.gleam", target_other),
  ])
  |> testing.run([
    fixture_rules.no_echo(),
    fixture_rules.duplicate_public_function(),
  ])
  |> testing.diagnostics
  |> support.describe
}

// Comments
//
// The comments `facts.comments` gives, which glance's syntax tree leaves
// out, with their spans in glance's units.

pub fn comments_come_in_source_order_with_kind_span_and_text_test() {
  let source =
    "//// The module.
/// The function.
pub fn main() {
  // In the body.
  let text = \"// not a comment\" // After code.
  text
}
// At the end, with no newline."
  assert comments_of("", source)
    == [
      expected_comment(source, "////", " The module."),
      expected_comment(source, "///", " The function."),
      expected_comment(source, "//", " In the body."),
      expected_comment(source, "//", " After code."),
      expected_comment(source, "//", " At the end, with no newline."),
    ]
}

// Spans count what the syntax tree counts: on Erlang `é` is two bytes and
// `🙂` four, so the first comment spans 13, and on JavaScript they're one
// and two UTF-16 code units, so it spans 10. The `\r` of each line ending
// is in neither the text nor the span.
pub fn comment_spans_count_glances_units_and_skip_carriage_returns_test() {
  let source = "// café 🙂\r\npub fn main() {\r\n  1 // one\r\n}\r\n"
  let first = case line_index.tree_units() {
    line_index.Bytes -> "// 0-13 \" café 🙂\""
    line_index.CodeUnits -> "// 0-10 \" café 🙂\""
  }
  assert comments_of("", source)
    == [first, expected_comment(source, "//", " one")]
}

const target_comments =
  "// Above the attribute.
@target(javascript)
// Between the attribute and the function.
pub fn javascript() {
  // In JavaScript.
  1
}
@target(erlang)
pub fn erlang() {
  // In Erlang.
  2
}
@target(erlang)
const erlang_constant = #(
  // In an Erlang constant.
  1,
)
@target(javascript)
import gleam/list.{
  // In a JavaScript import.
  map,
}
@target(js)
type JavaScriptType {
  // In a JavaScript custom type.
  JavaScriptType
}
@target(erl)
type ErlangAlias =
  #(
    // In an Erlang alias.
    Int,
  )
// After them all.
"

pub fn comments_inside_definitions_for_the_other_target_are_left_out_test() {
  let comment = expected_comment(target_comments, "//", _)
  let around = [
    comment(" Above the attribute."),
    comment(" Between the attribute and the function."),
  ]
  assert comments_of("target = \"erlang\"\n", target_comments)
    == list.flatten([
      around,
      [
        comment(" In Erlang."),
        comment(" In an Erlang constant."),
        comment(" In an Erlang alias."),
      ],
      [comment(" After them all.")],
    ])
  assert comments_of("target = \"javascript\"\n", target_comments)
    == list.flatten([
      around,
      [
        comment(" In JavaScript."),
        comment(" In a JavaScript import."),
        comment(" In a JavaScript custom type."),
      ],
      [comment(" After them all.")],
    ])
}

pub fn syntax_and_typed_rules_see_the_same_comments_test() {
  let source = "/// Docs.\npub fn main() {\n  // Body.\n  1\n}\n"
  let rules = [
    support.on_module_end("fixture/syntax-comments", report_comments),
    support.typed_on_module_end("fixture/typed-comments", report_comments),
  ]
  let assert [syntax, typed] =
    testing.module(source) |> testing.run(rules) |> testing.diagnostics
  assert syntax.message == typed.message
  assert syntax.message == comments_of("", source)
}

// What `facts.comments` gives for `source`, as `src/app.gleam` with the
// `gleam.toml` text `toml`, each as `report_comments` describes it.
fn comments_of(toml: String, source: String) -> List(String) {
  let rule = support.on_module_end("fixture/comments", report_comments)
  let assert [Diagnostic(message:, ..)] =
    testing.project([#("gleam.toml", toml), #("src/app.gleam", source)])
    |> testing.run([rule])
    |> testing.diagnostics
  message
}

// How `report_comments` describes the comment `marker <> text`, found in
// `source`.
fn expected_comment(source: String, marker: String, text: String) -> String {
  let span = support.glance_span(source, marker <> text)
  describe_comment(facts.Comment(
    kind: case marker {
      "////" -> facts.ModuleDoc
      "///" -> facts.Doc
      _ -> facts.Regular
    },
    span:,
    text:,
  ))
}

// Project rules
//
// What project rules report, and the order their summaries come in.

pub fn duplicate_public_function_reports_on_every_module_defining_it_test() {
  let diagnostics =
    testing.project([
      #("src/a.gleam", "pub fn shared() { 1 }\npub fn alone() { 2 }\n"),
      #("src/b.gleam", "fn shared() { 3 }\n"),
      #("src/c.gleam", "pub fn other() { 4 }\npub fn shared() { 5 }\n"),
      #("src/d.gleam", "pub fn shared() { 6 }\n"),
    ])
    |> testing.run([fixture_rules.duplicate_public_function()])
    |> testing.diagnostics
  // Each label names the first other module that defines the function.
  assert support.describe(diagnostics)
    == [
      "fixture/duplicate-public-function src/a.gleam: `c` also defines `shared`",
      "fixture/duplicate-public-function src/c.gleam: `a` also defines `shared`",
      "fixture/duplicate-public-function src/d.gleam: `a` also defines `shared`",
    ]
  let assert [_, Diagnostic(location: Some(location), ..), _] = diagnostics
  assert location.primary.span
    == support.span_of(
      "pub fn other() { 4 }\npub fn shared() { 5 }\n",
      "pub fn shared() { 5 }",
    )
}

pub fn project_rules_get_the_summaries_in_lint_set_order_test() {
  let labels =
    testing.project([
      #("src/zeta.gleam", ""),
      #("src/alpha.gleam", ""),
      #("src/mid/one.gleam", ""),
    ])
    |> testing.run([support.module_order()])
    |> testing.diagnostics
    |> support.labels
  assert labels == ["alpha, mid/one, zeta"]
}

// Typed rules
//
// Rules that need types, module and project rules alike, and what girard
// tells them.

pub fn discarded_result_reports_a_discarded_prelude_result_test() {
  testing.module(support.discards)
  |> testing.run([fixture_rules.discarded_result()])
  |> testing.render
  |> birdie.snap(
    title: "rules: discarded_result reports a discarded prelude result",
  )
}

pub fn a_typed_project_rule_sees_types_in_per_module_test() {
  let signatures =
    rule.project("fixture/signatures", title: "Made in a test")
    |> rule.typed
    |> rule.per_module(fn(module_facts) {
      facts.signature(module_facts, "parse")
      |> result.map(fn(scheme) { girard.type_to_string(scheme.type_) })
    })
    |> rule.final(fn(summaries) {
      use #(name, signature) <- list.map(summaries)
      #(name, support.at_start(string.inspect(signature)))
    })
  let labels =
    testing.module(support.discards)
    |> testing.run([signatures])
    |> testing.diagnostics
    |> support.labels
  assert labels
    == [
      "Ok(\"fn() -> Result(Int, Nil)\")",
      "girard couldn't type this definition",
    ]
}

// `typed_calls` reports on the call into the other module on each target.
pub fn typed_rules_see_types_across_target_specific_imports_test() {
  let on_target = fn(files) {
    testing.project(files)
    |> testing.run([support.typed_calls()])
    |> testing.diagnostics
    |> support.describe
  }
  assert on_target(support.crossed) == ["fixture/typed-calls src/a.gleam: b.B"]
  assert on_target([
      #("gleam.toml", "target = \"javascript\"\n"),
      ..support.crossed
    ])
    == ["fixture/typed-calls src/b.gleam: a.A"]
}

// Queries
//
// What each type query answers, over a module that imports the dependency
// module `dep/box`.

pub fn type_of_answers_for_expressions_test() {
  let int_type = girard.Named("gleam", "Int", [])
  let string_type = girard.Named("gleam", "String", [])
  assert answers(support.queried, fn(module_facts) {
      list.map(
        ["42", "box.shout(\"hi\")", "identity(n)", "\"hey\" |> box.shout"],
        fn(needle) {
          facts.type_of(
            module_facts,
            support.glance_span(support.queried, needle),
          )
        },
      )
    })
    == [Ok(int_type), Ok(string_type), Ok(int_type), Ok(string_type)]
}

pub fn resolution_of_answers_for_references_test() {
  let references = [
    #("box.shout(\"hi\")", "box.shout"),
    #("Point(1, 2)", "Point"),
    #("point.x", "point.x"),
    #("f(same)", "f"),
  ]
  assert answers(support.queried, fn(module_facts) {
      use #(around, reference) <- list.map(references)
      facts.resolution_of(
        module_facts,
        glance_span_in(support.queried, around, reference),
      )
    })
    == [
      Ok(girard.ModuleFn("dep/box", "shout")),
      Ok(girard.Constructor("app", "Point")),
      Ok(girard.RecordField(girard.Named("app", "Point", []), "x")),
      Ok(girard.LocalVariable("f")),
    ]
}

pub fn signature_answers_for_functions_and_constants_test() {
  assert answers(support.queried, fn(module_facts) {
      let assert Ok(girard.Scheme(vars:, type_:)) =
        facts.signature(module_facts, "identity")
      #(
        girard.type_to_string(type_),
        list.length(vars),
        facts.signature(module_facts, "origin"),
      )
    })
    == #(
      "fn(a) -> a",
      1,
      Ok(girard.Scheme([], girard.Named("app", "Point", []))),
    )
}

// Unknown
//
// Why a query has no answer, and a typed rule's silence where girard's
// answer can't be trusted.

const unknowns =
  "@target(javascript)
pub fn elsewhere() {
  \"js\"
}

pub fn main() {
  let pattern = 1
  pattern
}

// girard can't type this function, and neither could the compiler.
pub fn skipped() {
  let inside = 2
  inside + \"two\"
}
"

pub fn queries_say_why_girard_has_no_answer_test() {
  let #(types, signatures, resolution) =
    answers(unknowns, fn(module_facts) {
      #(
        list.map(["pattern", "2", "\"js\""], fn(needle) {
          facts.type_of(module_facts, support.glance_span(unknowns, needle))
        }),
        list.map(["pattern", "skipped", "elsewhere", "Point"], fn(name) {
          facts.signature(module_facts, name)
        }),
        facts.resolution_of(
          module_facts,
          support.glance_span(unknowns, "inside + \"two\""),
        ),
      )
    })
  assert types
    == [
      Error(facts.NotRecorded),
      Error(facts.Skipped("skipped")),
      Error(facts.Dropped("elsewhere")),
    ]
  assert signatures
    == [
      Error(facts.NotRecorded),
      Error(facts.Skipped("skipped")),
      Error(facts.Dropped("elsewhere")),
      Error(facts.NotRecorded),
    ]
  assert resolution == Error(facts.Skipped("skipped"))
}

// `d` is unavailable, so girard reads `Result` as the prelude's: an answer
// no rule can tell from a real one.
const shadowed =
  "import d.{type Result}

fn parse() -> Result(Int, String) {
  Ok(1)
}

pub fn main() {
  let _ = parse()
  Nil
}
"

pub fn discarded_result_is_silent_where_a_prelude_name_is_shadowed_test() {
  let project = support.project("", [#("src/app.gleam", shadowed)], [])
  let assert Ok(types) =
    typing.infer(project, typing.resolver(project)) |> dict.get("app")
  let assert Ok(girard.Named(module: "gleam", name: "Result", ..)) =
    dict.get(
      types.expressions,
      glance_span_in(shadowed, "let _ = parse()", "parse()"),
    )
  // The rule stays silent, and the note says why.
  testing.module(shadowed)
  |> testing.run([fixture_rules.discarded_result()])
  |> testing.expect_codes(["grice/unavailable-import"])
}

// What `ask` answers on the module `app`, whose source is `source`, with
// the dependency module `dep/box`, given the facts a typed rule gets, built
// as the runner builds them. The answers are values, compared as they are.
fn answers(source: String, ask: fn(ModuleFacts(Typed)) -> a) -> a {
  let project =
    support.project("", [#("src/app.gleam", source)], [
      #("dep/box", support.box),
    ])
  let types = typing.infer(project, typing.resolver(project))
  let assert Ok(module) = dict.get(project.modules, "app")
  let assert Ok(module_facts) =
    facts.new(
      module,
      project.config.target,
      option.from_result(dict.get(types, "app")),
    )
  ask(facts.change_kind(module_facts))
}

// Resolution
//
// What a report becomes: a diagnostic with the rule's code, title and
// severity, and the module's path.

pub fn reports_become_diagnostics_with_the_rule_and_the_module_test() {
  let source = "pub fn main() {\n  let x = 1\n  x\n}\n"
  let explained =
    support.on_module_end("fixture/explained", fn(_facts) {
      [
        rule.report(at: support.glance_span(source, "x\n}"), label: "used here")
        |> rule.with_label(
          at: support.glance_span(source, "x = 1"),
          label: "bound here",
        )
        |> rule.with_label(at: support.glance_span(source, "main"), label: "")
        |> rule.with_message(["First paragraph.", "Second paragraph."])
        |> rule.with_hint("A hint."),
      ]
    })
  testing.module(source)
  |> testing.run([explained])
  |> testing.render
  |> birdie.snap(
    title: "rules: a report becomes a diagnostic with the rule and the module",
  )
}

// Severity
//
// Rules report warnings unless `rule.with_severity` sets another severity.

pub fn rules_default_to_warnings_test() {
  assert severities([fixture_rules.no_echo(), support.module_order()])
    == [diagnostic.Warning, diagnostic.Warning]
}

pub fn with_severity_sets_the_severity_of_any_rule_test() {
  assert severities([
      fixture_rules.no_echo() |> rule.with_severity(diagnostic.Error),
      support.module_order() |> rule.with_severity(diagnostic.Note),
    ])
    == [diagnostic.Note, diagnostic.Error]
}

pub fn with_severity_keeps_the_last_severity_test() {
  assert severities([
      fixture_rules.no_echo()
        |> rule.with_severity(diagnostic.Error)
        |> rule.with_severity(diagnostic.Note),
      support.module_order()
        |> rule.with_severity(diagnostic.Note)
        |> rule.with_severity(diagnostic.Error),
    ])
    == [diagnostic.Error, diagnostic.Note]
}

// The severity of each diagnostic of the rules run on one module with an
// `echo`.
fn severities(rules: List(Rule)) -> List(diagnostic.Severity) {
  testing.module("pub fn f() { echo 1 }\n")
  |> testing.run(rules)
  |> testing.diagnostics
  |> list.map(fn(found) { found.severity })
}

// Rules made in the tests
//
// Rules that report what their facts hold, for the tests above to compare.

// Reports on the module named `name` what its facts hold, one paragraph
// each.
fn describe_facts(name: String) -> Rule {
  use module_facts <- support.on_module_end("fixture/describe-facts")
  use <- bool.guard(when: facts.module_name(module_facts) != name, return: [])
  let module = facts.module(module_facts)
  [
    support.at_start("facts")
    |> rule.with_message([
      facts.module_name(module_facts),
      facts.path(module_facts),
      facts.source(module_facts),
      string.join(facts.imports(module_facts), ", "),
      names(module.imports, fn(import_: glance.Import) { import_.module }),
      names(module.custom_types, fn(custom_type: glance.CustomType) {
        custom_type.name
      }),
      names(module.type_aliases, fn(alias: glance.TypeAlias) { alias.name }),
      names(module.constants, fn(constant: glance.Constant) { constant.name }),
      names(module.functions, fn(function: glance.Function) { function.name }),
    ]),
  ]
}

// Reports the module's comments, one paragraph each.
fn report_comments(module_facts: ModuleFacts(kind)) -> List(Report) {
  [
    support.at_start("comments")
    |> rule.with_message(list.map(
      facts.comments(module_facts),
      describe_comment,
    )),
  ]
}

// A comment as its marker, its span and its text, such as
// `// 0-6 " TODO"`.
fn describe_comment(comment: facts.Comment) -> String {
  let marker = case comment.kind {
    facts.Regular -> "//"
    facts.Doc -> "///"
    facts.ModuleDoc -> "////"
  }
  marker
  <> " "
  <> int.to_string(comment.span.start)
  <> "-"
  <> int.to_string(comment.span.end)
  <> " "
  <> string.inspect(comment.text)
}

// The name of each definition, joined with commas.
fn names(
  definitions: List(glance.Definition(definition)),
  name_of: fn(definition) -> String,
) -> String {
  definitions
  |> list.map(fn(definition) { name_of(definition.definition) })
  |> string.join(", ")
}

// A hook that reports `name` at the start of the module.
fn report_as(
  name: String,
) -> fn(context, node, ModuleFacts(Syntax)) -> #(context, List(Report)) {
  fn(context, _node, _facts) { #(context, [support.at_start(name)]) }
}

// Helpers
//
// Finding spans in a source.

// The span of the first `needle` inside the first `around` in `source`.
fn glance_span_in(
  source: String,
  around: String,
  needle: String,
) -> glance.Span {
  let outer = support.glance_span(source, around)
  let inner = support.glance_span(around, needle)
  glance.Span(outer.start + inner.start, outer.start + inner.end)
}
