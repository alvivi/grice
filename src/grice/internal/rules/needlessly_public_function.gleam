//// `grice_rules/needlessly-public-function`: a public function that isn't
//// public API, which no other Gleam module of the project refers to.
//// docs/RULES.md describes what it reads. It sees the whole project and
//// reads only the syntax tree, since a name the compiler accepts means one
//// thing; where the reading could be wrong, it counts a use.

import glance
import gleam/bool
import gleam/dict.{type Dict}
import gleam/list
import gleam/option
import gleam/result
import gleam/set
import gleam/string
import glexer
import glexer/token.{type Token}
import grice/facts.{type ModuleFacts, type Syntax}
import grice/internal/loader
import grice/internal/type_names
import grice/rule.{type Report, type Rule}
import grice/visit

const code = "grice_rules/needlessly-public-function"

/// The rule.
pub fn rule() -> Rule {
  rule.project(code, title: "Public function no other Gleam module refers to")
  |> rule.whole_project
  |> rule.per_module(summarise)
  |> rule.final(evaluate)
}

// What one module holds for the rule: its source, its candidates, and the
// functions of other modules it refers to, each as `#(key, name)`.
type Summary {
  Summary(
    source: String,
    candidates: List(Candidate),
    uses: List(#(Key, String)),
  )
}

// What a use names a function's module by.
type Key {
  // Its Erlang name, as the compiler writes it, such as
  // `app@internal@parser`, which names a module as exactly as its Gleam
  // name does, so an `@external`'s module compares as it's written.
  ErlangName(String)
  // Its JavaScript file name, such as `parser.mjs`.
  JavaScriptFile(String)
  // Any module, for a JavaScript `@external` whose module grice can't
  // follow.
  AnyModule
}

// A public function that isn't public API: its name, the span of its
// definition, from its `pub`, and why.
type Candidate {
  Candidate(name: String, location: glance.Span, reason: Reason)
}

// Why a candidate isn't public API. A function marked `@internal` in an
// internal module is in the internal module: without the attribute it still
// wouldn't be public API.
type Reason {
  InInternalModule
  MarkedInternal
}

fn summarise(module_facts: ModuleFacts(Syntax)) -> Summary {
  Summary(
    source: facts.source(module_facts),
    candidates: candidates(module_facts),
    uses: uses(module_facts),
  )
}

// Every candidate no other module uses, keyed by its module. Only a module
// with a finding is lexed for the spans of the names.
fn evaluate(summaries: List(#(String, Summary))) -> List(#(String, Report)) {
  let used =
    summaries
    |> list.flat_map(fn(entry) { { entry.1 }.uses })
    |> set.from_list
  use #(module, summary) <- list.flat_map(summaries)
  let keys = [
    ErlangName(loader.erlang_name(module)),
    JavaScriptFile(loader.javascript_file(module)),
    AnyModule,
  ]
  let unused =
    list.filter(summary.candidates, fn(candidate) {
      !list.any(keys, fn(key) { set.contains(used, #(key, candidate.name)) })
    })
  case unused {
    [] -> []
    [_, ..] -> reports(module, summary.source, unused)
  }
}

// Candidates
//
// The public functions of a linted module under `src/` that aren't public
// API, less those the toolchain calls by name and those a foreign source
// names, in source order.

fn candidates(module_facts: ModuleFacts(Syntax)) -> List(Candidate) {
  use <- bool.guard(
    when: !facts.is_linted(module_facts)
      || !string.starts_with(facts.path(module_facts), "src/"),
    return: [],
  )
  let internal =
    facts.is_internal_module(module_facts, facts.module_name(module_facts))
  let foreign = facts.foreign_mentions(module_facts)
  use definition <- list.filter_map(facts.module(module_facts).functions)
  let glance.Definition(attributes:, definition: function) = definition
  use reason <- result.try(reason(internal, attributes))
  use <- bool.guard(
    when: function.publicity == glance.Private
      || is_called_by_name(module_facts, function.name)
      || set.contains(foreign, function.name),
    return: Error(Nil),
  )
  Ok(Candidate(name: function.name, location: function.location, reason:))
}

fn reason(
  internal: Bool,
  attributes: List(glance.Attribute),
) -> Result(Reason, Nil) {
  case internal, type_names.is_marked_internal(attributes) {
    True, _ -> Ok(InInternalModule)
    False, True -> Ok(MarkedInternal)
    False, False -> Error(Nil)
  }
}

// `main` is what `gleam run -m` runs, and the start module's `start` is
// what the Erlang runtime calls when the application starts.
fn is_called_by_name(module_facts: ModuleFacts(Syntax), name: String) -> Bool {
  name == "main"
  || name == "start"
  && facts.is_application_start_module(module_facts)
}

// The finding on each of `candidates`, in source order, at its name: the
// first name token from the start of its definition, which is its `pub`,
// past `fn` and any comment between them. glexer counts glance's units, as
// the tree does, and a name is ASCII, so its length is the same in bytes
// and in UTF-16 code units.
fn reports(
  module: String,
  source: String,
  candidates: List(Candidate),
) -> List(#(String, Report)) {
  let tokens =
    glexer.new(source)
    |> glexer.discard_whitespace
    |> glexer.discard_comments
    |> glexer.lex
  let #(_tokens, found) = {
    use tokens, candidate <- list.map_fold(candidates, tokens)
    let start = candidate.location.start
    let tokens = list.drop_while(tokens, fn(entry) { offset(entry) < start })
    let span = case
      list.find(tokens, fn(entry) { entry.0 == token.Name(candidate.name) })
    {
      Ok(entry) ->
        glance.Span(
          offset(entry),
          offset(entry) + string.byte_size(candidate.name),
        )
      Error(Nil) -> candidate.location
    }
    #(tokens, #(module, report(candidate.name, span, module, candidate.reason)))
  }
  found
}

fn offset(entry: #(Token, glexer.Position)) -> Int {
  let glexer.Position(byte_offset:) = entry.1
  byte_offset
}

// The finding on the candidate `name` of `module`, at `span`.
fn report(
  name: String,
  span: glance.Span,
  module: String,
  reason: Reason,
) -> Report {
  let subject = "The public function `" <> name <> "` "
  let why = case reason {
    InInternalModule ->
      subject <> "is in the internal module `" <> module <> "`"
    MarkedInternal -> subject <> "is marked `@internal`"
  }
  rule.report(
    at: span,
    label: "no other Gleam module refers to `" <> name <> "`",
  )
  |> rule.with_message([
    why
    <> ", so it isn't part of the package's public API, and no other Gleam module of the project refers to it. Unless foreign code uses it, it doesn't need to be public.",
  ])
  |> rule.with_hint(
    "If no foreign code uses it, make it private. If `"
    <> module
    <> "` doesn't use it either, the compiler will then report it as unused.",
  )
}

// Uses
//
// What a module refers to in other modules, read in its syntax tree for
// every target, so code compiled only for the other target counts too. A
// module can't import itself, so its references never name it, but an
// `@external` can name it, which needs the function exported.

fn uses(module_facts: ModuleFacts(Syntax)) -> List(#(Key, String)) {
  let module = facts.module_for_every_target(module_facts)
  let imports =
    list.map(module.imports, fn(definition) { definition.definition })
  let qualifiers =
    list.fold(imports, dict.new(), fn(qualifiers, import_) {
      case type_names.qualifier(import_) {
        Ok(qualifier) ->
          dict.upsert(qualifiers, qualifier, fn(modules) {
            [
              ErlangName(loader.erlang_name(import_.module)),
              ..option.unwrap(modules, [])
            ]
          })
        Error(Nil) -> qualifiers
      }
    })
  let unqualified =
    list.flat_map(imports, fn(import_) {
      let key = ErlangName(loader.erlang_name(import_.module))
      list.map(import_.unqualified_values, fn(value) { #(key, value.name) })
    })
  let qualified =
    visit.new()
    |> visit.on_expression(fn(found, expression) {
      qualified_use(found, qualifiers, expression)
    })
    |> visit.module(module, from: [], with: _)
  let external =
    list.flat_map(module.functions, fn(definition) {
      list.filter_map(definition.attributes, external_use)
    })
  list.flatten([unqualified, qualified, external])
}

// `q.f`, where `q` qualifies the imports of some modules, is a use of `f` in
// each of them. A local variable named like a qualifier counts too, as a
// use the rule can't tell apart from one.
fn qualified_use(
  found: List(#(Key, String)),
  qualifiers: Dict(String, List(Key)),
  expression: glance.Expression,
) -> List(#(Key, String)) {
  case expression {
    glance.FieldAccess(container: glance.Variable(name:, ..), label:, ..) ->
      dict.get(qualifiers, name)
      |> result.unwrap([])
      |> list.fold(found, fn(found, key) { [#(key, label), ..found] })
    _ -> found
  }
}

// An `@external` naming a function of a Gleam module: by its Erlang name,
// such as `app@internal@parser`, or by its JavaScript file, such as
// `./internal/parser.mjs`, which only its file name names, as a foreign
// source does. A JavaScript module that isn't a relative path to a `.mjs`
// file, such as a package's own name or a `#` import, may lead to any
// module through `package.json`, which grice doesn't read.
fn external_use(attribute: glance.Attribute) -> Result(#(Key, String), Nil) {
  case attribute {
    glance.Attribute(
      name: "external",
      arguments: [
        glance.Variable(name: "erlang", ..),
        glance.String(value: module, ..),
        glance.String(value: name, ..),
      ],
    ) -> Ok(#(ErlangName(module), name))
    glance.Attribute(
      name: "external",
      arguments: [
        glance.Variable(name: "javascript", ..),
        glance.String(value: path, ..),
        glance.String(value: name, ..),
      ],
    ) ->
      case
        { string.starts_with(path, "./") || string.starts_with(path, "../") }
        && string.ends_with(path, ".mjs")
      {
        True -> Ok(#(JavaScriptFile(file_name(path)), name))
        False -> Ok(#(AnyModule, name))
      }
    _ -> Error(Nil)
  }
}

// The last segment of a path, such as `parser.mjs` for
// `./internal/parser.mjs`.
fn file_name(path: String) -> String {
  string.split(path, "/") |> list.last |> result.unwrap(path)
}
