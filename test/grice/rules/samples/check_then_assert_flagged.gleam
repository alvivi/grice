//// Each form check-then-assert reports, one per function. These functions
//// never run: the module is here to be linted, and compiled by every build
//// with `--warnings-as-errors`, which shows the compiler is silent on it.

import gleam/bool
import gleam/int
import gleam/list

// The constructors are imported under aliases, which the rule resolves
// through the import: `Present` is `option.Some`, and `Some` here is
// `option.None`.
import gleam/option.{type Option, None as Some, Some as Present}
import gleam/result

pub fn case_true(parsed: Result(Int, Nil)) -> Int {
  case result.is_ok(parsed) {
    True -> {
      let assert Ok(value) = parsed
      value
    }
    False -> 0
  }
}

pub fn case_false(parsed: Result(Int, Nil)) -> Nil {
  case result.is_ok(parsed) {
    True -> Nil
    False -> {
      let assert Error(reason) = parsed
      reason
    }
  }
}

pub fn is_error(parsed: Result(Int, Nil)) -> Nil {
  case result.is_error(parsed) {
    True -> {
      let assert Error(reason) = parsed
      reason
    }
    False -> Nil
  }
}

pub fn is_some(found: Option(Int)) -> Int {
  case option.is_some(found) {
    True -> {
      let assert Present(value) = found
      value
    }
    False -> 0
  }
}

pub fn is_none(found: Option(Int)) -> Int {
  case option.is_none(found) {
    True -> {
      let assert Some = found
      0
    }
    False -> 1
  }
}

// The fallback can only see what the unguarded `True` clause didn't match.
pub fn fallback(found: Option(Int)) -> Int {
  case option.is_none(found) {
    True -> 0
    _ -> {
      let assert Present(value) = found
      value
    }
  }
}

pub fn negated(parsed: Result(Int, Nil)) -> Nil {
  case !result.is_ok(parsed) {
    True -> {
      let assert Error(reason) = parsed
      reason
    }
    False -> Nil
  }
}

pub fn piped(parsed: Result(Int, Nil)) -> Int {
  case parsed |> result.is_ok {
    True -> {
      let assert Ok(value) = parsed
      value
    }
    False -> 0
  }
}

pub fn piped_with_parentheses(parsed: Result(Int, Nil)) -> Int {
  case parsed |> result.is_ok() {
    True -> {
      let assert Ok(value) = parsed
      value
    }
    False -> 0
  }
}

// A guard only narrows the clause further.
pub fn guarded_clause(parsed: Result(Int, Nil), allowed: Bool) -> Int {
  case result.is_ok(parsed) {
    True if allowed -> {
      let assert Ok(value) = parsed
      value
    }
    _ -> 0
  }
}

// The conventions page's own example.
pub fn guard(parsed: Result(Int, Nil)) -> Int {
  use <- bool.guard(when: result.is_error(parsed), return: 0)
  let assert Ok(value) = parsed
  value
}

pub fn guard_labels_in_another_order(parsed: Result(Int, Nil)) -> Int {
  use <- bool.guard(return: 0, when: result.is_error(parsed))
  let assert Ok(value) = parsed
  value
}

// With `otherwise` given, the continuation is `return`, which runs when the
// check is true.
pub fn lazy_guard_otherwise_given(parsed: Result(Int, Nil)) -> Int {
  use <- bool.lazy_guard(when: result.is_ok(parsed), otherwise: fn() { 0 })
  let assert Ok(value) = parsed
  value
}

// With `return` given, the continuation is `otherwise`, which runs when the
// check is false.
pub fn lazy_guard_return_given(parsed: Result(Int, Nil)) -> Nil {
  use <- bool.lazy_guard(when: result.is_ok(parsed), return: fn() { Nil })
  let assert Error(reason) = parsed
  reason
}

pub fn lazy_guard_return_callback(parsed: Result(Int, Nil)) -> Int {
  bool.lazy_guard(
    when: result.is_ok(parsed),
    return: fn() {
      let assert Ok(value) = parsed
      value
    },
    otherwise: fn() { 0 },
  )
}

pub fn guard_otherwise_callback(parsed: Result(Int, Nil)) -> Nil {
  bool.guard(when: result.is_ok(parsed), return: Nil, otherwise: fn() {
    let assert Error(reason) = parsed
    reason
  })
}

