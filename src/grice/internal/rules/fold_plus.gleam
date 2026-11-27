//// `grice_rules/fold-plus`: a `list.fold` that sums a list of ints from
//// 0, which `int.sum` does.
////
//// It's typed: it finds `list.fold` by what girard resolved the call to,
//// and reads the call in every form `call` reads. Its arguments are
//// matched to `over`, `from` and `with` as Gleam matches them, and a
//// piped fold is read only when the pipe supplies the list: piping the
//// initial value or the function in would leave `0 |> int.sum(xs)`. A
//// fold sums when:
////
//// - `from` is the literal 0, written without a sign, in any spelling,
////   such as `0x0`. `-0` is negative zero on JavaScript, which the fold
////   returns for an empty list and `int.sum` doesn't.
//// - `with` is `int.add`, by girard's resolution, or an anonymous function
////   of two named parameters whose body is only their sum.
////
//// On JavaScript, where an Int is a number, `int.sum` adds each element as
//// `element + total`. Adding in the other order gives the same number, but
//// a NaN result can have other bits, so on a project whose target is
//// JavaScript the rule reads only `fn(total, x) { x + total }`, which adds
//// as `int.sum` does. Code built for JavaScript from a project configured
//// for Erlang can still see the difference. It's silent inside `int.sum`
//// itself.

import glance
import gleam/bool
import gleam/result
import gleam/string
import grice/facts.{type ModuleFacts, type Typed}
import grice/internal/rules/call
import grice/internal/rules/int_literal
import grice/rule.{type Report, type Rule}

const code = "grice_rules/fold-plus"

/// The rule.
pub fn rule() -> Rule {
  rule.module(code, title: "A fold that sums")
  |> rule.typed
  |> call.build(silent_inside: [#("gleam/int", "sum")], on_expression: check)
}

fn check(
  expression: glance.Expression,
  module_facts: ModuleFacts(Typed),
) -> List(Report) {
  case sum(expression, module_facts) {
    Ok(span) -> [report(span)]
    Error(Nil) -> []
  }
}

// `list.fold`'s parameters, in order.
const parameters = ["over", "from", "with"]

// The span of a `list.fold` call that sums a list of ints from 0.
fn sum(
  expression: glance.Expression,
  module_facts: ModuleFacts(Typed),
) -> Result(glance.Span, Nil) {
  use fold <- result.try(call.read(expression, module_facts))
  use <- bool.guard(when: !is_fold(fold), return: Error(Nil))
  use from <- result.try(call.argument(fold, parameters, "from"))
  use with <- result.try(call.argument(fold, parameters, "with"))
  // At most one argument is piped, and it must be the list.
  use <- bool.guard(when: from.piped || with.piped, return: Error(Nil))
  use <- bool.guard(when: !is_zero(from.value), return: Error(Nil))
  use order <- result.try(adds(with.value, module_facts))
  case facts.target(module_facts), order {
    facts.Erlang, _ | facts.JavaScript, ElementFirst -> Ok(fold.span)
    facts.JavaScript, TotalFirst -> Error(Nil)
  }
}

fn is_fold(fold: call.Call) -> Bool {
  case fold {
    call.Call(module: "gleam/list", name: "fold", arguments: [_, _, _], ..) ->
      True
    _ -> False
  }
}

// Whether `value` is the literal 0, written without a sign.
fn is_zero(value: glance.Expression) -> Bool {
  case value {
    glance.Int(value: text, ..) ->
      !string.starts_with(text, "-") && int_literal.parse(text) == Ok(0)
    _ -> False
  }
}

// The order in which a fold's function adds the total and the element.
type Order {
  // `element + total`, as `int.sum` adds on JavaScript.
  ElementFirst
  // `total + element`, as `int.add` adds.
  TotalFirst
}

// The order in which `function` adds the total and the element, when it's
// `int.add` or an anonymous function of two named parameters, the total
// and the element, whose body is only their sum.
fn adds(
  function: glance.Expression,
  module_facts: ModuleFacts(Typed),
) -> Result(Order, Nil) {
  case function {
    glance.Fn(
      arguments: [
        glance.FnParameter(name: glance.Named(total), ..),
        glance.FnParameter(name: glance.Named(element), ..),
      ],
      body: [
        glance.Expression(glance.BinaryOperator(
          name: glance.AddInt,
          left: glance.Variable(name: left, ..),
          right: glance.Variable(name: right, ..),
          ..,
        )),
      ],
      ..,
    )
      if total != element
    ->
      case
        left == element && right == total,
        left == total && right == element
      {
        True, _ -> Ok(ElementFirst)
        _, True -> Ok(TotalFirst)
        False, False -> Error(Nil)
      }
    _ ->
      case call.module_function(function, module_facts) {
        Ok(#("gleam/int", "add")) -> Ok(TotalFirst)
        _ -> Error(Nil)
      }
  }
}

fn report(span: glance.Span) -> Report {
  rule.report(at: span, label: "This sums a list of ints with a fold")
  |> rule.with_message([
    "`int.sum` adds up the same numbers: \"Sums a list of ints.\"",
  ])
  |> rule.with_hint(
    "Use `sum` from `gleam/int` on the list in place of the fold.",
  )
}
