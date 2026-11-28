//// The corpus gate: every built-in rule, the default set, the simplify
//// pack and the library pack, over the Gleam core team's packages, pinned
//// in `test/corpus/`. A rule is on by default only if it runs clean on
//// them, or each finding it keeps there is a real defect, recorded below
//// with its reason. A pack rule's finding there is either a false positive
//// to fix in the rule, or correct, and then recorded with a reason that
//// says so and that the pack is opt-in. So the gate asserts that every
//// package is clean but for those findings: every other diagnostic fails
//// it, which covers every other finding and every coverage gap, and so
//// does a module girard didn't type. A failure lists each problem.
////
//// The built-in rules include typed ones, so girard types every package,
//// and a module it couldn't type shows up as a coverage note. The gate
//// checks that every module was typed, so a rule set that lost its typed
//// rules fails it instead of passing over untyped packages.
////
//// Each allowed finding is matched one to one: a diagnostic takes at most
//// one entry with its package, path, line, column and code, so a second
//// diagnostic at the same place is a new finding. An entry no diagnostic
//// took is stale, which fails the gate too: a bump of the corpus that
//// picks up the fix must remove it. An entry must give a reason, and can't
//// allow one of grice's own diagnostics, whose codes start with `grice/`.

import gleam/list
import gleam/option.{type Option, Some}
import gleam/pair
import gleam/result
import gleam/string
import grice/corpus
import grice/coverage.{Requested}
import grice/internal/parallel
import grice/rule

// Allowed findings

// Where a finding is: its package and path, the line and column of its
// primary label, counted from 1, and the code that reports it.
type Place {
  Place(package: String, path: String, line: Int, column: Int, code: String)
}

// A finding the gate allows, and why it's a real defect.
type Allowed {
  Allowed(place: Place, reason: String)
}

const uri_range_bug =
  "A real bug: each range is written the wrong way round (`48 >= char` for `char >= 48`), so on JavaScript `uri.parse` rejects bracketed IPv6 hosts with the hex digits b to f. Reported as gleam-lang/stdlib#881, fixed by #913 (open on 2026-11-20)."

const allowed = [
  Allowed(
    place: Place(
      package: "gleam_stdlib",
      path: "src/gleam/uri.gleam",
      line: 277,
      column: 19,
      code: "grice_rules/ineffective-double-comparison",
    ),
    reason: uri_range_bug,
  ),
  Allowed(
    place: Place(
      package: "gleam_stdlib",
      path: "src/gleam/uri.gleam",
      line: 279,
      column: 22,
      code: "grice_rules/ineffective-double-comparison",
    ),
    reason: uri_range_bug,
  ),
  Allowed(
    place: Place(
      package: "gleam_stdlib",
      path: "src/gleam/uri.gleam",
      line: 281,
      column: 22,
      code: "grice_rules/ineffective-double-comparison",
    ),
    reason: uri_range_bug,
  ),
]

// The gate

pub fn core_packages_are_clean_test() {
  corpus.download()
  let installed = corpus.installed()
  let #(untyped, findings) =
    corpus.core
    |> parallel.map(fn(package) {
      let rules = corpus.built_in_rules()
      let project = corpus.load(package, installed, rules)
      let linted = corpus.lint(project, rules)
      let coverage = linted.coverage
      let typed = Requested(full: coverage.modules, partial: 0, none: 0)
      let untyped = case coverage.types == typed {
        True -> []
        False -> [package <> ": " <> corpus.describe_coverage(coverage)]
      }
      let findings =
        list.map(linted.diagnostics, fn(found) {
          let place =
            corpus.position(project, found)
            |> option.from_result
            |> option.map(fn(position) {
              let #(path, line, column) = position
              Place(package:, path:, line:, column:, code: found.code)
            })
          let description = corpus.describe_diagnostic(package, project, found)
          Finding(place:, description:)
        })
      #(untyped, findings)
    })
    |> list.unzip
  let #(unallowed, stale) = match(list.flatten(findings), allowed)
  let problems =
    list.flatten([
      list.flatten(untyped),
      list.map(unallowed, fn(finding) { finding.description }),
      list.map(stale, fn(entry) {
        "Stale: " <> describe_place(entry.place) <> " is no longer reported"
      }),
      list.flat_map(allowed, invalid),
    ])
  assert problems == []
    as { "The core packages aren't clean:\n" <> string.join(problems, "\n") }
}

// Matching

// A diagnostic of the run over a package: where it is, when it has a
// location, and how the gate describes it.
type Finding {
  Finding(place: Option(Place), description: String)
}

// Each finding takes the first entry left at its place. What's left: the
// findings no entry took, and the entries no finding took, each in order.
fn match(
  findings: List(Finding),
  allowed: List(Allowed),
) -> #(List(Finding), List(Allowed)) {
  let entries = list.map(allowed, fn(entry) { #(entry.place, entry) })
  let #(unallowed, left) =
    list.fold(findings, #([], entries), fn(state, finding) {
      let #(unallowed, left) = state
      let taken =
        option.to_result(finding.place, Nil)
        |> result.try(list.key_pop(left, _))
      case taken {
        Ok(#(_entry, left)) -> #(unallowed, left)
        Error(Nil) -> #([finding, ..unallowed], left)
      }
    })
  #(list.reverse(unallowed), list.map(left, pair.second))
}

// What's wrong with an entry itself.
fn invalid(entry: Allowed) -> List(String) {
  let place = describe_place(entry.place)
  let reason = case string.trim(entry.reason) {
    "" -> ["Invalid: " <> place <> " gives no reason"]
    _ -> []
  }
  let code = case string.starts_with(entry.place.code, rule.reserved_prefix) {
    True -> [
      "Invalid: "
      <> place
      <> " allows one of grice's own diagnostics, which is never allowed",
    ]
    False -> []
  }
  list.append(reason, code)
}

fn describe_place(place: Place) -> String {
  place.package
  <> " "
  <> corpus.describe_position(place.path, place.line, place.column)
  <> " "
  <> place.code
}

pub fn a_second_finding_at_an_allowed_place_is_not_allowed_test() {
  let place = Place("app", "src/app.gleam", 3, 5, "my_app/no-echo")
  let found = Finding(Some(place), "found")
  assert match([found, found], [Allowed(place, "Why.")]) == #([found], [])
}

pub fn an_allowed_finding_no_longer_reported_is_stale_test() {
  let place = Place("app", "src/app.gleam", 3, 5, "my_app/no-echo")
  let elsewhere = Allowed(Place(..place, line: 4), "Why.")
  let found = Finding(Some(place), "found")
  assert match([found], [elsewhere, Allowed(place, "Why.")])
    == #([], [elsewhere])
}
