//// Each form of `echo` that no-echo reports, one per function. These
//// functions never run: the module is here to be linted, and compiled by
//// every build with `--warnings-as-errors`, which shows the compiler is
//// silent on it.

import gleam/int
import gleam/list

pub fn bare(count: Int) -> Int {
  echo count
}

pub fn with_a_message(count: Int) -> Int {
  echo count as "count"
}

pub fn last_in_a_pipeline(prices: List(Int)) -> List(Int) {
  prices |> echo
}

pub fn last_in_a_pipeline_with_a_message(prices: List(Int)) -> List(Int) {
  prices |> echo as "prices"
}

pub fn inside_a_pipeline(prices: List(Int)) -> Int {
  prices |> echo |> int.sum
}

// glance reads `"prices" |> int.sum` as the message, where the compiler
// pipes the `echo` into `int.sum`, so the span runs to the end of the line.
pub fn inside_a_pipeline_with_a_message(prices: List(Int)) -> Int {
  prices |> echo as "prices" |> int.sum
}

pub fn inside_an_anonymous_function(prices: List(Int)) -> List(Int) {
  list.map(prices, fn(price) { echo price * 2 })
}

pub fn inside_a_case(count: Int) -> Int {
  case count {
    0 -> 0
    _ -> echo count - 1
  }
}

// The literal `é` is one UTF-16 code unit and two bytes, so the span of the
// `echo` after it is checked on both runtimes.
pub fn after_a_non_ascii_string(name: String) -> String {
  let greeting = "Olé, " <> name
  echo greeting
}
