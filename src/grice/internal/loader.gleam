//// Loads a project from its directory into memory: the configuration, the
//// modules to lint and every project module they need, and the sources of
//// its dependencies.
////
//// `load_project` does the IO and hands what it found to `load`, which reads
//// only through the `read` function it's given, so tests can pass a
//// dictionary and an editor integration its unsaved buffers. Of the
//// project's own sources, only the load set is read, unless the scope is
//// the whole project: then every module and foreign source under `src/`,
//// `test/` and `dev/` is read too.
////
//// A project also knows which of its modules and types are internal, from
//// `internal_modules` in `gleam.toml`, the compiler's default patterns and
//// `@internal`, so every rule can ask.
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
import gleam/pair
import gleam/result
import gleam/set.{type Set}
import gleam/string
import glexer
import glexer/token
import grice/diagnostic.{type Diagnostic, type Label, Diagnostic, Label, Span}
import grice/internal/config.{type Config}
import grice/internal/glance_spans
import grice/internal/glob
import grice/internal/line_index.{type LineIndex}
import grice/internal/type_names
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
    /// How much of the project was read, and with the whole project, what
    /// reading it found beyond the load set.
    scope: Scope,
    /// The load set, by module name: with `WholeProject`, every module of
    /// the project that could be read.
    modules: Dict(String, Module),
    /// The names of the modules to lint, sorted by path.
    lint_set: List(String),
    /// The source of every dependency module, by module name.
    dependencies: Dict(String, String),
    /// The manifest packages whose `src/` isn't a directory.
    missing_dependencies: List(Package),
    /// A `grice/parse-error` for each lint-set module that doesn't parse.
    diagnostics: List(Diagnostic),
    /// The names of the project's internal modules: every module under
    /// `src/`, `test/` and `dev/`, loaded or not, whose name a pattern of
    /// the configuration's `internal_modules` matches.
    internal_modules: Set(String),
    /// The internal types of the load set's modules that parse, as they're
    /// compiled for the target, each `#(module, name)`: what
    /// `type_names.internal_types` finds. Only the load set's, with either
    /// scope.
    internal_types: Set(#(String, String)),
  )
}

/// How much of the project `load` reads.
pub type Load {
  /// The lint set and the project modules it imports, transitively: the
  /// load set. Nothing else of the project is opened.
  LoadLintSet
  /// The load set, then every other module under `src/`, `test/` and
  /// `dev/`, and the project's foreign sources, for a rule that sees the
  /// whole project. A file outside the load set that can't be read is
  /// recorded in `WholeProject`'s `unread` rather than failing the load, a
  /// `.gleam` file there that grice doesn't take for a module in its
  /// `unnamed`, and a module there that doesn't parse keeps its error in
  /// `parsed`, as an excluded module does.
  LoadWholeProject
}

