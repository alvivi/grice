//// Tests for `grice_rules/internal-type-in-public-api`, over its samples
//// and small projects, each linted for both targets unless what it reads
//// depends on the target. The rule reads only `src/`, so the samples are
//// linted at their module names' paths under `src/`, as modules of a
//// package named `grice`, whose default patterns make `hidden` internal.
//// Each project that the rule must leave alone has a reporting control
//// beside it, so a test can't pass because the rule reads nothing.

import birdie
import gleam/list
import grice/rules
import grice/support
import grice/testing

const code = "grice_rules/internal-type-in-public-api"

// Samples

pub fn internal_type_in_public_api_flagged_samples_test() {
  let run = samples("internal_type_in_public_api_flagged")
  testing.expect_codes(run, list.repeat(code, 19))
  testing.render(run)
  |> birdie.snap(title: "built-in internal-type-in-public-api: flagged samples")
}

pub fn internal_type_in_public_api_clean_samples_test() {
  samples("internal_type_in_public_api_clean")
  |> testing.expect_none
}

// Run the rule over the sample `name` and the internal module it imports,
// each at its module name's path under `src/`, in a package named `grice`.
fn samples(name: String) -> testing.Run {
  lint("name = \"grice\"\n", [
    #(
      "src/grice/internal/rules/samples/hidden.gleam",
      support.internal_sample("hidden"),
    ),
    #("src/grice/rules/samples/" <> name <> ".gleam", support.sample(name)),
  ])
}

// Run the rule over the project of `files` with the `gleam.toml` text
// `toml`, on both targets.
fn lint(toml: String, files: List(#(String, String))) -> testing.Run {
  support.project_on_both_targets(toml, files, [
    rules.internal_type_in_public_api(),
  ])
}

// Internal modules

// An internal module of `app`, by the default patterns, with a type of each
// kind the tests name.
const thing = #(
  "src/app/internal/thing.gleam",
  "pub type Thing {
  Thing
}

pub type Box(a) {
  Box(a)
}

pub fn new() -> Thing {
  Thing
}
",
)

// A module of `app` that names `thing.Thing` in a public signature, and
// what the rule reports on it.
const make_thing =
  "import app/internal/thing

pub fn make() -> thing.Thing {
  thing.new()
}
"

const thing_finding =
  code
  <> " src/app.gleam: `Thing` is defined in the internal module `app/internal/thing`"

// lustre's own patterns replace the default ones, so its `lustre/internal`
// isn't internal, and `lustre/vdom/vnode` is.
pub fn internal_type_in_public_api_reads_custom_internal_modules_test() {
  let run =
    lint(
      "name = \"lustre\"
internal_modules = [\"lustre/vdom/*\", \"lustre/runtime/*\"]
",
      [
        #(
          "src/lustre/element.gleam",
          "import lustre/internal/escape
import lustre/vdom/vnode

pub fn element(node: vnode.Element(msg)) -> vnode.Element(msg) {
  node
}

pub fn escaped(text: escape.Escaped) -> escape.Escaped {
  text
}
",
        ),
        #(
          "src/lustre/vdom/vnode.gleam",
          "pub type Element(msg) {\n  Text(String)\n}\n",
        ),
        #(
          "src/lustre/internal/escape.gleam",
          "pub type Escaped {\n  Escaped(String)\n}\n",
        ),
      ],
    )
  assert support.describe(testing.diagnostics(run))
    == [
      code
        <> " src/lustre/element.gleam: `Element` is defined in the internal module `lustre/vdom/vnode`",
      code
        <> " src/lustre/element.gleam: `Element` is defined in the internal module `lustre/vdom/vnode`",
    ]
}

// An internal module's public functions name its own types freely: it
// isn't part of the public API.
pub fn internal_type_in_public_api_skips_internal_modules_test() {
  let run =
    lint("name = \"app\"\n", [
      #("src/app.gleam", make_thing),
      thing,
    ])
  assert support.describe(testing.diagnostics(run)) == [thing_finding]
}

