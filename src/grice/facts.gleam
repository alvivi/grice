//// What a rule may ask about the module it's looking at.
////
//// Every rule hook gets the `ModuleFacts` of the module being linted. They
//// describe the module as it's compiled for the project's target: a
//// definition whose `@target` attribute names the other target isn't
//// there, whatever its kind, and neither is an import marked that way.
////
//// The `kind` parameter says which facts a rule can ask for. Every rule
//// gets `Syntax` facts: the module's name, path, source, comments and
//// syntax tree. A rule built with `rule.typed` gets `Typed` facts, which
//// also answer what girard, the type inference grice uses, found: the type
//// of an expression, what a name or field access resolved to, and the type
//// of a top-level definition. A typed query never guesses: when girard has
//// no answer, it says why with an `Unknown`.
////
//// Spans count what glance counts on the target grice runs on: bytes on
//// Erlang and UTF-16 code units on JavaScript. The syntax tree, the
//// comments and the type queries all count the same units, so a rule can
//// compare their spans and pass them to `rule.report` as they are; grice
//// turns them into the byte offsets of its diagnostics.

import girard
import glance
import gleam/bool
import gleam/dict
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/pair
import gleam/result
import gleam/set
import glexer
import glexer/token.{type Token}
import grice/internal/config.{type Target}
import grice/internal/line_index.{type LineIndex}
import grice/internal/loader
import grice/internal/typing.{type ModuleTypes}

// Facts
//
// The facts every rule gets, whatever its kind.

/// The facts about one module. The phantom `kind` is the kind of facts a
/// rule was built for: `Syntax` or `Typed`.
pub opaque type ModuleFacts(kind) {
  ModuleFacts(
    module_name: String,
    path: String,
    source: LineIndex,
    module: glance.Module,
    imports: List(String),
    comments: List(Comment),
    // What girard found for the module: `None` when no rule asked for
    // types, or girard returned nothing for the module.
    types: Option(ModuleTypes),
  )
}

/// The kind of facts every rule gets: what can be read from the syntax tree
/// alone.
pub type Syntax

/// The module's name, such as `app/router`.
pub fn module_name(facts: ModuleFacts(kind)) -> String {
  facts.module_name
}

/// The module's path relative to the project root, such as
/// `src/app/router.gleam`.
pub fn path(facts: ModuleFacts(kind)) -> String {
  facts.path
}

/// The module's source. Spans in the syntax tree are offsets into it, in
/// glance's units: bytes on Erlang and UTF-16 code units on JavaScript.
pub fn source(facts: ModuleFacts(kind)) -> String {
  line_index.source(facts.source)
}

/// The module's syntax tree, with only the definitions compiled for the
/// project's target. Each list of definitions is in source order.
pub fn module(facts: ModuleFacts(kind)) -> glance.Module {
  facts.module
}

/// The names of the modules this one imports for the project's target,
/// project and dependency modules alike, in source order.
pub fn imports(facts: ModuleFacts(kind)) -> List(String) {
  facts.imports
}

/// The facts of a loaded module, with what girard found for it when a rule
/// asked for types, or an error when it doesn't parse, which the loader has
/// already reported. Its comments are read here, so only modules that get
/// facts are lexed for them.
@internal
pub fn new(
  module: loader.Module,
  target: Target,
  types: Option(ModuleTypes),
) -> Result(ModuleFacts(Syntax), Nil) {
  use syntax <- result.map(result.replace_error(module.parsed, Nil))
  let view = loader.for_target(syntax, target)
  ModuleFacts(
    module_name: module.name,
    path: module.path,
    source: module.source,
    module: view,
    imports: module.imports,
    comments: read_comments(module.source, syntax, view),
    types:,
  )
}

/// The index of the module's source, which report spans are checked
/// against.
@internal
pub fn line_index(facts: ModuleFacts(kind)) -> LineIndex {
  facts.source
}

