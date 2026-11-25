//// Code no-length-for-emptiness leaves alone. These functions never run.

import gleam/list
import gleam/string

pub type Config {
  Config(length: Int)
}

pub fn compared_with_another_number(name: String) -> Bool {
  string.length(name) > 1 || string.length(name) == 2
}

pub fn compared_with_another_length(name: String, other: String) -> Bool {
  string.length(name) == string.length(other)
}

pub fn a_field_named_length(config: Config) -> Bool {
  config.length == 0
}

pub fn a_function_of_its_own(name: String) -> Bool {
  size(name) == 0
}

fn size(name: String) -> Int {
  string.byte_size(name)
}

pub fn counting(items: List(Int)) -> String {
  case list.length(items) {
    0 -> "none"
    1 -> "one"
    _ -> "many"
  }
}

pub fn binding_the_length(name: String) -> Int {
  case string.length(name) {
    0 -> 1
    length -> length
  }
}

pub fn a_guarded_zero(name: String, strict: Bool) -> Bool {
  case string.length(name) {
    0 if strict -> False
    _ -> True
  }
}

pub fn an_alternative(name: String) -> Bool {
  case string.length(name) {
    0 | 1 -> False
    _ -> True
  }
}

pub fn the_value_itself(name: String, items: List(Int)) -> Bool {
  name == "" || items != []
}
