//// The internal module the samples of internal-type-in-public-api import.
//// Its name is under `grice/internal`, so the compiler, building grice's
//// tests, treats it as internal, as grice does by its default patterns
//// for a package named `grice`. Nothing here runs.

pub type Message {
  Message(text: String)
}

pub type Box(a) {
  Box(content: a)
}

pub type Handle {
  Handle
}

/// An alias in an internal module that names an internal type, which makes
/// it internal too.
pub type Boxed =
  Box(Message)

/// An alias in an internal module that names only a public type, which
/// doesn't.
pub type Count =
  Int