/// The same facts, seen as another kind. Rule builders use it to hand a
/// rule the facts it was built for.
@internal
pub fn change_kind(facts: ModuleFacts(a)) -> ModuleFacts(b) {
  ModuleFacts(..facts, types: facts.types)
}

/// The name and span of each top-level function, constant, custom type and
/// type alias of `module`: every definition but its imports.
@internal
pub fn definitions(module: glance.Module) -> List(#(String, glance.Span)) {
  list.flatten([
    list.map(module.functions, fn(function) {
      #(function.definition.name, function.definition.location)
    }),
    list.map(module.constants, fn(constant) {
      #(constant.definition.name, constant.definition.location)
    }),
    list.map(module.custom_types, fn(custom_type) {
      #(custom_type.definition.name, custom_type.definition.location)
    }),
    list.map(module.type_aliases, fn(alias) {
      #(alias.definition.name, alias.definition.location)
    }),
  ])
}

// Comments
//
// glance keeps no comments, so they're read with glexer, the lexer glance
// itself uses, which knows that a `//` inside a string isn't one. A
// comment inside a definition left out for the other target is left out
// with it, as rules never see that code.

/// A comment in the module's source.
pub type Comment {
  Comment(
    kind: CommentKind,
    /// The comment's span in the source, in glance's units: its `//`,
    /// `///` or `////`, and the rest of its line, without the line ending.
    span: glance.Span,
    /// What follows the `//`, `///` or `////`, such as `" TODO"` for
    /// `// TODO`.
    text: String,
  )
}

/// What a comment's first slashes make it.
pub type CommentKind {
  /// A regular comment, `//`.
  Regular
  /// A documentation comment for the definition below it, `///`.
  Doc
  /// A documentation comment for the module, `////`.
  ModuleDoc
}

/// The module's comments as it's compiled for the project's target, in
/// source order: a comment inside a definition whose `@target` attribute
/// names the other target isn't there.
pub fn comments(facts: ModuleFacts(kind)) -> List(Comment) {
  facts.comments
}

// The comments of `source`, except those inside a definition of `module`
// that `view`, its target view, leaves out.
fn read_comments(
  source: LineIndex,
  module: glance.Module,
  view: glance.Module,
) -> List(Comment) {
  let kept = set.from_list(definition_spans(view))
  let dropped =
    list.filter(definition_spans(module), fn(span) { !set.contains(kept, span) })
  let units = line_index.units(source)
  use #(token, glexer.Position(byte_offset: start)) <- list.filter_map(
    glexer.new(line_index.source(source))
    |> glexer.discard_whitespace
    |> glexer.lex,
  )
  use #(kind, marker, text) <- result.try(comment_token(token))
  use <- bool.guard(
    when: list.any(dropped, fn(span) { span.start <= start && start < span.end }),
    return: Error(Nil),
  )
  // glexer gives an offset in glance's units and the text after the
  // marker, without the `\r` of a CRLF line ending, so the end is counted
  // in those units too.
  let end = start + marker + line_index.length(text, in: units)
  Ok(Comment(kind:, span: glance.Span(start, end), text:))
}

