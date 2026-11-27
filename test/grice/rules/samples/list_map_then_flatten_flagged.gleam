//// Each form list-map-then-flatten reports, one per function. These
//// functions never run: the module is here to be linted, and compiled by
//// every build with `--warnings-as-errors`, which shows the compiler is
//// silent on it. `list.map` and `list.flatten` are also imported
//// unqualified, and the rule finds them by what they resolve to.

import gleam/list.{flatten, map}

pub fn nested(rows: List(Int), cells: fn(Int) -> List(Int)) -> List(Int) {
  list.flatten(list.map(rows, cells))
}

pub fn unqualified(rows: List(Int), cells: fn(Int) -> List(Int)) -> List(Int) {
  flatten(map(rows, cells))
}

pub fn piped_into_the_flatten(
  rows: List(Int),
  cells: fn(Int) -> List(Int),
) -> List(Int) {
  list.map(rows, cells) |> list.flatten
}

pub fn piped_with_parentheses(
  rows: List(Int),
  cells: fn(Int) -> List(Int),
) -> List(Int) {
  list.map(rows, cells) |> list.flatten()
}

pub fn piped_throughout(
  rows: List(Int),
  cells: fn(Int) -> List(Int),
) -> List(Int) {
  rows |> list.map(cells) |> list.flatten
}

pub fn piped_inside(rows: List(Int), cells: fn(Int) -> List(Int)) -> List(Int) {
  list.flatten(rows |> list.map(cells))
}

pub fn piped_into_a_capture(
  rows: List(Int),
  cells: fn(Int) -> List(Int),
) -> List(Int) {
  cells |> list.map(rows, _) |> list.flatten
}

pub fn labelled(rows: List(Int), cells: fn(Int) -> List(Int)) -> List(Int) {
  list.map(rows, with: cells) |> list.flatten
}

pub fn labelled_placeholder(
  rows: List(Int),
  cells: fn(Int) -> List(Int),
) -> List(Int) {
  cells |> list.map(rows, with: _) |> list.flatten
}

pub fn shorthand(rows: List(Int), with: fn(Int) -> List(Int)) -> List(Int) {
  list.map(rows, with:) |> list.flatten
}
