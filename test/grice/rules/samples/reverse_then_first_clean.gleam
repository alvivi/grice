//// Code reverse-then-first leaves alone: fixed forms of the flagged
//// samples, written as the rule's hint says, one for each kind of edit the
//// hint asks for, and the near misses. A flagged form whose fix is the
//// same edit as another's, such as the unqualified or the piped call, has
//// none of its own. These functions never run.

import gleam/list

pub type Tools {
  Tools(first: fn(List(Int)) -> Result(Int, Nil))
}

// The fixed forms

pub fn nested(scores: List(Int)) -> Result(Int, Nil) {
  list.last(scores)
}

pub fn piped_throughout(scores: List(Int)) -> Result(Int, Nil) {
  scores |> list.last
}

pub fn piped_with_parentheses_throughout(
  scores: List(Int),
) -> Result(Int, Nil) {
  scores |> list.last()
}

// The near misses

pub fn each_function_alone(
  scores: List(Int),
) -> #(List(Int), Result(Int, Nil)) {
  #(list.reverse(scores), list.first(scores))
}

pub fn another_second_call(scores: List(Int)) -> List(Int) {
  list.reverse(scores) |> list.drop(1)
}

pub fn a_first_then_another(scores: List(Int)) -> Result(Int, Nil) {
  list.filter(scores, fn(score) { score > 0 }) |> list.first
}

pub fn a_function_of_its_own(scores: List(Int)) -> Result(Int, Nil) {
  first(list.reverse(scores))
}

fn first(scores: List(Int)) -> Result(Int, Nil) {
  list.last(scores)
}

pub fn a_record_field(tools: Tools, scores: List(Int)) -> Result(Int, Nil) {
  tools.first(list.reverse(scores))
}

pub fn bound_first(scores: List(Int)) -> Result(Int, Nil) {
  let reversed = list.reverse(scores)
  list.first(reversed)
}

pub fn in_a_block(scores: List(Int)) -> Result(Int, Nil) {
  list.first({ list.reverse(scores) })
}
