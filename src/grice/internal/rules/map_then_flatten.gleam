//// `grice_rules/map-then-flatten`: `result.map` then `result.flatten`, or
//// `option.map` then `option.flatten`, which `result.try` and
//// `option.then` do in one call.
////
//// It's typed: it finds each function by what girard resolved the call
//// to, and reads the calls in every form `call` reads, nested or piped,
//// so `result.map(r, f) |> result.flatten` and
//// `r |> result.map(f) |> result.flatten` are both found. It's silent
//// inside `result.try` and `option.then` themselves.

import glance
import gleam/option.{Some}
import gleam/string
import grice/facts.{type ModuleFacts, type Typed}
import grice/internal/rules/call.{type Call}
import grice/rule.{type Report, type Rule}

const code = "grice_rules/map-then-flatten"

/// The rule.
pub fn rule() -> Rule {
  rule.module(code, title: "A map then a flatten")
  |> rule.typed
  |> call.build(
    silent_inside: [#("gleam/result", "try"), #("gleam/option", "then")],
    on_expression: check,
  )
}

// The type a `map` then a `flatten` works on.
type Kind {
  OfResult
  OfOption
}

fn check(
  expression: glance.Expression,
  module_facts: ModuleFacts(Typed),
) -> List(Report) {
  let flattens = [#("gleam/result", "flatten"), #("gleam/option", "flatten")]
  case call.composition(expression, module_facts, outer: flattens) {
    Ok(call.Composition(
      outer: call.Call(module: "gleam/result", ..),
      inner: call.Call(
        module: "gleam/result",
        name: "map",
        arguments: [_, _],
        ..,
      ) as map,
      span:,
    )) -> [report(OfResult, span, map)]
    Ok(call.Composition(
      outer: call.Call(module: "gleam/option", ..),
      inner: call.Call(
        module: "gleam/option",
        name: "map",
        arguments: [_, _],
        ..,
      ) as map,
      span:,
    )) -> [report(OfOption, span, map)]
    _ -> []
  }
}

fn report(kind: Kind, span: glance.Span, map: Call) -> Report {
  let #(label, module, try, why) = case kind {
    OfResult -> #(
      "This maps a `Result` and then flattens it",
      "result",
      "try",
      ", and it is the function `use` chains fallible steps with.",
    )
    OfOption -> #(
      "This maps an `Option` and then flattens it",
      "option",
      "then",
      ".",
    )
  }
  let relabel =
    call.relabel(map, first: Some("over"), renamed: [#("with", "apply")])
  rule.report(at: span, label:)
  |> rule.with_message([
    "`"
    <> module
    <> "."
    <> try
    <> "` does both in one call: its docs say it \"is the equivalent of calling `map` followed by `flatten`\""
    <> why,
  ])
  |> rule.with_hint(string.join(
    [
      "Call `"
        <> module
        <> "."
        <> try
        <> "("
        <> module
        <> ", apply: fun)` in place of `"
        <> module
        <> ".map`, and drop the `"
        <> module
        <> ".flatten`.",
      ..relabel
    ],
    " ",
  ))
}
