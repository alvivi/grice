//// Tests for correcting glance's string ends. First the correction on
//// trees built by hand as glance 7.0.0 builds them on JavaScript, which
//// run on every target: each node kind whose end it changes, nesting,
//// attributes, the spans it keeps, and that it changes nothing in a tree
//// that's already right. Then real parses, where reports on each of those
//// node kinds, a typed rule, a suppression and an ignore see the same
//// spans on both targets.

import girard
import glance.{Span}
import gleam/bit_array
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import grice/diagnostic.{type Diagnostic}
import grice/facts
import grice/fixture_rules
import grice/internal/glance_spans
import grice/rule.{type Rule}
import grice/support

// Trees built by hand
//
// `é🙂` is 3 UTF-16 code units and 6 bytes, so on JavaScript glance 7.0.0
// ends a literal of it 3 past its real end, after its two quotes. Each
// test builds its nodes around a literal from `mixed`, as glance 7.0.0
// gives it, and from `fixed`, as the correction should give it, with the
// nodes that take a literal's end ending where it ends.

const text = "é🙂"

pub fn expressions_end_with_their_corrected_child_test() {
  let x = glance.Variable(Span(0, 1), "x")
  let one = glance.Int(Span(5, 6), "1")
  let expressions = fn(literal: fn(Int) -> glance.Expression) {
    [
      literal(10),
      glance.BinaryOperator(
        Span(0, end(literal(10))),
        glance.Eq,
        x,
        literal(10),
      ),
      glance.NegateBool(Span(9, end(literal(10))), literal(10)),
      glance.NegateInt(Span(9, end(literal(10))), literal(10)),
      glance.Echo(Span(5, end(literal(10))), Some(literal(10)), None),
      glance.Echo(Span(0, end(literal(20))), Some(one), Some(literal(20))),
      glance.Panic(Span(0, end(literal(10))), Some(literal(10))),
      glance.Todo(Span(0, end(literal(10))), Some(literal(10))),
      // A case keeps its span, and its string pattern is corrected.
      glance.Case(Span(0, 30), [x], [
        glance.Clause([[pattern(literal(9))]], None, one),
      ]),
    ]
    |> list.map(glance.Expression)
  }
  assert correct_body(expressions(mixed)) == expressions(fixed)
}

pub fn statements_end_with_their_corrected_child_test() {
  let x = glance.PatternVariable(Span(4, 5), "x")
  let y = glance.Variable(Span(22, 23), "y")
  let statements = fn(literal: fn(Int) -> glance.Expression) {
    [
      glance.Assignment(
        Span(0, end(literal(10))),
        glance.Let,
        x,
        None,
        literal(10),
      ),
      glance.Assignment(
        Span(0, end(literal(18))),
        glance.LetAssert(message: None),
        x,
        None,
        literal(18),
      ),
      glance.Assignment(
        Span(0, end(literal(30))),
        glance.LetAssert(message: Some(literal(30))),
        pattern(literal(11)),
        None,
        y,
      ),
      glance.Assert(Span(0, end(literal(7))), literal(7), None),
      glance.Assert(Span(0, end(literal(22))), y, Some(literal(22))),
      glance.Use(Span(0, end(literal(10))), [], literal(10)),
    ]
  }
  assert correct_body(statements(mixed)) == statements(fixed)
}

pub fn a_constant_ends_with_its_corrected_value_test() {
  let module = fn(literal: fn(Int) -> glance.Expression) {
    let constant =
      glance.Constant(
        location: Span(0, end(literal(15))),
        name: "greeting",
        publicity: glance.Public,
        annotation: None,
        value: literal(15),
      )
    glance.Module([], [], [], [glance.Definition([], constant)], [])
  }
  assert glance_spans.correct(module(mixed)) == module(fixed)
}

// Each end follows the corrected end below it: the negation, the `echo`
// and the `let` all end where the literal really ends.
pub fn ends_follow_nested_corrections_test() {
  let x = glance.PatternVariable(Span(4, 5), "x")
  let statement = fn(end, literal) {
    glance.Assignment(
      Span(0, end),
      glance.Let,
      x,
      None,
      glance.Echo(
        Span(8, end),
        Some(glance.NegateBool(Span(13, end), literal)),
        None,
      ),
    )
  }
  let block = fn(statement) {
    glance.Expression(
      glance.Block(Span(0, 40), [
        glance.Expression(glance.Fn(Span(2, 38), [], None, [statement])),
      ]),
    )
  }
  assert correct_body([block(statement(22, mixed(14)))])
    == [block(statement(19, fixed(14)))]
}