// A pattern that matches a dependency's module name as well as the
// project's: grice doesn't read a dependency's `gleam.toml`, so only the
// project's type counts.
pub fn internal_type_in_public_api_skips_dependency_types_test() {
  let run =
    testing.project([
      #("gleam.toml", "name = \"app\"\ninternal_modules = [\"*/internal/*\"]\n"),
      #(
        "src/app.gleam",
        "import app/internal/thing
import dep/internal/other

pub fn both(mine: thing.Thing, theirs: other.Other) -> Nil {
  let _ = #(mine, theirs)
  Nil
}
",
      ),
      thing,
    ])
    |> testing.with_dependency(
      module: "dep/internal/other",
      source: "pub type Other {\n  Other\n}\n",
    )
    |> testing.run([rules.internal_type_in_public_api()])
  assert support.describe(testing.diagnostics(run)) == [thing_finding]
}

// An excluded module is still loaded when a linted one imports it, so its
// internal types count.
pub fn internal_type_in_public_api_sees_excluded_internal_modules_test() {
  lint("name = \"app\"\n[tools.grice]\nexclude = [\"src/app/internal/\"]\n", [
    #("src/app.gleam", make_thing),
    thing,
  ])
  |> testing.expect_codes([code])
}

// With no `name`, the default patterns don't apply, so `app/internal/thing`
// isn't internal. With one, it is.
pub fn internal_type_in_public_api_needs_a_name_for_the_defaults_test() {
  let files = [
    #("src/app.gleam", make_thing),
    thing,
  ]
  lint("", files)
  |> testing.expect_none
  lint("name = \"app\"\n", files)
  |> testing.expect_codes([code])
}

// Paths

// `include` selects all three directories, and only `src/` reports: tests
// and development tools aren't published.
pub fn internal_type_in_public_api_reads_only_src_test() {
  let run =
    lint(
      "name = \"app\"\n[tools.grice]\ninclude = [\"src/\", \"test/\", \"dev/\"]\n",
      [
        #("src/app.gleam", make_thing),
        #("test/app_test.gleam", make_thing),
        #("dev/tool.gleam", make_thing),
        thing,
      ],
    )
  assert support.describe(testing.diagnostics(run)) == [thing_finding]
}

// Targets

// A declaration or an import for the other target isn't there, so each
// target reports its own declarations and the shared one.
pub fn internal_type_in_public_api_reads_the_target_view_test() {
  let files = [
    #(
      "src/app.gleam",
      "import app/internal/thing
@target(erlang)
import app/internal/beam

@target(erlang)
pub fn on_erlang(handle: beam.Handle) -> Nil {
  let _ = handle
  Nil
}

@target(javascript)
pub fn on_javascript(box: thing.Box(Int)) -> Nil {
  let _ = box
  Nil
}

pub fn everywhere() -> thing.Thing {
  thing.new()
}
",
    ),
    #("src/app/internal/beam.gleam", "pub type Handle {\n  Handle\n}\n"),
    thing,
  ]
  let findings = fn(target) {
    support.project_on_target(target, "name = \"app\"\n", files, [
      rules.internal_type_in_public_api(),
    ])
    |> testing.diagnostics
    |> support.describe
  }
  assert findings("erlang")
    == [
      code
        <> " src/app.gleam: `Handle` is defined in the internal module `app/internal/beam`",
      thing_finding,
    ]
  assert findings("javascript")
    == [
      code
        <> " src/app.gleam: `Box` is defined in the internal module `app/internal/thing`",
      thing_finding,
    ]
}

