//// Tests for paths as text: shown relative to a directory, and made
//// absolute.

import grice/internal/path

pub fn relative_paths_climb_out_of_the_directory_test() {
  assert path.relative("src/app.gleam", from: "") == "src/app.gleam"
  assert path.relative("src/app.gleam", from: "test/deep")
    == "../../src/app.gleam"
  assert path.relative("src/app/inner.gleam", from: "src/app") == "inner.gleam"
  assert path.relative("src/app.gleam", from: "src/app") == "../app.gleam"
  // A `.` segment names nothing.
  assert path.relative("src/app.gleam", from: ".") == "src/app.gleam"
  assert path.relative("src/app.gleam", from: "./dev/.") == "../src/app.gleam"
  assert path.relative("./src/app.gleam", from: "src") == "app.gleam"
  // The working directory below the root.
  assert path.relative("/home/me/app/test", from: "/home/me/app") == "test"
  assert path.relative("/home/me/app", from: "/home/me/app") == ""
}

// `.` segments go, `..` stays: after a symbolic link it doesn't cancel.
pub fn absolute_paths_keep_parent_segments_test() {
  assert path.absolute("app", in: "/home/me") == "/home/me/app"
  assert path.absolute("./app/.", in: "/home/me") == "/home/me/app"
  assert path.absolute("link/../app", in: "/home/me") == "/home/me/link/../app"
  assert path.absolute("app", in: "/") == "/app"
}