// Their spans end at a closing token or a name, which glance places right.
pub fn other_spans_are_kept_test() {
  let f = glance.Variable(Span(0, 1), "f")
  let kept = fn(literal) {
    [
      glance.Expression(
        glance.Call(Span(0, 20), f, [glance.UnlabelledField(literal)]),
      ),
      glance.Expression(glance.FieldAccess(Span(0, 7), literal, "x")),
      glance.Expression(glance.TupleIndex(Span(0, 7), literal, 0)),
      glance.Expression(glance.Tuple(Span(0, 20), [literal])),
      glance.Expression(glance.List(Span(0, 20), [literal], Some(literal))),
      glance.Expression(
        glance.BitString(Span(0, 30), [
          #(literal, [glance.SizeValueOption(literal), glance.Utf8Option]),
        ]),
      ),
      glance.Expression(
        glance.FnCapture(
          Span(0, 30),
          None,
          f,
          [glance.LabelledField("a", Span(2, 3), literal)],
          [glance.ShorthandField("b", Span(20, 21))],
        ),
      ),
      glance.Expression(
        glance.RecordUpdate(Span(0, 30), None, "Box", literal, [
          glance.RecordUpdateField("text", Some(literal)),
        ]),
      ),
      glance.Expression(glance.Panic(Span(0, 5), None)),
      glance.Expression(glance.Echo(Span(0, 4), None, None)),
    ]
  }
  assert correct_body(kept(mixed(2))) == kept(fixed(2))
}

pub fn attribute_arguments_are_corrected_test() {
  let attributes = fn(literal) { [glance.Attribute("deprecated", [literal])] }
  let module = fn(literal) {
    glance.Module(
      imports: [
        glance.Definition(
          attributes(literal),
          glance.Import(Span(20, 31), "gleam/list", None, [], []),
        ),
      ],
      custom_types: [
        glance.Definition(
          attributes(literal),
          glance.CustomType(Span(20, 40), "Thing", glance.Public, False, [], [
            glance.Variant("Thing", [], attributes(literal)),
          ]),
        ),
      ],
      type_aliases: [
        glance.Definition(
          attributes(literal),
          glance.TypeAlias(
            Span(20, 40),
            "Alias",
            glance.Public,
            [],
            glance.NamedType(Span(34, 40), "String", None, []),
          ),
        ),
      ],
      constants: [],
      functions: [
        glance.Definition(
          attributes(literal),
          glance.Function(Span(20, 40), "main", glance.Public, [], None, []),
        ),
      ],
    )
  }
  assert glance_spans.correct(module(mixed(12))) == module(fixed(12))
}

// Correcting a corrected tree, or a tree that was already right, changes
// nothing.
pub fn the_correction_changes_nothing_in_a_right_tree_test() {
  let body = [
    glance.Assignment(
      Span(0, 22),
      glance.Let,
      glance.PatternVariable(Span(4, 5), "x"),
      None,
      glance.Echo(Span(8, 22), Some(mixed(14)), None),
    ),
    glance.Expression(glance.BinaryOperator(
      Span(30, 48),
      glance.Eq,
      mixed(30),
      glance.Variable(Span(47, 48), "x"),
    )),
  ]
  let corrected = correct_body(body)
  assert corrected != body
  assert correct_body(corrected) == corrected
}

// Real parses
//
// The same diagnostics and types on both targets, where a wrong end on
// JavaScript would show.

// In this comparison, glance 7.0.0 on JavaScript gives the literal the
// comparison's span, so girard's index would answer `String` for both.
const collision =
  "pub fn check(x: String) -> Bool {
  \"\u{E9}\u{E9}\u{E9}\u{E9}\u{E9}\" == x
}
"

