//// Each form no-length-for-emptiness reports, one per function. These
//// functions never run: the module is here to be linted, and compiled by
//// every build with `--warnings-as-errors`, which shows the compiler is
//// silent on it. `string.length` is imported under an alias and
//// `list.length` unqualified, and the rule finds both by what they
//// resolve to.

import gleam/list.{length}
import gleam/string as text

pub fn string_equal_to_zero(name: String) -> Bool {
  text.length(name) == 0
}

pub fn string_not_equal_to_zero(name: String) -> Bool {
  text.length(name) != 0
}

pub fn string_greater_than_zero(name: String) -> Bool {
  text.length(name) > 0
}

pub fn string_at_least_one(name: String) -> Bool {
  text.length(name) >= 1
}

pub fn string_less_than_one(name: String) -> Bool {
  text.length(name) < 1
}

pub fn string_at_most_zero(name: String) -> Bool {
  text.length(name) <= 0
}

pub fn zero_equal_to_string(name: String) -> Bool {
  0 == text.length(name)
}

pub fn zero_not_equal_to_string(name: String) -> Bool {
  0 != text.length(name)
}

pub fn zero_less_than_string(name: String) -> Bool {
  0 < text.length(name)
}

pub fn one_at_most_string(name: String) -> Bool {
  1 <= text.length(name)
}

pub fn one_greater_than_string(name: String) -> Bool {
  1 > text.length(name)
}

pub fn zero_at_least_string(name: String) -> Bool {
  0 >= text.length(name)
}

pub fn string_piped(name: String) -> Bool {
  name |> text.length == 0
}

pub fn string_piped_with_parentheses(name: String) -> Bool {
  name |> text.length() > 0
}

pub fn string_other_spellings(name: String) -> Bool {
  text.length(name) == 0x0 || text.length(name) >= 0b1
}

pub fn string_case(name: String) -> String {
  case text.length(name) {
    0 -> "Hello"
    _ -> "Hello, " <> name
  }
}

pub fn list_unqualified(items: List(Int)) -> Bool {
  length(items) == 0
}

pub fn list_at_least_one(items: List(Int)) -> Bool {
  list.length(items) >= 1
}

pub fn one_at_most_list(items: List(Int)) -> Bool {
  1 <= list.length(items)
}

pub fn list_piped(items: List(Int)) -> Bool {
  items |> list.length == 0
}

pub fn list_piped_with_parentheses(items: List(Int)) -> Bool {
  items |> list.length() != 0
}

pub fn list_other_spellings(items: List(Int)) -> Bool {
  list.length(items) == 00 || list.length(items) > 0o0
}

pub fn list_case(items: List(Int)) -> String {
  case list.length(items) {
    0x0 -> "none"
    _count -> "some"
  }
}
