//// `grice_rules/list-map-then-flatten`: `list.map` then `list.flatten`,
//// which `list.flat_map` does in one call.
////
//// It's typed: it finds each function by what girard resolved the call
//// to, and reads the calls in every form `call` reads, nested or piped. It's
//// silent inside `list.flat_map` itself, which the standard library writes
//// as `flatten(map(list, fun))`.

import glance
import grice/facts.{type ModuleFacts, type Typed}
import grice/internal/rules/call
import grice/rule.{type Report, type Rule}

const code = "grice_rules/list-map-then-flatten"

/// The rule.
pub fn rule() -> Rule {
  rule.module(code, title: "A map then a flatten of a list")
  |> rule.typed
  |> call.build(
    silent_inside: [#("gleam/list", "flat_map")],
    on_expression: check,
  )
}

fn check(
  expression: glance.Expression,
  module_facts: ModuleFacts(Typed),
) -> List(Report) {
  let flatten = [#("gleam/list", "flatten")]
  case call.composition(expression, module_facts, outer: flatten) {
    Ok(call.Composition(
      inner: call.Call(module: "gleam/list", name: "map", arguments: [_, _], ..),
      span:,
      ..,
    )) -> [report(span)]
    _ -> []
  }
}

fn report(span: glance.Span) -> Report {
  rule.report(
    at: span,
    label: "This maps a list into lists and then flattens them",
  )
  |> rule.with_message([
    "`list.flat_map` does both in one call. Its docs say it \"Maps the list with the given function into a list of lists, and then flattens it.\"",
  ])
  |> rule.with_hint(
    "Call `list.flat_map(over: list, with: fun)` in place of `list.map`, and drop the `list.flatten`.",
  )
}
