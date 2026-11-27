//// Tests for `grice_rules/list-map-then-flatten`, over its samples and
//// sources the compiler won't let be samples, each linted for both
//// targets.

import birdie
import gleam/list
import gleam/option.{Some}
import grice/diagnostic.{Diagnostic}
import grice/rules
import grice/support
import grice/testing

const code = "grice_rules/list-map-then-flatten"

// Samples

pub fn list_map_then_flatten_flagged_samples_test() {
  let run =
    support.sample("list_map_then_flatten_flagged")
    |> support.on_both_targets([rules.list_map_then_flatten()])
  testing.expect_codes(run, list.repeat(code, 10))
  testing.render(run)
  |> birdie.snap(title: "built-in list-map-then-flatten: flagged samples")
}

pub fn list_map_then_flatten_clean_samples_test() {
  support.sample("list_map_then_flatten_clean")
  |> support.on_both_targets([rules.list_map_then_flatten()])
  |> testing.expect_none
}

// Forms the compiler warns on

// The compiler warns that a capture whose placeholder is its first
// argument, unlabelled, is redundant, and `gleam format` drops it, so a
// sample can't hold the pipe into one. The warning is about the capture,
// not about the map then the flatten, so the rule reports it.
pub fn list_map_then_flatten_reports_a_pipe_into_a_redundant_capture_test() {
  "import gleam/list

pub fn cells(rows: List(Int), cells: fn(Int) -> List(Int)) -> List(Int) {
  rows |> list.map(cells) |> list.flatten(_)
}
"
  |> support.on_both_targets([rules.list_map_then_flatten()])
  |> testing.expect_codes([code])
}

// A pipeline

// A pipeline that maps, flattens and counts gives one finding, on the map
// and the flatten, and nothing for the count of the flattened list.
pub fn a_mixed_pipeline_gives_one_finding_test() {
  let source =
    "import gleam/list

pub fn count(rows: List(Int), cells: fn(Int) -> List(Int)) -> Int {
  rows |> list.map(cells) |> list.flatten |> list.length
}
"
  let assert [Diagnostic(code: found, location: Some(location), ..)] =
    source
    |> support.on_both_targets(rules.simplify())
    |> testing.diagnostics
  assert found == code
  assert location.primary.span
    == support.span_of(source, "list.map(cells) |> list.flatten")
}

// The function it recommends

// A project that defines `gleam/list` itself, as the standard library
// does: `flat_map` is written as a map then a flatten, and the rule leaves
// it alone, but not another function written the same way.
pub fn list_map_then_flatten_is_silent_in_list_flat_map_test() {
  let list_module =
    "pub fn map(list: List(a), with fun: fn(a) -> b) -> List(b) {
  case list {
    [] -> []
    [first, ..rest] -> [fun(first), ..map(rest, fun)]
  }
}

pub fn flatten(lists: List(List(a))) -> List(a) {
  case lists {
    [] -> []
    [first, ..rest] -> append(first, flatten(rest))
  }
}

fn append(first: List(a), second: List(a)) -> List(a) {
  case first {
    [] -> second
    [item, ..rest] -> [item, ..append(rest, second)]
  }
}

pub fn flat_map(over list: List(a), with fun: fn(a) -> List(b)) -> List(b) {
  flatten(map(list, fun))
}

pub fn other(over items: List(a), with callback: fn(a) -> List(b)) -> List(b) {
  flatten(map(items, callback))
}
"
  let assert [Diagnostic(code: found, location: Some(location), ..)] =
    support.project_on_both_targets(
      "",
      [#("src/gleam/list.gleam", list_module)],
      [rules.list_map_then_flatten()],
    )
    |> testing.diagnostics
  assert found == code
  assert location.path == "src/gleam/list.gleam"
  assert location.primary.span
    == support.span_of(list_module, "flatten(map(items, callback))")
}

// Gaps

// girard can't type `broken`, so the rule has no answer there and stays
// silent, and the run has only the note on the gap.
pub fn list_map_then_flatten_is_silent_over_a_gap_test() {
  "import gleam/list

pub fn broken(rows: List(Int), cells: fn(Int) -> List(Int)) -> List(Int) {
  let _ = 1 + \"one\"
  list.flatten(list.map(rows, cells))
}
"
  |> support.on_both_targets([rules.list_map_then_flatten()])
  |> testing.expect_codes(["grice/untyped-definition"])
}
