//// Each form fold-plus reports, one per function, on a project whose
//// target is Erlang. On one whose target is JavaScript, it reports only
//// `element_first`, which adds as `int.sum` does there. These functions
//// never run: the module is here to be linted, and compiled by every build
//// with `--warnings-as-errors`, which shows the compiler is silent on it.
//// `gleam/int` is imported under an alias and `list.fold` also
//// unqualified, and the rule finds them by what they resolve to.

import gleam/int as integer
import gleam/list.{fold}

pub fn direct(numbers: List(Int)) -> Int {
  list.fold(numbers, 0, integer.add)
}

pub fn piped(numbers: List(Int)) -> Int {
  numbers |> list.fold(0, integer.add)
}

pub fn unqualified(numbers: List(Int)) -> Int {
  fold(numbers, 0, integer.add)
}

pub fn labelled(numbers: List(Int)) -> Int {
  list.fold(over: numbers, from: 0, with: integer.add)
}

pub fn labels_in_another_order(numbers: List(Int)) -> Int {
  list.fold(numbers, with: integer.add, from: 0)
}

pub fn piped_into_a_capture(numbers: List(Int)) -> Int {
  numbers |> list.fold(from: 0, over: _, with: integer.add)
}

pub fn hexadecimal_zero(numbers: List(Int)) -> Int {
  list.fold(numbers, 0x0, integer.add)
}

pub fn binary_zero(numbers: List(Int)) -> Int {
  list.fold(numbers, 0b0, integer.add)
}

pub fn total_first(numbers: List(Int)) -> Int {
  list.fold(numbers, 0, fn(total, number) { total + number })
}

pub fn annotated(numbers: List(Int)) -> Int {
  list.fold(numbers, 0, fn(total: Int, number: Int) -> Int { total + number })
}

pub fn element_first(numbers: List(Int)) -> Int {
  list.fold(numbers, 0, fn(total, number) { number + total })
}
