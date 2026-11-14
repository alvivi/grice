//// Loads a project from its directory into memory: the configuration, the
//// modules to lint and every project module they need, and the sources of
//// its dependencies.
////
//// `load_project` does the IO and hands what it found to `load`, which reads
//// only through the `read` function it's given, so tests can pass a
//// dictionary and an editor integration its unsaved buffers. Of the
//// project's own sources, only the load set is read.
////
//// `root` is the only path read relative to the working directory. Every
//// other path in a `Project` is relative to the root, except a local
//// dependency whose manifest `path` is absolute.

import glance
import gleam/bit_array
import gleam/bool
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import glexer
import glexer/token
import grice/diagnostic.{type Diagnostic, type Label, Diagnostic, Label, Span}
import grice/internal/config.{type Config}
import grice/internal/glob
import grice/internal/line_index.{type LineIndex}
import simplifile
import tom.{type Toml}

// Projects
//
// The loaded project and the pure core that builds it from file paths and a
// `read` function.

/// A loaded project: what rules run on and what types are inferred over.
pub type Project {
  Project(
    /// The project directory, as given to `load_project`.
    root: String,
    config: Config,
    /// The load set, by module name.
    modules: Dict(String, Module),
    /// The names of the modules to lint, sorted by path.
    lint_set: List(String),
    /// The source of every dependency module, by module name.
    dependencies: Dict(String, String),
    /// The manifest packages whose `src/` isn't a directory.
    missing_dependencies: List(Package),
    /// A `grice/parse-error` for each lint-set module that doesn't parse.
    diagnostics: List(Diagnostic),
  )
}

/// One loaded project module.
pub type Module {
  Module(
    /// The module name, such as `app/router`.
    name: String,
    /// The root-relative path, such as `src/app/router.gleam`.
    path: String,
    source: LineIndex,
    /// The syntax tree, or why glance couldn't parse the source. A module
    /// outside the lint set that doesn't parse keeps its error here, with no
    /// diagnostic.
    parsed: Result(glance.Module, glance.Error),
    /// Every module it imports for the configured target, project and
    /// dependency modules alike, in source order. Empty when it doesn't
    /// parse.
    imports: List(String),
  )
}

/// Why a project couldn't be loaded.
pub type LoadError {
  /// The configuration is invalid, or selects no module to lint.
  InvalidConfig(diagnostics: List(Diagnostic))
  /// A file or directory grice needed couldn't be read, or a source isn't
  /// UTF-8.
  CannotRead(path: String, reason: String)
  /// `manifest.toml` doesn't have the structure the compiler writes.
  InvalidManifest(reason: String)
}

/// Build a project from its file paths, with no IO of its own.
///
/// `paths` are the root-relative paths of the files under `src/`, `test/`
/// and `dev/`. Those that aren't module paths are skipped, and when two
/// paths give one module name, which the compiler rejects, the first is
/// kept. `read` gives the source at a root-relative path and is
/// called for load-set modules only.
pub fn load(
  root root: String,
  config config: Config,
  paths paths: List(String),
  read read: fn(String) -> Result(String, String),
  dependencies dependencies: Dict(String, String),
  missing_dependencies missing_dependencies: List(Package),
) -> Result(Project, LoadError) {
  let table = module_table(paths)
  use lint_set <- result.try(
    select_lint_set(config, table) |> result.map_error(InvalidConfig),
  )
  use modules <- result.try(load_modules(
    lint_set,
    table,
    read,
    config.target,
    dict.new(),
  ))
  let lint_set = list.map(lint_set, fn(entry) { entry.0 })
  let diagnostics =
    list.filter_map(lint_set, fn(name) {
      use module <- result.try(dict.get(modules, name))
      parse_error(module)
    })
  Ok(Project(
    root:,
    config:,
    modules:,
    lint_set:,
    dependencies:,
    missing_dependencies:,
    diagnostics:,
  ))
}

// Dependencies
//
// Where each dependency's sources live, read from `manifest.toml`. The
// manifest is the compiler's file, so only the fields grice uses are
// checked, and a malformed one fails loudly instead of silently dropping a
// dependency.

/// A manifest package with Gleam sources.
pub type Package {
  Package(
    name: String,
    source: PackageSource,
    /// The package directory, which holds its `src/`. Root-relative, unless
    /// it's a local package whose manifest `path` is absolute.
    directory: String,
  )
}

/// Where a package comes from.
pub type PackageSource {
  Hex
  Git
  Local
}

