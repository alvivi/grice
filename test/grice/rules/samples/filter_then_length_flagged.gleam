//// Each form filter-then-length reports, one per function. These
//// functions never run: the module is here to be linted, and compiled by
//// every build with `--warnings-as-errors`, which shows the compiler is
//// silent on it. `list.filter` and `list.length` are also imported
//// unqualified, and the rule finds them by what they resolve to.

import gleam/list.{filter, length}
import gleam/option.{type Option}

pub fn nested(ages: List(Int), adult: fn(Int) -> Bool) -> Int {
  list.length(list.filter(ages, adult))
}

pub fn unqualified(ages: List(Int), adult: fn(Int) -> Bool) -> Int {
  length(filter(ages, adult))
}

pub fn labelled_length(ages: List(Int), adult: fn(Int) -> Bool) -> Int {
  list.length(of: list.filter(ages, adult))
}

pub fn piped_into_the_length(ages: List(Int), adult: fn(Int) -> Bool) -> Int {
  list.filter(ages, adult) |> list.length
}

pub fn piped_with_parentheses(ages: List(Int), adult: fn(Int) -> Bool) -> Int {
  list.filter(ages, adult) |> list.length()
}

pub fn piped_throughout(ages: List(Int), adult: fn(Int) -> Bool) -> Int {
  ages |> list.filter(adult) |> list.length
}

pub fn piped_inside(ages: List(Int), adult: fn(Int) -> Bool) -> Int {
  list.length(ages |> list.filter(adult))
}

pub fn piped_into_a_capture(ages: List(Int), adult: fn(Int) -> Bool) -> Int {
  adult |> list.filter(ages, _) |> list.length
}

pub fn piped_into_a_labelled_length(
  ages: List(Int),
  adult: fn(Int) -> Bool,
) -> Int {
  ages |> list.filter(adult) |> list.length(of: _)
}

pub fn labelled_predicate(ages: List(Int), adult: fn(Int) -> Bool) -> Int {
  list.filter(ages, keeping: adult) |> list.length
}

pub fn labelled_placeholder(ages: List(Int), adult: fn(Int) -> Bool) -> Int {
  adult |> list.filter(ages, keeping: _) |> list.length
}

// `where` is in scope, so `keeping:` written as the shorthand `where:`
// would pass it in place of `keeping`.
pub fn shorthand(
  ages: List(Int),
  keeping: fn(Int) -> Bool,
  where: fn(Int) -> Bool,
) -> #(Int, List(Int)) {
  #(list.filter(ages, keeping:) |> list.length, list.filter(ages, where))
}

pub fn compared_with_one(ages: List(Int), adult: fn(Int) -> Bool) -> Bool {
  list.length(list.filter(ages, adult)) > 1
}

pub fn options(found: List(Option(Int))) -> Int {
  list.filter(found, option.is_some) |> list.length
}
