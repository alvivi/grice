//// Tests for `grice_rules/map-then-flatten`, over its samples and sources
//// the compiler won't let be samples, each linted for both targets.

import birdie
import gleam/list
import gleam/option.{Some}
import grice/diagnostic.{Diagnostic}
import grice/rules
import grice/support
import grice/testing

const code = "grice_rules/map-then-flatten"

// Samples

pub fn map_then_flatten_flagged_samples_test() {
  let run =
    support.sample("map_then_flatten_flagged")
    |> support.on_both_targets([rules.map_then_flatten()])
  testing.expect_codes(run, list.repeat(code, 14))
  testing.render(run)
  |> birdie.snap(title: "built-in map-then-flatten: flagged samples")
}

pub fn map_then_flatten_clean_samples_test() {
  support.sample("map_then_flatten_clean")
  |> support.on_both_targets([rules.map_then_flatten()])
  |> testing.expect_none
}

// Forms the compiler warns on

// The compiler warns that a capture whose placeholder is its first
// argument, unlabelled, is redundant, and `gleam format` drops it, so a
// sample can't hold the pipe into one. The warning is about the capture,
// not about the map then the flatten, so the rule reports it.
pub fn map_then_flatten_reports_a_pipe_into_a_redundant_capture_test() {
  "import gleam/result

pub fn port(parsed: Result(Int, Nil), check: fn(Int) -> Result(Int, Nil)) -> Result(Int, Nil) {
  result.map(parsed, check) |> result.flatten(_)
}
"
  |> support.on_both_targets([rules.map_then_flatten()])
  |> testing.expect_codes([code])
}

// The function it recommends

// A project that defines `gleam/result` itself, as the standard library
// does: `try` is written as a map then a flatten, and the rule leaves it
// alone, but not another function written the same way.
pub fn map_then_flatten_is_silent_in_result_try_test() {
  let result_module =
    "pub fn map(over result: Result(a, e), with fun: fn(a) -> b) -> Result(b, e) {
  case result {
    Ok(x) -> Ok(fun(x))
    Error(e) -> Error(e)
  }
}

pub fn flatten(result: Result(Result(a, e), e)) -> Result(a, e) {
  case result {
    Ok(x) -> x
    Error(e) -> Error(e)
  }
}

pub fn try(result: Result(a, e), apply fun: fn(a) -> Result(b, e)) -> Result(b, e) {
  flatten(map(result, fun))
}

pub fn other(value: Result(a, e), apply callback: fn(a) -> Result(b, e)) -> Result(b, e) {
  flatten(map(value, callback))
}
"
  let assert [Diagnostic(code: found, location: Some(location), ..)] =
    support.project_on_both_targets(
      "",
      [#("src/gleam/result.gleam", result_module)],
      [rules.map_then_flatten()],
    )
    |> testing.diagnostics
  assert found == code
  assert location.path == "src/gleam/result.gleam"
  assert location.primary.span
    == support.span_of(result_module, "flatten(map(value, callback))")
}

// Gaps

// girard can't type `broken`, so the rule has no answer there and stays
// silent, and the run has only the note on the gap.
pub fn map_then_flatten_is_silent_over_a_gap_test() {
  "import gleam/result

pub fn broken(parsed: Result(Int, Nil), check: fn(Int) -> Result(Int, Nil)) -> Result(Int, Nil) {
  let _ = 1 + \"one\"
  result.flatten(result.map(parsed, check))
}
"
  |> support.on_both_targets([rules.map_then_flatten()])
  |> testing.expect_codes(["grice/untyped-definition"])
}