/// The packages of a `manifest.toml` that have Gleam sources, in manifest
/// order. Hex and git packages live in `build/packages/<name>`, a git
/// package with a `path` included, since the compiler copies that
/// subdirectory there. Local packages live at their `path`. Packages built
/// only by other tools, such as rebar3 or mix, are left out.
pub fn packages(manifest: String) -> Result(List(Package), LoadError) {
  use toml <- result.try(
    tom.parse(manifest)
    |> result.map_error(fn(error) {
      InvalidManifest(
        "`manifest.toml` isn't valid TOML: "
        <> config.describe_toml_error(error),
      )
    }),
  )
  use entries <- result.try(
    tom.get_array(toml, ["packages"])
    |> result.map_error(fn(error) {
      case error {
        tom.NotFound(..) ->
          InvalidManifest("`manifest.toml` has no `packages` list")
        tom.WrongType(..) ->
          InvalidManifest("`packages` in `manifest.toml` isn't a list")
      }
    }),
  )
  entries
  |> list.index_map(parse_package)
  |> result.all
  |> result.map(list.key_filter(_, True))
}

// A package, keyed by whether Gleam builds it.
fn parse_package(
  entry: Toml,
  index: Int,
) -> Result(#(Bool, Package), LoadError) {
  let position = "Package " <> int.to_string(index + 1)
  use fields <- result.try(case entry {
    tom.Table(fields) | tom.InlineTable(fields) -> Ok(fields)
    _ -> Error(InvalidManifest(position <> " in `manifest.toml` isn't a table"))
  })
  use name <- result.try(string_field(fields, position, "name"))
  let owner = "The package `" <> name <> "`"
  use source <- result.try(string_field(fields, owner, "source"))
  use build_tools <- result.try(
    tom.get_array(fields, ["build_tools"])
    |> result.try(list.try_map(_, tom.as_string))
    |> field(owner, "build_tools", "a list of strings"),
  )
  use #(source, directory) <- result.try(case source {
    "hex" -> Ok(#(Hex, "build/packages/" <> name))
    "git" -> Ok(#(Git, "build/packages/" <> name))
    "local" ->
      string_field(fields, owner, "path")
      |> result.map(fn(path) { #(Local, path) })
    _ ->
      Error(InvalidManifest(
        owner <> " in `manifest.toml` has the unknown source `" <> source <> "`",
      ))
  })
  Ok(#(list.contains(build_tools, "gleam"), Package(name:, source:, directory:)))
}

fn string_field(
  fields: Dict(String, Toml),
  owner: String,
  key: String,
) -> Result(String, LoadError) {
  tom.get_string(fields, [key]) |> field(owner, key, "a string")
}

// A package field, or what's wrong with it.
fn field(
  found: Result(a, tom.GetError),
  owner: String,
  key: String,
  expected: String,
) -> Result(a, LoadError) {
  use error <- result.map_error(found)
  let problem = case error {
    tom.NotFound(..) -> "has no `" <> key <> "`"
    tom.WrongType(..) -> "has a `" <> key <> "` that isn't " <> expected
  }
  InvalidManifest(owner <> " in `manifest.toml` " <> problem)
}

// Discovery
//
// Which files are modules, and which modules are linted. A file is a
// module when its path inside `src/`, `test/` or `dev/` is a valid module
// path, as the compiler decides: segments of a lowercase letter followed by
// lowercase letters, digits and `_`, ending in `.gleam`. The compiler warns
// about other `.gleam` files and ignores them, so grice skips them silently.

const lowercase = "abcdefghijklmnopqrstuvwxyz"

// The module name of a path whose first segment is `src`, `test` or `dev`,
// such as `app/router` for `src/app/router.gleam`.
fn module_name(path: String) -> Result(String, Nil) {
  let relative = case path {
    "src/" <> relative | "test/" <> relative | "dev/" <> relative -> relative
    _ -> ""
  }
  let name = string.drop_end(relative, string.length(".gleam"))
  case
    string.ends_with(relative, ".gleam")
    && list.all(string.split(name, "/"), is_module_segment)
  {
    True -> Ok(name)
    False -> Error(Nil)
  }
}

fn is_module_segment(segment: String) -> Bool {
  case string.to_graphemes(segment) {
    [first, ..rest] ->
      string.contains(lowercase, first)
      && list.all(rest, string.contains(lowercase <> "0123456789_", _))
    [] -> False
  }
}

// Every module, by name, with its path. The first path wins a name.
fn module_table(paths: List(String)) -> Dict(String, String) {
  paths
  |> list.filter_map(fn(path) {
    module_name(path) |> result.map(fn(name) { #(name, path) })
  })
  |> list.reverse
  |> dict.from_list
}

// The modules to lint, as `#(name, path)` sorted by path. Every `include`
// must select at least one module, and the lint set must not be empty:
// otherwise the run would report success over code it never looked at.
fn select_lint_set(
  config: Config,
  table: Dict(String, String),
) -> Result(List(#(String, String)), List(Diagnostic)) {
  let modules = dict.to_list(table)
  let unmatched =
    config.include
    |> list.filter(fn(pattern) {
      !list.any(modules, fn(module) { glob.matches(pattern, module.1) })
    })
    |> list.map(unmatched_include)
  let selected =
    modules
    |> list.filter(fn(module) {
      list.any(config.include, glob.matches(_, module.1))
      && !list.any(config.exclude, glob.matches(_, module.1))
    })
    |> list.sort(fn(left, right) { string.compare(left.1, right.1) })
  case unmatched, selected {
    [], [] -> Error([nothing_to_lint()])
    [], [_, ..] -> Ok(selected)
    [_, ..], _ -> Error(unmatched)
  }
}

fn unmatched_include(pattern: glob.Glob) -> Diagnostic {
  config.diagnostic(
    title: "An `include` matches no module",
    message: "`tools.grice.include` in `gleam.toml` holds `"
      <> glob.to_string(pattern)
      <> "`, which matches no module under `src/`, `test/` or `dev/`. An `include` says what to lint, so one that selects nothing is most likely a typo or a stale path.",
    hint: Some("Fix the pattern, or remove it."),
  )
}

fn nothing_to_lint() -> Diagnostic {
  config.diagnostic(
    title: "Nothing to lint",
    message: "`tools.grice.include` and `tools.grice.exclude` in `gleam.toml` select no module, so there is nothing to lint, and grice doesn't report success over code it didn't check.",
    hint: Some(
      "Include at least one module under `src/`, `test/` or `dev/`, and check that `exclude` doesn't remove them all.",
    ),
  )
}

// Load set
//
// Starting from the lint set, every import that names a project module is
// followed, transitively. Imports marked for the other target are dropped
// before they're followed, which is what lets a package whose modules import
// each other on different targets load on either one.

// Load each queued module that isn't loaded yet, and queue the project
// modules it imports.
fn load_modules(
  queue: List(#(String, String)),
  table: Dict(String, String),
  read: fn(String) -> Result(String, String),
  target: config.Target,
  loaded: Dict(String, Module),
) -> Result(Dict(String, Module), LoadError) {
  case queue {
    [] -> Ok(loaded)
    [#(name, path), ..rest] -> {
      use <- bool.lazy_guard(when: dict.has_key(loaded, name), return: fn() {
        load_modules(rest, table, read, target, loaded)
      })
      use source <- result.try(
        read(path) |> result.map_error(CannotRead(path, _)),
      )
      let module = parse_module(name, path, source, target)
      let imported =
        list.filter_map(module.imports, fn(import_name) {
          dict.get(table, import_name)
          |> result.map(fn(import_path) { #(import_name, import_path) })
        })
      load_modules(
        list.append(imported, rest),
        table,
        read,
        target,
        dict.insert(loaded, name, module),
      )
    }
  }
}

fn parse_module(
  name: String,
  path: String,
  source: String,
  target: config.Target,
) -> Module {
  let parsed = glance.module(source)
  let imports = case parsed {
    Ok(syntax) ->
      syntax.imports
      |> list.filter(is_on_target(_, target))
      // glance doesn't keep the imports in source order, so they're sorted
      // back into it.
      |> list.map(fn(definition) { definition.definition })
      |> list.sort(fn(left, right) {
        int.compare(left.location.start, right.location.start)
      })
      |> list.map(fn(import_) { import_.module })
    // A module that doesn't parse has no imports to follow. Its error is
    // kept in `parsed`.
    Error(_) -> []
  }
  Module(name:, path:, source: line_index.new(source), parsed:, imports:)
}

// An import is on the target unless a `@target` attribute names the other
// one. The compiler also accepts the deprecated `erl` and `js`.
fn is_on_target(
  definition: glance.Definition(glance.Import),
  target: config.Target,
) -> Bool {
  let other = case target {
    config.Erlang -> ["javascript", "js"]
    config.JavaScript -> ["erlang", "erl"]
  }
  !list.any(definition.attributes, fn(attribute) {
    case attribute {
      glance.Attribute(name: "target", arguments: [glance.Variable(_, name)]) ->
        list.contains(other, name)
      _ -> False
    }
  })
}

// Parse errors
//
// A lint-set module glance can't parse is an error that points at the
// token glance stopped at. The rest of the project still loads, so the other
// modules can be linted.

/// The `grice/parse-error` diagnostic for a module that doesn't parse.
pub fn parse_error(module: Module) -> Result(Diagnostic, Nil) {
  case module.parsed {
    Ok(_) -> Error(Nil)
    Error(error) ->
      Ok(Diagnostic(
        code: "grice/parse-error",
        severity: diagnostic.Error,
        title: "Can't parse this module",
        location: Some(diagnostic.Location(
          path: module.path,
          primary: error_label(module.source, error),
          secondary: [],
          fix: None,
        )),
        message: [
          "grice reads Gleam code with glance, and glance couldn't parse this file. No rule ran on it, and the modules that import it may lose type information.",
        ],
        hint: Some(
          "If `gleam build` accepts this file, glance doesn't support its syntax yet, so please report it to glance.",
        ),
      ))
  }
}

// The label under the token glance stopped at, or an empty one at the end of
// the source when the input ended too soon.
fn error_label(source: LineIndex, error: glance.Error) -> Label {
  case error {
    glance.UnexpectedEndOfInput -> {
      let end = string.byte_size(line_index.source(source))
      Label(span: Span(end, end), message: "The file ends here unexpectedly")
    }
    glance.UnexpectedToken(
      token: unexpected,
      position: glexer.Position(byte_offset:),
    ) ->
      Label(
        span: token_span(source, token.to_source(unexpected), byte_offset),
        message: "glance didn't expect this",
      )
  }
}

// The span of `text` at `offset`, used only if the source really holds that
// text there. Otherwise it's an empty span at `offset`, or at the end of the
// source if `offset` isn't a valid position, so the span is always one the
// renderer accepts.
fn token_span(source: LineIndex, text: String, offset: Int) -> diagnostic.Span {
  let bytes = bit_array.from_string(line_index.source(source))
  let size = string.byte_size(text)
  let found = bit_array.slice(bytes, offset, size)
  use <- bool.guard(
    when: size > 0 && found == Ok(bit_array.from_string(text)),
    return: Span(offset, offset + size),
  )
  let empty = Span(offset, offset)
  case line_index.check_span(source, empty) {
    Ok(Nil) -> empty
    Error(_problem) -> {
      let end = bit_array.byte_size(bytes)
      Span(end, end)
    }
  }
}

// IO
//
// Reading the project from disk. Directories are walked the way the
// compiler finds modules: breadth-first, entries in the order the file
// system lists them, symbolic links followed, and each directory entered at
// most once per walk however it's reached. Each source directory is a walk
// of its own, as each is a separate walk in the compiler.

/// Load the project in the directory `root`: read its configuration and
/// manifest, read every dependency's sources, walk `src/`, `test/` and
/// `dev/`, and `load` the result, reading files under `root`.
pub fn load_project(root: String) -> Result(Project, LoadError) {
  use gleam_toml <- result.try(read_file(root, "gleam.toml"))
  use config <- result.try(
    config.parse(gleam_toml) |> result.map_error(InvalidConfig),
  )
  use manifest <- result.try(read_file(root, "manifest.toml"))
  use packages <- result.try(packages(manifest))
  use #(dependencies, missing_dependencies) <- result.try(read_dependencies(
    root,
    packages,
  ))
  use paths <- result.try(
    ["src", "test", "dev"]
    |> list.try_map(walk(root, "", _))
    |> result.map(list.flatten),
  )
  load(
    root:,
    config:,
    paths:,
    read: fn(path) {
      simplifile.read(join(root, path))
      |> result.map_error(simplifile.describe_error)
    },
    dependencies:,
    missing_dependencies:,
  )
}

fn read_file(root: String, path: String) -> Result(String, LoadError) {
  simplifile.read(join(root, path)) |> result.map_error(cannot_read(path))
}

// The sources of every package module, by module name, and the packages
// whose `src/` isn't a directory, in manifest order. A package with an empty
// `src/` is present, with no modules.
fn read_dependencies(
  root: String,
  packages: List(Package),
) -> Result(#(Dict(String, String), List(Package)), LoadError) {
  use #(sources, missing), package <- list.try_fold(packages, #(dict.new(), []))
  // Only a leading `/` marks an absolute path. Gleam writes local paths
  // relative to the root, and telling Windows forms apart from relative Unix
  // names such as `C:/dep` needs the host's path rules.
  let location = case string.starts_with(package.directory, "/") {
    True -> package.directory
    False -> join(root, package.directory)
  }
  use present <- result.try(is_directory(
    join(location, "src"),
    join(package.directory, "src"),
  ))
  use <- bool.guard(
    when: !present,
    return: Ok(#(sources, list.append(missing, [package]))),
  )
  use files <- result.try(walk(location, package.directory, "src"))
  use sources <- result.map({
    use sources, file <- list.try_fold(files, sources)
    case module_name(file) {
      Error(Nil) -> Ok(sources)
      Ok(name) ->
        simplifile.read(join(location, file))
        |> result.map(dict.insert(sources, name, _))
        |> result.map_error(cannot_read(join(package.directory, file)))
    }
  })
  #(sources, missing)
}

// Whether there's a directory at `location`. Only a path that doesn't exist
// counts as missing; any other problem is an error naming `path`.
fn is_directory(location: String, path: String) -> Result(Bool, LoadError) {
  case simplifile.file_info(location) {
    Ok(info) -> Ok(simplifile.file_info_type(info) == simplifile.Directory)
    Error(simplifile.Enoent) | Error(simplifile.Enotdir) -> Ok(False)
    Error(error) -> Error(cannot_read(path)(error))
  }
}

// Every file under `start`, a directory inside `location`, as paths relative
// to `location`, in the order the walk finds them. A `start` that isn't a
// directory has no files. Errors name paths under `path`.
fn walk(
  location: String,
  path: String,
  start: String,
) -> Result(List(String), LoadError) {
  use present <- result.try(is_directory(
    join(location, start),
    join(path, start),
  ))
  use <- bool.guard(when: !present, return: Ok([]))
  walk_level(location, path, [start], set.new(), [])
}

// One level of the breadth-first walk: every entry in `level`, in order,
// with the entries of the directories among them queued for the next level.
// `visited` holds the `#(device, inode)` of every directory entered, and
// `found` the files found so far, newest first.
fn walk_level(
  location: String,
  path: String,
  level: List(String),
  visited: Set(#(Int, Int)),
  found: List(String),
) -> Result(List(String), LoadError) {
  case level {
    [] -> Ok(list.reverse(found))
    [_, ..] -> {
      use #(next, visited, found) <- result.try(
        list.try_fold(level, #([], visited, found), fn(state, entry) {
          visit(location, path, entry, state)
        }),
      )
      walk_level(location, path, list.reverse(next), visited, found)
    }
  }
}

// A file is found, and a directory not entered yet has its entries queued.
// A directory whose inode is reported as 0 has nothing to tell it apart by,
// so it's always entered. A dangling link fails `file_info`.
fn visit(
  location: String,
  path: String,
  entry: String,
  state: #(List(String), Set(#(Int, Int)), List(String)),
) -> Result(#(List(String), Set(#(Int, Int)), List(String)), LoadError) {
  let #(next, visited, found) = state
  let full = join(location, entry)
  let cannot_read = cannot_read(join(path, entry))
  use info <- result.try(
    simplifile.file_info(full) |> result.map_error(cannot_read),
  )
  case simplifile.file_info_type(info) {
    simplifile.File -> Ok(#(next, visited, [entry, ..found]))
    simplifile.Directory -> {
      let id = #(info.dev, info.inode)
      use <- bool.guard(
        when: info.inode != 0 && set.contains(visited, id),
        return: Ok(state),
      )
      use names <- result.map(
        simplifile.read_directory(full) |> result.map_error(cannot_read),
      )
      let next =
        list.fold(names, next, fn(next, name) { [join(entry, name), ..next] })
      #(next, set.insert(visited, id), found)
    }
    simplifile.Symlink | simplifile.Other -> Ok(state)
  }
}

fn cannot_read(path: String) -> fn(simplifile.FileError) -> LoadError {
  fn(error) { CannotRead(path, simplifile.describe_error(error)) }
}

// Join two paths with `/`. An empty side is left out.
fn join(left: String, right: String) -> String {
  case left, right {
    "", _ -> right
    _, "" -> left
    _, _ -> left <> "/" <> right
  }
}