// One shared function names `selected.Handle`, and `selected` is an
// internal module on Erlang and a public one on JavaScript: the resolver
// reads only the imports compiled for the target.
pub fn internal_type_in_public_api_resolves_imports_for_the_target_test() {
  let files = [
    #(
      "src/app.gleam",
      "@target(erlang)
import app/internal/beam as selected
@target(javascript)
import app/public/script as selected

pub fn shared(handle: selected.Handle) -> selected.Handle {
  handle
}
",
    ),
    #("src/app/internal/beam.gleam", "pub type Handle {\n  Handle\n}\n"),
    #("src/app/public/script.gleam", "pub type Handle {\n  Handle\n}\n"),
  ]
  let findings = fn(target) {
    support.project_on_target(target, "name = \"app\"\n", files, [
      rules.internal_type_in_public_api(),
    ])
    |> testing.diagnostics
    |> support.describe
  }
  let handle =
    code
    <> " src/app.gleam: `Handle` is defined in the internal module `app/internal/beam`"
  assert findings("erlang") == [handle, handle]
  assert findings("javascript") == []
}

// Names

// A qualifier is an import's alias, or the last segment of its path. A
// discarded alias gives none: `thing.Thing` is the public module's, though
// the internal `thing`, imported with `as _thing`, comes after it. An
// unqualified import with `as` names the type it imports.
pub fn internal_type_in_public_api_resolves_import_aliases_test() {
  let run =
    lint("name = \"app\"\n", [
      #(
        "src/app.gleam",
        "import app/internal/other as stuff
import app/public/thing
import app/internal/thing.{type Box as Renamed} as _thing

pub fn aliased(value: stuff.Other) -> Nil {
  let _ = value
  Nil
}

pub fn last_segment(value: thing.Thing) -> Nil {
  let _ = value
  Nil
}

pub fn renamed(value: Renamed(Int)) -> Nil {
  let _ = value
  Nil
}
",
      ),
      #("src/app/public/thing.gleam", "pub type Thing {\n  Thing\n}\n"),
      #("src/app/internal/other.gleam", "pub type Other {\n  Other\n}\n"),
      thing,
    ])
  assert support.describe(testing.diagnostics(run))
    == [
      code
        <> " src/app.gleam: `Other` is defined in the internal module `app/internal/other`",
      code
        <> " src/app.gleam: `Box` is defined in the internal module `app/internal/thing`",
    ]
}

// Aliases

// An alias of another module that isn't public API counts as what it
// names: one marked `@internal` that names an internal type is internal,
// and one that names only `Int` isn't.
pub fn internal_type_in_public_api_reads_aliases_of_other_modules_test() {
  let run =
    lint("name = \"app\"\n", [
      #(
        "src/app.gleam",
        "import app/types

pub fn leak(value: types.Leak) -> Nil {
  let _ = value
  Nil
}

pub fn plain(value: types.Plain) -> Nil {
  let _ = value
  Nil
}
",
      ),
      #(
        "src/app/types.gleam",
        "import app/internal/thing

@internal
pub type Leak =
  thing.Thing

@internal
pub type Plain =
  Int
",
      ),
      thing,
    ])
  assert support.describe(testing.diagnostics(run))
    == [code <> " src/app.gleam: `Leak` is marked `@internal`"]
}

// A public alias is a name users can import, so a private alias of one
// isn't internal, whatever it stands for. A public alias's written
// arguments still count, and so does anything else in a private alias.
pub fn internal_type_in_public_api_stops_at_public_aliases_test() {
  let run =
    lint("name = \"app\"\n", [
      #(
        "src/app.gleam",
        "import app/a
import app/internal/thing

type Nested =
  a.BoxAlias(thing.Thing)

type Composite =
  #(Int, fn(thing.Box(Int)) -> Nil)

type ThroughPublic =
  a.Alias

pub fn nested(value: Nested) -> Nil {
  let _ = value
  Nil
}

pub fn composite(value: Composite) -> Nil {
  let _ = value
  Nil
}

pub fn through_public(value: ThroughPublic) -> Nil {
  let _ = value
  Nil
}
",
      ),
      #(
        "src/app/a.gleam",
        "import app/internal/thing

pub type Alias =
  thing.Thing

pub type BoxAlias(a) =
  thing.Box(a)
",
      ),
      thing,
    ])
  assert support.describe(testing.diagnostics(run))
    == [
      code
        <> " src/app.gleam: `Nested` is a private alias that names an internal type",
      code
        <> " src/app.gleam: `Composite` is a private alias that names an internal type",
    ]
}