pub fn a_typed_rule_tells_a_literal_from_its_comparison_test() {
  assert run(collision, [types()])
    == [
      support.finding(
        "fixture/types",
        support.span_of(collision, "\"\u{E9}\u{E9}\u{E9}\u{E9}\u{E9}\""),
        "String",
      ),
      support.finding(
        "fixture/types",
        support.span_of(collision, "\"\u{E9}\u{E9}\u{E9}\u{E9}\u{E9}\" == x"),
        "Bool",
      ),
    ]
}

// Each case is a kind of node whose end glance takes from a string
// literal, after text outside ASCII and ending the file, with the source
// each report points at, in order.
const literal_ends = [
  #("pub fn f(x) { x <> \"é🙂\" }", ["x <> \"é🙂\"", "\"é🙂\""]),
  #("pub fn f() { !\"é🙂\" }", ["!\"é🙂\"", "\"é🙂\""]),
  #("pub fn f() { -\"é🙂\" }", ["-\"é🙂\"", "\"é🙂\""]),
  #("pub fn f() { echo \"é🙂\" }", ["echo \"é🙂\"", "\"é🙂\""]),
  #("pub fn f() { echo 1 as \"é🙂\" }", ["echo 1 as \"é🙂\"", "\"é🙂\""]),
  #("pub fn f() { panic as \"é🙂\" }", ["panic as \"é🙂\"", "\"é🙂\""]),
  #("pub fn f() { todo as \"é🙂\" }", ["todo as \"é🙂\"", "\"é🙂\""]),
  #("pub fn f() { let x = \"é🙂\" }", ["let x = \"é🙂\"", "\"é🙂\""]),
  #("pub fn f(x) { let assert \"é\" = x as \"🙂\" }", [
    "let assert \"é\" = x as \"🙂\"",
    "\"é\"",
    "\"🙂\"",
  ]),
  #("pub fn f(x) { assert x == \"é🙂\" }", [
    "assert x == \"é🙂\"",
    "x == \"é🙂\"",
    "\"é🙂\"",
  ]),
  #("pub fn f(x) { assert x as \"é🙂\" }", ["assert x as \"é🙂\"", "\"é🙂\""]),
  #("pub fn f() { use <- \"é🙂\" }", ["use <- \"é🙂\"", "\"é🙂\""]),
  #("pub fn f(x) { case x { \"é🙂\" -> 1 } }", ["\"é🙂\""]),
  #("const c = \"é🙂\"", ["const c = \"é🙂\"", "\"é🙂\""]),
  #("@deprecated(\"é🙂\")\npub fn f() { 1 }", ["\"é🙂\""]),
]

pub fn reports_on_nodes_that_end_on_a_literal_are_bytes_test() {
  use #(code, expected) <- list.each(literal_ends)
  let source = "// café 🙂\n" <> code
  let reported =
    list.map(run(source, [literal_ends_rule()]), fn(found) {
      let assert Some(location) = found.location
      let span = location.primary.span
      bit_array.from_string(source)
      |> bit_array.slice(span.start, span.end - span.start)
      |> result.try(bit_array.to_string)
    })
  assert #(code, reported) == #(code, list.map(expected, Ok))
}

// The constant is left out on Erlang, the project's target, and its end
// decides which comments go with it: a wrong end would take the
// suppression after it.
pub fn a_suppression_after_a_constant_left_out_for_the_target_test() {
  let source =
    "@target(javascript)
const greeting = \"🙂🙂🙂\"
// grice-ignore fixture/no-echo: The constant is gone, not this.
pub fn main() { echo 1 }
"
  assert run(source, [fixture_rules.no_echo()]) == []
}

