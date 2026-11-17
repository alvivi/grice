//// Fixture projects for the tests. Most are built in memory with
//// `project`. The tests that read from disk write the tree they need under
//// `build/fixtures/<test>/`, which git ignores and the compiler doesn't
//// read, and delete it afterwards.

import glance
import gleam/dict
import gleam/list
import gleam/result
import gleam/string
import grice/fixture_rules
import grice/internal/config
import grice/internal/loader.{type Project}
import grice/internal/runner.{type Linted}
import grice/internal/typing
import simplifile

/// The project with the `gleam.toml` text `toml`, the files of `files`,
/// `#(path, source)` with root-relative paths, and the dependency modules
/// of `dependencies`, `#(module name, source)`, loaded with `loader.load`.
pub fn project(
  toml: String,
  files: List(#(String, String)),
  dependencies: List(#(String, String)),
) -> Project {
  let assert Ok(parsed) = config.parse(toml)
  let sources = dict.from_list(files)
  let assert Ok(project) =
    loader.load(
      root: "app",
      config: parsed,
      paths: list.map(files, fn(file) { file.0 }),
      read: fn(path) {
        dict.get(sources, path) |> result.replace_error("No such file")
      },
      dependencies: dict.from_list(dependencies),
      missing_dependencies: [],
    )
  project
}

/// A package where `a` imports `b` on Erlang and `b` imports `a` on
/// JavaScript, which the compiler accepts on both targets. On each target,
/// `from_other` calls into the other module, and is left out of the
/// module the other target compiles it for.
pub const crossed = [
  #(
    "src/a.gleam",
    "@target(erlang)\nimport b\npub type A {\n  A\n}\n@target(erlang)\npub fn from_other() { b.make() }\npub fn make() { A }\n",
  ),
  #(
    "src/b.gleam",
    "@target(javascript)\nimport a\npub type B {\n  B\n}\n@target(javascript)\npub fn from_other() { a.make() }\npub fn make() { B }\n",
  ),
]

/// A typed run, in memory, that shows every kind of diagnostic and gap a
/// completed run can: `fixture/no-echo` findings, one of them hidden, both
/// suppression warnings, a parse error, a definition girard couldn't type,
/// a module it returned nothing for, an import it couldn't use directly
/// and one reached through a dependency, and a missing package.
pub fn showcase() -> #(Project, Linted) {
  let project =
    loader.Project(
      ..project("", showcase_files, showcase_dependencies),
      missing_dependencies: [
        loader.Package("hexdep", loader.Hex, "build/packages/hexdep"),
      ],
    )
  let assert Ok(linted) =
    runner.run_with(
      project,
      [fixture_rules.no_echo(), fixture_rules.discarded_result()],
      infer: fn(project) {
        typing.infer(project, typing.resolver(project)) |> dict.delete("lonely")
      },
    )
  #(project, linted)
}

const showcase_files = [
  #(
    "src/app.gleam",
    "pub fn main() {
  // grice-ignore fixture/no-echo: The test shows a hidden diagnostic.
  echo 1
  echo 2
}

// grice-ignore fixture/no-echo: Nothing here prints.
pub fn quiet() {
  1
}

// grice-ignore fixture/no-echo
pub fn skipped() {
  1 + \"one\"
}
",
  ),
  #("src/broken.gleam", "pub fn ("),
  #(
    "src/dependent.gleam",
    "import dep/outer\n\npub fn main() {\n  outer.value()\n}\n",
  ),
  #("src/lonely.gleam", "pub fn main() {\n  2\n}\n"),
  #("src/nameless.gleam", "import nowhere\n"),
]

const showcase_dependencies = [
  #("dep/outer", "import dep/inner\n\npub fn value() {\n  3\n}\n"),
  #("dep/inner", "pub const x = 1\npub fn ("),
]

/// The span of the first `needle` in `source`.
pub fn glance_span(source: String, needle: String) -> glance.Span {
  let assert Ok(#(before, _)) = string.split_once(source, needle)
  let start = string.byte_size(before)
  glance.Span(start, start + string.byte_size(needle))
}

/// `path`, relative to the working directory, as an absolute path.
pub fn absolute(path: String) -> String {
  let assert Ok(working) = simplifile.current_directory()
  working <> "/" <> path
}

/// The directory a test named `name` writes its fixture in.
pub fn fixture_directory(name: String) -> String {
  "build/fixtures/" <> name
}

/// Write each `#(path, contents)` under `directory`, creating parent
/// directories as needed, after deleting whatever was there.
pub fn write_fixture(directory: String, files: List(#(String, String))) -> Nil {
  cleanup(directory)
  list.each(files, fn(file) {
    let #(path, contents) = file
    write_file(directory <> "/" <> path, contents)
  })
}

/// Write `files` as `write_fixture` does, then create each `#(link, target)`
/// symbolic link. `link` is relative to `directory`, and `target` is what
/// the link holds, so a relative target is read from the link's own
/// directory.
pub fn write_linked_fixture(
  directory: String,
  files: List(#(String, String)),
  links: List(#(String, String)),
) -> Nil {
  write_fixture(directory, files)
  list.each(links, fn(link) {
    let #(at, target) = link
    let path = directory <> "/" <> at
    create_parent(path)
    let assert Ok(Nil) = simplifile.create_symlink(to: target, from: path)
      as { "can't create the link " <> path }
  })
}

/// Write bytes that aren't UTF-8 at `path`.
pub fn write_not_utf8(path: String) -> Nil {
  create_parent(path)
  let assert Ok(Nil) = simplifile.write_bits(path, <<255, 254, 255>>)
    as { "can't write " <> path }
  Nil
}

/// Run `check` with the directory at `path` set to `mode`, a mode that
/// denies listing it, then restore mode `0o755`. `check` is skipped where the
/// directory can still be listed: a process that reads past the mode, as
/// root does, proves nothing.
pub fn with_directory_mode(path: String, mode: Int, check: fn() -> Nil) -> Nil {
  let assert Ok(Nil) = simplifile.set_permissions_octal(path, mode)
    as { "can't change the mode of " <> path }
  case simplifile.read_directory(path) {
    Error(_) -> check()
    Ok(_) -> Nil
  }
  let assert Ok(Nil) = simplifile.set_permissions_octal(path, 0o755)
    as { "can't restore the mode of " <> path }
  Nil
}

/// Delete a fixture directory and everything in it.
pub fn cleanup(directory: String) -> Nil {
  // A missing directory is already clean.
  let _ = simplifile.delete(directory)
  Nil
}

fn write_file(path: String, contents: String) -> Nil {
  create_parent(path)
  let assert Ok(Nil) = simplifile.write(path, contents)
    as { "can't write " <> path }
  Nil
}

fn create_parent(path: String) -> Nil {
  let segments = string.split(path, "/")
  let parent =
    segments
    |> list.take(list.length(segments) - 1)
    |> string.join("/")
  let assert Ok(Nil) = simplifile.create_directory_all(parent)
    as { "can't create " <> parent }
  Nil
}
