//// `grice_rules/no-echo`: an `echo` left in a module outside `test/` and
//// `dev/`. It reads only the syntax tree: `echo` is a keyword, so every
//// `glance.Echo` is one, with or without a message, alone or in a pipe.

import glance
import gleam/string
import grice/facts
import grice/rule.{type Report, type Rule}

const code = "grice_rules/no-echo"

/// The rule. It reports every `echo` at the span glance gives it, and
/// nothing in a module whose path starts with `test/` or `dev/`, even when
/// `include` selects those.
pub fn rule() -> Rule {
  rule.module(code, title: "Leftover `echo`")
  |> rule.with_context(initial: Nil)
  |> rule.on_expression(fn(context, expression, module_facts) {
    case expression {
      glance.Echo(location:, ..) ->
        case is_exempt(facts.path(module_facts)) {
          True -> #(context, [])
          False -> #(context, [report(location)])
        }
      _ -> #(context, [])
    }
  })
  |> rule.build
}

// Tests and development tools may print as they like: neither is part of
// what a package publishes or an application runs.
fn is_exempt(path: String) -> Bool {
  string.starts_with(path, "test/") || string.starts_with(path, "dev/")
}

fn report(location: glance.Span) -> Report {
  rule.report(at: location, label: "This prints debug output when it runs")
  |> rule.with_message([
    "`echo` is for debugging. `gleam build` accepts it, but `gleam publish` refuses a package that still has one, and an application prints it whenever this code runs.",
  ])
  |> rule.with_hint(
    "Remove the `echo` and keep its value: write `x` for `echo x`, and drop an `echo` step from a pipeline. If this module prints on purpose, use `gleam/io` instead.",
  )
}
