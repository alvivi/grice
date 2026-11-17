//// Paths as grice handles them: `/`-separated, where an absolute path
//// starts with `/`. Everything grice does with a path as text is here, so
//// a host's own path rules can slot in later in one place.

import gleam/list
import gleam/string

/// The segments of a path, without empty or `.` ones, which name nothing:
/// `["src", "app.gleam"]` for `src/app.gleam`, `./src//app.gleam` and
/// `/src/./app.gleam` alike. A `..` stays: after a symbolic link it names
/// the parent of the link's target, which the text alone can't tell.
pub fn segments(path: String) -> List(String) {
  string.split(path, "/")
  |> list.filter(fn(segment) { segment != "" && segment != "." })
}

/// `path` as seen from the directory `directory`, both relative to the same
/// directory or both absolute: `../src/app.gleam` for `src/app.gleam` from
/// `test` or `./test`, and `""` for a directory from itself. Neither may
/// hold a `..`, which isn't resolved.
pub fn relative(path: String, from directory: String) -> String {
  let #(up, down) = drop_common(segments(directory), segments(path))
  list.append(list.map(up, fn(_) { ".." }), down)
  |> string.join("/")
}

/// The relative `path` joined to the absolute `directory`, with its
/// `segments`: empty and `.` segments dropped, any `..` kept.
pub fn absolute(path: String, in directory: String) -> String {
  "/" <> string.join(segments(directory <> "/" <> path), "/")
}

fn drop_common(
  from: List(String),
  to: List(String),
) -> #(List(String), List(String)) {
  case from, to {
    [first, ..from_rest], [other, ..to_rest] if first == other ->
      drop_common(from_rest, to_rest)
    _, _ -> #(from, to)
  }
}
