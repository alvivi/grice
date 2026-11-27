//// Code fold-plus leaves alone: fixed forms of the flagged samples,
//// written as the rule's hint says, one for each kind of edit the hint
//// asks for, and the near misses. Every direct fold becomes
//// `int.sum(numbers)` whatever its labels, zero or function, so `direct`
//// stands for them all. These functions never run.

import gleam/float
import gleam/int.{add}
import gleam/list
import gleam/string

pub type Tools {
  Tools(add: fn(Int, Int) -> Int)
}

// The fixed forms

pub fn direct(numbers: List(Int)) -> Int {
  int.sum(numbers)
}

pub fn piped(numbers: List(Int)) -> Int {
  numbers |> int.sum
}

// The whole capture goes, so no placeholder is left for the compiler to
// warn on.
pub fn piped_into_a_capture(numbers: List(Int)) -> Int {
  numbers |> int.sum
}

// The near misses

pub fn from_one(numbers: List(Int)) -> Int {
  list.fold(numbers, 1, int.add)
}

// `-0` is negative zero on JavaScript, which the fold returns for an empty
// list and `int.sum` doesn't.
pub fn from_a_signed_zero(numbers: List(Int)) -> Int {
  list.fold(numbers, -0, int.add)
}

pub fn from_a_variable(numbers: List(Int)) -> Int {
  let zero = 0
  list.fold(numbers, zero, int.add)
}

pub fn a_product(numbers: List(Int)) -> Int {
  list.fold(numbers, 1, int.multiply)
}

pub fn from_zero_multiplied(numbers: List(Int)) -> Int {
  list.fold(numbers, 0, int.multiply)
}

// Piped its initial value or its function, the fold would become
// `0 |> int.sum(numbers)`.
pub fn piped_its_initial_value(numbers: List(Int)) -> Int {
  0 |> list.fold(numbers, _, int.add)
}

pub fn piped_its_function(numbers: List(Int)) -> Int {
  int.add |> list.fold(numbers, 0, _)
}

pub fn a_sum_of_widths(rows: List(String)) -> Int {
  list.fold(rows, 0, fn(sum, row) { sum + width(row) })
}

fn width(row: String) -> Int {
  string.length(row)
}

pub fn a_count(numbers: List(Int)) -> Int {
  list.fold(numbers, 0, fn(count, _) { count + 1 })
}

pub fn a_difference(numbers: List(Int)) -> Int {
  list.fold(numbers, 0, fn(total, number) { total - number })
}

pub fn more_than_a_sum(numbers: List(Int)) -> Int {
  list.fold(numbers, 0, fn(total, number) { total + number + 1 })
}

pub fn a_sum_in_a_block(numbers: List(Int)) -> Int {
  list.fold(numbers, 0, fn(total, number) {
    let sum = total + number
    sum
  })
}

pub fn floats(prices: List(Float)) -> Float {
  list.fold(prices, 0.0, float.add)
}

// girard records no resolution for a name passed as a value unqualified.
pub fn unqualified_add(numbers: List(Int)) -> Int {
  list.fold(numbers, 0, add)
}

pub fn a_function_of_its_own(numbers: List(Int)) -> Int {
  list.fold(numbers, 0, plus)
}

fn plus(a: Int, b: Int) -> Int {
  a + b
}

pub fn a_record_field(tools: Tools, numbers: List(Int)) -> Int {
  list.fold(numbers, 0, tools.add)
}
