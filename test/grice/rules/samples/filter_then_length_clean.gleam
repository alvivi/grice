//// Code filter-then-length leaves alone: fixed forms of the flagged
//// samples, written as the rule's hint says, one for each kind of edit the
//// hint asks for, and the near misses. A flagged form whose fix is the
//// same edit as another's, such as the unqualified or the piped call, has
//// none of its own. These functions never run.

import gleam/list
import gleam/option.{type Option}

pub type Tools {
  Tools(length: fn(List(Int)) -> Int)
}

// The fixed forms

pub fn nested(ages: List(Int), adult: fn(Int) -> Bool) -> Int {
  list.count(ages, adult)
}

pub fn piped_throughout(ages: List(Int), adult: fn(Int) -> Bool) -> Int {
  ages |> list.count(adult)
}

pub fn piped_into_a_capture(ages: List(Int), adult: fn(Int) -> Bool) -> Int {
  adult |> list.count(ages, _)
}

// Dropping `|> list.length(of: _)` leaves the piped list going into
// `list.count`, with no capture left to warn on.
pub fn piped_into_a_labelled_length(
  ages: List(Int),
  adult: fn(Int) -> Bool,
) -> Int {
  ages |> list.count(adult)
}

pub fn labelled_predicate(ages: List(Int), adult: fn(Int) -> Bool) -> Int {
  list.count(ages, where: adult)
}

pub fn labelled_placeholder(ages: List(Int), adult: fn(Int) -> Bool) -> Int {
  adult |> list.count(ages, where: _)
}

pub fn shorthand(
  ages: List(Int),
  keeping: fn(Int) -> Bool,
  where: fn(Int) -> Bool,
) -> #(Int, List(Int)) {
  #(list.count(ages, where: keeping), list.filter(ages, where))
}

pub fn compared_with_one(ages: List(Int), adult: fn(Int) -> Bool) -> Bool {
  list.count(ages, adult) > 1
}

pub fn options(found: List(Option(Int))) -> Int {
  list.count(found, option.is_some)
}

// Checked for emptiness, where counting every element is the wrong fix:
// no-length-for-emptiness reports the first two, and nothing reports the
// captured length yet.

pub fn piped_and_compared(ages: List(Int), adult: fn(Int) -> Bool) -> Bool {
  ages |> list.filter(adult) |> list.length > 0
}

pub fn matched_on_zero(ages: List(Int), adult: fn(Int) -> Bool) -> String {
  case list.length(list.filter(ages, adult)) {
    0 -> "none"
    _ -> "some"
  }
}

pub fn captured_and_compared(ages: List(Int), adult: fn(Int) -> Bool) -> Bool {
  ages |> list.filter(adult) |> list.length(of: _) > 0
}

// The near misses

pub fn each_function_alone(
  ages: List(Int),
  adult: fn(Int) -> Bool,
) -> #(List(Int), Int) {
  #(list.filter(ages, adult), list.length(ages))
}

pub fn another_second_call(
  ages: List(Int),
  adult: fn(Int) -> Bool,
) -> Result(Int, Nil) {
  list.filter(ages, adult) |> list.first
}

pub fn a_function_of_its_own(ages: List(Int), adult: fn(Int) -> Bool) -> Int {
  length(list.filter(ages, adult))
}

fn length(ages: List(Int)) -> Int {
  list.fold(ages, 0, fn(count, _age) { count + 1 })
}

pub fn a_record_field(
  tools: Tools,
  ages: List(Int),
  adult: fn(Int) -> Bool,
) -> Int {
  tools.length(list.filter(ages, adult))
}

pub fn bound_first(ages: List(Int), adult: fn(Int) -> Bool) -> Int {
  let adults = list.filter(ages, adult)
  list.length(adults)
}

pub fn in_a_block(ages: List(Int), adult: fn(Int) -> Bool) -> Int {
  list.length({ list.filter(ages, adult) })
}

pub fn with_use(ages: List(Int)) -> Int {
  list.length({
    use age <- list.filter(ages)
    age >= 18
  })
}

pub fn a_capture_on_its_own(ages: List(Int), adult: fn(Int) -> Bool) -> Int {
  let filter_ages = list.filter(ages, _)
  list.length(filter_ages(adult))
}