// Labelled arguments take their slots first, then the unlabelled ones and
// the continuation fill the slots left, in order: here the function is
// `return` and the continuation `otherwise`, which runs when the check is
// false.
pub fn lazy_guard_unlabelled_return(parsed: Result(Int, Nil)) -> Nil {
  use <- bool.lazy_guard(fn() { Nil }, when: result.is_ok(parsed))
  let assert Error(reason) = parsed
  reason
}

pub fn guard_unlabelled_return(parsed: Result(Int, Nil)) -> Int {
  use <- bool.guard(0, when: result.is_error(parsed))
  let assert Ok(value) = parsed
  value
}

// The unlabelled function fills `otherwise`, the slot the labels leave.
pub fn lazy_guard_unlabelled_otherwise(parsed: Result(Int, Nil)) -> Nil {
  bool.lazy_guard(
    fn() {
      let assert Error(reason) = parsed
      reason
    },
    when: result.is_ok(parsed),
    return: fn() { Nil },
  )
}

// A shorthand argument takes the slot of its label too.
pub fn guard_shorthand_return(parsed: Result(Int, Nil)) -> Int {
  let return = 0
  use <- bool.guard(when: result.is_error(parsed), return:)
  let assert Ok(value) = parsed
  value
}

pub fn lazy_guard_shorthand_otherwise(parsed: Result(Int, Nil)) -> Int {
  let otherwise = fn() { 0 }
  use <- bool.lazy_guard(when: result.is_ok(parsed), otherwise:)
  let assert Ok(value) = parsed
  value
}

pub fn lazy_guard_by_position(parsed: Result(Int, Nil)) -> Int {
  bool.lazy_guard(
    result.is_ok(parsed),
    fn() {
      let assert Ok(value) = parsed
      value
    },
    fn() { 0 },
  )
}

pub fn let_of_a_call(text: String) -> Int {
  let parsed = int.parse(text)
  case result.is_ok(parsed) {
    True -> {
      let assert Ok(value) = parsed
      value
    }
    False -> 0
  }
}

pub fn let_of_a_pipe(text: String) -> Int {
  let parsed = text |> int.parse
  case result.is_ok(parsed) {
    True -> {
      let assert Ok(value) = parsed
      value
    }
    False -> 0
  }
}

pub fn anonymous_function_parameter(all: List(Result(Int, Nil))) -> List(Int) {
  list.map(all, fn(parsed) {
    case result.is_ok(parsed) {
      True -> {
        let assert Ok(value) = parsed
        value
      }
      False -> 0
    }
  })
}

pub fn use_callback_parameter(all: List(Result(Int, Nil))) -> List(Int) {
  use parsed <- list.map(all)
  case result.is_ok(parsed) {
    True -> {
      let assert Ok(value) = parsed
      value
    }
    False -> 0
  }
}

pub fn qualified_constructor(found: Option(Int)) -> Int {
  case option.is_some(found) {
    True -> {
      let assert option.Some(value) = found
      value
    }
    False -> 0
  }
}

pub fn with_a_message_and_a_discard(parsed: Result(Int, Nil)) -> Int {
  case result.is_ok(parsed) {
    True -> {
      let assert Ok(_) = parsed as "checked above"
      1
    }
    False -> 0
  }
}

pub fn inside_a_closure(parsed: Result(Int, Nil)) -> fn() -> Int {
  case result.is_ok(parsed) {
    True -> fn() {
      let assert Ok(value) = parsed
      value
    }
    False -> fn() { 0 }
  }
}

// The compiler doesn't infer the variant after a block, so the assert in
// it narrows nothing after it.
pub fn after_an_assert_in_a_block(parsed: Result(Int, Nil)) -> Int {
  let _ = {
    let assert Ok(_) = parsed
    Nil
  }
  case result.is_ok(parsed) {
    True -> {
      let assert Ok(value) = parsed
      value
    }
    False -> 0
  }
}

// Nor after a `case` that matched it.
pub fn after_a_case_that_matched(parsed: Result(Int, Nil)) -> Int {
  let _ = case parsed {
    Ok(_) -> 1
    Error(_) -> 2
  }
  case result.is_ok(parsed) {
    True -> {
      let assert Ok(value) = parsed
      value
    }
    False -> 0
  }
}
