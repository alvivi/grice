//// `grice_rules/filter-then-length`: `list.filter` then `list.length`,
//// which `list.count` does without building the filtered list.
////
//// It's typed: it finds each function by what girard resolved the call
//// to, and reads the calls in every form `call` reads, nested or piped.
//// It's silent inside `list.count` itself.
////
//// It's also silent where the count is checked for emptiness, as in
//// `xs |> list.filter(p) |> list.length > 0`, since `list.count` would
//// still count every element there. The compiler or
//// no-length-for-emptiness reports the forms each reads, with a fix that
//// doesn't count; a captured `list.length(of: _)` gets no finding from
//// either. The check is read as no-length-for-emptiness reads it, and its
//// operand with `call`, so every form the pack reads is skipped, the
//// captured length included. The walk reaches a check before its
//// operand, so the check puts the operand's location in the context, and
//// the operand takes it out when the walk reaches it.

import glance
import gleam/option.{None}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import grice/facts.{type ModuleFacts, type Typed}
import grice/internal/rules/call.{type Call}
import grice/internal/rules/no_length_for_emptiness
import grice/rule.{type Report, type Rule}

const code = "grice_rules/filter-then-length"

type Context {
  Context(
    // Whether the walk is inside the function the rule recommends.
    exempt: Bool,
    // The locations of the counts an emptiness check reads, which the walk
    // hasn't reached yet.
    checked: Set(glance.Span),
  )
}

/// The rule.
pub fn rule() -> Rule {
  rule.module(code, title: "A filter then a length")
  |> rule.typed
  |> rule.with_context(initial: Context(exempt: False, checked: set.new()))
  |> rule.on_function(fn(context, function, module_facts) {
    let exempt =
      call.defines(module_facts, function, [#("gleam/list", "count")])
    #(Context(..context, exempt:), [])
  })
  |> rule.on_function_exit(fn(context, _function, _module_facts) {
    #(Context(..context, exempt: False), [])
  })
  |> rule.on_expression(fn(context, expression, module_facts) {
    case context.exempt {
      True -> #(context, [])
      False -> check(context, expression, module_facts)
    }
  })
  |> rule.build
}

fn check(
  context: Context,
  expression: glance.Expression,
  module_facts: ModuleFacts(Typed),
) -> #(Context, List(Report)) {
  let context = skip_checked(context, expression, module_facts)
  case composition(expression, module_facts) {
    Ok(#(span, filter)) ->
      case set.contains(context.checked, expression.location) {
        True -> #(
          Context(
            ..context,
            checked: set.delete(context.checked, expression.location),
          ),
          [],
        )
        False -> #(context, [report(span, filter)])
      }
    Error(Nil) -> #(context, [])
  }
}

// When `expression` checks a count of a filter for emptiness, the context
// with the count's location, so the walk skips it when it gets there.
fn skip_checked(
  context: Context,
  expression: glance.Expression,
  module_facts: ModuleFacts(Typed),
) -> Context {
  let counted = {
    use operand <- result.try(no_length_for_emptiness.emptiness_operand(
      expression,
    ))
    use _ <- result.map(composition(operand, module_facts))
    operand.location
  }
  case counted {
    Ok(location) ->
      Context(..context, checked: set.insert(context.checked, location))
    Error(Nil) -> context
  }
}

// The span from the earlier call to the later of a `list.length` call of
// a `list.filter` call, and the `list.filter` call.
fn composition(
  expression: glance.Expression,
  module_facts: ModuleFacts(Typed),
) -> Result(#(glance.Span, Call), Nil) {
  let length = [#("gleam/list", "length")]
  case call.composition(expression, module_facts, outer: length) {
    Ok(call.Composition(
      inner: call.Call(
        module: "gleam/list",
        name: "filter",
        arguments: [_, _],
        ..,
      ) as filter,
      span:,
      ..,
    )) -> Ok(#(span, filter))
    _ -> Error(Nil)
  }
}

fn report(span: glance.Span, filter: Call) -> Report {
  let relabel =
    call.relabel(filter, first: None, renamed: [#("keeping", "where")])
  rule.report(at: span, label: "This builds a filtered list only to count it")
  |> rule.with_message([
    "`list.filter` builds a new list that `list.length` then walks to count. `list.count` counts the elements that pass without building one: \"Counts the number of elements in a given list satisfying a given predicate.\"",
  ])
  |> rule.with_hint(string.join(
    [
      "Call `list.count(list, where: predicate)` in place of `list.filter`, and drop the `list.length`.",
      ..relabel
    ],
    " ",
  ))
}
