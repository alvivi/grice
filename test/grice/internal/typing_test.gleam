//// Tests for inferring a project's types with girard. Projects are built
//// in memory. The order girard gets the modules in comes first, then the
//// resolver, then packages whose imports differ by target, and last what
//// the index keeps of girard's results.

import girard
import glance
import gleam/dict
import gleam/list
import gleam/string
import grice/internal/loader.{type Project}
import grice/internal/typing.{type ModuleTypes}
import grice/support

// Order

// `a` imports `b`, which imports `c`, so the lint order is the reverse of
// the order they must be typed in. `b` is excluded, and `c` uses a
// dependency module.
const chain = [
  #("src/a.gleam", "import b\npub fn make() { b.make() }\n"),
  #("src/b.gleam", "import c\npub fn make() { c.make() }\n"),
  #("src/c.gleam", "import dep/thing\npub fn make() { thing.new() }\n"),
]

const chain_toml = "[tools.grice]\nexclude = [\"src/b.gleam\"]\n"

const thing =
  "pub type Thing {\n  Thing(Int)\n}\n\npub fn new() -> Thing {\n  Thing(1)\n}\n"

pub fn order_puts_each_module_after_the_modules_it_imports_test() {
  let project = support.project(chain_toml, chain, [#("dep/thing", thing)])
  assert project.lint_set == ["a", "c"]
  assert order(project) == ["c", "b", "a"]
}

pub fn order_walks_the_lint_set_in_order_and_skips_what_girard_cant_get_test() {
  let files = [
    #("src/one.gleam", "import broken\nimport gleam/list\nimport shared\n"),
    #("src/two.gleam", "import shared\nimport three\n"),
    #("src/three.gleam", "import two\n"),
    #("src/shared.gleam", ""),
    #("src/broken.gleam", "pub fn ("),
  ]
  let project = support.project("", files, [])
  // The lint set is sorted by path. `broken` doesn't parse and
  // `gleam/list` isn't a project module. `three` is entered before `two`,
  // so the import of `three` from `two` closes a cycle, which the compiler
  // would reject, and is skipped.
  assert order(project) == ["shared", "one", "two", "three"]
}

pub fn infer_types_project_modules_without_the_resolver_test() {
  let project = support.project(chain_toml, chain, [#("dep/thing", thing)])
  let types =
    typing.infer(project, dependencies_only(project), project.lint_set)
  assert dict.keys(types) |> list.sort(string.compare) == ["a", "c"]
  let thing_type = girard.Named("dep/thing", "Thing", [])
  let assert Ok(a) = dict.get(types, "a")
  let assert Ok(c) = dict.get(types, "c")
  assert scheme_of(a, "make") == girard.Fn([], thing_type)
  assert scheme_of(c, "make") == girard.Fn([], thing_type)
  assert a.complete && c.complete
}

// Resolver

pub fn resolver_answers_for_dependency_modules_only_test() {
  let files = [
    #("src/app.gleam", "import broken\nimport clash\n"),
    #("src/broken.gleam", "pub fn ("),
    #("src/clash.gleam", "pub fn f() { 1 }\n"),
  ]
  let dependencies = [
    #("dep/thing", thing),
    #("clash", "pub fn g() { 2 }\n"),
  ]
  let resolver = typing.resolver(support.project("", files, dependencies))
  assert resolver("dep/thing") == Ok(thing)
  assert resolver("app") == Error(Nil)
  assert resolver("broken") == Error(Nil)
  assert resolver("clash") == Error(Nil)
  assert resolver("nowhere") == Error(Nil)
}

// Targets

pub fn imports_that_cross_on_different_targets_type_on_erlang_test() {
  let project = support.project("", support.crossed, [])
  assert order(project) == ["b", "a"]
  let types =
    typing.infer(project, dependencies_only(project), project.lint_set)
  let assert Ok(a) = dict.get(types, "a")
  let assert Ok(b) = dict.get(types, "b")
  assert scheme_of(a, "from_other") == girard.Fn([], girard.Named("b", "B", []))
  assert dropped(b) == ["from_other"]
  assert dropped(a) == []
  assert a.complete && b.complete
}

pub fn imports_that_cross_on_different_targets_type_on_javascript_test() {
  let project =
    support.project("target = \"javascript\"\n", support.crossed, [])
  assert order(project) == ["a", "b"]
  let types =
    typing.infer(project, dependencies_only(project), project.lint_set)
  let assert Ok(a) = dict.get(types, "a")
  let assert Ok(b) = dict.get(types, "b")
  assert scheme_of(b, "from_other") == girard.Fn([], girard.Named("a", "A", []))
  assert dropped(a) == ["from_other"]
  assert dropped(b) == []
  assert a.complete && b.complete
}

// The deprecated `erl` and `js` target names, on an import and on a
// function.
const shorthands = [
  #(
    "src/app.gleam",
    "@target(erl)\nimport erl_only\n@target(js)\nimport js_only\n@target(erl)\npub fn value() { erl_only.value() }\n@target(js)\npub fn value() { js_only.value() }\n",
  ),
  #("src/erl_only.gleam", "pub fn value() { 1 }\n"),
  #("src/js_only.gleam", "pub fn value() { \"one\" }\n"),
]

pub fn target_shorthands_type_on_erlang_test() {
  let app = app_types("", shorthands)
  assert scheme_of(app, "value")
    == girard.Fn([], girard.Named("gleam", "Int", []))
  assert dropped(app) == ["value"]
  assert app.complete
}

pub fn target_shorthands_type_on_javascript_test() {
  let app = app_types("target = \"javascript\"\n", shorthands)
  assert scheme_of(app, "value")
    == girard.Fn([], girard.Named("gleam", "String", []))
  assert dropped(app) == ["value"]
  assert app.complete
}

// The index

// girard records each expression once. The index still keeps the first
// annotation at a span, which the next test pins.
pub fn a_call_girard_records_once_answers_its_type_test() {
  let source = "fn f(x: Int) -> Int { x }\npub fn g() { f(1) }\n"
  let call = support.glance_span(source, "f(1)")
  let assert Ok(syntax) = glance.module(source)
  let assert Ok(girard.ModuleResult(annotated:, ..)) =
    girard.annotate_package([#("app", syntax)], girard.default_options())
    |> dict.get("app")
  let recorded =
    list.filter(annotated.expressions, fn(annotation) {
      annotation.span == call
    })
  assert list.length(recorded) == 1
  let app = app_types("", [#("src/app.gleam", source)])
  assert dict.get(app.expressions, call) == Ok(girard.Named("gleam", "Int", []))
}

pub fn the_first_annotation_at_a_span_is_kept_test() {
  let span = glance.Span(0, 1)
  let first = girard.Named("gleam", "Int", [])
  let found =
    girard.ModuleResult(
      annotated: girard.AnnotatedModule(
        functions: [],
        constants: [],
        expressions: [
          girard.Annotation(span, first),
          girard.Annotation(span, girard.Named("gleam", "String", [])),
        ],
        resolutions: [],
        dropped: [],
        unavailable: [],
      ),
      skipped: [],
    )
  let assert Ok(view) = glance.module("")
  assert dict.get(typing.index(found, view).expressions, span) == Ok(first)
}

pub fn skipped_definitions_are_located_in_source_order_test() {
  let first = "pub fn first() {\n  gone.value()\n}"
  let second = "pub const second = gone.constant"
  let source = "import gone\n" <> first <> "\n" <> second <> "\n"
  let app = app_types("", [#("src/app.gleam", source)])
  assert list.map(app.skipped, fn(skipped) { #(skipped.name, skipped.span) })
    == [
      #("first", support.glance_span(source, first)),
      #("second", support.glance_span(source, second)),
    ]
  assert list.map(app.unavailable, fn(unavailable) { unavailable.module })
    == ["gone"]
  assert !app.complete
}

// Helpers

// The names of the modules in the order girard gets them.
fn order(project: Project) -> List(String) {
  list.map(typing.order(project, project.lint_set), fn(entry) { entry.0 })
}

// The project's resolver, failing the test when it's asked for a project
// module: those are all typed before the modules that import them.
fn dependencies_only(project: Project) -> girard.Resolver {
  let resolver = typing.resolver(project)
  fn(name) {
    case dict.has_key(project.modules, name) {
      True -> panic as { "the resolver was asked for " <> name }
      False -> resolver(name)
    }
  }
}

// The types of the module `app` in a project of `files`.
fn app_types(toml: String, files: List(#(String, String))) -> ModuleTypes {
  let project = support.project(toml, files, [])
  let assert Ok(app) =
    typing.infer(project, dependencies_only(project), project.lint_set)
    |> dict.get("app")
  app
}

fn scheme_of(types: ModuleTypes, name: String) -> girard.Type {
  let assert Ok(girard.Scheme(type_:, ..)) = dict.get(types.schemes, name)
  type_
}

fn dropped(types: ModuleTypes) -> List(String) {
  list.map(types.dropped, fn(dropped) { dropped.name })
}
