//// Tests for `grice_rules/check-then-assert`, over its samples and sources
//// the compiler won't let be samples, each linted for both targets.

import birdie
import gleam/list
import grice/rules
import grice/support
import grice/testing

const code = "grice_rules/check-then-assert"

// Samples

pub fn check_then_assert_flagged_samples_test() {
  let run =
    support.sample("check_then_assert_flagged")
    |> support.on_both_targets([rules.check_then_assert()])
  testing.expect_codes(run, list.repeat(code, 31))
  testing.render(run)
  |> birdie.snap(title: "built-in check-then-assert: flagged samples")
}

pub fn check_then_assert_clean_samples_test() {
  support.sample("check_then_assert_clean")
  |> support.on_both_targets([rules.check_then_assert()])
  |> testing.expect_none
}

// The compiler's own forms

// The compiler infers each variable's variant here, from a constructor or
// from what narrowed it, directly or through `echo`, and warns "Redundant
// assertion" on the assert, so a sample can't hold them, and the rule
// leaves them to it.
pub fn check_then_assert_leaves_the_compiler_its_forms_test() {
  "import gleam/result

pub fn constructed(n: Int) -> Int {
  let parsed = Ok(n)
  case result.is_ok(parsed) {
    True -> {
      let assert Ok(value) = parsed
      value
    }
    False -> 0
  }
}

pub fn copied(n: Int) -> Int {
  let original = Ok(n)
  let parsed = original
  case result.is_ok(parsed) {
    True -> {
      let assert Ok(value) = parsed
      value
    }
    False -> 0
  }
}

pub fn through_a_local_constructor(n: Int) -> Int {
  let make = Ok
  let parsed = make(n)
  case result.is_ok(parsed) {
    True -> {
      let assert Ok(value) = parsed
      value
    }
    False -> 0
  }
}

pub fn after_an_assert(parsed: Result(Int, Int)) -> Int {
  let assert Ok(_) = parsed
  case result.is_ok(parsed) {
    True -> {
      let assert Ok(value) = parsed
      value
    }
    False -> 0
  }
}

pub fn after_an_assert_through_echo(parsed: Result(Int, Int)) -> Int {
  let assert Ok(_) = echo parsed
  case result.is_ok(parsed) {
    True -> {
      let assert Ok(value) = parsed
      value
    }
    False -> 0
  }
}

pub fn inside_a_case_through_echo(parsed: Result(Int, Int)) -> Int {
  case echo parsed {
    Ok(_) ->
      case result.is_ok(parsed) {
        True -> {
          let assert Ok(value) = parsed
          value
        }
        False -> 0
      }
    Error(_) -> 0
  }
}

pub fn inside_a_case(parsed: Result(Int, Int)) -> Int {
  case parsed {
    Ok(_) ->
      case result.is_ok(parsed) {
        True -> {
          let assert Ok(value) = parsed
          value
        }
        False -> 0
      }
    Error(_) -> 0
  }
}

pub fn inside_a_case_of_several_subjects(parsed: Result(Int, Int), allowed: Bool) -> Int {
  case parsed, allowed {
    Ok(_), True ->
      case result.is_ok(parsed) {
        True -> {
          let assert Ok(value) = parsed
          value
        }
        False -> 0
      }
    _, _ -> 0
  }
}

pub fn in_a_closure_of_a_narrowing_case(parsed: Result(Int, Int)) -> fn() -> Int {
  case parsed {
    Ok(_) ->
      case result.is_ok(parsed) {
        True -> fn() {
          let assert Ok(value) = parsed
          value
        }
        False -> fn() { 0 }
      }
    Error(_) -> fn() { 0 }
  }
}
"
  |> support.on_both_targets([rules.check_then_assert()])
  |> testing.expect_none
}

// Gaps

// girard can't type `broken`, so the rule has no answer there and stays
// silent, and the run has only the note on the gap.
pub fn check_then_assert_is_silent_over_a_gap_test() {
  "import gleam/result

pub fn broken(parsed: Result(Int, Nil)) -> Int {
  let _ = 1 + \"one\"
  case result.is_ok(parsed) {
    True -> {
      let assert Ok(value) = parsed
      value
    }
    False -> 0
  }
}
"
  |> support.on_both_targets([rules.check_then_assert()])
  |> testing.expect_codes(["grice/untyped-definition"])
}
