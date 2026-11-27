//// `grice_rules/reverse-then-first`: `list.reverse` then `list.first`,
//// which `list.last` does without the reversed copy.
////
//// It's typed: it finds each function by what girard resolved the call
//// to, and reads the calls in every form `call` reads, nested or piped.
//// It's silent inside `list.last` itself.

import glance
import grice/facts.{type ModuleFacts, type Typed}
import grice/internal/rules/call
import grice/rule.{type Report, type Rule}

const code = "grice_rules/reverse-then-first"

/// The rule.
pub fn rule() -> Rule {
  rule.module(code, title: "A reverse then a first")
  |> rule.typed
  |> call.build(silent_inside: [#("gleam/list", "last")], on_expression: check)
}

fn check(
  expression: glance.Expression,
  module_facts: ModuleFacts(Typed),
) -> List(Report) {
  let first = [#("gleam/list", "first")]
  case call.composition(expression, module_facts, outer: first) {
    Ok(call.Composition(
      inner: call.Call(
        module: "gleam/list",
        name: "reverse",
        arguments: [_],
        ..,
      ),
      span:,
      ..,
    )) -> [report(span)]
    _ -> []
  }
}

fn report(span: glance.Span) -> Report {
  rule.report(
    at: span,
    label: "This reverses the whole list to take its last element",
  )
  |> rule.with_message([
    "`list.reverse` builds a reversed copy of the list only for `list.first` to take one element of it. `list.last` walks to the last element without the copy.",
  ])
  |> rule.with_hint(
    "Call `list.last(list)` in place of `list.reverse`, and drop the `list.first`.",
  )
}
