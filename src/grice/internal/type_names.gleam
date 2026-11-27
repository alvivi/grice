//// The type names written in a module: what each one resolves to, and
//// which types of the project are internal.
////
//// A written type name is resolved from the module's imports and the types
//// it defines. Gleam has no glob imports, and the compiler rejects every
//// ambiguity left, such as two imports with one alias or an imported type
//// that clashes with a local one, so in code the compiler accepts, each
//// name means one type. The loader reads alias definitions with it, and
//// the rule that looks for internal types in public signatures reads
//// annotations with it, so both read a name the same way.

import glance
import gleam/bool
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import grice/visit

// Resolving
//
// A module's resolver is built once from its imports and its type
// definitions, and then answers for every name written in it.

/// How a module's written type names resolve: its imports and the types it
/// defines.
pub opaque type Resolver {
  Resolver(
    module: String,
    // The module each qualifier names: an import's alias, or the last
    // segment of its module path when it has none.
    qualifiers: Dict(String, String),
    // The module and declared name of each type an unqualified import
    // brings in, by the name it's brought in as.
    imported: Dict(String, #(String, String)),
    // The names of the types the module defines.
    defined: Set(String),
  )
}

/// A type name as written: `Name` or `module.Name`, at the span glance
/// gives it, which covers its arguments.
pub type WrittenName {
  WrittenName(location: glance.Span, qualifier: Option(String), name: String)
}

/// The resolver of the module `name`, whose syntax tree is `module` as it's
/// compiled for the project's target.
pub fn resolver(name: String, module: glance.Module) -> Resolver {
  let imports = list.map(module.imports, fn(import_) { import_.definition })
  let qualifiers =
    list.filter_map(imports, fn(import_) {
      qualifier(import_) |> result.map(fn(found) { #(found, import_.module) })
    })
  let imported =
    list.flat_map(imports, fn(import_) {
      use unqualified <- list.map(import_.unqualified_types)
      let as_name = option.unwrap(unqualified.alias, unqualified.name)
      #(as_name, #(import_.module, unqualified.name))
    })
  let defined =
    list.append(
      list.map(module.custom_types, fn(custom_type) {
        custom_type.definition.name
      }),
      list.map(module.type_aliases, fn(alias) { alias.definition.name }),
    )
  Resolver(
    module: name,
    qualifiers: dict.from_list(qualifiers),
    imported: dict.from_list(imported),
    defined: set.from_list(defined),
  )
}

/// The module and declared name of the type a written name stands for. A
/// qualified name names a type of the module imported with that alias, or,
/// for an import with no alias, whose path ends in that segment. An
/// unqualified name names the type an unqualified import brings in under
/// that name, such as `X` of `a/b` for `import a/b.{type X as T}`, or else
/// a type the module defines. Any other name, a prelude type included,
/// resolves to nothing.
pub fn resolve(
  resolver: Resolver,
  qualifier: Option(String),
  name: String,
) -> Result(#(String, String), Nil) {
  case qualifier {
    Some(qualifier) ->
      dict.get(resolver.qualifiers, qualifier)
      |> result.map(fn(module) { #(module, name) })
    None -> {
      use <- result.lazy_or(dict.get(resolver.imported, name))
      use <- bool.guard(
        when: !set.contains(resolver.defined, name),
        return: Error(Nil),
      )
      Ok(#(resolver.module, name))
    }
  }
}

/// Every type name written in `type_`, at any depth, in source order: a
/// named type before its arguments, the elements of a tuple, and the
/// parameters and return of a function type. Type variables and holes name
/// nothing.
pub fn written_names(type_: glance.Type) -> List(WrittenName) {
  visit.new()
  |> visit.on_type(fn(found, type_) {
    case type_ {
      glance.NamedType(location:, name:, module:, ..) -> [
        WrittenName(location:, qualifier: module, name:),
        ..found
      ]
      glance.TupleType(..)
      | glance.FunctionType(..)
      | glance.VariableType(..)
      | glance.HoleType(..) -> found
    }
  })
  |> visit.type_(type_, from: [], with: _)
  |> list.reverse
}

/// The name a module gives an import, which qualifies the names it uses
/// from it: the import's alias, or the last segment of its path. A
/// discarded alias, such as `as _b`, gives none.
pub fn qualifier(import_: glance.Import) -> Result(String, Nil) {
  case import_.alias {
    Some(glance.Named(alias)) -> Ok(alias)
    Some(glance.Discarded(_)) -> Error(Nil)
    None -> string.split(import_.module, "/") |> list.last
  }
}

// Internal types
//
// Which types of the project are internal: the public custom types of an
// internal module or marked `@internal`, and the aliases that aren't public
// API whose definitions name one. A public alias is a public type alias,
// not marked `@internal`, in a module that isn't internal: the name a
// package gives a type for its users, whatever it stands for. An alias that
// isn't public API counts as what it names.
//
// Following each alias down to what it names could take exponential time
// over aliases that name each other many times, so the index works the
// other way round: each alias that isn't public API has the names in its
// definition resolved once, and each name is an edge back to it. The
// internal custom types are marked first, then every alias with an edge
// from a marked type, so each alias is visited at most once, and a cycle,
// which the compiler rejects anyway, ends the walk like any alias marked
// already.

/// The internal types of `modules`, each the name and syntax tree of a
/// project module as it's compiled for the project's target, given the
/// names of the project's internal modules: every public custom type of an
/// internal module or marked `@internal`, and every type alias that isn't
/// public API, because it's private, marked `@internal` or in an internal
/// module, whose definition names an internal type anywhere in it. That
/// includes the written arguments of a public alias, but not what the
/// public alias stands for. Each type is `#(module, name)`.
pub fn internal_types(
  modules: List(#(String, glance.Module)),
  internal_modules: Set(String),
) -> Set(#(String, String)) {
  index(modules, internal_modules).types
}

/// The internal types `index` found, and the number of visits it made.
@internal
pub type Index {
  Index(types: Set(#(String, String)), visits: Int)
}

/// The internal types of `modules`, as `internal_types` gives them, with
/// the number of visits made to find them: one for each name read in the
/// definition of an alias that isn't public API, and one for each type
/// taken from the queue of types marked internal.
@internal
pub fn index(
  modules: List(#(String, glance.Module)),
  internal_modules: Set(String),
) -> Index {
  let graph =
    list.fold(
      modules,
      Graph(seeds: [], edges: dict.new(), reads: 0),
      fn(graph, entry) {
        let #(name, module) = entry
        read_module(graph, name, module, set.contains(internal_modules, name))
      },
    )
  let #(types, marks) =
    mark(graph.seeds, graph.edges, set.from_list(graph.seeds), 0)
  Index(types:, visits: graph.reads + marks)
}

/// Whether a definition is marked `@internal`.
pub fn is_marked_internal(attributes: List(glance.Attribute)) -> Bool {
  list.any(attributes, fn(attribute) { attribute.name == "internal" })
}

// A type of the project, as `#(module, name)`.
type Key =
  #(String, String)

// What the modules read so far give: the internal custom types, the edges
// from each type to the aliases that aren't public API whose definitions
// name it, and how many names those definitions held.
type Graph {
  Graph(seeds: List(Key), edges: Dict(Key, List(Key)), reads: Int)
}

// The graph with the module `name` read, which is internal or not.
fn read_module(
  graph: Graph,
  name: String,
  module: glance.Module,
  internal: Bool,
) -> Graph {
  let seeds =
    list.fold(module.custom_types, graph.seeds, fn(seeds, custom_type) {
      let glance.Definition(attributes:, definition:) = custom_type
      let is_internal =
        definition.publicity == glance.Public
        && { internal || is_marked_internal(attributes) }
      case is_internal {
        True -> [#(name, definition.name), ..seeds]
        False -> seeds
      }
    })
  let aliases =
    list.filter(module.type_aliases, fn(alias) {
      internal
      || alias.definition.publicity == glance.Private
      || is_marked_internal(alias.attributes)
    })
  case aliases {
    [] -> Graph(..graph, seeds:)
    // The resolver is built only for a module with such an alias.
    [_, ..] -> {
      let resolver = resolver(name, module)
      use graph, alias <- list.fold(aliases, Graph(..graph, seeds:))
      let from = #(name, alias.definition.name)
      use graph, written <- list.fold(
        written_names(alias.definition.aliased),
        graph,
      )
      let edges = case resolve(resolver, written.qualifier, written.name) {
        Ok(to) ->
          dict.upsert(graph.edges, to, fn(found) {
            [from, ..option.unwrap(found, [])]
          })
        Error(Nil) -> graph.edges
      }
      Graph(..graph, edges:, reads: graph.reads + 1)
    }
  }
}

// Mark every alias with an edge from a type in `queue`, which are all
// marked, and so on from each alias marked, counting the types taken from
// the queue. Each type is queued only when it's marked, so once.
fn mark(
  queue: List(Key),
  edges: Dict(Key, List(Key)),
  marked: Set(Key),
  marks: Int,
) -> #(Set(Key), Int) {
  case queue {
    [] -> #(marked, marks)
    [type_, ..queue] -> {
      let #(queue, marked) =
        dict.get(edges, type_)
        |> result.unwrap([])
        |> list.fold(#(queue, marked), fn(state, alias) {
          let #(queue, marked) = state
          use <- bool.guard(when: set.contains(marked, alias), return: state)
          #([alias, ..queue], set.insert(marked, alias))
        })
      mark(queue, edges, marked, marks + 1)
    }
  }
}