/// How much of the project a load read, as `Load` asked.
pub type Scope {
  /// The load set alone.
  LintSet
  /// The whole project, and what reading it found beyond the load set.
  WholeProject(
    /// Each module and foreign source outside the load set that couldn't
    /// be read, as its root-relative path and why, sorted by path.
    unread: List(#(String, String)),
    /// Each `.gleam` file under the source directories that grice doesn't
    /// take for a module, which the compiler might, as its spelling isn't
    /// one grice reads or another path gives its name, sorted.
    unnamed: List(String),
    /// The words of the project's foreign sources that name each module,
    /// by module name: see `foreign_mentions`. A module no foreign source
    /// names has no entry.
    foreign_mentions: Dict(String, Set(String)),
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
    parsed: Result(glance.Module, ParseError),
    /// Every module it imports for the configured target, project and
    /// dependency modules alike, in source order. Empty when it doesn't
    /// parse.
    imports: List(String),
  )
}

/// Why a module doesn't parse.
pub type ParseError {
  /// glance stopped at a token, or at the end of the input.
  Unexpected(glance.Error)
  /// grice ran out of stack reading the module. glance's parser recurses
  /// once for each definition and statement, and the correction of its
  /// spans into nested expressions, so on JavaScript, whose stack is much
  /// smaller than an Erlang process's, a module with more than about a
  /// thousand definitions, a function with thousands of statements, or
  /// very deeply nested code uses it up.
  OutOfStack
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
/// kept. `read` gives the bytes of the file at a root-relative path, or why
/// it can't. With `LoadLintSet` it's called for load-set modules only; with
/// `LoadWholeProject`, also for every other module and for each foreign source
/// among `paths`. A module must be UTF-8, while a foreign source is read
/// only for its ASCII words, in whatever encoding it's in.
pub fn load(
  root root: String,
  config config: Config,
  paths paths: List(String),
  read read: fn(String) -> Result(BitArray, String),
  dependencies dependencies: Dict(String, String),
  missing_dependencies missing_dependencies: List(Package),
  scope requested: Load,
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
  let internal_modules =
    dict.keys(table)
    |> list.filter(fn(name) {
      list.any(config.internal_modules, glob.matches_module(_, name))
    })
    |> set.from_list
  // Only the load set's types, whatever the scope, so every rule gets the
  // same answers as from a load of the lint set.
  let internal_types =
    dict.values(modules)
    |> list.filter_map(fn(module) {
      use syntax <- result.map(module.parsed)
      #(module.name, for_target(syntax, config.target))
    })
    |> type_names.internal_types(internal_modules)
  let #(modules, scope) = case requested {
    LoadLintSet -> #(modules, LintSet)
    LoadWholeProject -> load_rest(modules, table, paths, read, config.target)
  }
  let lint_set = list.map(lint_set, fn(entry) { entry.0 })
  let diagnostics =
    list.filter_map(lint_set, fn(name) {
      use module <- result.try(dict.get(modules, name))
      parse_error(module)
    })
  Ok(Project(
    root:,
    config:,
    scope:,
    modules:,
    lint_set:,
    dependencies:,
    missing_dependencies:,
    diagnostics:,
    internal_modules:,
    internal_types:,
  ))
}

/// The source of every loaded project module, by its root-relative path:
/// every source a diagnostic of the project can point into.
pub fn sources(project: Project) -> Dict(String, LineIndex) {
  project.modules
  |> dict.values
  |> list.map(fn(module) { #(module.path, module.source) })
  |> dict.from_list
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

/// The module name of a path whose first segment is `src`, `test` or `dev`,
/// such as `app/router` for `src/app/router.gleam`, or `Error` when the path
/// isn't a module path.
@internal
pub fn module_name(path: String) -> Result(String, Nil) {
  let relative = case path {
    "src/" <> relative | "test/" <> relative | "dev/" <> relative -> relative
    _ -> ""
  }
  let name = string.drop_end(relative, string.length(".gleam"))
  case
    string.ends_with(relative, ".gleam")
    && list.all(string.split(name, "/"), config.is_lowercase_name)
  {
    True -> Ok(name)
    False -> Error(Nil)
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

/// The module as it's compiled for `target`, with each list of definitions
/// in source order. A definition of any kind is left out when a `@target`
/// attribute names the other target. Imports are followed from this view,
/// and rules see it.
pub fn for_target(
  module: glance.Module,
  target: config.Target,
) -> glance.Module {
  glance.Module(
    imports: on_target(module.imports, target),
    custom_types: on_target(module.custom_types, target),
    type_aliases: on_target(module.type_aliases, target),
    constants: on_target(module.constants, target),
    functions: on_target(module.functions, target),
  )
}

/// The module with the definitions of every target, each list in source
/// order: `for_target` with nothing left out.
pub fn for_every_target(module: glance.Module) -> glance.Module {
  glance.Module(
    imports: list.reverse(module.imports),
    custom_types: list.reverse(module.custom_types),
    type_aliases: list.reverse(module.type_aliases),
    constants: list.reverse(module.constants),
    functions: list.reverse(module.functions),
  )
}

// The definitions compiled for `target`, put back in source order: glance
// builds every list in reverse.
fn on_target(
  definitions: List(glance.Definition(definition)),
  target: config.Target,
) -> List(glance.Definition(definition)) {
  definitions
  |> list.filter(fn(definition) { is_on_target(definition.attributes, target) })
  |> list.reverse
}

// Load each queued module that isn't loaded yet, and queue the project
// modules it imports.
fn load_modules(
  queue: List(#(String, String)),
  table: Dict(String, String),
  read: fn(String) -> Result(BitArray, String),
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
        read_source(read, path) |> result.map_error(CannotRead(path, _)),
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

// The text of the module at `path`, or why it can't be read: `read` failed,
// or the module isn't UTF-8.
fn read_source(
  read: fn(String) -> Result(BitArray, String),
  path: String,
) -> Result(String, String) {
  use bytes <- result.try(read(path))
  line_index.decode(bytes)
  |> result.replace_error(simplifile.describe_error(simplifile.NotUtf8))
}

// The tree is corrected before anything reads it, so the target view,
// girard, the rules and the suppressions all see the same spans.
fn parse_module(
  name: String,
  path: String,
  source: String,
  target: config.Target,
) -> Module {
  let index = line_index.new(source)
  let parsed = parse(source, line_index.units(index))
  let imports = case parsed {
    Ok(syntax) ->
      on_target(syntax.imports, target)
      |> list.map(fn(definition) { definition.definition.module })
    // A module that doesn't parse has no imports to follow. Its error is
    // kept in `parsed`.
    Error(_) -> []
  }
  Module(name:, path:, source: index, parsed:, imports:)
}

// The syntax tree of `source`, corrected where glance's offsets count
// UTF-16 code units, or why it couldn't be built. Parsing and correcting
// both recurse, so both run inside one catch for running out of stack.
fn parse(
  source: String,
  units: line_index.Units,
) -> Result(glance.Module, ParseError) {
  let read = fn() {
    use syntax <- result.map(glance.module(source))
    case units {
      line_index.CodeUnits -> glance_spans.correct(syntax)
      line_index.Bytes -> syntax
    }
  }
  case catching_stack_overflow(read) {
    Ok(parsed) -> result.map_error(parsed, Unexpected)
    Error(Nil) -> Error(OutOfStack)
  }
}

// What `run` returns, or `Error(Nil)` when it runs out of stack, which only
// happens on JavaScript.
@external(javascript, "../../grice_ffi.mjs", "catching_stack_overflow")
fn catching_stack_overflow(run: fn() -> a) -> Result(a, Nil) {
  Ok(run())
}

// A definition is on the target unless a `@target` attribute names the
// other one. The compiler also accepts the deprecated `erl` and `js`.
fn is_on_target(
  attributes: List(glance.Attribute),
  target: config.Target,
) -> Bool {
  let other = case target {
    config.Erlang -> ["javascript", "js"]
    config.JavaScript -> ["erlang", "erl"]
  }
  !list.any(attributes, fn(attribute) {
    case attribute {
      glance.Attribute(name: "target", arguments: [glance.Variable(_, name)]) ->
        list.contains(other, name)
      _ -> False
    }
  })
}

// The whole project
//
// After the load set, every other module of the table is read and parsed,
// in path order, and every foreign source is read for the words it holds.
// A file that can't be read is recorded rather than failing the load: it
// limits what a whole-project rule can see, not the run.

/// The file extensions of the foreign sources a whole-project load reads:
/// the compiler's native files, which it compiles or copies beside the
/// project's own (`is_native_file_extension` in the compiler's
/// `compiler-core/src/io.rs`, at v1.19.2).
const foreign_extensions = [
  ".erl", ".hrl", ".ex", ".js", ".mjs", ".cjs", ".jsx", ".ts", ".mts", ".cts",
  ".tsx",
]

/// Whether the root-relative `path` is a foreign source of the project: a
/// file under `src/`, `test/` or `dev/` ending in `.erl`, `.hrl`, `.ex`,
/// `.js`, `.mjs`, `.cjs`, `.jsx`, `.ts`, `.mts`, `.cts` or `.tsx`.
pub fn is_foreign_source(path: String) -> Bool {
  is_in_source_directory(path)
  && list.any(foreign_extensions, string.ends_with(path, _))
}

fn is_in_source_directory(path: String) -> Bool {
  case path {
    "src/" <> _ | "test/" <> _ | "dev/" <> _ -> True
    _ -> False
  }
}

/// The module's Erlang name, as the compiler writes it: its name with each
/// `/` turned into `@`, such as `app@internal@parser`.
pub fn erlang_name(module: String) -> String {
  string.replace(module, "/", "@")
}

/// The name of the module's JavaScript file, such as `parser.mjs` for
/// `app/internal/parser`: what an import from beside it names it by.
pub fn javascript_file(module: String) -> String {
  { string.split(module, "/") |> list.last |> result.unwrap(module) } <> ".mjs"
}

// Every module of `table` that `modules` doesn't hold yet, read and
// parsed in path order, and the foreign sources among `paths`: the
// modules, and the `WholeProject` scope with what couldn't be read and the
// `.gleam` files that aren't modules of the table, each sorted by path,
// and the foreign mentions, among the names of every loaded module's
// functions.
fn load_rest(
  modules: Dict(String, Module),
  table: Dict(String, String),
  paths: List(String),
  read: fn(String) -> Result(BitArray, String),
  target: config.Target,
) -> #(Dict(String, Module), Scope) {
  let #(loaded, unread_modules) =
    dict.to_list(table)
    |> list.filter(fn(entry) { !dict.has_key(modules, entry.0) })
    |> list.sort(fn(left, right) { string.compare(left.1, right.1) })
    |> list.map(fn(entry) {
      let #(name, path) = entry
      read_source(read, path)
      |> result.map(fn(source) {
        #(name, parse_module(name, path, source, target))
      })
      |> result.map_error(pair.new(path, _))
    })
    |> result.partition
  let modules = dict.merge(modules, dict.from_list(loaded))
  let #(sources, unread_sources) =
    paths
    |> list.filter(is_foreign_source)
    |> list.unique
    |> list.sort(string.compare)
    |> list.map(fn(path) { read(path) |> result.map_error(pair.new(path, _)) })
    |> result.partition
  // A `.gleam` file under the source directories that isn't a module of the
  // table, as its name has a spelling grice doesn't read, or another path
  // gives it, may still be one the compiler builds.
  let unnamed =
    paths
    |> list.filter(fn(path) {
      string.ends_with(path, ".gleam")
      && is_in_source_directory(path)
      && result.try(module_name(path), dict.get(table, _)) != Ok(path)
    })
    |> list.sort(string.compare)
  let unread =
    list.append(unread_modules, unread_sources)
    |> list.sort(fn(left, right) { string.compare(left.0, right.0) })
  let functions =
    dict.values(modules)
    |> list.flat_map(fn(module) {
      case module.parsed {
        Ok(syntax) ->
          list.map(syntax.functions, fn(function) { function.definition.name })
        Error(_) -> []
      }
    })
    |> set.from_list
  #(
    modules,
    WholeProject(
      unread:,
      unnamed:,
      foreign_mentions: foreign_mentions(sources, dict.keys(table), functions),
    ),
  )
}

/// For each of `modules`, the words of the foreign sources among `sources`,
/// each the bytes of one, that name it and that are among `names`, by
/// module name. A source names the module `a/b/c` when it holds its Erlang
/// name, `a@b@c`, as a word, or its JavaScript file name, `c.mjs`, with no
/// directory, since an import from beside it carries none. A word is a
/// longest run of ASCII letters, digits, `_` and `@`, so an Erlang module
/// name is one word, and a Gleam function's name is a word wherever foreign
/// code calls it. A module no source names has no entry.
pub fn foreign_mentions(
  sources: List(BitArray),
  modules: List(String),
  names: Set(String),
) -> Dict(String, Set(String)) {
  // Modules in different directories can share a JavaScript file name.
  let by_erlang_name =
    list.map(modules, fn(module) { #(erlang_name(module), module) })
    |> dict.from_list
  let by_file = list.group(modules, javascript_file)
  use mentions, source <- list.fold(sources, dict.new())
  let #(words, before_mjs) = foreign_words(source)
  let named =
    list.append(
      list.filter_map(words, dict.get(by_erlang_name, _)),
      list.flat_map(before_mjs, fn(word) {
        dict.get(by_file, word <> ".mjs") |> result.unwrap([])
      }),
    )
  use <- bool.guard(when: named == [], return: mentions)
  let found = list.filter(words, set.contains(names, _)) |> set.from_list
  use mentions, module <- list.fold(named, mentions)
  dict.upsert(mentions, module, fn(earlier) {
    set.union(option.unwrap(earlier, set.new()), found)
  })
}

// Each longest run of ASCII letters, digits, `_` and `@` in `source`, and
// each one of them that `.mjs` follows, each once. Every byte of a word is
// ASCII, so any other byte ends one, whatever the source's encoding.
@external(erlang, "grice_ffi", "foreign_words")
@external(javascript, "../../grice_ffi.mjs", "foreign_words")
fn foreign_words(source: BitArray) -> #(List(String), List(String))

// Parse errors
//
// A lint-set module glance can't parse is an error that points at the
// token glance stopped at, or at the start of the file when grice ran out
// of stack reading it. The rest of the project still loads, so the other modules can
// be linted.

/// The `grice/parse-error` diagnostic for a module that doesn't parse.
pub fn parse_error(module: Module) -> Result(Diagnostic, Nil) {
  case module.parsed {
    Ok(_) -> Error(Nil)
    Error(error) -> Ok(unparsed(module, error))
  }
}

fn unparsed(module: Module, error: ParseError) -> Diagnostic {
  let #(label, why, hint) =
    describe_parse_error(module.source, module.path, error)
  Diagnostic(
    code: "grice/parse-error",
    severity: diagnostic.Error,
    title: "Can't parse this module",
    location: Some(diagnostic.Location(
      path: module.path,
      primary: label,
      secondary: [],
      fix: None,
    )),
    message: [
      why
      <> " No rule ran on it, and the modules that import it may lose type information.",
    ],
    hint: Some(hint),
  )
}

/// The hint for a project module at `path` that grice ran out of stack
/// reading.
pub fn out_of_stack_hint(path: String) -> String {
  "Split `"
  <> path
  <> "` into smaller modules, or run grice on Erlang, with `gleam run --target erlang -m <module>`, if the project compiles for Erlang."
}

// The label, the opening sentence and the hint of a parse error of the
// module at `path`.
fn describe_parse_error(
  source: LineIndex,
  path: String,
  error: ParseError,
) -> #(Label, String, String) {
  case error {
    Unexpected(error) -> #(
      error_label(source, error),
      "grice reads Gleam code with glance, and glance couldn't parse this file.",
      "If `gleam build` accepts this file, glance doesn't support its syntax yet, so please report it to glance.",
    )
    OutOfStack -> #(
      Label(span: Span(0, 0), message: "grice ran out of stack reading this"),
      "grice ran out of stack partway through reading this file on JavaScript, where the stack is much smaller than on Erlang: the file has too many definitions or statements, or code nested too deeply.",
      out_of_stack_hint(path),
    )
  }
}

/// The label under the token glance stopped at in `source`, or an empty one
/// at the end of the source when the input ended too soon.
pub fn error_label(source: LineIndex, error: glance.Error) -> Label {
  case error {
    glance.UnexpectedEndOfInput -> {
      let end = string.byte_size(line_index.source(source))
      Label(span: Span(end, end), message: "The file ends here unexpectedly")
    }
    // glexer's offset counts glance's units, which may not be bytes.
    glance.UnexpectedToken(
      token: unexpected,
      position: glexer.Position(byte_offset: offset),
    ) ->
      Label(
        span: token_span(source, token.to_source(unexpected), offset),
        message: "glance didn't expect this",
      )
  }
}

// The span of `text` at glance's offset `offset`, used only if the source
// really holds that text there. Otherwise it's an empty span at `offset`,
// or at the end of the source if `offset` isn't a valid position, so the
// span is always one the renderer accepts.
fn token_span(source: LineIndex, text: String, offset: Int) -> diagnostic.Span {
  let bytes = bit_array.from_string(line_index.source(source))
  let end = Span(bit_array.byte_size(bytes), bit_array.byte_size(bytes))
  case line_index.to_bytes(source, offset) {
    Error(_problem) -> end
    Ok(offset) -> {
      let size = string.byte_size(text)
      let found = bit_array.slice(bytes, offset, size)
      use <- bool.guard(
        when: size > 0 && found == Ok(bit_array.from_string(text)),
        return: Span(offset, offset + size),
      )
      let empty = Span(offset, offset)
      case line_index.check_span(source, empty) {
        Ok(Nil) -> empty
        Error(_problem) -> end
      }
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
/// `dev/`, and `load` the result with `scope`, reading files under `root`.
pub fn load_project(root: String, scope: Load) -> Result(Project, LoadError) {
  load_project_with(root, scope, installed: fn() { installed(root) })
}

/// Load the project in the directory `root` as `load_project` does, with
/// `installed` standing in for reading its installed dependencies. It's
/// called once, after the configuration is read, so a caller loading many
/// projects over the same dependencies can read them once.
@internal
pub fn load_project_with(
  root: String,
  scope: Load,
  installed installed: fn() ->
    Result(#(Dict(String, String), List(Package)), LoadError),
) -> Result(Project, LoadError) {
  use gleam_toml <- result.try(read_file(root, "gleam.toml"))
  use config <- result.try(
    config.parse(gleam_toml) |> result.map_error(InvalidConfig),
  )
  use #(dependencies, missing_dependencies) <- result.try(installed())
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
      simplifile.read_bits(join(root, path))
      |> result.map_error(simplifile.describe_error)
    },
    dependencies:,
    missing_dependencies:,
    scope:,
  )
}

/// The dependencies installed for the project in the directory `root`, as
/// `load_project` reads them: the source of every module in each
/// `manifest.toml` package's `src/`, by module name, and the packages whose
/// `src/` isn't a directory, in manifest order.
pub fn installed(
  root: String,
) -> Result(#(Dict(String, String), List(Package)), LoadError) {
  use manifest <- result.try(read_file(root, "manifest.toml"))
  use packages <- result.try(packages(manifest))
  read_dependencies(root, packages)
}

fn read_file(root: String, path: String) -> Result(String, LoadError) {
  read_text(join(root, path)) |> result.map_error(cannot_read(path))
}

// The text of the file at `location`, every byte kept, a leading byte
// order mark included, as `simplifile.read` doesn't on JavaScript.
fn read_text(location: String) -> Result(String, simplifile.FileError) {
  use bytes <- result.try(simplifile.read_bits(location))
  line_index.decode(bytes) |> result.replace_error(simplifile.NotUtf8)
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
        read_text(join(location, file))
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
