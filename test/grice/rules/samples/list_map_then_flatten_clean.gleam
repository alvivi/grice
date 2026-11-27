//// Code list-map-then-flatten leaves alone: fixed forms of the flagged
//// samples, written as the rule's hint says, one for each kind of edit the
//// hint asks for, and the near misses. A flagged form whose fix is the
//// same edit as another's, such as the unqualified or the piped call, has
//// none of its own. These functions never run.

import gleam/list

pub type Tools {
  Tools(flatten: fn(List(List(Int))) -> List(Int))
}

// The fixed forms

pub fn nested(rows: List(Int), cells: fn(Int) -> List(Int)) -> List(Int) {
  list.flat_map(rows, cells)
}

pub fn piped_throughout(
  rows: List(Int),
  cells: fn(Int) -> List(Int),
) -> List(Int) {
  rows |> list.flat_map(cells)
}

pub fn piped_into_a_capture(
  rows: List(Int),
  cells: fn(Int) -> List(Int),
) -> List(Int) {
  cells |> list.flat_map(rows, _)
}

pub fn labelled(rows: List(Int), cells: fn(Int) -> List(Int)) -> List(Int) {
  list.flat_map(rows, with: cells)
}

pub fn labelled_placeholder(
  rows: List(Int),
  cells: fn(Int) -> List(Int),
) -> List(Int) {
  cells |> list.flat_map(rows, with: _)
}

pub fn shorthand(rows: List(Int), with: fn(Int) -> List(Int)) -> List(Int) {
  list.flat_map(rows, with:)
}

// The near misses

pub fn each_function_alone(
  rows: List(Int),
  cells: fn(Int) -> List(Int),
  nested: List(List(Int)),
) -> #(List(List(Int)), List(Int)) {
  #(list.map(rows, cells), list.flatten(nested))
}

pub fn another_second_call(
  rows: List(Int),
  cells: fn(Int) -> List(Int),
) -> Result(List(Int), Nil) {
  list.map(rows, cells) |> list.first
}

pub fn a_function_of_its_own(
  rows: List(Int),
  cells: fn(Int) -> List(Int),
) -> List(Int) {
  flatten(list.map(rows, cells))
}

fn flatten(nested: List(List(Int))) -> List(Int) {
  list.fold(nested, [], list.append)
}

pub fn a_record_field(
  tools: Tools,
  rows: List(Int),
  cells: fn(Int) -> List(Int),
) -> List(Int) {
  tools.flatten(list.map(rows, cells))
}

pub fn bound_first(rows: List(Int), cells: fn(Int) -> List(Int)) -> List(Int) {
  let mapped = list.map(rows, cells)
  list.flatten(mapped)
}

pub fn in_a_block(rows: List(Int), cells: fn(Int) -> List(Int)) -> List(Int) {
  list.flatten({ list.map(rows, cells) })
}

pub fn with_use(rows: List(Int), cells: fn(Int) -> List(Int)) -> List(Int) {
  list.flatten({
    use row <- list.map(rows)
    cells(row)
  })
}

pub fn a_capture_on_its_own(
  rows: List(Int),
  cells: fn(Int) -> List(Int),
) -> List(Int) {
  let map_rows = list.map(rows, _)
  list.flatten(map_rows(cells))
}

pub fn a_map_of_a_flatten(
  nested: List(List(Int)),
  cells: fn(Int) -> List(Int),
) -> List(List(Int)) {
  list.map(list.flatten(nested), cells)
}
