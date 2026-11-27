//// `grice_rules/no-length-for-emptiness`: `string.length` or `list.length`
//// compared with 0 or 1, or matched on 0 in a `case`, to check whether a
//// string or a list is empty. Each walks the whole value to count it.
////
//// It's typed: a call is a length call when girard resolved its callee
//// to `gleam/string.length` or `gleam/list.length`, however it's written:
//// qualified through any alias, unqualified, or as the function after a
//// pipe, with or without empty parentheses. Without an answer from
//// girard, it stays silent.
////
//// The compiler already warns on some `list.length` forms
//// (InefficientEmptyListCheck), and its boundary is spelling: a direct
//// call through a module access, compared with a literal written exactly
//// `0` or `-0` as `== 0`, `!= 0`, `> 0` or `<= 0`, or exactly `1` as
//// `< 1`, with the literal on either side. The rule skips exactly those
//// and reports the rest: `>= 1`, other spellings such as `0x0` or `- 0`,
//// pipes, unqualified calls, the `case` form, and every `string.length`
//// form.

import girard
import glance
import gleam/bool
import gleam/option.{None}
import gleam/result
import grice/facts.{type ModuleFacts, type Typed}
import grice/internal/rules/int_literal
import grice/rule.{type Report, type Rule}

const code = "grice_rules/no-length-for-emptiness"

/// The rule.
pub fn rule() -> Rule {
  rule.module(code, title: "Length used to check for emptiness")
  |> rule.typed
  |> rule.with_context(initial: Nil)
  |> rule.on_expression(fn(context, expression, module_facts) {
    #(context, check(expression, module_facts))
  })
  |> rule.build
}

