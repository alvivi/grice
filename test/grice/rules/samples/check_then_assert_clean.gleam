//// Code check-then-assert leaves alone. These functions never run.

import gleam/bool
import gleam/int
import gleam/list
import gleam/result

pub type Holder {
  Holder(parsed: Result(Int, Int))
}

// After `True if allowed`, the fallback can still see `True`.
pub fn guarded_fallback(parsed: Result(Int, Int), allowed: Bool) -> Int {
  case result.is_ok(parsed) {
    True if allowed -> 0
    _ -> {
      let assert Error(reason) = parsed
      reason
    }
  }
}

pub fn alternative(parsed: Result(Int, Int)) -> Int {
  case result.is_ok(parsed) {
    True | False -> {
      let assert Ok(value) = parsed
      value
    }
  }
}

// An assert the check disproves always fails: a sharper problem, which
// isn't this rule's.
pub fn disproved(parsed: Result(Int, Int)) -> Int {
  case result.is_ok(parsed) {
    True -> {
      let assert Error(reason) = parsed
      reason
    }
    False -> 0
  }
}

pub fn lazy_guard_disproved(parsed: Result(Int, Int)) -> Int {
  use <- bool.lazy_guard(when: result.is_ok(parsed), otherwise: fn() { 0 })
  let assert Error(reason) = parsed
  reason
}

// With `return` given, the continuation runs when the check is false, so
// an `Ok` assert there always fails.
pub fn lazy_guard_return_disproved(parsed: Result(Int, Int)) -> Int {
  use <- bool.lazy_guard(when: result.is_ok(parsed), return: fn() { 0 })
  let assert Ok(value) = parsed
  value
}

pub fn asks_for_more(parsed: Result(Int, Int)) -> Int {
  case result.is_ok(parsed) {
    True -> {
      let assert Ok(0) = parsed
      0
    }
    False -> 1
  }
}

pub fn shadowed(parsed: Result(Int, Int), other: Result(Int, Int)) -> Int {
  case result.is_ok(parsed) {
    True -> {
      let parsed = other
      let assert Ok(value) = parsed
      value
    }
    False -> 0
  }
}

// A name a pattern binds, here by a shorthand field, is a new binding,
// which nothing has checked.
pub fn shadowed_by_a_clause(parsed: Result(Int, Int), holder: Holder) -> Int {
  case result.is_ok(parsed) {
    True ->
      case holder {
        Holder(parsed:) -> {
          let assert Ok(value) = parsed
          value
        }
      }
    False -> 0
  }
}

pub fn shadowed_by_a_parameter(
  parsed: Result(Int, Int),
  all: List(Result(Int, Int)),
) -> List(Int) {
  case result.is_ok(parsed) {
    True ->
      list.map(all, fn(parsed) {
        let assert Ok(value) = parsed
        value
      })
    False -> []
  }
}

pub fn shadowed_by_a_use(
  parsed: Result(Int, Int),
  all: List(Result(Int, Int)),
) -> List(Int) {
  use <- bool.guard(when: result.is_error(parsed), return: [])
  use parsed <- list.map(all)
  let assert Ok(value) = parsed
  value
}

pub fn another_binding(
  parsed: Result(Int, Int),
  other: Result(Int, Int),
) -> Int {
  case result.is_ok(parsed) {
    True -> {
      let assert Ok(value) = other
      value
    }
    False -> 0
  }
}

// A copy isn't eligible: the compiler infers a copy's variant from what it
// copies.
pub fn a_copy(parsed: Result(Int, Int)) -> Int {
  let copy = parsed
  case result.is_ok(copy) {
    True -> {
      let assert Ok(value) = copy
      value
    }
    False -> 0
  }
}

pub fn a_stored_check(parsed: Result(Int, Int)) -> Int {
  let valid = result.is_ok(parsed)
  case valid {
    True -> {
      let assert Ok(value) = parsed
      value
    }
    False -> 0
  }
}

pub fn several_subjects(parsed: Result(Int, Int), allowed: Bool) -> Int {
  case result.is_ok(parsed), allowed {
    True, True -> {
      let assert Ok(value) = parsed
      value
    }
    _, _ -> 0
  }
}

pub fn named_callback(parsed: Result(Int, Int)) -> Int {
  bool.lazy_guard(when: result.is_ok(parsed), return: zero, otherwise: zero)
}

fn zero() -> Int {
  0
}

// `bool.guard`'s `return` is computed before the check runs.
pub fn eager_return(parsed: Result(Int, Int)) -> Int {
  use <- bool.guard(when: result.is_ok(parsed), return: {
    let assert Ok(value) = parsed
    value
  })
  0
}

pub fn a_clause_binding(pair: #(Result(Int, Int), Int)) -> Int {
  case pair {
    #(parsed, _) ->
      case result.is_ok(parsed) {
        True -> {
          let assert Ok(value) = parsed
          value
        }
        False -> 0
      }
  }
}

pub fn not_checked(text: String) -> Int {
  let assert Ok(value) = int.parse(text)
  value
}
