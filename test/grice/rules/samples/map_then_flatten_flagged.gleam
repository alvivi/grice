//// Each form map-then-flatten reports, one per function. These functions
//// never run: the module is here to be linted, and compiled by every build
//// with `--warnings-as-errors`, which shows the compiler is silent on it.
//// `gleam/option` is imported under an alias and `result.flatten`
//// unqualified, and the rule finds both by what they resolve to.

import gleam/int
import gleam/option as maybe
import gleam/result.{flatten}

pub fn nested(
  parsed: Result(Int, Nil),
  check: fn(Int) -> Result(Int, Nil),
) -> Result(Int, Nil) {
  result.flatten(result.map(parsed, check))
}

pub fn unqualified(
  parsed: Result(Int, Nil),
  check: fn(Int) -> Result(Int, Nil),
) -> Result(Int, Nil) {
  flatten(result.map(parsed, check))
}

pub fn piped_into_the_flatten(
  parsed: Result(Int, Nil),
  check: fn(Int) -> Result(Int, Nil),
) -> Result(Int, Nil) {
  result.map(parsed, check) |> result.flatten
}

pub fn piped_with_parentheses(
  parsed: Result(Int, Nil),
  check: fn(Int) -> Result(Int, Nil),
) -> Result(Int, Nil) {
  result.map(parsed, check) |> result.flatten()
}

pub fn piped_throughout(
  parsed: Result(Int, Nil),
  check: fn(Int) -> Result(Int, Nil),
) -> Result(Int, Nil) {
  parsed |> result.map(check) |> result.flatten
}

pub fn piped_inside(
  parsed: Result(Int, Nil),
  check: fn(Int) -> Result(Int, Nil),
) -> Result(Int, Nil) {
  result.flatten(parsed |> result.map(check))
}

pub fn piped_into_a_capture(
  parsed: Result(Int, Nil),
  check: fn(Int) -> Result(Int, Nil),
) -> Result(Int, Nil) {
  check |> result.map(parsed, _) |> result.flatten
}

pub fn labelled(
  parsed: Result(Int, Nil),
  check: fn(Int) -> Result(Int, Nil),
) -> Result(Int, Nil) {
  result.map(over: parsed, with: check) |> result.flatten
}

pub fn labelled_function_first(
  parsed: Result(Int, Nil),
  check: fn(Int) -> Result(Int, Nil),
) -> Result(Int, Nil) {
  result.flatten(result.map(with: check, over: parsed))
}

pub fn captured_function_first(
  parsed: Result(Int, Nil),
  check: fn(Int) -> Result(Int, Nil),
) -> Result(Int, Nil) {
  check |> result.map(with: _, over: parsed) |> result.flatten
}

pub fn labelled_placeholder(
  parsed: Result(Int, Nil),
  check: fn(Int) -> Result(Int, Nil),
) -> Result(Int, Nil) {
  parsed |> result.map(over: _, with: check) |> result.flatten
}

// `apply` is in scope, so `with:` written as the shorthand `apply:` would
// pass it in place of `with`.
pub fn shorthand(
  over: Result(Int, Nil),
  with: fn(Int) -> Result(Int, Nil),
  apply: fn(Int) -> Int,
) -> Result(Int, Nil) {
  result.map(over:, with:) |> result.flatten |> result.map(apply)
}

pub fn option(
  found: maybe.Option(Int),
  check: fn(Int) -> maybe.Option(Int),
) -> maybe.Option(Int) {
  found |> maybe.map(check) |> maybe.flatten
}

// The label of the pipe below starts after a literal e-acute, which is two
// bytes and one UTF-16 code unit, so its column shows that the span counts
// the same on both targets.
pub fn after_a_literal_e_acute(
  parsed: Result(Int, Nil),
) -> Result(String, Nil) {
  let prefix = "café "
  parsed
  |> result.map(fn(count) { Ok(prefix <> int.to_string(count)) })
  |> result.flatten
}
