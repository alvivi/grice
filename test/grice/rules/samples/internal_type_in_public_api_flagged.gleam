//// Each form internal-type-in-public-api reports, linted as a module of
//// a package named `grice`, under `src/`. These functions never run: the
//// module is here to be linted, and compiled by every build with
//// `--warnings-as-errors`, which shows the compiler is silent on it.
//// `hidden` is internal, and so is every custom type it defines.

import gleam/option.{type Option}
import grice/internal/rules/samples/hidden.{type Handle}

/// A constant's annotation, before a string with an e-acute, so the spans
/// after it differ between bytes and UTF-16 code units.
pub const greeting: hidden.Message = hidden.Message("café")

pub fn parameter(message: hidden.Message) -> Nil {
  let _ = message
  Nil
}

pub fn returned() -> Handle {
  hidden.Handle
}

pub fn in_an_argument(boxes: List(hidden.Box(Int))) -> Nil {
  let _ = boxes
  Nil
}

/// An internal type inside the arguments of another: one finding each.
pub fn in_an_internal_argument(box: hidden.Box(hidden.Message)) -> Nil {
  let _ = box
  Nil
}

pub fn in_a_function(callback: fn(hidden.Message) -> Option(Handle)) -> Nil {
  let _ = callback
  Nil
}

pub fn in_a_tuple(pair: #(Int, hidden.Message)) -> Nil {
  let _ = pair
  Nil
}

/// One type named twice: one finding each.
pub fn twice(first: hidden.Message, second: hidden.Message) -> Nil {
  let _ = #(first, second)
  Nil
}

/// An alias of the internal module that names an internal type.
pub fn through_an_internal_alias(boxed: hidden.Boxed) -> Nil {
  let _ = boxed
  Nil
}

/// An external function, with a body for the targets it isn't external on.
@external(erlang, "gleam_stdlib", "identity")
pub fn external(handle: hidden.Handle) -> hidden.Handle {
  handle
}

/// A constructor's fields.
pub type Envelope {
  Envelope(message: hidden.Message, count: Int)
  Wrapped(hidden.Box(Int))
}

/// A type of this module marked `@internal`.
@internal
pub type State {
  State(count: Int)
}

pub fn state() -> State {
  State(0)
}

/// A private alias that names an internal type is internal too.
type Private =
  hidden.Message

pub fn private_alias(message: Private) -> Private {
  message
}
