//// Tests for `grice_rules/filter-then-length`, over its samples and
//// sources the compiler won't let be samples, each linted for both
//// targets.

import birdie
import gleam/list
import gleam/option.{Some}
import grice/diagnostic.{type Diagnostic, Diagnostic}
import grice/rules
import grice/support
import grice/testing

const code = "grice_rules/filter-then-length"

// Samples

pub fn filter_then_length_flagged_samples_test() {
  let run =
    support.sample("filter_then_length_flagged")
    |> support.on_both_targets([rules.filter_then_length()])
  testing.expect_codes(run, list.repeat(code, 14))
  testing.render(run)
  |> birdie.snap(title: "built-in filter-then-length: flagged samples")
}

pub fn filter_then_length_clean_samples_test() {
  support.sample("filter_then_length_clean")
  |> support.on_both_targets([rules.filter_then_length()])
  |> testing.expect_none
}

// Emptiness checks

// Each count of a filter checked for emptiness, which `list.count` would
// still count in full: piped, matched on zero, compared as the compiler
// warns on, so it can't be a sample, and piped into a labelled capture.
// Then a count compared with 1, which isn't a check for emptiness, and a
// count on its own.
const checked =
  "import gleam/list

pub fn piped(ages: List(Int), adult: fn(Int) -> Bool) -> Bool {
  ages |> list.filter(adult) |> list.length > 0
}

pub fn matched(ages: List(Int), adult: fn(Int) -> Bool) -> String {
  case list.length(list.filter(ages, adult)) {
    0 -> \"none\"
    _ -> \"some\"
  }
}

pub fn compared(ages: List(Int), adult: fn(Int) -> Bool) -> Bool {
  list.length(list.filter(ages, adult)) == 0
}

pub fn captured(ages: List(Int), adult: fn(Int) -> Bool) -> Bool {
  ages |> list.filter(adult) |> list.length(of: _) > 0
}

pub fn more_than_one(people: List(Int), grown: fn(Int) -> Bool) -> Bool {
  list.length(list.filter(people, grown)) > 1
}

pub fn counted(members: List(Int), active: fn(Int) -> Bool) -> Int {
  members |> list.filter(active) |> list.length
}
"

// With the default set, no-length-for-emptiness reports the two checks it
// reads, the pipe and the `case`, and the compiler the comparison it warns
// on. filter-then-length reports only the counts that aren't checked for
// emptiness, so each check gets at most one finding, and the captured
// length, which no-length-for-emptiness doesn't read, gets none.
pub fn filter_then_length_skips_checks_for_emptiness_test() {
  let found =
    checked
    |> support.on_both_targets(list.append(rules.default(), rules.simplify()))
    |> testing.diagnostics
  assert places(found)
    == [
      #(
        "grice_rules/no-length-for-emptiness",
        support.span_of(
          checked,
          "ages |> list.filter(adult) |> list.length > 0",
        ),
      ),
      #(
        "grice_rules/no-length-for-emptiness",
        support.span_of(checked, "list.length(list.filter(ages, adult))"),
      ),
      #(
        code,
        support.span_of(checked, "list.length(list.filter(people, grown))"),
      ),
      #(code, support.span_of(checked, "list.filter(active) |> list.length")),
    ]
}

// Without the default set, the checks are still skipped.
pub fn filter_then_length_skips_checks_for_emptiness_alone_test() {
  let found =
    checked
    |> support.on_both_targets(rules.simplify())
    |> testing.diagnostics
  assert places(found)
    == [
      #(
        code,
        support.span_of(checked, "list.length(list.filter(people, grown))"),
      ),
      #(code, support.span_of(checked, "list.filter(active) |> list.length")),
    ]
}

// Each diagnostic's code and the byte span of its primary label.
fn places(found: List(Diagnostic)) -> List(#(String, diagnostic.Span)) {
  list.map(found, fn(found) {
    let assert Some(location) = found.location
    #(found.code, location.primary.span)
  })
}

// The function it recommends

// A project that defines `gleam/list` itself, with `count` written as a
// filter then a length, which the standard library's isn't, so the corpus
// gate can't show this: the rule leaves `count` alone, but not another
// function written the same way.
pub fn filter_then_length_is_silent_in_list_count_test() {
  let list_module =
    "pub fn filter(list: List(a), keeping predicate: fn(a) -> Bool) -> List(a) {
  case list {
    [] -> []
    [first, ..rest] ->
      case predicate(first) {
        True -> [first, ..filter(rest, predicate)]
        False -> filter(rest, predicate)
      }
  }
}

pub fn length(of list: List(a)) -> Int {
  case list {
    [] -> 0
    [_, ..rest] -> 1 + length(rest)
  }
}

pub fn count(list: List(a), where predicate: fn(a) -> Bool) -> Int {
  length(filter(list, predicate))
}

pub fn other(items: List(a), where keep: fn(a) -> Bool) -> Int {
  length(filter(items, keep))
}
"
  let assert [Diagnostic(code: found, location: Some(location), ..)] =
    support.project_on_both_targets(
      "",
      [#("src/gleam/list.gleam", list_module)],
      [rules.filter_then_length()],
    )
    |> testing.diagnostics
  assert found == code
  assert location.path == "src/gleam/list.gleam"
  assert location.primary.span
    == support.span_of(list_module, "length(filter(items, keep))")
}

// Gaps

// girard can't type `broken`, so the rule has no answer there and stays
// silent, and the run has only the note on the gap.
pub fn filter_then_length_is_silent_over_a_gap_test() {
  "import gleam/list

pub fn broken(ages: List(Int), adult: fn(Int) -> Bool) -> Int {
  let _ = 1 + \"one\"
  list.length(list.filter(ages, adult))
}
"
  |> support.on_both_targets([rules.filter_then_length()])
  |> testing.expect_codes(["grice/untyped-definition"])
}
