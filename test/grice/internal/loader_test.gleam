//// Tests for loading a project. Discovery, the load set, parse errors and
//// the manifest are tested in memory, through `load` with a dictionary as
//// the file system. The IO tests then write small projects to disk and load
//// them with `load_project`: the main project, then the directory walk with
//// its links and odd source directories. The manifests Gleam wrote, used by
//// the dependency tests, are at the end.

import glance
import gleam/dict
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import glexer
import glexer/token
import grice/diagnostic.{type Diagnostic, Diagnostic}
import grice/internal/config
import grice/internal/line_index
import grice/internal/loader.{
  type LoadError, type Project, CannotRead, Git, Hex, InvalidConfig,
  InvalidManifest, Local, Module, Package,
}
import grice/internal/render/human
import grice/support
import simplifile

// Discovery

pub fn load_finds_the_modules_of_each_source_directory_test() {
  let modules = [
    "src/app.gleam", "src/app/router.gleam", "src/app/web/router_2.gleam",
    "test/app_test.gleam", "test/app/router_test.gleam", "dev/app/dev.gleam",
  ]
  let not_modules = [
    "src/App.gleam", "src/my-mod.gleam", "src/a.b/c.gleam", "src/1app.gleam",
    "src/_app.gleam", "src/.gleam", "src/app.erl", "src/app.gleam.bak",
    "src//app.gleam", "lib/app.gleam", "app.gleam",
  ]
  let files =
    list.map(list.append(modules, not_modules), fn(path) { #(path, "") })
  let assert Ok(project) =
    load_files("[tools.grice]\ninclude = [\"**\"]\n", files)
  assert project.lint_set
    == [
      "app/dev", "app", "app/router", "app/web/router_2", "app/router_test",
      "app_test",
    ]
}

pub fn load_lint_set_honours_include_and_exclude_sorted_by_path_test() {
  let toml =
    "[tools.grice]\ninclude = [\"src/\", \"test/\"]\nexclude = [\"src/gen\"]\n"
  let assert Ok(project) =
    load_files(toml, [
      #("test/alpha_test.gleam", ""),
      #("src/zeta.gleam", ""),
      #("src/gen/schema.gleam", ""),
      #("src/app/router.gleam", ""),
      #("dev/tool.gleam", ""),
    ])
  assert project.lint_set == ["app/router", "zeta", "alpha_test"]
}

pub fn load_rejects_an_empty_lint_set_test() {
  assert titles(load_files("[tools.grice]\ninclude = []\n", app))
    == ["Nothing to lint"]
  assert titles(load_files("[tools.grice]\nexclude = [\"**\"]\n", app))
    == ["Nothing to lint"]
}

pub fn load_rejects_an_include_that_matches_nothing_test() {
  let assert Error(InvalidConfig([diagnostic])) =
    load_files("[tools.grice]\ninclude = [\"tset/\"]\n", app)
  assert diagnostic
    == Diagnostic(
      code: "grice/invalid-config",
      severity: diagnostic.Error,
      title: "An `include` matches no module",
      location: None,
      message: [
        "`tools.grice.include` in `gleam.toml` holds `tset/`, which matches no module under `src/`, `test/` or `dev/`. An `include` says what to lint, so one that selects nothing is most likely a typo or a stale path.",
      ],
      hint: option.Some("Fix the pattern, or remove it."),
    )
}

pub fn load_rejects_an_include_that_matches_nothing_beside_one_that_does_test() {
  assert titles(load_files(
      "[tools.grice]\ninclude = [\"src/\", \"tset/\", \"dve/\"]\n",
      app,
    ))
    == ["An `include` matches no module", "An `include` matches no module"]
}

pub fn load_rejects_a_project_with_no_modules_test() {
  assert titles(load_files("", [#("README.md", "")]))
    == ["An `include` matches no module"]
}

const app = [#("src/app.gleam", "pub fn f() {\n  1\n}\n")]

// Load set

pub fn load_follows_imports_into_excluded_modules_test() {
  let toml = "[tools.grice]\nexclude = [\"src/app/gen/\"]\n"
  let assert Ok(project) =
    load_files(toml, [
      #("src/app.gleam", "import app/gen/a\nimport gleam/list\n"),
      #("src/app/gen/a.gleam", "import app/gen/b\n"),
      #("src/app/gen/b.gleam", ""),
    ])
  assert project.lint_set == ["app"]
  assert loaded(project) == ["app", "app/gen/a", "app/gen/b"]
  assert imports(project, "app") == ["app/gen/a", "gleam/list"]
  assert project.diagnostics == []
}

pub fn load_follows_imports_for_the_target_only_test() {
  let files = [
    #(
      "src/app.gleam",
      "@target(erlang)\nimport app/erlang\n@target(javascript)\nimport app/javascript\n@target(erl)\nimport app/erl\n@target(js)\nimport app/js\nimport app/both\n",
    ),
    #("src/app/erlang.gleam", ""),
    #("src/app/javascript.gleam", ""),
    #("src/app/erl.gleam", ""),
    #("src/app/js.gleam", ""),
    #("src/app/both.gleam", ""),
  ]
  let include = "[tools.grice]\ninclude = [\"src/app.gleam\"]\n"
  let assert Ok(erlang) = load_files(include, files)
  assert loaded(erlang) == ["app", "app/both", "app/erl", "app/erlang"]
  assert imports(erlang, "app") == ["app/erlang", "app/erl", "app/both"]
  let assert Ok(javascript) =
    load_files("target = \"javascript\"\n" <> include, files)
  assert loaded(javascript) == ["app", "app/both", "app/javascript", "app/js"]
  assert imports(javascript, "app") == ["app/javascript", "app/js", "app/both"]
}

pub fn load_follows_cross_target_imports_on_both_targets_test() {
  // `a` imports `b` on Erlang, and `b` imports `a` on JavaScript.
  let files = [
    #("src/a.gleam", "@target(erlang)\nimport b\n"),
    #("src/b.gleam", "@target(javascript)\nimport a\n"),
  ]
  let include = "[tools.grice]\ninclude = [\"src/a.gleam\"]\n"
  let assert Ok(erlang) = load_files(include, files)
  assert loaded(erlang) == ["a", "b"]
  assert imports(erlang, "b") == []
  let assert Ok(javascript) =
    load_files("target = \"javascript\"\n" <> include, files)
  assert loaded(javascript) == ["a"]
}

pub fn load_terminates_on_an_import_cycle_test() {
  let assert Ok(project) =
    load_files("", [
      #("src/a.gleam", "import b\n"),
      #("src/b.gleam", "import a\n"),
    ])
  assert loaded(project) == ["a", "b"]
}

pub fn load_never_reads_an_excluded_module_nothing_imports_test() {
  // `unread` isn't in the file system: reading it would fail.
  let toml = "[tools.grice]\nexclude = [\"src/app/unread.gleam\"]\n"
  let assert Ok(project) =
    load_files_with_unreadable(toml, app, ["src/app/unread.gleam"])
  assert loaded(project) == ["app"]
}

pub fn load_fails_on_an_imported_module_it_cant_read_test() {
  let toml = "[tools.grice]\nexclude = [\"src/app/unread.gleam\"]\n"
  assert load_files_with_unreadable(
      toml,
      [#("src/app.gleam", "import app/unread\n")],
      ["src/app/unread.gleam"],
    )
    == Error(CannotRead("src/app/unread.gleam", "No such file"))
}

// Parse errors

pub fn load_reports_a_lint_set_module_that_doesnt_parse_test() {
  let assert Ok(project) =
    load_files("", [#("src/app.gleam", "pub fn main() {\n  1 +\n}\n")])
  assert render(project) == "error[grice/parse-error]: Can't parse this module
  ┌─ src/app.gleam:3:1
  │
3 │ }
  │ ^ glance didn't expect this

grice reads Gleam code with glance, and glance couldn't parse this file. No
rule ran on it, and the modules that import it may lose type information.

Hint: If `gleam build` accepts this file, glance doesn't support its syntax
yet, so please report it to glance.

"
}

pub fn load_reports_an_unexpected_end_of_input_at_the_end_test() {
  let source = "pub fn main() {\n  1\n"
  let assert Ok(project) = load_files("", [#("src/app.gleam", source)])
  let end = string.byte_size(source)
  assert primary(project)
    == diagnostic.Label(
      diagnostic.Span(end, end),
      "The file ends here unexpectedly",
    )
}

pub fn load_points_at_a_multibyte_token_test() {
  let assert Ok(project) =
    load_files("", [#("src/app.gleam", "pub fn main() {\n  é\n}\n")])
  assert primary(project).span == diagnostic.Span(18, 20)
}

pub fn load_keeps_the_parse_error_of_an_excluded_module_test() {
  let toml = "[tools.grice]\nexclude = [\"src/app/broken.gleam\"]\n"
  let assert Ok(project) =
    load_files(toml, [
      #("src/app.gleam", "import app/broken\n"),
      #("src/app/broken.gleam", "pub fn main() {\n"),
    ])
  assert project.diagnostics == []
  let assert Ok(broken) = dict.get(project.modules, "app/broken")
  assert broken.parsed == Error(glance.UnexpectedEndOfInput)
  assert broken.imports == []
}

pub fn parse_error_falls_back_to_an_empty_span_test() {
  // A token whose text isn't at its position, and a position past the end
  // of the source: neither gives a span the renderer would reject.
  let source = line_index.new("pub fn main() {}\n")
  let module = fn(position) {
    Module(
      name: "app",
      path: "src/app.gleam",
      source:,
      parsed: Error(glance.UnexpectedToken(
        token.Name("wibble"),
        glexer.Position(position),
      )),
      imports: [],
    )
  }
  assert primary_span(module(4)) == diagnostic.Span(4, 4)
  assert primary_span(module(99)) == diagnostic.Span(17, 17)
}

// The primary label of the project's one diagnostic.
fn primary(project: Project) -> diagnostic.Label {
  let assert [Diagnostic(location: option.Some(location), ..)] =
    project.diagnostics
  location.primary
}

fn primary_span(module: loader.Module) -> diagnostic.Span {
  let assert Ok(Diagnostic(location: option.Some(location), ..)) =
    loader.parse_error(module)
  location.primary.span
}

// Every diagnostic of the project, rendered without colour.
fn render(project: Project) -> String {
  let assert Ok(text) =
    human.render(
      project.diagnostics,
      loader.sources(project),
      human.Options(colour: False, directory: ""),
    )
  text
}

// Dependencies

pub fn packages_of_a_manifest_with_native_packages_test() {
  // Only gleam_stdlib is built by Gleam. The others are rebar3 and mix
  // packages, and jason requires decimal, which isn't listed.
  assert loader.packages(hex_native_manifest)
    == Ok([Package("gleam_stdlib", Hex, "build/packages/gleam_stdlib")])
}

pub fn packages_of_a_manifest_with_a_git_member_test() {
  // gmember is a subdirectory of gdep's repository, copied into
  // build/packages like any git package.
  assert loader.packages(git_member_manifest)
    == Ok([
      Package("gdep", Git, "build/packages/gdep"),
      Package("gmember", Git, "build/packages/gmember"),
    ])
}

pub fn packages_of_a_manifest_with_transitive_local_paths_test() {
  assert loader.packages(transitive_path_manifest)
    == Ok([Package("a", Local, "../a"), Package("b", Local, "../b")])
}

pub fn packages_keeps_an_absolute_local_path_test() {
  let manifest =
    "packages = [\n  { name = \"x\", version = \"1.0.0\", build_tools = [\"gleam\"], requirements = [], source = \"local\", path = \"/opt/x\" },\n]\n"
  assert loader.packages(manifest) == Ok([Package("x", Local, "/opt/x")])
}

pub fn packages_rejects_a_malformed_manifest_test() {
  let package = fn(fields) { "packages = [\n  { " <> fields <> " },\n]\n" }
  let cases = [
    #("[requirements]\n", "`manifest.toml` has no `packages` list"),
    #("packages = 1\n", "`packages` in `manifest.toml` isn't a list"),
    #(
      package("source = \"hex\", build_tools = [\"gleam\"]"),
      "Package 1 in `manifest.toml` has no `name`",
    ),
    #(
      package("name = \"x\", build_tools = [\"gleam\"]"),
      "The package `x` in `manifest.toml` has no `source`",
    ),
    #(
      package("name = \"x\", source = \"hex\""),
      "The package `x` in `manifest.toml` has no `build_tools`",
    ),
    #(
      package("name = \"x\", source = \"hex\", build_tools = \"gleam\""),
      "The package `x` in `manifest.toml` has a `build_tools` that isn't a list of strings",
    ),
    #(
      package("name = 1, source = \"hex\", build_tools = [\"gleam\"]"),
      "Package 1 in `manifest.toml` has a `name` that isn't a string",
    ),
    #(
      package("name = \"x\", source = \"local\", build_tools = [\"gleam\"]"),
      "The package `x` in `manifest.toml` has no `path`",
    ),
    #(
      package("name = \"x\", source = \"svn\", build_tools = [\"gleam\"]"),
      "The package `x` in `manifest.toml` has the unknown source `svn`",
    ),
  ]
  assert list.map(cases, fn(row) { loader.packages(row.0) })
    == list.map(cases, fn(row) { Error(InvalidManifest(row.1)) })
}

// The main project
//
// `app` lints `src/` but excludes its generated code, and depends on a local
// package beside it, on a local package that's gone, on a hex package whose
// `build/packages` was never downloaded, on one whose `src/` is gone, and on
// one whose `src/` is empty.

pub fn load_project_loads_the_main_project_test() {
  let directory = support.fixture_directory("load_project")
  support.write_fixture(directory, [
    #(
      "app/gleam.toml",
      "name = \"app\"\n\n[tools.grice]\nexclude = [\"src/app/generated/\"]\n",
    ),
    #("app/manifest.toml", app_manifest),
    #(
      "app/src/app.gleam",
      "import app/generated/schema\nimport localdep\n\npub fn main() -> Int {\n  schema.version() + localdep.answer()\n}\n",
    ),
    #(
      "app/src/app/generated/schema.gleam",
      "pub fn version() -> Int {\n  1\n}\n",
    ),
    #("localdep/gleam.toml", "name = \"localdep\"\n"),
    #("localdep/src/localdep.gleam", localdep_source),
    #("app/build/packages/halfdep/gleam.toml", "name = \"halfdep\"\n"),
  ])
  let assert Ok(Nil) =
    simplifile.create_directory_all(
      directory <> "/app/build/packages/emptydep/src",
    )
  // Excluded and imported by nothing, so it's never read.
  support.write_not_utf8(directory <> "/app/src/app/generated/blob.gleam")
  let assert Ok(root) = simplifile.resolve(directory <> "/app")
  let assert Ok(project) = loader.load_project(root)
  assert project.root == root
  assert project.lint_set == ["app"]
  assert loaded(project) == ["app", "app/generated/schema"]
  let assert Ok(module) = dict.get(project.modules, "app")
  assert module.path == "src/app.gleam"
  assert module.imports == ["app/generated/schema", "localdep"]
  assert project.dependencies
    == dict.from_list([#("localdep", localdep_source)])
  assert project.missing_dependencies
    == [
      Package("gleam_stdlib", Hex, "build/packages/gleam_stdlib"),
      Package("gonedep", Local, "../gone"),
      Package("halfdep", Hex, "build/packages/halfdep"),
    ]
  assert project.diagnostics == []
  support.cleanup(directory)
}

pub fn load_project_reads_an_absolute_local_dependency_test() {
  // The root is relative, so joining it to the manifest's absolute `path`
  // would find nothing.
  let directory = support.fixture_directory("absolute_dependency")
  support.write_fixture(directory, [
    #("app/gleam.toml", "name = \"app\"\n"),
    #("app/src/app.gleam", module_source),
    #("absdep/src/absdep.gleam", localdep_source),
  ])
  let assert Ok(path) = simplifile.resolve(directory <> "/absdep")
  let assert Ok(Nil) =
    simplifile.write(
      directory <> "/app/manifest.toml",
      "packages = [\n  { name = \"absdep\", version = \"1.0.0\", build_tools = [\"gleam\"], requirements = [], source = \"local\", path = \""
        <> path
        <> "\" },\n]\n",
    )
  let assert Ok(project) = loader.load_project(directory <> "/app")
  assert project.dependencies == dict.from_list([#("absdep", localdep_source)])
  assert project.missing_dependencies == []
  support.cleanup(directory)
}

pub fn load_project_reads_a_drive_like_local_path_under_the_root_test() {
  // On Unix, `C:/dep` is the directory `dep` inside one named `C:`, under the
  // project root.
  let directory = support.fixture_directory("drive_like_dependency")
  support.write_fixture(directory, [
    #("gleam.toml", "name = \"app\"\n"),
    #(
      "manifest.toml",
      "packages = [\n  { name = \"dep\", version = \"1.0.0\", build_tools = [\"gleam\"], requirements = [], source = \"local\", path = \"C:/dep\" },\n]\n",
    ),
    #("src/app.gleam", module_source),
    #("C:/dep/src/dep.gleam", localdep_source),
  ])
  let assert Ok(project) = loader.load_project(directory)
  assert project.dependencies == dict.from_list([#("dep", localdep_source)])
  assert project.missing_dependencies == []
  support.cleanup(directory)
}

pub fn load_project_needs_a_manifest_test() {
  let directory = support.fixture_directory("no_manifest")
  support.write_fixture(directory, [
    #("gleam.toml", "name = \"app\"\n"),
    #("src/app.gleam", ""),
  ])
  assert loader.load_project(directory)
    == Error(CannotRead("manifest.toml", "No such file or directory"))
  support.cleanup(directory)
}

const app_manifest =
  "packages = [
  { name = \"gleam_stdlib\", version = \"1.0.5\", build_tools = [\"gleam\"], requirements = [], otp_app = \"gleam_stdlib\", source = \"hex\", outer_checksum = \"CEE5B6C076A85B45F60C585F4316C63EC8B7127C119D5738C3958A9C4D50404E\" },
  { name = \"emptydep\", version = \"1.0.0\", build_tools = [\"gleam\"], requirements = [], source = \"hex\", outer_checksum = \"0\" },
  { name = \"gonedep\", version = \"1.0.0\", build_tools = [\"gleam\"], requirements = [], source = \"local\", path = \"../gone\" },
  { name = \"halfdep\", version = \"1.0.0\", build_tools = [\"gleam\"], requirements = [], source = \"hex\", outer_checksum = \"0\" },
  { name = \"localdep\", version = \"1.0.0\", build_tools = [\"gleam\"], requirements = [], source = \"local\", path = \"../localdep\" },
]
"

const localdep_source = "pub fn answer() -> Int {\n  42\n}\n"

// The directory walk
//
// Links are followed, each directory is entered at most once per walk, and
// the source directories are walked separately.

pub fn load_project_follows_links_and_enters_each_directory_once_test() {
  let directory = support.fixture_directory("walk_links")
  support.write_linked_fixture(
    directory,
    [
      #("src/a/one.gleam", module_source),
      #("src/a/two.gleam", module_source),
      #("elsewhere/shared/lib.gleam", module_source),
      #("elsewhere/both/b.gleam", module_source),
      ..minimal
    ],
    [
      // Back to `src/`, which this walk has already entered.
      #("src/a/back", ".."),
      // Outside every source directory.
      #("src/shared", "../elsewhere/shared"),
      // Two links to one directory.
      #("src/x", "../elsewhere/both"),
      #("src/y", "../elsewhere/both"),
    ],
  )
  // The directory behind `x` and `y` is walked through whichever of the two
  // the file system lists first, as the compiler does.
  let assert Ok(listed) = simplifile.read_directory(directory <> "/src")
  let assert Ok(first) =
    list.find(listed, fn(entry) { entry == "x" || entry == "y" })
  let assert Ok(project) = loader.load_project(directory)
  assert project.lint_set
    == ["a/one", "a/two", "app", "shared/lib", first <> "/b"]
  support.cleanup(directory)
}

pub fn load_project_enters_a_directory_through_its_shallowest_link_test() {
  // `t` and `u` are each reached through a link one level down and through
  // another two levels down, one of each under `a` and under `z`. A
  // breadth-first walk takes the shallow link to both, in whatever order the
  // file system lists the entries. A depth-first walk would take a deep link
  // under whichever of `a` and `z` it entered first.
  let directory = support.fixture_directory("walk_depth")
  support.write_linked_fixture(
    directory,
    [
      #("elsewhere/t/t.gleam", module_source),
      #("elsewhere/u/u.gleam", module_source),
      ..minimal
    ],
    [
      #("src/a/near", "../../elsewhere/t"),
      #("src/a/far/deep", "../../../elsewhere/u"),
      #("src/z/near", "../../elsewhere/u"),
      #("src/z/far/deep", "../../../elsewhere/t"),
    ],
  )
  let assert Ok(project) = loader.load_project(directory)
  assert project.lint_set == ["a/near/t", "app", "z/near/u"]
  support.cleanup(directory)
}

pub fn load_project_walks_each_source_directory_separately_test() {
  // `src/up` leads to the project root, so the `src/` walk finds `test/`'s
  // module under `up/test/`, and the `test/` walk still finds it as its own.
  let directory = support.fixture_directory("walk_up")
  support.write_linked_fixture(
    directory,
    [
      #(
        "gleam.toml",
        "name = \"app\"\n\n[tools.grice]\ninclude = [\"src/\", \"test/\"]\n",
      ),
      #("manifest.toml", "packages = []\n"),
      #("src/app.gleam", module_source),
      #("test/app_test.gleam", module_source),
    ],
    [#("src/up", "..")],
  )
  let assert Ok(project) = loader.load_project(directory)
  assert project.lint_set == ["app", "up/test/app_test", "app_test"]
  support.cleanup(directory)
}

pub fn load_project_treats_source_directories_that_arent_directories_as_empty_test() {
  let directory = support.fixture_directory("odd_roots")
  support.write_linked_fixture(
    directory,
    [#("dev", "a regular file\n"), ..minimal],
    [#("test", "nowhere")],
  )
  let assert Ok(project) = loader.load_project(directory)
  assert project.lint_set == ["app"]
  support.cleanup(directory)
}

pub fn load_project_fails_on_a_dangling_link_test() {
  let directory = support.fixture_directory("dangling_link")
  support.write_linked_fixture(directory, minimal, [
    #("src/.#app.gleam", "nowhere"),
  ])
  assert loader.load_project(directory)
    == Error(CannotRead("src/.#app.gleam", "No such file or directory"))
  support.cleanup(directory)
}

pub fn load_project_fails_on_a_directory_it_cant_read_test() {
  let directory = support.fixture_directory("locked_directory")
  // A failed earlier run may have left the directory locked.
  let _ = simplifile.set_permissions_octal(directory <> "/src/locked", 0o755)
  support.write_fixture(directory, [
    #("src/locked/hidden.gleam", module_source),
    ..minimal
  ])
  support.with_directory_mode(directory <> "/src/locked", 0o000, fn() {
    assert loader.load_project(directory)
      == Error(CannotRead("src/locked", "Permission denied"))
  })
  support.cleanup(directory)
}

const module_source = "pub fn f() -> Int {\n  1\n}\n"

// The smallest project that loads: one module, no dependencies.
const minimal = [
  #("gleam.toml", "name = \"app\"\n"),
  #("manifest.toml", "packages = []\n"),
  #("src/app.gleam", module_source),
]

// Helpers

// Load the files of a project in memory, with `toml` as its `gleam.toml`.
fn load_files(
  toml: String,
  files: List(#(String, String)),
) -> Result(Project, LoadError) {
  load_files_with_unreadable(toml, files, [])
}

// Load as `load_files` does, with `unreadable` listed as files that can't be
// read.
fn load_files_with_unreadable(
  toml: String,
  files: List(#(String, String)),
  unreadable: List(String),
) -> Result(Project, LoadError) {
  let assert Ok(parsed) = config.parse(toml)
  let sources = dict.from_list(files)
  loader.load(
    root: "app",
    config: parsed,
    paths: list.append(list.map(files, fn(file) { file.0 }), unreadable),
    read: fn(path) {
      dict.get(sources, path) |> result.replace_error("No such file")
    },
    dependencies: dict.new(),
    missing_dependencies: [],
  )
}

// The names of the loaded modules, sorted.
fn loaded(project: Project) -> List(String) {
  project.modules |> dict.keys |> list.sort(string.compare)
}

fn imports(project: Project, name: String) -> List(String) {
  let assert Ok(module) = dict.get(project.modules, name)
  module.imports
}

// The titles of the configuration problems a load failed with.
fn titles(loaded: Result(Project, LoadError)) -> List(String) {
  let assert Error(InvalidConfig(diagnostics)) = loaded
  list.map(diagnostics, fn(found: Diagnostic) { found.title })
}

// Manifests written by Gleam 1.19.0

const hex_native_manifest =
  "# Do not manually edit this file, it is managed by Gleam.
#
# This file locks the dependency versions used, to make your build
# deterministic and to prevent unexpected versions from being included
# in your application.
#
# You should check this file into your source control repository.

packages = [
  { name = \"base64url\", version = \"0.0.1\", build_tools = [\"rebar\"], requirements = [], otp_app = \"base64url\", source = \"hex\", outer_checksum = \"FAB09B20E3F5DB886725544CBCF875B8E73EC93363954EB8A1A9ED834AA8C1F9\" },
  { name = \"gleam_stdlib\", version = \"1.0.5\", build_tools = [\"gleam\"], requirements = [], otp_app = \"gleam_stdlib\", source = \"hex\", outer_checksum = \"CEE5B6C076A85B45F60C585F4316C63EC8B7127C119D5738C3958A9C4D50404E\" },
  { name = \"jason\", version = \"1.4.5\", build_tools = [\"mix\"], requirements = [\"decimal\"], otp_app = \"jason\", source = \"hex\", outer_checksum = \"B0C823996102BCD0239B3C2444EB00409B72F6A140C1950BC8B457D836B30684\" },
  { name = \"ssl_verify_fun\", version = \"1.1.9\", build_tools = [\"mix\", \"rebar3\", \"make\"], requirements = [], otp_app = \"ssl_verify_fun\", source = \"hex\", outer_checksum = \"19F24AD715EF6255D530B2F0DB8B2D2191AE435B6527234E943F523E84ED0895\" },
  { name = \"telemetry\", version = \"1.4.2\", build_tools = [\"rebar3\"], requirements = [], otp_app = \"telemetry\", source = \"hex\", outer_checksum = \"928F6495066506077862C0D1646609EED891A4326BEE3126BA54B60AF61FEBB1\" },
]

[requirements]
base64url = { version = \">= 0.0.1 and < 1.0.0\" }
gleam_stdlib = { version = \">= 0.44.0 and < 2.0.0\" }
jason = { version = \">= 1.4.0 and < 2.0.0\" }
ssl_verify_fun = { version = \">= 1.1.0 and < 2.0.0\" }
telemetry = { version = \">= 1.0.0 and < 2.0.0\" }
"

const git_member_manifest =
  "# Do not manually edit this file, it is managed by Gleam.
#
# This file locks the dependency versions used, to make your build
# deterministic and to prevent unexpected versions from being included
# in your application.
#
# You should check this file into your source control repository.

packages = [
  { name = \"gdep\", version = \"1.0.0\", build_tools = [\"gleam\"], requirements = [\"gmember\"], source = \"git\", repo = \"https://git.example.com/gdep\", commit = \"54d9f8667c1ea2d2422a0c7252f9c1cbd2a9ffeb\" },
  { name = \"gmember\", version = \"1.0.0\", build_tools = [\"gleam\"], requirements = [], source = \"git\", repo = \"https://git.example.com/gdep\", commit = \"54d9f8667c1ea2d2422a0c7252f9c1cbd2a9ffeb\", path = \"sub/gmember\" },
]

[requirements]
gdep = { git = \"https://git.example.com/gdep\", ref = \"main\" }
"

const transitive_path_manifest =
  "# Do not manually edit this file, it is managed by Gleam.
#
# This file locks the dependency versions used, to make your build
# deterministic and to prevent unexpected versions from being included
# in your application.
#
# You should check this file into your source control repository.

packages = [
  { name = \"a\", version = \"1.0.0\", build_tools = [\"gleam\"], requirements = [\"b\"], source = \"local\", path = \"../a\" },
  { name = \"b\", version = \"1.0.0\", build_tools = [\"gleam\"], requirements = [], source = \"local\", path = \"../b\" },
]

[requirements]
a = { path = \"../a\" }
"
