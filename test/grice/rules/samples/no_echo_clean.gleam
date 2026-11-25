//// Code no-echo leaves alone: printing with `gleam/io`, and names, strings
//// and comments that only mention `echo`. These functions never run.

import gleam/io

pub fn print(message: String) -> Nil {
  io.println(message)
}

pub fn echo_back(message: String) -> String {
  message
}

pub fn describe() -> String {
  // An echo in a comment is not one.
  "echo is for debugging"
}

pub fn echoed(message: String) -> String {
  let echoed = echo_back(message)
  echoed
}
