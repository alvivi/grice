//// The near misses internal-type-in-public-api leaves alone, linted as a
//// module of a package named `grice`, under `src/`. These functions never
//// run: the module is here to be linted, and compiled by every build with
//// `--warnings-as-errors`, which shows the compiler is silent on it.
//// `hidden` is internal, and so is every custom type it defines.

import grice/internal/rules/samples/hidden

/// A public alias of an internal type, which the documentation shows in
/// place of the type.
pub type Message =
  hidden.Message

/// A public alias that fixes a parameter, which the documentation expands.
/// It's still a public name.
pub type IntBox =
  hidden.Box(Int)

pub fn through_public_aliases(message: Message, box: IntBox) -> Message {
  let _ = box
  message
}

/// An alias of the internal module that names only `Int`.
pub fn through_an_alias_of_int(count: hidden.Count) -> hidden.Count {
  count
}

fn private(message: hidden.Message) -> hidden.Message {
  message
}

const fallback: hidden.Message = hidden.Message("")

type Wrapper {
  Wrapper(hidden.Message)
}

pub fn calls_private(message: Message) -> Message {
  let Wrapper(wrapped) = Wrapper(private(message))
  let _ = fallback
  wrapped
}

@internal
pub fn marked(message: hidden.Message) -> hidden.Message {
  message
}

@internal
pub const marked_constant: hidden.Message = hidden.Message("marked")

@internal
pub type Marked {
  Marked(hidden.Message)
}

/// An opaque type's constructors are private to this module.
pub opaque type Sealed {
  Sealed(message: hidden.Message)
}

pub fn seal(message: Message) -> Sealed {
  Sealed(message)
}

/// An annotation inside a public function's body.
pub fn in_the_body(message: Message) -> Message {
  let inner: hidden.Message = message
  inner
}

/// An unannotated return, which the rule doesn't read.
pub fn unannotated() {
  hidden.Handle
}
