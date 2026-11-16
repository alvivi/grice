//// Rules for the runner tests, never shipped. Their `fixture/` codes keep
//// them apart from real rules. Each shows one way to build a rule: a module
//// rule with no context, one that threads a context through its hooks, a
//// project rule, and a module rule that needs types.

import girard
import glance
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import grice/facts
import grice/rule.{type Report, type Rule}

/// Reports each `echo`. It keeps no context.
pub fn no_echo() -> Rule {
  rule.module("fixture/no-echo", title: "Echo left in the code")
  |> rule.with_context(initial: Nil)
  |> rule.on_expression(fn(context, expression, _module_facts) {
    case expression {
      glance.Echo(location:, ..) -> #(context, [
        rule.report(at: location, label: "This prints when it runs")
        |> rule.with_message(["`echo` prints its value each time it runs."])
        |> rule.with_hint("Remove it once you're done debugging."),
      ])
      _ -> #(context, [])
    }
  })
  |> rule.build
}

/// Reports each function with more than one `panic`. Its context is the
/// number of panics seen in the function being walked.
pub fn many_panics() -> Rule {
  rule.module("fixture/many-panics", title: "Function with many panics")
  |> rule.with_context(initial: 0)
  |> rule.on_function(fn(_panics, _function, _module_facts) { #(0, []) })
  |> rule.on_expression(fn(panics, expression, _module_facts) {
    case expression {
      glance.Panic(..) -> #(panics + 1, [])
      _ -> #(panics, [])
    }
  })
  |> rule.on_function_exit(fn(panics, function, _module_facts) {
    case panics > 1 {
      True -> #(panics, [
        rule.report(
          at: function.definition.location,
          label: "This function panics in "
            <> int.to_string(panics)
            <> " places",
        ),
      ])
      False -> #(panics, [])
    }
  })
  |> rule.build
}

/// Reports each public function whose name another linted module also
/// gives a public function. The label names the first other module that
/// defines it, in the order the summaries come in.
pub fn duplicate_public_function() -> Rule {
  rule.project(
    "fixture/duplicate-public-function",
    title: "Public function name used twice",
  )
  |> rule.per_module(fn(module_facts) {
    facts.module(module_facts).functions
    |> list.filter(fn(function) {
      function.definition.publicity == glance.Public
    })
    |> list.map(fn(function) {
      #(function.definition.name, function.definition.location)
    })
  })
  |> rule.final(fn(summaries) {
    // The first two modules that define each name, in summary order. One
    // pass to fold them and one to report keeps the evaluation linear.
    let definers =
      list.fold(summaries, dict.new(), fn(definers, summary) {
        let #(module_name, functions) = summary
        use definers, #(name, _location) <- list.fold(functions, definers)
        use found <- dict.upsert(definers, name)
        case found {
          None -> [module_name]
          Some([first]) -> [first, module_name]
          Some(first_two) -> first_two
        }
      })
    use #(module_name, functions) <- list.flat_map(summaries)
    use #(name, location) <- list.filter_map(functions)
    let other = case dict.get(definers, name) {
      Ok([first, second, ..]) if first == module_name -> Ok(second)
      Ok([first, _, ..]) -> Ok(first)
      Ok([_]) | Ok([]) | Error(Nil) -> Error(Nil)
    }
    use other <- result.map(other)
    let label = "`" <> other <> "` also defines `" <> name <> "`"
    #(module_name, rule.report(at: location, label:))
  })
}

/// Reports each `let _ = value` whose value is a `Result` from the prelude.
/// The compiler warns about an unused `Result` but not about one discarded
/// this way. The rule needs types, and stays silent when girard has no
/// answer.
pub fn discarded_result() -> Rule {
  rule.module("fixture/discarded-result", title: "Result discarded")
  |> rule.typed
  |> rule.with_context(initial: Nil)
  |> rule.on_statement(fn(context, statement, module_facts) {
    case statement {
      glance.Assignment(
        location:,
        kind: glance.Let,
        pattern: glance.PatternDiscard(..),
        value:,
        ..,
      ) -> #(
        context,
        report_result(location, facts.type_of(module_facts, value.location)),
      )
      _ -> #(context, [])
    }
  })
  |> rule.build
}

fn report_result(
  location: glance.Span,
  value: Result(girard.Type, facts.Unknown),
) -> List(Report) {
  case value {
    Ok(girard.Named(module: "gleam", name: "Result", ..)) -> [
      rule.report(at: location, label: "This discards a `Result`")
      |> rule.with_message([
        "A `Result` says whether something failed, and discarding it hides the failure.",
      ])
      |> rule.with_hint("Handle the error, or assert that there is none."),
    ]
    Ok(_) | Error(_) -> []
  }
}
