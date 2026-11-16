//// Tests for running rules. Projects are built in memory with
//// `loader.load`. The fixture rules come first: module rules, then the
//// facts, target view and comments they see, then project rules and which modules
//// rules run on. Then typed rules: the types they see, why a query has no
//// answer, when girard runs, and a typed run from a project on disk. Then
//// how reports become diagnostics: resolution, severity and invalid
//// reports. Then the checks of the rule set and of the codes `gleam.toml`
//// ignores, and last what ignores and suppressions hide. Edge cases use
//// small rules built in the test.

import girard
import glance
import gleam/bool
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import grice/diagnostic.{type Diagnostic, Diagnostic, Label, Location, Span}
import grice/facts.{type ModuleFacts, type Syntax, type Typed}
import grice/fixture_rules
import grice/internal/config
import grice/internal/line_index
import grice/internal/loader.{type Project}
import grice/internal/render/human
import grice/internal/runner
import grice/internal/typing.{type ModuleTypes}
import grice/rule.{type Report, type Rule}
import grice/support
import simplifile

// Module rules

const echoes = "pub fn main() {\n  echo 1\n  echo 2 as \"two\"\n}\n"

pub fn no_echo_reports_each_echo_with_its_message_and_hint_test() {
  let diagnostics =
    run_files([#("src/app.gleam", echoes)], [fixture_rules.no_echo()])
  assert diagnostics
    == [
      echo_diagnostic(span_of(echoes, "echo 1")),
      echo_diagnostic(span_of(echoes, "echo 2 as \"two\"")),
    ]
}

pub fn many_panics_threads_its_context_and_reports_at_the_function_test() {
  let wild =
    "pub fn wild(x) {\n  case x {\n    1 -> panic as \"one\"\n    _ -> panic\n  }\n}"
  let source = "pub fn calm() {\n  panic\n}\n\n" <> wild <> "\n"
  let assert [Diagnostic(code:, location: Some(location), ..)] =
    run_files([#("src/app.gleam", source)], [fixture_rules.many_panics()])
  assert code == "fixture/many-panics"
  assert location.primary
    == Label(
      span: span_of(source, wild),
      message: "This function panics in 2 places",
    )
}

pub fn on_module_end_sees_the_final_context_test() {
  let source = "pub fn a() { 1 }\npub fn b() { 2 }\nfn c() { 3 }\n"
  assert labels(run_files([#("src/app.gleam", source)], [count_functions()]))
    == ["3 functions"]
}

pub fn every_module_starts_from_the_initial_context_test() {
  let files = [
    #("src/one.gleam", "pub fn a() { 1 }\n"),
    #("src/two.gleam", "pub fn a() { 1 }\npub fn b() { 2 }\n"),
  ]
  let rules = [count_functions()]
  let project = support.project("", files, [])
  let assert Ok(first) = runner.run(project, rules)
  let assert Ok(second) = runner.run(project, rules)
  assert labels(first.diagnostics) == ["1 functions", "2 functions"]
  assert second == first
}

pub fn one_rule_list_holds_rules_of_every_kind_test() {
  let files = [
    #("src/one.gleam", "pub fn shared() {\n  echo 1\n}\n"),
    #("src/two.gleam", "pub fn shared() {\n  panic\n  panic\n}\n"),
  ]
  let rules = [
    fixture_rules.no_echo(),
    fixture_rules.many_panics(),
    fixture_rules.duplicate_public_function(),
  ]
  assert describe(run_files(files, rules))
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
    |> rule.on_module_end(fn(_context, _facts) { [at_start("module_end")] })
    |> rule.build
  // Every report is at the same span, so they stay in the order made.
  assert labels(run_files([#("src/app.gleam", source)], [every_hook]))
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
      #(context <> "b", [at_start(context <> "b")])
    })
    |> rule.on_module_end(fn(context, _facts) {
      [at_start("end 1 " <> context)]
    })
    |> rule.on_module_end(fn(context, _facts) {
      [at_start("end 2 " <> context)]
    })
    |> rule.build
  let source = "fn f() {\n  x\n  y\n}\n"
  assert labels(run_files([#("src/app.gleam", source)], [in_order]))
    == ["ab", "abab", "end 1 abab", "end 2 abab"]
}

// Facts

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
  let files = [#("src/app.gleam", source), #("src/app/other.gleam", "")]
  let assert [Diagnostic(message:, ..)] =
    run_files(files, [describe_facts("app")])
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
  run_files_with(
    "target = \"" <> target <> "\"\n",
    [#("src/app.gleam", target_module), #("src/other.gleam", target_other)],
    [fixture_rules.no_echo(), fixture_rules.duplicate_public_function()],
  )
  |> describe
}

// Comments

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

// Spans are bytes: `é` is two and `🙂` four, so the first comment spans
// 13, and the `\r` of each line ending is in neither the text nor the span.
pub fn comment_spans_count_bytes_and_skip_carriage_returns_test() {
  let source = "// café 🙂\r\npub fn main() {\r\n  1 // one\r\n}\r\n"
  assert comments_of("", source)
    == ["// 0-13 \" café 🙂\"", expected_comment(source, "//", " one")]
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
    on_module_end("fixture/syntax-comments", report_comments),
    typed_on_module_end("fixture/typed-comments", report_comments),
  ]
  let assert [syntax, typed] = run_files([#("src/app.gleam", source)], rules)
  assert syntax.message == typed.message
  assert syntax.message == comments_of("", source)
}

// What `facts.comments` gives for `source`, as `src/app.gleam` with the
// `gleam.toml` text `toml`, each as `report_comments` describes it.
fn comments_of(toml: String, source: String) -> List(String) {
  let rule = on_module_end("fixture/comments", report_comments)
  let assert [Diagnostic(message:, ..)] =
    run_files_with(toml, [#("src/app.gleam", source)], [rule])
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

pub fn duplicate_public_function_reports_on_every_module_defining_it_test() {
  let files = [
    #("src/a.gleam", "pub fn shared() { 1 }\npub fn alone() { 2 }\n"),
    #("src/b.gleam", "fn shared() { 3 }\n"),
    #("src/c.gleam", "pub fn other() { 4 }\npub fn shared() { 5 }\n"),
    #("src/d.gleam", "pub fn shared() { 6 }\n"),
  ]
  let diagnostics =
    run_files(files, [fixture_rules.duplicate_public_function()])
  // Each label names the first other module that defines the function.
  assert describe(diagnostics)
    == [
      "fixture/duplicate-public-function src/a.gleam: `c` also defines `shared`",
      "fixture/duplicate-public-function src/c.gleam: `a` also defines `shared`",
      "fixture/duplicate-public-function src/d.gleam: `a` also defines `shared`",
    ]
  let assert [_, Diagnostic(location: Some(location), ..), _] = diagnostics
  assert location.primary.span
    == span_of(
      "pub fn other() { 4 }\npub fn shared() { 5 }\n",
      "pub fn shared() { 5 }",
    )
}

pub fn project_rules_get_the_summaries_in_lint_set_order_test() {
  let files = [
    #("src/zeta.gleam", ""),
    #("src/alpha.gleam", ""),
    #("src/mid/one.gleam", ""),
  ]
  assert labels(run_files(files, [module_order()])) == ["alpha, mid/one, zeta"]
}

// Lint set only

pub fn rules_run_on_parsed_lint_set_modules_only_test() {
  let toml = "[tools.grice]\nexclude = [\"src/app/gen/\"]\n"
  let files = [
    #("src/app.gleam", "import app/gen/a\npub fn f() { echo 1 }\n"),
    #("src/app/gen/a.gleam", "pub fn g() { echo 2 }\n"),
    #("src/broken.gleam", "pub fn ("),
  ]
  let project = support.project(toml, files, [])
  assert dict.has_key(project.modules, "app/gen/a")
  let assert Ok(runner.Linted(diagnostics:, ..)) =
    runner.run(project, [
      fixture_rules.no_echo(),
      module_order(),
      count_functions(),
    ])
  assert describe(diagnostics)
    == [
      "fixture/count-functions src/app.gleam: 1 functions",
      "fixture/module-order src/app.gleam: app",
      "fixture/no-echo src/app.gleam: This prints when it runs",
      "grice/parse-error src/broken.gleam: glance didn't expect this",
    ]
}

// Typed rules

const discards =
  "fn parse() -> Result(Int, Nil) {
  Ok(1)
}

pub fn main() {
  let _ = parse()
  let _ = 1
  let _ = Ok(\"two\")
  Nil
}

// girard can't type this function, and neither could the compiler.
pub fn skipped() {
  let _ = parse()
  1 + \"one\"
}
"

pub fn discarded_result_reports_a_discarded_prelude_result_test() {
  let diagnostics =
    run_files([#("src/app.gleam", discards)], [fixture_rules.discarded_result()])
    |> list.filter(fn(found) { found.code == "fixture/discarded-result" })
  assert diagnostics
    == [
      discarded_diagnostic(span_of(discards, "let _ = parse()")),
      discarded_diagnostic(span_of(discards, "let _ = Ok(\"two\")")),
    ]
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
      #(name, at_start(string.inspect(signature)))
    })
  assert labels(run_files([#("src/app.gleam", discards)], [signatures]))
    == [
      "Ok(\"fn() -> Result(Int, Nil)\")",
      "girard couldn't type this definition",
    ]
}

// `typed_calls` reports on the call into the other module on each target.
pub fn typed_rules_see_types_across_target_specific_imports_test() {
  let files = support.crossed
  assert describe(run_files(files, [typed_calls()]))
    == ["fixture/typed-calls src/a.gleam: Ok(Named(\"b\", \"B\", []))"]
  assert describe(
      run_files_with("target = \"javascript\"\n", files, [typed_calls()]),
    )
    == ["fixture/typed-calls src/b.gleam: Ok(Named(\"a\", \"A\", []))"]
}

// Queries

const box =
  "pub type Box {\n  Box(content: String)\n}\n\npub fn shout(text: String) -> String {\n  text\n}\n"

const queried =
  "import dep/box

pub type Point {
  Point(x: Int, y: Int)
}

pub const origin = Point(0, 0)

pub fn identity(value) {
  value
}

pub fn main() {
  let n = 42
  let loud = box.shout(\"hi\")
  let same = identity(n)
  let piped = \"hey\" |> box.shout
  let point = Point(1, 2)
  let x = point.x
  let f = fn(v) { v }
  f(same)
}
"

pub fn type_of_answers_for_expressions_test() {
  assert answers(queried, fn(module_facts) {
      list.map(
        ["42", "box.shout(\"hi\")", "identity(n)", "\"hey\" |> box.shout"],
        fn(needle) {
          facts.type_of(module_facts, support.glance_span(queried, needle))
          |> string.inspect
        },
      )
    })
    == [
      "Ok(Named(\"gleam\", \"Int\", []))",
      "Ok(Named(\"gleam\", \"String\", []))",
      "Ok(Named(\"gleam\", \"Int\", []))",
      "Ok(Named(\"gleam\", \"String\", []))",
    ]
}

pub fn resolution_of_answers_for_references_test() {
  let references = [
    #("box.shout(\"hi\")", "box.shout"),
    #("Point(1, 2)", "Point"),
    #("point.x", "point.x"),
    #("f(same)", "f"),
  ]
  assert answers(queried, fn(module_facts) {
      use #(around, reference) <- list.map(references)
      facts.resolution_of(
        module_facts,
        glance_span_in(queried, around, reference),
      )
      |> string.inspect
    })
    == [
      "Ok(ModuleFn(\"dep/box\", \"shout\"))",
      "Ok(Constructor(\"app\", \"Point\"))",
      "Ok(RecordField(Named(\"app\", \"Point\", []), \"x\"))",
      "Ok(LocalVariable(\"f\"))",
    ]
}

pub fn signature_answers_for_functions_and_constants_test() {
  assert answers(queried, fn(module_facts) {
      let assert Ok(girard.Scheme(vars:, type_:)) =
        facts.signature(module_facts, "identity")
      [
        girard.type_to_string(type_),
        string.inspect(list.length(vars)),
        string.inspect(facts.signature(module_facts, "origin")),
      ]
    })
    == [
      "fn(a) -> a",
      "1",
      "Ok(Scheme([], Named(\"app\", \"Point\", [])))",
    ]
}

// Unknown

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
  assert answers(unknowns, fn(module_facts) {
      [
        facts.type_of(module_facts, support.glance_span(unknowns, "pattern")),
        facts.type_of(module_facts, support.glance_span(unknowns, "2")),
        facts.type_of(module_facts, support.glance_span(unknowns, "\"js\"")),
      ]
      |> list.map(string.inspect)
      |> list.append(
        list.map(["pattern", "skipped", "elsewhere", "Point"], fn(name) {
          string.inspect(facts.signature(module_facts, name))
        }),
      )
      |> list.append([
        string.inspect(facts.resolution_of(
          module_facts,
          support.glance_span(unknowns, "inside + \"two\""),
        )),
      ])
    })
    == [
      "Error(NotRecorded)", "Error(Skipped(\"skipped\"))",
      "Error(Dropped(\"elsewhere\"))", "Error(NotRecorded)",
      "Error(Skipped(\"skipped\"))", "Error(Dropped(\"elsewhere\"))",
      "Error(NotRecorded)", "Error(Skipped(\"skipped\"))",
    ]
}

pub fn queries_on_a_module_girard_returned_nothing_for_test() {
  let files = [
    #("src/app.gleam", "pub fn main() {\n  1\n}\n"),
    #("src/other.gleam", "pub fn main() {\n  2\n}\n"),
  ]
  let project = support.project("", files, [])
  let assert Ok(linted) =
    runner.run_with(project, [every_query()], infer: fn(project) {
      typing.infer(project, typing.resolver(project)) |> dict.delete("app")
    })
  // The module's rules still run.
  let assert [note, ..reports] = linted.diagnostics
  assert describe(reports)
    == [
      "fixture/every-query src/app.gleam: Error(NotInferred) Error(NotInferred) Error(NotInferred)",
      "fixture/every-query src/other.gleam: Ok(Named(\"gleam\", \"Int\", [])) Error(NotRecorded) Ok(Scheme([], Fn([], Named(\"gleam\", \"Int\", []))))",
    ]
  assert note
    == Diagnostic(
      code: "grice/uninferred-module",
      severity: diagnostic.Note,
      title: "Can't infer the types of a module",
      location: None,
      message: [
        "girard, the type inference grice uses, returned no types for the module `app`, at `src/app.gleam`. Rules still ran on it, but typed rules got no answers about it, so they may have missed problems there.",
      ],
      hint: Some(girard_hint),
    )
  assert linted.coverage
    == runner.Coverage(
      modules: 2,
      parsed: 2,
      types: runner.Requested(full: 1, partial: 0, none: 1),
      gaps: [runner.UninferredModule("src/app.gleam")],
    )
}

// `app` uses nothing from `gone`, and its last expression is a reference
// girard did resolve, yet no query on it answers.
pub fn no_query_answers_in_a_module_with_an_unavailable_import_test() {
  let source =
    "import gone\nimport dep/box\n\npub fn main() {\n  box.shout\n}\n"
  let files = [
    #("src/app.gleam", source),
    #("src/other.gleam", "pub fn main() {\n  2\n}\n"),
  ]
  let project = support.project("", files, [#("dep/box", box)])
  let assert Ok(app) =
    typing.infer(project, typing.resolver(project)) |> dict.get("app")
  assert dict.get(app.resolutions, support.glance_span(source, "box.shout"))
    == Ok(girard.ModuleFn("dep/box", "shout"))
  let assert Ok(linted) = runner.run(project, [every_query()])
  assert describe(linted.diagnostics)
    == [
      "fixture/every-query src/app.gleam: Error(Unavailable([\"gone\"])) Error(Unavailable([\"gone\"])) Error(Unavailable([\"gone\"]))",
      "grice/unavailable-import src/app.gleam: girard couldn't use this",
      "fixture/every-query src/other.gleam: Ok(Named(\"gleam\", \"Int\", [])) Error(NotRecorded) Ok(Scheme([], Fn([], Named(\"gleam\", \"Int\", []))))",
    ]
  // It still counts as partial.
  assert linted.coverage
    == runner.Coverage(
      modules: 2,
      parsed: 2,
      types: runner.Requested(full: 1, partial: 1, none: 0),
      gaps: [
        runner.UnavailableImport("src/app.gleam", "gone", runner.NoSuchModule),
      ],
    )
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
  assert run_files([#("src/app.gleam", shadowed)], [
      fixture_rules.discarded_result(),
    ])
    |> list.filter(fn(found) { found.code == "fixture/discarded-result" })
    == []
}

// Planning

pub fn an_invalid_rule_set_never_infers_test() {
  let project = support.project("", [#("src/app.gleam", discards)], [])
  let assert Error(_) =
    runner.run_with(
      project,
      [fixture_rules.discarded_result(), named("Bad")],
      infer: never_infer,
    )
}

pub fn a_run_infers_once_for_every_typed_rule_test() {
  let project =
    support.project(
      "",
      [#("src/app.gleam", discards), #("src/other.gleam", queried)],
      [#("dep/box", box)],
    )
  take_mailbox()
  let assert Ok(_) =
    runner.run_with(
      project,
      [
        fixture_rules.discarded_result(),
        fixture_rules.no_echo(),
        typed_calls(),
        every_query(),
        rule.project("fixture/typed-project", title: "Made in a test")
          |> rule.typed
          |> rule.per_module(fn(module_facts) {
            facts.signature(module_facts, "main")
          })
          |> rule.final(fn(_summaries) { [] }),
      ],
      infer: fn(project) {
        send_self(dynamic.string("inferred"))
        typing.infer(project, typing.resolver(project))
      },
    )
  assert take_mailbox() == [dynamic.string("inferred")]
}

// Root
//
// A project on disk whose dependency's modules grice's own build doesn't
// have, so girard can only find them through the project's resolver.

pub fn typed_runs_dont_depend_on_the_working_directory_test() {
  let directory = support.fixture_directory("typed_root")
  support.write_fixture(directory, [
    #("gleam.toml", "name = \"app\"\n"),
    #(
      "manifest.toml",
      "packages = [\n  { name = \"shapes\", version = \"1.0.0\", build_tools = [\"gleam\"], requirements = [], source = \"hex\" },\n]\n",
    ),
    #(
      "build/packages/shapes/src/shapes/square.gleam",
      "pub type Square {\n  Square(Int)\n}\n\npub fn new(size: Int) -> Square {\n  Square(size)\n}\n",
    ),
    #(
      "src/app.gleam",
      "import shapes/square\n\npub fn main() {\n  square.new(2)\n}\n",
    ),
  ])
  let assert Ok(absolute) = simplifile.resolve(directory)
  let runs =
    list.map([directory, absolute], fn(root) {
      let assert Ok(project) = loader.load_project(root)
      let assert Ok(linted) = runner.run(project, [typed_calls()])
      linted
    })
  support.cleanup(directory)
  let assert [relative_run, absolute_run] = runs
  assert describe(relative_run.diagnostics)
    == [
      "fixture/typed-calls src/app.gleam: Ok(Named(\"shapes/square\", \"Square\", []))",
    ]
  assert relative_run.coverage
    == runner.Coverage(
      modules: 1,
      parsed: 1,
      types: runner.Requested(full: 1, partial: 0, none: 0),
      gaps: [],
    )
  assert absolute_run == relative_run
}

// Coverage

const girard_hint =
  "If `gleam build` accepts this code, it's a gap in girard, the type inference grice uses, so please report it at https://github.com/alvivi/girard/issues."

pub fn untyped_definition_notes_each_skipped_definition_of_the_lint_set_test() {
  let toml = "[tools.grice]\nexclude = [\"src/gen.gleam\"]\n"
  let skipped = "pub fn skipped() {\n  1 + \"one\"\n}"
  let source =
    "import gen\n\npub fn main() {\n  gen.typed()\n}\n\n" <> skipped <> "\n"
  let files = [
    #("src/app.gleam", source),
    // An excluded module's gaps aren't reported.
    #(
      "src/gen.gleam",
      "pub fn typed() {\n  1\n}\n\npub fn untyped() {\n  1 + \"one\"\n}\n",
    ),
  ]
  let linted = run_typed(support.project(toml, files, []))
  assert linted.diagnostics
    == [
      Diagnostic(
        code: "grice/untyped-definition",
        severity: diagnostic.Note,
        title: "Can't infer the types of this definition",
        location: Some(Location(
          path: "src/app.gleam",
          primary: Label(
            span_of(source, skipped),
            "girard couldn't type this definition",
          ),
          secondary: [],
          fix: None,
        )),
        message: [
          "girard couldn't type `skipped`: type mismatch: String vs Int. Typed rules get no answers about the code inside it, so they may miss problems there.",
        ],
        hint: Some(girard_hint),
      ),
    ]
  assert linted.coverage
    == runner.Coverage(
      modules: 1,
      parsed: 1,
      types: runner.Requested(full: 0, partial: 1, none: 0),
      gaps: [runner.UntypedDefinition("src/app.gleam", "skipped")],
    )
}

// Each lint-set module reaches one module girard can't use: `direct` and
// `indirect` an excluded module that doesn't parse, `importer` a lint-set
// module that doesn't parse, `nameless` a name no module has, and
// `dependent` a dependency module that doesn't parse, through another one.
const unavailable_files = [
  #("src/broken_linted.gleam", "pub fn ("),
  #(
    "src/dependent.gleam",
    "import dep/outer\n\npub fn main() {\n  outer.value()\n}\n",
  ),
  #("src/direct.gleam", "import gen/broken\n"),
  #("src/gen/broken.gleam", "pub fn fine() {\n  1\n}\npub fn ("),
  #("src/gen/wrapper.gleam", "import gen/broken\n\npub fn value() {\n  2\n}\n"),
  #("src/importer.gleam", "import broken_linted\n"),
  #(
    "src/indirect.gleam",
    "import gen/wrapper\n\npub fn main() {\n  wrapper.value()\n}\n",
  ),
  #("src/nameless.gleam", "import nowhere\n"),
]

const unavailable_dependencies = [
  #("dep/outer", "import dep/inner\n\npub fn value() {\n  3\n}\n"),
  #("dep/inner", "pub const x = 1\npub fn ("),
]

pub fn unavailable_import_notes_each_module_girard_couldnt_use_test() {
  let toml = "[tools.grice]\nexclude = [\"src/gen/\"]\n"
  let project =
    support.project(toml, unavailable_files, unavailable_dependencies)
  let linted = run_typed(project)
  assert describe(linted.diagnostics)
    == [
      "grice/unavailable-import", "grice/unavailable-import",
      "grice/parse-error src/broken_linted.gleam: glance didn't expect this",
      "grice/unavailable-import src/direct.gleam: girard couldn't use this",
      "grice/unavailable-import src/importer.gleam: girard couldn't use this",
      "grice/unavailable-import src/nameless.gleam: girard couldn't use this",
    ]
  assert linted.coverage.modules == 6
  assert linted.coverage.parsed == 5
  assert linted.coverage.types == runner.Requested(full: 0, partial: 5, none: 0)
  assert linted.coverage.gaps
    == [
      runner.UnparsedModule("src/broken_linted.gleam"),
      runner.UnavailableImport(
        "src/dependent.gleam",
        "dep/inner",
        runner.DependencyUnparsable,
      ),
      runner.UnavailableImport(
        "src/direct.gleam",
        "gen/broken",
        runner.ProjectModuleUnparsable,
      ),
      runner.UnavailableImport(
        "src/importer.gleam",
        "broken_linted",
        runner.ProjectModuleUnparsable,
      ),
      runner.UnavailableImport(
        "src/indirect.gleam",
        "gen/broken",
        runner.ProjectModuleUnparsable,
      ),
      runner.UnavailableImport(
        "src/nameless.gleam",
        "nowhere",
        runner.NoSuchModule,
      ),
    ]
  let assert [dependent, indirect, _, direct, importer, nameless] =
    linted.diagnostics
  assert dependent
    == Diagnostic(
      code: "grice/unavailable-import",
      severity: diagnostic.Note,
      title: "Can't use the types of an imported module",
      location: None,
      message: [
        "The module `dependent`, at `src/dependent.gleam`, reaches the module `dep/inner` through the modules it imports, and girard, the type inference grice uses, couldn't use it. It's a dependency module, which glance can't parse: it stopped at line 2, column 1 of its source. Types that depend on it may be incomplete, so typed rules get no answers in this module.",
      ],
      hint: Some(
        "If the package builds, glance doesn't support its syntax yet, so please report it to glance.",
      ),
    )
  assert indirect.message
    == [
      "The module `indirect`, at `src/indirect.gleam`, reaches the module `gen/broken` through the modules it imports, and girard, the type inference grice uses, couldn't use it. It's the project module at `src/gen/broken.gleam`, which glance can't parse: it stopped at line 4, column 1. Types that depend on it may be incomplete, so typed rules get no answers in this module.",
    ]
  assert direct
    == Diagnostic(
      code: "grice/unavailable-import",
      severity: diagnostic.Note,
      title: "Can't use the types of an imported module",
      location: Some(Location(
        path: "src/direct.gleam",
        primary: Label(Span(0, 17), "girard couldn't use this"),
        secondary: [],
        fix: None,
      )),
      message: [
        "girard, the type inference grice uses, couldn't use the module `gen/broken`, which this module imports. It's the project module at `src/gen/broken.gleam`, which glance can't parse: it stopped at line 4, column 1. Types that depend on it may be incomplete, so typed rules get no answers in this module.",
      ],
      hint: Some(
        "If `gleam build` accepts `src/gen/broken.gleam`, glance doesn't support its syntax yet, so please report it to glance.",
      ),
    )
  assert importer.message
    == [
      "girard, the type inference grice uses, couldn't use the module `broken_linted`, which this module imports. It's the project module at `src/broken_linted.gleam`, which glance can't parse: it stopped at line 1, column 1. Types that depend on it may be incomplete, so typed rules get no answers in this module.",
    ]
  assert nameless.message
    == [
      "girard, the type inference grice uses, couldn't use the module `nowhere`, which this module imports. No module of the project or of its dependencies has that name. Types that depend on it may be incomplete, so typed rules get no answers in this module.",
    ]
  assert nameless.hint
    == Some(
      "Check the import. If the module belongs to a dependency, `gleam deps download` fetches its sources.",
    )
}

// The compiler rejects an import cycle, but girard is still given both
// modules, and the module it types first can't use the other, which
// parses.
pub fn unavailable_import_notes_a_project_module_girard_couldnt_use_test() {
  let files = [
    #("src/one.gleam", "import two\n"),
    #("src/two.gleam", "import one\n"),
  ]
  let linted = run_typed(support.project("", files, []))
  // `two` is typed first, without `one`, and `one` inherits the entry
  // from `two`'s interface.
  assert linted.coverage.gaps
    == [
      runner.UnavailableImport(
        "src/one.gleam",
        "one",
        runner.ProjectModuleUnusable,
      ),
      runner.UnavailableImport(
        "src/two.gleam",
        "one",
        runner.ProjectModuleUnusable,
      ),
    ]
  let assert Ok(note) =
    list.find(linted.diagnostics, fn(found) {
      describe([found])
      == ["grice/unavailable-import src/two.gleam: girard couldn't use this"]
    })
  assert note.message
    == [
      "girard, the type inference grice uses, couldn't use the module `one`, which this module imports. It's the project module at `src/one.gleam`, which parses, but girard couldn't use it. Types that depend on it may be incomplete, so typed rules get no answers in this module.",
    ]
  assert note.hint == Some(girard_hint)
}

pub fn missing_package_notes_each_package_when_types_are_requested_test() {
  let project =
    loader.Project(
      ..support.project("", [#("src/app.gleam", "")], []),
      missing_dependencies: [
        loader.Package("hexdep", loader.Hex, "build/packages/hexdep"),
        loader.Package("gitdep", loader.Git, "build/packages/gitdep"),
        loader.Package("localdep", loader.Local, "../localdep"),
      ],
    )
  let linted = run_typed(project)
  let download = Some("Run `gleam deps download`.")
  let assert [hex, ..] = linted.diagnostics
  assert hex
    == Diagnostic(
      code: "grice/missing-package",
      severity: diagnostic.Note,
      title: "A dependency's sources are missing",
      location: None,
      message: [
        "The package `hexdep` is in `manifest.toml`, but `build/packages/hexdep/src` isn't a directory, so girard, the type inference grice uses, can't read its modules. Types that come from them may be incomplete.",
      ],
      hint: download,
    )
  assert list.map(linted.diagnostics, fn(found) { found.hint })
    == [
      download,
      download,
      Some(
        "Restore the directory, or fix the path dependency that points to it.",
      ),
    ]
  assert linted.coverage.gaps
    == [
      runner.MissingPackage("hexdep"),
      runner.MissingPackage("gitdep"),
      runner.MissingPackage("localdep"),
    ]
  let assert Ok(syntax_only) = runner.run(project, [fixture_rules.no_echo()])
  assert syntax_only.diagnostics == []
  assert syntax_only.coverage.gaps == []
}

pub fn a_syntax_only_run_never_infers_and_reports_only_parse_errors_test() {
  let files = [
    #("src/broken.gleam", "pub fn ("),
    // girard couldn't type `skipped`, but no rule asked for types.
    #("src/fine.gleam", "pub fn skipped() {\n  1 + \"one\"\n}\n"),
  ]
  let assert Ok(linted) =
    runner.run_with(
      support.project("", files, []),
      [fixture_rules.no_echo(), fixture_rules.duplicate_public_function()],
      infer: never_infer,
    )
  assert describe(linted.diagnostics)
    == ["grice/parse-error src/broken.gleam: glance didn't expect this"]
  assert linted.coverage
    == runner.Coverage(modules: 2, parsed: 1, types: runner.NotRequested, gaps: [
      runner.UnparsedModule("src/broken.gleam"),
    ])
}

// Parallel work

const two_modules = [
  #("src/one.gleam", "pub fn f() { 1 }\n"),
  #("src/two.gleam", "pub fn g() { 2 }\n"),
]

pub fn module_hooks_run_outside_the_calling_process_test() {
  let where_hooks_run =
    on_module_end("fixture/where", fn(_facts) { [at_start(process_label())] })
  let ran_in = labels(run_files(two_modules, [where_hooks_run]))
  assert list.length(ran_in) == 2
  assert !list.contains(ran_in, process_label())
}

pub fn project_summaries_run_outside_the_calling_process_test() {
  let where_summaries_run =
    rule.project("fixture/where", title: "Made in a test")
    |> rule.per_module(fn(_facts) { process_label() })
    |> rule.final(fn(summaries) {
      list.map(summaries, fn(summary) { #(summary.0, at_start(summary.1)) })
    })
  let ran_in = labels(run_files(two_modules, [where_summaries_run]))
  assert list.length(ran_in) == 2
  assert !list.contains(ran_in, process_label())
}

// Resolution

pub fn reports_become_diagnostics_with_the_rule_and_the_module_test() {
  let source = "pub fn main() {\n  let x = 1\n  x\n}\n"
  let explained =
    on_module_end("fixture/explained", fn(_facts) {
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
  assert run_files([#("src/app.gleam", source)], [explained])
    == [
      Diagnostic(
        code: "fixture/explained",
        severity: diagnostic.Warning,
        title: "Made in a test",
        location: Some(Location(
          path: "src/app.gleam",
          primary: Label(span_of(source, "x\n}"), "used here"),
          secondary: [
            Label(span_of(source, "x = 1"), "bound here"),
            Label(span_of(source, "main"), ""),
          ],
          fix: None,
        )),
        message: ["First paragraph.", "Second paragraph."],
        hint: Some("A hint."),
      ),
    ]
}

pub fn diagnostics_come_out_sorted_test() {
  let files = [
    #("src/c.gleam", "pub fn ("),
    #("src/b.gleam", "pub fn f() { 1 }\n"),
    #("src/a.gleam", "pub fn f() { 1 }\n"),
  ]
  let second =
    on_module_end("fixture/second", fn(_facts) {
      [
        rule.report(at: glance.Span(10, 12), label: ""),
        rule.report(at: glance.Span(0, 3), label: ""),
        rule.report(at: glance.Span(0, 1), label: ""),
        rule.report(at: glance.Span(99, 99), label: "invalid"),
      ]
    })
  let first =
    on_module_end("fixture/first", fn(_facts) {
      [rule.report(at: glance.Span(0, 3), label: "")]
    })
  let positions =
    run_files(files, [second, first])
    |> list.map(fn(found: Diagnostic) {
      case found.location {
        Some(location) ->
          location.path
          <> " "
          <> int.to_string(location.primary.span.start)
          <> "-"
          <> int.to_string(location.primary.span.end)
          <> " "
          <> found.code
        None -> found.code
      }
    })
  assert positions
    == [
      "grice/invalid-report", "grice/invalid-report",
      "src/a.gleam 0-1 fixture/second", "src/a.gleam 0-3 fixture/first",
      "src/a.gleam 0-3 fixture/second", "src/a.gleam 10-12 fixture/second",
      "src/b.gleam 0-1 fixture/second", "src/b.gleam 0-3 fixture/first",
      "src/b.gleam 0-3 fixture/second", "src/b.gleam 10-12 fixture/second",
      // glance stops at `pub`, the first token of the broken definition.
      "src/c.gleam 0-3 grice/parse-error",
    ]
}

pub fn resolved_diagnostics_render_like_the_compiler_test() {
  let project = support.project("", [#("src/app.gleam", echoes)], [])
  let assert Ok(runner.Linted(diagnostics: [diagnostic, _], ..)) =
    runner.run(project, [fixture_rules.no_echo()])
  let sources =
    project.modules
    |> dict.values
    |> list.map(fn(module) { #(module.path, module.source) })
    |> dict.from_list
  let assert Ok(text) =
    human.render([diagnostic], sources, human.Options(colour: False))
  assert text == "warning[fixture/no-echo]: Echo left in the code
  ┌─ src/app.gleam:2:3
  │
2 │   echo 1
  │   ^^^^^^ This prints when it runs

`echo` prints its value each time it runs.

Hint: Remove it once you're done debugging.

"
}

// Severity

pub fn rules_default_to_warnings_test() {
  assert severities([fixture_rules.no_echo(), module_order()])
    == [diagnostic.Warning, diagnostic.Warning]
}

pub fn with_severity_sets_the_severity_of_any_rule_test() {
  assert severities([
      fixture_rules.no_echo() |> rule.with_severity(diagnostic.Error),
      module_order() |> rule.with_severity(diagnostic.Note),
    ])
    == [diagnostic.Note, diagnostic.Error]
}

pub fn with_severity_keeps_the_last_severity_test() {
  assert severities([
      fixture_rules.no_echo()
        |> rule.with_severity(diagnostic.Error)
        |> rule.with_severity(diagnostic.Note),
      module_order()
        |> rule.with_severity(diagnostic.Note)
        |> rule.with_severity(diagnostic.Error),
    ])
    == [diagnostic.Error, diagnostic.Note]
}

// Invalid reports

// 22 bytes, with a two-byte `é` at bytes 16 and 17.
const accented = "pub fn f() {\n  \"é\"\n}\n"

pub fn a_report_with_a_bad_primary_span_is_an_invalid_report_test() {
  let bad_spans =
    on_module_end("fixture/spans", fn(_facts) {
      [
        rule.report(at: glance.Span(0, 99), label: "out of bounds"),
        rule.report(at: glance.Span(0, 3), label: "valid sibling"),
        rule.report(at: glance.Span(5, 2), label: "reversed"),
        rule.report(at: glance.Span(17, 18), label: "inside a codepoint"),
      ]
    })
  let assert [out_of_bounds, reversed, inside, valid] =
    run_files([#("src/app.gleam", accented)], [
      bad_spans,
      fixture_rules.no_echo(),
    ])
  assert out_of_bounds
    == Diagnostic(
      code: "grice/invalid-report",
      severity: diagnostic.Error,
      title: "A rule made an invalid report",
      location: None,
      message: [
        "The rule `fixture/spans` reported a problem in the module `app`, at `src/app.gleam`, with a span that isn't valid for the module's source. grice can't show where it points, so the report is dropped.",
        "The span of the primary label, from byte 0 to byte 99, isn't inside the source, which is 22 bytes long.",
      ],
      hint: Some(
        "This is a bug in the rule, so please report it to the rule's author. The other reports of the run are unaffected.",
      ),
    )
  assert reversed.message
    == [
      first_paragraph("fixture/spans"),
      "The span of the primary label, from byte 5 to byte 2, starts after it ends.",
    ]
  assert inside.message
    == [
      first_paragraph("fixture/spans"),
      "The span of the primary label, from byte 17 to byte 18, has an end inside a multi-byte character.",
    ]
  assert labels([valid]) == ["valid sibling"]
}

pub fn a_report_with_a_bad_secondary_span_is_an_invalid_report_test() {
  let bad_secondary =
    on_module_end("fixture/spans", fn(_facts) {
      [
        rule.report(at: glance.Span(0, 3), label: "")
        |> rule.with_label(at: glance.Span(4, 6), label: "")
        |> rule.with_label(at: glance.Span(30, 31), label: ""),
      ]
    })
  let assert [Diagnostic(code: "grice/invalid-report", message:, ..)] =
    run_files([#("src/app.gleam", accented)], [bad_secondary])
  assert message
    == [
      first_paragraph("fixture/spans"),
      "The span of the secondary label 2, from byte 30 to byte 31, isn't inside the source, which is 22 bytes long.",
    ]
}

pub fn a_report_with_several_bad_spans_is_one_invalid_report_test() {
  let bad_spans =
    on_module_end("fixture/spans", fn(_facts) {
      [
        rule.report(at: glance.Span(0, 99), label: "")
        |> rule.with_label(at: glance.Span(3, 1), label: ""),
      ]
    })
  let assert [Diagnostic(code: "grice/invalid-report", message:, ..)] =
    run_files([#("src/app.gleam", accented)], [bad_spans])
  assert message
    == [
      first_paragraph("fixture/spans"),
      "The span of the primary label, from byte 0 to byte 99, isn't inside the source, which is 22 bytes long.",
      "The span of the secondary label 1, from byte 3 to byte 1, starts after it ends.",
    ]
}

pub fn empty_spans_at_the_end_and_spans_around_characters_are_valid_test() {
  let edges =
    on_module_end("fixture/edges", fn(_facts) {
      [
        rule.report(at: glance.Span(22, 22), label: "end")
        |> rule.with_label(at: glance.Span(16, 18), label: "é")
        |> rule.with_label(at: glance.Span(18, 18), label: "after é"),
      ]
    })
  assert describe(run_files([#("src/app.gleam", accented)], [edges]))
    == ["fixture/edges src/app.gleam: end"]
}

pub fn a_project_rule_report_on_an_unlinted_module_is_an_invalid_report_test() {
  let toml = "[tools.grice]\nexclude = [\"src/app/gen/\"]\n"
  let files = [
    #("src/app.gleam", "import app/gen/a\nimport broken\n"),
    #("src/app/gen/a.gleam", ""),
    #("src/broken.gleam", "pub fn ("),
  ]
  let elsewhere =
    rule.project("fixture/elsewhere", title: "Made in a test")
    |> rule.per_module(fn(_facts) { Nil })
    |> rule.final(fn(_summaries) {
      list.map(["app/gen/a", "broken", "nowhere", "app"], fn(name) {
        #(name, rule.report(at: glance.Span(0, 0), label: name))
      })
    })
  let diagnostics = run_files_with(toml, files, [elsewhere])
  assert describe(diagnostics)
    == [
      "grice/invalid-report",
      "grice/invalid-report",
      "grice/invalid-report",
      "fixture/elsewhere src/app.gleam: app",
      "grice/parse-error src/broken.gleam: glance didn't expect this",
    ]
  let assert [Diagnostic(message:, ..), ..] = diagnostics
  assert message
    == [
      "The project rule `fixture/elsewhere` reported a problem in the module `app/gen/a`, which isn't one of the modules this run linted: it isn't in the lint set, doesn't parse, or isn't a module of the project. The report is dropped.",
    ]
}

// The rule set

pub fn rule_codes_follow_one_syntax_test() {
  let accepted = [
    "my_app/no-echo", "a/b", "app2/rule9", "my_app_2/no-io-in-view", "app/b1-2c",
    "app_/x",
  ]
  let rejected = [
    // Leading or trailing text.
    "!my_app/no-echo", "my_app/no-echo!", "my_app/no-echo ", " my_app/no-echo",
    // A missing or a second slash.
    "my_app", "my_app/no/echo", "/no-echo", "my_app/", "",
    // Uppercase and whitespace.
    "My_app/no-echo", "my_app/No-echo", "my app/no-echo", "my_app/no echo",
    // An underscore in the name, and starting with a digit.
    "my_app/no_echo", "1app/no-echo", "_app/no-echo", "my_app/1-echo",
    // Leading, trailing or doubled hyphens.
    "my_app/-no-echo", "my_app/no-echo-", "my_app/no--echo", "my-app/no-echo",
  ]
  assert list.filter(accepted, is_rejected) == []
  assert list.filter(rejected, fn(code) { !is_rejected(code) }) == []
  let assert Error([diagnostic]) = check_rules([named("my_app/no echo")])
  assert diagnostic
    == Diagnostic(
      code: "grice/invalid-rule",
      severity: diagnostic.Error,
      title: "Invalid rule code",
      location: None,
      message: [
        "A rule has the code \"my_app/no echo\", which isn't a valid rule code. Codes name rules in `gleam.toml`, so they follow a fixed syntax.",
      ],
      hint: Some(
        "A rule code is a package-style prefix, a slash and a kebab-case name, such as `my_app/no-io-in-view`. The prefix is a lowercase letter followed by lowercase letters, digits and underscores, and the name is words of lowercase letters and digits joined by single hyphens, starting with a letter.",
      ),
    )
}

pub fn rule_set_problems_are_reported_together_and_nothing_runs_test() {
  let untitled =
    rule.module("fixture/untitled", title: "")
    |> rule.with_context(initial: Nil)
    |> rule.build
  let assert Error(problems) =
    check_rules([
      fixture_rules.no_echo(),
      named("fixture/twice"),
      named("grice/thing"),
      untitled,
      named("fixture/twice"),
      named("Bad"),
      named("fixture/twice"),
    ])
  assert list.map(problems, fn(problem) { #(problem.code, problem.title) })
    == [
      #("grice/invalid-rule", "Reserved rule code"),
      #("grice/invalid-rule", "Rule without a title"),
      #("grice/invalid-rule", "Invalid rule code"),
      #("grice/invalid-rule", "Rule code used more than once"),
    ]
  let assert [reserved, no_title, _, repeated] = problems
  assert reserved.message
    == [
      "A rule has the code `grice/thing`, but the `grice/` prefix is reserved for grice's own diagnostics.",
    ]
  assert reserved.hint
    == Some("Use your package's name as the prefix, such as `my_app/thing`.")
  assert no_title.message
    == [
      "The rule `fixture/untitled` has an empty title. The title is the one-line summary printed with each of the rule's diagnostics.",
    ]
  assert repeated.message
    == [
      "3 rules have the code `fixture/twice`. Ignores name rules by their code, so each code must belong to one rule.",
    ]
}

// Ignored codes

pub fn an_ignored_code_must_name_a_rule_of_the_run_test() {
  let toml =
    "[[tools.grice.ignore]]\npaths = [\"test/**\"]\nrules = [\"fixture/no-echo\", \"fixture/no-ecko\"]\nreason = \"r\"\n"
  let assert Error([diagnostic]) =
    runner.run(support.project(toml, [#("src/app.gleam", "")], []), [
      fixture_rules.no_echo(),
    ])
  assert diagnostic
    == config.diagnostic(
      title: "Unknown rule in `gleam.toml`",
      message: "`rules` in entry 1 of `tools.grice.ignore` in `gleam.toml` names the rule `fixture/no-ecko`, but no rule of this run has that code. An ignore that names no rule silences nothing, so it's most likely a typo or a rule that was removed.",
      hint: Some("Fix the code, or remove it from the list."),
    )
}

pub fn grice_codes_cant_be_ignored_test() {
  let toml =
    "[[tools.grice.ignore]]\npaths = [\"src/**\"]\nrules = [\"grice/parse-error\"]\nreason = \"r\"\n"
  let assert Error([diagnostic]) =
    runner.run(support.project(toml, [#("src/app.gleam", "")], []), [
      fixture_rules.no_echo(),
    ])
  assert diagnostic
    == config.diagnostic(
      title: "grice's own diagnostics can't be ignored",
      message: "`rules` in entry 1 of `tools.grice.ignore` in `gleam.toml` names `grice/parse-error`, one of grice's own diagnostics rather than a rule. Those report on the run itself, such as code grice couldn't read or configuration it couldn't use, so they can't be ignored.",
      hint: Some(
        "Remove the code from the list, and fix what it reports instead.",
      ),
    )
}

pub fn rule_set_and_ignore_problems_are_reported_together_test() {
  let toml =
    "[[tools.grice.ignore]]
paths = [\"src/**\"]
rules = [\"grice/invalid-rule\", \"fixture/missing\"]
reason = \"r\"

[[tools.grice.ignore]]
paths = [\"dev/**\"]
rules = [\"fixture/no-echo\"]
reason = \"r\"
"
  let assert Error(problems) =
    runner.run(support.project(toml, [#("src/app.gleam", "")], []), [
      fixture_rules.no_echo(),
      named("fixture/broken_name"),
      panics_if_run(),
    ])
  assert list.map(problems, fn(problem) { problem.title })
    == [
      "Invalid rule code",
      "grice's own diagnostics can't be ignored",
      "Unknown rule in `gleam.toml`",
    ]
}

// Ignores and suppressions

pub fn suppressions_hide_module_and_project_rule_diagnostics_test() {
  let files = [
    #(
      "src/one.gleam",
      "pub fn main() {
  // grice-ignore fixture/no-echo: Printing is the point.
  echo 1
  echo 2
}

// grice-ignore fixture/duplicate-public-function: Both are entry points.
pub fn shared() { 1 }
",
    ),
    #("src/two.gleam", "pub fn shared() { 2 }\n"),
  ]
  let rules = [
    fixture_rules.no_echo(),
    fixture_rules.duplicate_public_function(),
  ]
  assert describe(run_files(files, rules))
    == [
      "fixture/no-echo src/one.gleam: This prints when it runs",
      "fixture/duplicate-public-function src/two.gleam: `one` also defines `shared`",
    ]
}

// A rule's severity doesn't change what can hide its diagnostics: a
// suppression in `src/app.gleam` and an ignore of `src/ignored.gleam`
// leave nothing, not even an unused suppression, at every severity.
pub fn suppressions_and_ignores_hide_rules_of_every_severity_test() {
  let toml =
    "[[tools.grice.ignore]]
paths = [\"src/ignored.gleam\"]
rules = [\"fixture/no-echo\"]
reason = \"why\"
"
  let files = [
    #(
      "src/app.gleam",
      "pub fn main() {\n  // grice-ignore fixture/no-echo: why\n  echo 1\n}\n",
    ),
    #("src/ignored.gleam", "pub fn main() { echo 2 }\n"),
  ]
  let left =
    list.filter(
      [diagnostic.Error, diagnostic.Warning, diagnostic.Note],
      fn(severity) {
        let rules = [fixture_rules.no_echo() |> rule.with_severity(severity)]
        run_files_with(toml, files, rules) != []
      },
    )
  assert left == []
}

// The comment after `echo 2` follows code on its line, and the last one
// has no code after it but the closing brace, where nothing is reported.
pub fn suppression_warnings_render_in_a_crlf_file_with_non_ascii_text_test() {
  let source =
    "pub fn main() {\r\n  // grice-ignore fixture/no-echo: café 🙂\r\n  // naïve, ünïcödé\r\n  echo 1\r\n  echo 2 // grice-ignore fixture/no-echo: après\r\n  // grice-ignore fixture/no-echo: fin ✓\r\n}\r\n"
  let project = support.project("", [#("src/app.gleam", source)], [])
  let assert Ok(runner.Linted(diagnostics: [kept, misplaced, unused], ..)) =
    runner.run(project, [fixture_rules.no_echo()])
  assert kept == echo_diagnostic(span_of(source, "echo 2"))
  let sources = dict.from_list([#("src/app.gleam", line_index.new(source))])
  let assert Ok(text) =
    human.render([misplaced, unused], sources, human.Options(colour: False))
  assert text == "warning[grice/invalid-suppression]: Invalid suppression
  ┌─ src/app.gleam:5:10
  │
5 │   echo 2 // grice-ignore fixture/no-echo: après
  │          ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ This comes after code

A `grice-ignore` comment must be alone on its line, and a
`grice-ignore-file` comment must come before the module's first line of
code, but this one comes after code. It hides nothing.

Hint: Write `// grice-ignore <rule code>: <reason>` on its own line, above
the code it covers, or `// grice-ignore-file <rule code>: <reason>` before
the module's first line of code to cover the whole module.

warning[grice/unused-suppression]: Unused suppression
  ┌─ src/app.gleam:6:3
  │
6 │   // grice-ignore fixture/no-echo: fin ✓
  │   ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ This hides nothing

This suppression hides nothing: no diagnostic of the rule `fixture/no-echo`
is left to hide on line 7, the next line of code.

Hint: Fix the suppression, or remove it. Write `// grice-ignore <rule
code>: <reason>` on its own line, above the code it covers, or `//
grice-ignore-file <rule code>: <reason>` before the module's first line of
code to cover the whole module.

"
}

// The suppression inside the JavaScript function has no reason. The one
// above its attribute is read on both targets, and the file suppression
// comes after that function, which is code on both targets too.
const target_suppressions =
  "// grice-ignore fixture/no-echo: Above the attribute.
@target(javascript)
pub fn javascript() {
  // grice-ignore-file fixture/no-echo
  1
}
// grice-ignore-file fixture/no-echo: After a definition.
pub fn main() { 1 }
"

pub fn suppressions_follow_the_target_view_test() {
  let suppressions = fn(toml) {
    run_files_with(toml, [#("src/app.gleam", target_suppressions)], [
      fixture_rules.no_echo(),
    ])
    |> describe
  }
  let unused = "grice/unused-suppression src/app.gleam: This hides nothing"
  let after_code =
    "grice/invalid-suppression src/app.gleam: This comes after code"
  assert suppressions("target = \"erlang\"\n") == [unused, after_code]
  assert suppressions("target = \"javascript\"\n")
    == [
      unused,
      "grice/invalid-suppression src/app.gleam: This gives no reason",
      after_code,
    ]
  let turned_off =
    "grice/invalid-suppression src/app.gleam: grice doesn't read this"
  assert suppressions(
      "target = \"erlang\"\n[tools.grice]\nsuppression_comments = false\n",
    )
    == [turned_off, turned_off]
}

pub fn ignores_and_suppressions_never_hide_grices_own_diagnostics_test() {
  let toml =
    "[[tools.grice.ignore]]
paths = [\"**\"]
rules = [\"fixture/no-echo\", \"fixture/spans\"]
reason = \"why\"
"
  let files = [
    #(
      "src/app.gleam",
      "// grice-ignore-file fixture/no-echo: why\npub fn main() { echo 1 }\n",
    ),
    #("src/broken.gleam", "// grice-ignore-file fixture/no-echo: why\npub fn ("),
  ]
  let bad_span =
    on_module_end("fixture/spans", fn(_facts) {
      [rule.report(at: glance.Span(0, 999), label: "out of bounds")]
    })
  assert describe(
      run_files_with(toml, files, [fixture_rules.no_echo(), bad_span]),
    )
    == [
      "grice/invalid-report",
      "grice/unused-suppression src/app.gleam: This hides nothing",
      "grice/parse-error src/broken.gleam: glance didn't expect this",
    ]
}

// Rules made in the tests

// Reports how many functions the module has once it has been walked.
fn count_functions() -> Rule {
  rule.module("fixture/count-functions", title: "Made in a test")
  |> rule.with_context(initial: 0)
  |> rule.on_function(fn(count, _function, _facts) { #(count + 1, []) })
  |> rule.on_module_end(fn(count, _facts) {
    [at_start(int.to_string(count) <> " functions")]
  })
  |> rule.build
}

// Reports, on the first module it's given, the names of every module in
// the order its summaries came in.
fn module_order() -> Rule {
  rule.project("fixture/module-order", title: "Made in a test")
  |> rule.per_module(facts.module_name)
  |> rule.final(fn(summaries) {
    let names = list.map(summaries, fn(summary) { summary.1 })
    case names {
      [first, ..] -> [#(first, at_start(string.join(names, ", ")))]
      [] -> []
    }
  })
}

// Reports on the module named `name` what its facts hold, one paragraph
// each.
fn describe_facts(name: String) -> Rule {
  use module_facts <- on_module_end("fixture/describe-facts")
  use <- bool.guard(when: facts.module_name(module_facts) != name, return: [])
  let module = facts.module(module_facts)
  [
    at_start("facts")
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
    at_start("comments")
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
  fn(context, _node, _facts) { #(context, [at_start(name)]) }
}

// A module rule that reports what `reports` gives once each module has
// been walked.
fn on_module_end(
  code: String,
  reports: fn(ModuleFacts(Syntax)) -> List(Report),
) -> Rule {
  rule.module(code, title: "Made in a test")
  |> rule.with_context(initial: Nil)
  |> rule.on_module_end(fn(_context, module_facts) { reports(module_facts) })
  |> rule.build
}

// A typed module rule that reports what `reports` gives once each module
// has been walked.
fn typed_on_module_end(
  code: String,
  reports: fn(ModuleFacts(Typed)) -> List(Report),
) -> Rule {
  rule.module(code, title: "Made in a test")
  |> rule.typed
  |> rule.with_context(initial: Nil)
  |> rule.on_module_end(fn(_context, module_facts) { reports(module_facts) })
  |> rule.build
}

// Reports each call with what `type_of` answers for it.
fn typed_calls() -> Rule {
  rule.module("fixture/typed-calls", title: "Made in a test")
  |> rule.typed
  |> rule.with_context(initial: Nil)
  |> rule.on_expression(fn(context, expression, module_facts) {
    case expression {
      glance.Call(location:, ..) -> #(context, [
        rule.report(
          at: location,
          label: string.inspect(facts.type_of(module_facts, location)),
        ),
      ])
      _ -> #(context, [])
    }
  })
  |> rule.build
}

// Reports, on each module, what `type_of` and `resolution_of` answer for
// the last expression of `main`, and what `signature` answers for `main`.
fn every_query() -> Rule {
  use module_facts <- typed_on_module_end("fixture/every-query")
  let assert Ok(main) =
    list.find(facts.module(module_facts).functions, fn(function) {
      function.definition.name == "main"
    })
  let assert Ok(glance.Expression(last)) = list.last(main.definition.body)
  [
    at_start(
      [
        string.inspect(facts.type_of(module_facts, last.location)),
        string.inspect(facts.resolution_of(module_facts, last.location)),
        string.inspect(facts.signature(module_facts, "main")),
      ]
      |> string.join(" "),
    ),
  ]
}

// What `ask` answers on the module `app`, whose source is `source`, with
// the dependency module `dep/box`.
fn answers(
  source: String,
  ask: fn(ModuleFacts(Typed)) -> List(String),
) -> List(String) {
  let asking =
    typed_on_module_end("fixture/answers", fn(module_facts) {
      [at_start("answers") |> rule.with_message(ask(module_facts))]
    })
  let project =
    support.project("", [#("src/app.gleam", source)], [#("dep/box", box)])
  let assert Ok(runner.Linted(diagnostics:, ..)) = runner.run(project, [asking])
  let assert Ok(Diagnostic(message:, ..)) =
    list.find(diagnostics, fn(found) { found.code == "fixture/answers" })
  message
}

// The run of a typed rule that reports nothing on the modules it's used on
// here.
fn run_typed(project: Project) -> runner.Linted {
  let assert Ok(linted) =
    runner.run(project, [fixture_rules.discarded_result()])
  linted
}

// An inference function that fails the test when it's called.
fn never_infer(_project: Project) -> Dict(String, ModuleTypes) {
  panic as "girard ran although no rule needs types"
}

// A rule with the code `code` that reports nothing.
fn named(code: String) -> Rule {
  rule.module(code, title: "Made in a test")
  |> rule.with_context(initial: Nil)
  |> rule.build
}

fn panics_if_run() -> Rule {
  use _facts <- on_module_end("fixture/panics-if-run")
  panic as "a rule ran although the rule set is invalid"
}

// The process that calls it, as a label.
fn process_label() -> String {
  string.inspect(self_pid())
}

fn at_start(label: String) -> Report {
  rule.report(at: glance.Span(0, 0), label:)
}

// Helpers

fn echo_diagnostic(span: diagnostic.Span) -> Diagnostic {
  Diagnostic(
    code: "fixture/no-echo",
    severity: diagnostic.Warning,
    title: "Echo left in the code",
    location: Some(Location(
      path: "src/app.gleam",
      primary: Label(span, "This prints when it runs"),
      secondary: [],
      fix: None,
    )),
    message: ["`echo` prints its value each time it runs."],
    hint: Some("Remove it once you're done debugging."),
  )
}

fn discarded_diagnostic(span: diagnostic.Span) -> Diagnostic {
  Diagnostic(
    code: "fixture/discarded-result",
    severity: diagnostic.Warning,
    title: "Result discarded",
    location: Some(Location(
      path: "src/app.gleam",
      primary: Label(span, "This discards a `Result`"),
      secondary: [],
      fix: None,
    )),
    message: [
      "A `Result` says whether something failed, and discarding it hides the failure.",
    ],
    hint: Some("Handle the error, or assert that there is none."),
  )
}

fn first_paragraph(code: String) -> String {
  "The rule `"
  <> code
  <> "` reported a problem in the module `app`, at `src/app.gleam`, with a span that isn't valid for the module's source. grice can't show where it points, so the report is dropped."
}

fn run_files(
  files: List(#(String, String)),
  rules: List(Rule),
) -> List(Diagnostic) {
  run_files_with("", files, rules)
}

fn run_files_with(
  toml: String,
  files: List(#(String, String)),
  rules: List(Rule),
) -> List(Diagnostic) {
  let assert Ok(runner.Linted(diagnostics:, ..)) =
    runner.run(support.project(toml, files, []), rules)
  diagnostics
}

fn check_rules(rules: List(Rule)) -> Result(runner.Linted, List(Diagnostic)) {
  runner.run(support.project("", [#("src/app.gleam", "")], []), rules)
}

fn is_rejected(code: String) -> Bool {
  result.is_error(check_rules([named(code)]))
}

// The severity of each diagnostic of the rules run on one module with an
// `echo`.
fn severities(rules: List(Rule)) -> List(diagnostic.Severity) {
  run_files([#("src/app.gleam", "pub fn f() { echo 1 }\n")], rules)
  |> list.map(fn(found) { found.severity })
}

// The primary label of each diagnostic.
fn labels(diagnostics: List(Diagnostic)) -> List(String) {
  list.map(diagnostics, fn(found) {
    let assert Some(location) = found.location
    location.primary.message
  })
}

// Each diagnostic as its code, then its path and primary label if it has a
// location.
fn describe(diagnostics: List(Diagnostic)) -> List(String) {
  list.map(diagnostics, fn(found) {
    case found.location {
      Some(location) ->
        found.code <> " " <> location.path <> ": " <> location.primary.message
      None -> found.code
    }
  })
}

// The span of the first `needle` in `source`.
fn span_of(source: String, needle: String) -> diagnostic.Span {
  let glance.Span(start:, end:) = support.glance_span(source, needle)
  Span(start:, end:)
}

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

type Pid

@external(erlang, "grice_test_ffi", "self_pid")
fn self_pid() -> Pid

@external(erlang, "grice_test_ffi", "send_self")
fn send_self(message: Dynamic) -> Nil

// Every message in the mailbox, oldest first, removed from it.
@external(erlang, "grice_test_ffi", "take_mailbox")
fn take_mailbox() -> List(Dynamic)