// A wrong end of `greeting` would reach into `main`, where the finding
// starts, and the ignore would hide it.
pub fn an_ignore_of_a_definition_ending_on_a_literal_test() {
  let toml =
    "[[tools.grice.ignore]]
paths = [\"src/app.gleam\"]
definitions = [\"greeting\"]
rules = [\"fixture/functions\"]
reason = \"why\"
"
  let source = "pub const greeting = \"🙂🙂🙂\"\npub fn main() {\n  1\n}\n"
  assert support.run_files_with(toml, [#("src/app.gleam", source)], [
      functions(),
    ])
    == [
      support.finding(
        "fixture/functions",
        support.span_of(source, "pub fn main() {\n  1\n}"),
        "A function",
      ),
    ]
}

// Helpers

// The literal `"é🙂"` at `start`, as glance 7.0.0 builds it on JavaScript:
// its end adds the text's 6 bytes and two quotes to a start in code units.
fn mixed(start: Int) -> glance.Expression {
  glance.String(Span(start, start + 8), text)
}

// The same literal, ending after its 3 code units and two quotes.
fn fixed(start: Int) -> glance.Expression {
  glance.String(Span(start, start + 5), text)
}

fn end(expression: glance.Expression) -> Int {
  expression.location.end
}

// A literal as a string pattern with the same span.
fn pattern(literal: glance.Expression) -> glance.Pattern {
  glance.PatternString(literal.location, text)
}

// The corrected body of a function whose body is `statements`.
fn correct_body(statements: List(glance.Statement)) -> List(glance.Statement) {
  let function =
    glance.Function(Span(0, 99), "main", glance.Public, [], None, statements)
  let assert glance.Module(
    functions: [glance.Definition(definition: glance.Function(body:, ..), ..)],
    ..,
  ) =
    glance_spans.correct(
      glance.Module([], [], [], [], [glance.Definition([], function)]),
    )
  body
}

// The diagnostics of a run of `rules` over `src/app.gleam` holding
// `source`.
fn run(source: String, rules: List(Rule)) -> List(Diagnostic) {
  support.run_files([#("src/app.gleam", source)], rules)
}

// Reports the type of each string literal and binary operator.
fn types() -> Rule {
  rule.module("fixture/types", title: "Made in a test")
  |> rule.typed
  |> rule.with_context(initial: Nil)
  |> rule.on_expression(fn(context, expression, module_facts) {
    case expression {
      glance.String(location:, ..) | glance.BinaryOperator(location:, ..) -> {
        let label = case facts.type_of(module_facts, location) {
          Ok(type_) -> girard.type_to_string(type_)
          Error(_unknown) -> "No type"
        }
        #(context, [rule.report(at: location, label:)])
      }
      _ -> #(context, [])
    }
  })
  |> rule.build
}

// Reports each node of `literal_ends`' kinds: string literals and
// patterns, the expressions and statements that take a child's end,
// constants, and the arguments of functions' attributes, which the walk
// doesn't visit.
fn literal_ends_rule() -> Rule {
  let report = fn(context, location) {
    #(context, [rule.report(at: location, label: "")])
  }
  rule.module("fixture/literal-ends", title: "Made in a test")
  |> rule.with_context(initial: Nil)
  |> rule.on_expression(fn(context, expression, _facts) {
    case expression {
      glance.String(location:, ..)
      | glance.BinaryOperator(location:, ..)
      | glance.NegateBool(location:, ..)
      | glance.NegateInt(location:, ..)
      | glance.Echo(location:, ..)
      | glance.Panic(location:, ..)
      | glance.Todo(location:, ..) -> report(context, location)
      _ -> #(context, [])
    }
  })
  |> rule.on_pattern(fn(context, pattern, _facts) {
    case pattern {
      glance.PatternString(location:, ..) -> report(context, location)
      _ -> #(context, [])
    }
  })
  |> rule.on_statement(fn(context, statement, _facts) {
    case statement {
      glance.Assignment(location:, ..)
      | glance.Assert(location:, ..)
      | glance.Use(location:, ..) -> report(context, location)
      glance.Expression(_) -> #(context, [])
    }
  })
  |> rule.on_constant(fn(context, constant, _facts) {
    report(context, constant.definition.location)
  })
  |> rule.on_function(fn(context, function, _facts) {
    let arguments =
      list.flat_map(function.attributes, fn(attribute) { attribute.arguments })
    #(
      context,
      list.map(arguments, fn(argument) {
        rule.report(at: argument.location, label: "")
      }),
    )
  })
  |> rule.build
}

// Reports each function.
fn functions() -> Rule {
  rule.module("fixture/functions", title: "Made in a test")
  |> rule.with_context(initial: Nil)
  |> rule.on_function(fn(context, function, _facts) {
    #(context, [
      rule.report(at: function.definition.location, label: "A function"),
    ])
  })
  |> rule.build
}