fn check(
  expression: glance.Expression,
  module_facts: ModuleFacts(Typed),
) -> List(Report) {
  let found = {
    use check <- result.try(emptiness_check(expression))
    use call <- result.map(length_call(check.operand, module_facts))
    #(check, call)
  }
  case found {
    Ok(#(Compared(operator:, literal:, polarity:, ..), call)) ->
      case compiler_warns(call, operator, literal) {
        True -> []
        False -> [comparison_report(expression.location, call, polarity)]
      }
    Ok(#(Matched(operand:), call)) -> [case_report(operand.location, call)]
    Error(Nil) -> []
  }
}

/// The operand `expression` checks for emptiness, when it's an emptiness
/// check whatever its operand: a comparison with an Int literal that
/// makes it one, such as `> 0` or `< 1`, the side that isn't the literal,
/// or a `case` with a lone zero clause and a discard, its subject. It
/// reads the check alone, before the forms the compiler warns on are left
/// out, so the simplify pack can stay silent on a count that is checked
/// for emptiness.
pub fn emptiness_operand(
  expression: glance.Expression,
) -> Result(glance.Expression, Nil) {
  emptiness_check(expression) |> result.map(fn(check) { check.operand })
}

// Emptiness checks

// An emptiness check of an operand, read without the operand.
type Check {
  // `operand <operator> literal`, with the operator turned so the operand
  // is on its left.
  Compared(
    operand: glance.Expression,
    operator: glance.BinaryOperator,
    literal: glance.Expression,
    polarity: Polarity,
  )
  // A `case` on `operand`, its subject, with a lone zero clause and a
  // discard.
  Matched(operand: glance.Expression)
}

fn emptiness_check(expression: glance.Expression) -> Result(Check, Nil) {
  case expression {
    glance.BinaryOperator(name:, left:, right:, ..) ->
      compared(name, left, right)
    glance.Case(subjects: [subject], clauses: [zero, rest], ..) ->
      case is_emptiness_case(zero, rest) {
        True -> Ok(Matched(operand: subject))
        False -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

// `left <operator> right` as an emptiness check, when one side is a
// literal that makes it one: the right first, then the left.
fn compared(
  operator: glance.BinaryOperator,
  left: glance.Expression,
  right: glance.Expression,
) -> Result(Check, Nil) {
  use <- bool.guard(when: !is_comparison(operator), return: Error(Nil))
  oriented(left, operator, right)
  |> result.lazy_or(fn() { oriented(right, int_literal.mirror(operator), left) })
}

fn oriented(
  operand: glance.Expression,
  operator: glance.BinaryOperator,
  literal: glance.Expression,
) -> Result(Check, Nil) {
  use value <- result.try(int_literal.value(literal))
  use polarity <- result.map(polarity(operator, value))
  Compared(operand:, operator:, literal:, polarity:)
}

// Length calls

// What a length call counts.
type Kind {
  Graphemes
  Elements
}

type LengthCall {
  LengthCall(
    kind: Kind,
    // Whether the call is direct and through a module access, as in
    // `list.length(items)`: the form the compiler checks.
    direct_and_qualified: Bool,
  )
}

// `expression` as a call of `string.length` or `list.length`: direct, or
// the function after a pipe.
fn length_call(
  expression: glance.Expression,
  module_facts: ModuleFacts(Typed),
) -> Result(LengthCall, Nil) {
  case expression {
    glance.Call(function: callee, arguments: [_], ..) -> {
      use kind <- result.map(counted(callee, module_facts))
      let direct_and_qualified = case callee {
        glance.FieldAccess(..) -> True
        _ -> False
      }
      LengthCall(kind:, direct_and_qualified:)
    }
    glance.BinaryOperator(
      name: glance.Pipe,
      right: glance.Call(function: callee, arguments: [], ..),
      ..,
    )
    | glance.BinaryOperator(name: glance.Pipe, right: callee, ..) -> {
      use kind <- result.map(counted(callee, module_facts))
      LengthCall(kind:, direct_and_qualified: False)
    }
    _ -> Error(Nil)
  }
}

// What a call through `callee` counts, when girard resolved it to one of
// the two length functions.
fn counted(
  callee: glance.Expression,
  module_facts: ModuleFacts(Typed),
) -> Result(Kind, Nil) {
  case facts.resolution_of(module_facts, callee.location) {
    Ok(girard.ModuleFn(module: "gleam/string", name: "length")) -> Ok(Graphemes)
    Ok(girard.ModuleFn(module: "gleam/list", name: "length")) -> Ok(Elements)
    _ -> Error(Nil)
  }
}

// Comparisons

// Whether the comparison checks for emptiness or for the opposite.
type Polarity {
  Empty
  NotEmpty
}

fn is_comparison(operator: glance.BinaryOperator) -> Bool {
  case operator {
    glance.Eq
    | glance.NotEq
    | glance.LtInt
    | glance.LtEqInt
    | glance.GtInt
    | glance.GtEqInt -> True
    _ -> False
  }
}

// What `length <operator> value` checks, when it checks for emptiness.
fn polarity(
  operator: glance.BinaryOperator,
  value: Int,
) -> Result(Polarity, Nil) {
  case operator, value {
    glance.Eq, 0 | glance.LtEqInt, 0 | glance.LtInt, 1 -> Ok(Empty)
    glance.NotEq, 0 | glance.GtInt, 0 | glance.GtEqInt, 1 -> Ok(NotEmpty)
    _, _ -> Error(Nil)
  }
}

// Whether the compiler warns on `length <operator> literal`, with the
// literal as written: only a direct `list.length` call through a module
// access does, compared with a literal whose text is exactly `0` or `-0`,
// or exactly `1`.
fn compiler_warns(
  call: LengthCall,
  operator: glance.BinaryOperator,
  literal: glance.Expression,
) -> Bool {
  let checked = call.kind == Elements && call.direct_and_qualified
  case literal {
    glance.Int(value: text, ..) if checked ->
      case operator, text {
        glance.Eq, "0"
        | glance.NotEq, "0"
        | glance.GtInt, "0"
        | glance.LtEqInt, "0"
        | glance.Eq, "-0"
        | glance.NotEq, "-0"
        | glance.GtInt, "-0"
        | glance.LtEqInt, "-0"
        | glance.LtInt, "1"
        -> True
        _, _ -> False
      }
    _ -> False
  }
}

// The `case` form

// Whether a `case` on a length has exactly these two clauses: a lone zero
// pattern, in any spelling, with no alternative and no guard, then a
// discard. A clause that binds the length or matches another number is
// counting, not checking for emptiness.
fn is_emptiness_case(zero: glance.Clause, rest: glance.Clause) -> Bool {
  case zero, rest {
    glance.Clause(patterns: [[glance.PatternInt(value:, ..)]], guard: None, ..),
      glance.Clause(patterns: [[glance.PatternDiscard(..)]], guard: None, ..)
    -> int_literal.parse(value) == Ok(0)
    _, _ -> False
  }
}

// Reports

fn comparison_report(
  location: glance.Span,
  call: LengthCall,
  polarity: Polarity,
) -> Report {
  let operator = case polarity {
    Empty -> "=="
    NotEmpty -> "!="
  }
  let empty = empty(call)
  rule.report(at: location, label: label(call))
  |> rule.with_message([
    why(call)
    <> " Comparing with `"
    <> empty
    <> "` answers the same question at once.",
  ])
  |> rule.with_hint(
    "Compare with `"
    <> empty
    <> "` instead: `"
    <> operator
    <> " "
    <> empty
    <> "`.",
  )
}

fn case_report(location: glance.Span, call: LengthCall) -> Report {
  let hint = case call.kind {
    Graphemes ->
      "Match on the string itself: `case text { \"\" -> ... _ -> ... }`."
    Elements -> "Match on the list itself: `case items { [] -> ... _ -> ... }`."
  }
  rule.report(at: location, label: label(call))
  |> rule.with_message([
    why(call)
    <> " Matching on `"
    <> empty(call)
    <> "` answers the same question at once.",
  ])
  |> rule.with_hint(hint)
}

// The empty value of what the call counts.
fn empty(call: LengthCall) -> String {
  case call.kind {
    Graphemes -> "\"\""
    Elements -> "[]"
  }
}

fn label(call: LengthCall) -> String {
  case call.kind {
    Graphemes -> "This counts every grapheme of the string"
    Elements -> "This counts every element of the list"
  }
}

fn why(call: LengthCall) -> String {
  case call.kind {
    Graphemes ->
      "`string.length` walks the whole string to count its graphemes, and its docs say to avoid it in a loop."
    Elements ->
      "`list.length` walks the whole list to count its elements, as the compiler says when it warns on `list.length(items) == 0`."
  }
}
