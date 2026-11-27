//// Code map-then-flatten leaves alone: fixed forms of the flagged samples,
//// written as the rule's hint says, one for each kind of edit the hint
//// asks for, and the near misses. A flagged form whose fix is the same
//// edit as another's, such as the unqualified or the piped call, has none
//// of its own. These functions never run.

import gleam/int
import gleam/option as maybe
import gleam/result

pub type Tools {
  Tools(flatten: fn(Result(Result(Int, Nil), Nil)) -> Result(Int, Nil))
}

// The fixed forms

pub fn nested(
  parsed: Result(Int, Nil),
  check: fn(Int) -> Result(Int, Nil),
) -> Result(Int, Nil) {
  result.try(parsed, check)
}

pub fn piped_throughout(
  parsed: Result(Int, Nil),
  check: fn(Int) -> Result(Int, Nil),
) -> Result(Int, Nil) {
  parsed |> result.try(check)
}

pub fn piped_into_a_capture(
  parsed: Result(Int, Nil),
  check: fn(Int) -> Result(Int, Nil),
) -> Result(Int, Nil) {
  check |> result.try(parsed, _)
}

pub fn labelled(
  parsed: Result(Int, Nil),
  check: fn(Int) -> Result(Int, Nil),
) -> Result(Int, Nil) {
  result.try(parsed, apply: check)
}

pub fn labelled_function_first(
  parsed: Result(Int, Nil),
  check: fn(Int) -> Result(Int, Nil),
) -> Result(Int, Nil) {
  result.try(parsed, apply: check)
}

pub fn captured_function_first(
  parsed: Result(Int, Nil),
  check: fn(Int) -> Result(Int, Nil),
) -> Result(Int, Nil) {
  check |> result.try(parsed, apply: _)
}

pub fn labelled_placeholder(
  parsed: Result(Int, Nil),
  check: fn(Int) -> Result(Int, Nil),
) -> Result(Int, Nil) {
  parsed |> result.try(apply: check)
}

pub fn shorthand(
  over: Result(Int, Nil),
  with: fn(Int) -> Result(Int, Nil),
  apply: fn(Int) -> Int,
) -> Result(Int, Nil) {
  result.try(over, apply: with) |> result.map(apply)
}

pub fn option(
  found: maybe.Option(Int),
  check: fn(Int) -> maybe.Option(Int),
) -> maybe.Option(Int) {
  found |> maybe.then(check)
}

pub fn after_a_literal_e_acute(
  parsed: Result(Int, Nil),
) -> Result(String, Nil) {
  let prefix = "café "
  parsed
  |> result.try(fn(count) { Ok(prefix <> int.to_string(count)) })
}

// The near misses

pub fn each_function_alone(
  parsed: Result(Int, Nil),
  nested: Result(Result(Int, Nil), Nil),
) -> #(Result(Int, Nil), Result(Int, Nil)) {
  #(result.map(parsed, int.negate), result.flatten(nested))
}

pub fn another_second_call(
  parsed: Result(Int, Nil),
  check: fn(Int) -> Result(Int, Nil),
) -> Result(Int, Nil) {
  result.map(parsed, check) |> result.unwrap(Error(Nil))
}

pub fn a_function_of_its_own(
  parsed: Result(Int, Nil),
  check: fn(Int) -> Result(Int, Nil),
) -> Result(Int, Nil) {
  flatten(result.map(parsed, check))
}

fn flatten(nested: Result(Result(Int, Nil), Nil)) -> Result(Int, Nil) {
  result.unwrap(nested, Error(Nil))
}

pub fn a_record_field(
  tools: Tools,
  parsed: Result(Int, Nil),
  check: fn(Int) -> Result(Int, Nil),
) -> Result(Int, Nil) {
  tools.flatten(result.map(parsed, check))
}

pub fn bound_first(
  parsed: Result(Int, Nil),
  check: fn(Int) -> Result(Int, Nil),
) -> Result(Int, Nil) {
  let mapped = result.map(parsed, check)
  result.flatten(mapped)
}

pub fn in_a_block(
  parsed: Result(Int, Nil),
  check: fn(Int) -> Result(Int, Nil),
) -> Result(Int, Nil) {
  result.flatten({ result.map(parsed, check) })
}

pub fn with_use(
  parsed: Result(Int, Nil),
  check: fn(Int) -> Result(Int, Nil),
) -> Result(Int, Nil) {
  result.flatten({
    use value <- result.map(parsed)
    check(value)
  })
}

pub fn a_capture_on_its_own(
  parsed: Result(Int, Nil),
  check: fn(Int) -> Result(Int, Nil),
) -> Result(Int, Nil) {
  let map_parsed = result.map(parsed, _)
  result.flatten(map_parsed(check))
}

pub fn the_other_types_flatten(
  found: maybe.Option(Int),
  check: fn(Int) -> maybe.Option(Int),
) -> maybe.Option(Int) {
  maybe.map(found, check) |> maybe.unwrap(maybe.None)
}
