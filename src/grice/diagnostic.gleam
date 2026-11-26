//// The diagnostic model: what grice reports and how it points at code.
////
//// Every finding grice prints, from a rule or from grice itself, is a
//// `Diagnostic`. It always has a rule code, a severity and a title. It may
//// point into one source file through a `Location`, which owns everything
//// that only makes sense inside a file: the path, the labelled spans and an
//// optional fix. Diagnostics with nothing to point at, such as a problem with
//// the configuration as a whole, have no location.
////
//// Positions are byte offsets into the file's source, never lines and
//// columns. Renderers and editor integrations convert them at the edge, each
//// into the positions it needs.

import gleam/option.{type Option}

/// A finding, ready to be rendered as text or JSON.
///
/// `message` holds the explanation as a list of paragraphs. Write each one
/// as plain, unwrapped text: renderers wrap paragraphs themselves. `hint` is
/// a single suggestion on how to fix the problem, printed after the message.
///
/// All of a diagnostic's text, its title, message, hint and label messages,
/// marks code with backticks, as Markdown's inline code and the compiler's
/// own diagnostics do: `` Unknown key in `gleam.toml` ``. Renderers print the
/// backticks as they are.
pub type Diagnostic {
  Diagnostic(
    /// A stable identifier for the rule that produced the diagnostic, such
    /// as `"grice/parse-error"` or `"my_app/no-io-in-view"`. It's what
    /// suppressions and documentation refer to.
    code: String,
    severity: Severity,
    /// A short summary on one line, such as `"Unused result value"`.
    title: String,
    location: Option(Location),
    message: List(String),
    hint: Option(String),
  )
}

/// How serious a diagnostic is.
pub type Severity {
  Error
  Warning
  Note
}

/// Where a diagnostic points: one file, one primary label, any number of
/// secondary labels, and an optional fix.
///
/// Every span in a location, those of the fix's edits included, is a byte
/// range into the source of the file at `path`.
pub type Location {
  Location(
    path: String,
    /// The span the diagnostic is about. The location line of a rendered
    /// diagnostic points at its start.
    primary: Label,
    /// Related spans in the same file that help explain the problem.
    secondary: List(Label),
    /// A machine-applicable fix. Reserved: grice checks that a fix is
    /// well formed but doesn't apply or print it yet.
    fix: Option(Fix),
  )
}

/// A span of source with a message to print next to it.
///
/// The message is a single line, and an empty message prints the span's
/// underline alone.
pub type Label {
  Label(span: Span, message: String)
}

/// A range of bytes in a file's source. `start` is inclusive and `end` is
/// exclusive, so an empty span (`start == end`) is a position between two
/// bytes.
///
/// A span is valid when `0 <= start <= end <= byte_size(source)` and both
/// ends fall on UTF-8 codepoint boundaries. Renderers reject invalid spans
/// instead of guessing what was meant.
pub type Span {
  Span(start: Int, end: Int)
}

/// A suggested change to the file of the enclosing `Location`.
///
/// Edits follow the Language Server Protocol's `TextEdit` rules: every span
/// is relative to the original source, and no part of the source is changed
/// by more than one edit. Several edits may share a start position only as
/// any number of insertions (empty spans) followed by at most one
/// replacement, applied in list order. An edit may not start or end between
/// a `\r` and the `\n` after it.
pub type Fix {
  Fix(title: String, edits: List(Edit))
}

/// Replace the bytes in `span` with `replacement`. An empty span inserts.
pub type Edit {
  Edit(span: Span, replacement: String)
}
