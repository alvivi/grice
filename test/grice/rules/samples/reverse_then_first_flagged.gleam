//// Each form reverse-then-first reports, one per function. These
//// functions never run: the module is here to be linted, and compiled by
//// every build with `--warnings-as-errors`, which shows the compiler is
//// silent on it. `gleam/list` is imported under an alias, with `first`
//// and `reverse` also unqualified, and the rule finds them by what they
//// resolve to.

import gleam/list.{first, reverse} as items

pub fn nested(scores: List(Int)) -> Result(Int, Nil) {
  items.first(items.reverse(scores))
}

pub fn unqualified(scores: List(Int)) -> Result(Int, Nil) {
  first(reverse(scores))
}

pub fn piped_into_the_first(scores: List(Int)) -> Result(Int, Nil) {
  items.reverse(scores) |> items.first
}

pub fn piped_with_parentheses(scores: List(Int)) -> Result(Int, Nil) {
  items.reverse(scores) |> items.first()
}

pub fn piped_throughout(scores: List(Int)) -> Result(Int, Nil) {
  scores |> items.reverse |> items.first
}

pub fn piped_inside(scores: List(Int)) -> Result(Int, Nil) {
  items.first(scores |> items.reverse)
}

pub fn piped_with_parentheses_throughout(
  scores: List(Int),
) -> Result(Int, Nil) {
  scores |> items.reverse() |> items.first()
}