// A comment token's kind, the length of its marker and its text.
fn comment_token(token: Token) -> Result(#(CommentKind, Int, String), Nil) {
  case token {
    token.CommentNormal(text) -> Ok(#(Regular, 2, text))
    token.CommentDoc(text) -> Ok(#(Doc, 3, text))
    token.CommentModule(text) -> Ok(#(ModuleDoc, 4, text))
    _ -> Error(Nil)
  }
}

// The span of every top-level definition of a module, imports included.
fn definition_spans(module: glance.Module) -> List(glance.Span) {
  list.map(module.imports, fn(import_) { import_.definition.location })
  |> list.append(list.map(definitions(module), pair.second))
}

// Types
//
// What girard found, asked by span or by name. Spans match exactly, as
// glance gives them in the syntax tree of `module`. A query that girard
// can't answer says why, and the reasons are tried in a fixed order:
// whether girard returned anything for the module, whether it could use
// every module it needed, and then, on a miss, whether the span or name
// belongs to a definition girard couldn't type, or to one left out for the
// other target.

/// The kind of facts a rule built with `rule.typed` gets: the syntax facts,
/// and what girard found.
pub type Typed

/// Why a typed query has no answer. A rule that gets one stays silent
/// about what it asked, since grice never guesses what types can tell.
pub type Unknown {
  /// girard keeps nothing for this span or name: the span isn't one of an
  /// expression, a field access or a name in call position, or the name
  /// isn't a top-level function or constant of the module.
  NotRecorded
  /// The span lies inside, or the name is, the top-level definition
  /// `definition`, which girard couldn't type. grice reports each one as a
  /// `grice/untyped-definition` note.
  Skipped(definition: String)
  /// The span lies inside, or the name is, the top-level definition
  /// `definition`, which isn't compiled for the project's target.
  Dropped(definition: String)
  /// girard returned nothing for the module.
  NotInferred
  /// girard couldn't use these modules, which the module imports directly
  /// or reaches through other modules. girard types code that uses them as
  /// if they existed, and its answers can't be told apart from real ones,
  /// so no query on the module has an answer, whatever it asks.
  Unavailable(modules: List(String))
}

/// The type of the expression at `span`, the `location` glance gives it.
pub fn type_of(
  facts: ModuleFacts(Typed),
  span: glance.Span,
) -> Result(girard.Type, Unknown) {
  use types <- answer(facts)
  dict.get(types.expressions, span)
  |> result.map_error(fn(_) { why_missing(types, holds_span(span)) })
}

/// What the reference at `span` resolved to: a field access, with the
/// `location` glance gives it, or a name in call position (the callee of a
/// call, a capture or a `use`, or a function after a pipe), with the span
/// of that name.
pub fn resolution_of(
  facts: ModuleFacts(Typed),
  span: glance.Span,
) -> Result(girard.Resolution, Unknown) {
  use types <- answer(facts)
  dict.get(types.resolutions, span)
  |> result.map_error(fn(_) { why_missing(types, holds_span(span)) })
}

/// The type of the module's top-level function or constant `name`, with
/// its generic variables.
pub fn signature(
  facts: ModuleFacts(Typed),
  name: String,
) -> Result(girard.Scheme, Unknown) {
  use types <- answer(facts)
  dict.get(types.schemes, name)
  |> result.map_error(fn(_) {
    why_missing(types, fn(definition, _span) { definition == name })
  })
}

// Call `query` with what girard found for the module, unless girard
// returned nothing for it or couldn't use a module it needed.
fn answer(
  facts: ModuleFacts(kind),
  query: fn(ModuleTypes) -> Result(a, Unknown),
) -> Result(a, Unknown) {
  case facts.types {
    None -> Error(NotInferred)
    Some(typing.ModuleTypes(unavailable: [], ..) as types) -> query(types)
    Some(typing.ModuleTypes(unavailable:, ..)) ->
      Error(Unavailable(list.map(unavailable, fn(entry) { entry.module })))
  }
}

// Why girard keeps nothing for a query, given whether the top-level
// definition with a name and a span holds what it asks for. It's only
// worked out on a miss.
fn why_missing(
  types: ModuleTypes,
  holds: fn(String, glance.Span) -> Bool,
) -> Unknown {
  let skipped =
    list.find(types.skipped, fn(skipped) { holds(skipped.name, skipped.span) })
    |> result.map(fn(skipped) { Skipped(skipped.name) })
  use <- result.lazy_unwrap(skipped)
  list.find(types.dropped, fn(dropped) { holds(dropped.name, dropped.span) })
  |> result.map(fn(dropped) { Dropped(dropped.name) })
  |> result.unwrap(NotRecorded)
}

// Whether a definition's span holds the whole of `span`.
fn holds_span(span: glance.Span) -> fn(String, glance.Span) -> Bool {
  fn(_definition, outer: glance.Span) {
    outer.start <= span.start && span.end <= outer.end
  }
}
