//// `grice_rules/internal-type-in-public-api`: a public function, constant
//// or constructor whose written signature names an internal type of the
//// package. It reads only the syntax tree and the facts on internal
//// modules and types: each type name written in a signature is resolved
//// from the module's imports and definitions, which leave no doubt in
//// code the compiler accepts, so it needs no types from girard. A type
//// written through a public alias is fine, whatever the alias stands for.

import glance
import gleam/bool
import gleam/list
import gleam/option
import gleam/result
import gleam/set.{type Set}
import gleam/string
import grice/facts.{type ModuleFacts, type Syntax}
import grice/internal/type_names.{type Resolver, type WrittenName}
import grice/rule.{type Report, type Rule}

const code = "grice_rules/internal-type-in-public-api"

/// The rule. In a module under `src/` that isn't internal, it reads the
/// public declarations not marked `@internal`: each annotated parameter and
/// return of a function, external ones included, the annotation of a
/// constant, and the fields of each constructor of a custom type that isn't
/// opaque. It reports each named type at any depth there that resolves to
/// a type `facts.is_internal_type` knows to be internal, at the span glance
/// gives the name.
pub fn rule() -> Rule {
  rule.module(code, title: "Internal type in the public API")
  |> rule.with_context(initial: Nil)
  |> rule.on_module_end(fn(_context, module_facts) {
    use <- bool.guard(when: !reads(module_facts), return: [])
    // The module's names are read only when a declaration names a type.
    case declarations(facts.module(module_facts)) {
      [] -> []
      found -> reports(names(module_facts), module_facts, found)
    }
  })
  |> rule.build
}

// What the rule needs of the module it reads, worked out once per module:
// how its type names resolve, and the names of its private aliases.
type Names {
  Names(resolver: Resolver, private_aliases: Set(String))
}

// A public declaration that names types in its signature.
type Declaration {
  Function(name: String)
  Constant(name: String)
  Constructor(name: String, custom_type: String)
}

// Why the rule counts a type as internal, as far as it can tell from the
// facts and the module it reads.
type Reason {
  // The type is defined in this internal module.
  InInternalModule(module: String)
  // The type is a private alias of the module the rule reads, which names
  // an internal type.
  PrivateAlias
  // The type is marked `@internal`: the only other way a type of a module
  // that isn't internal can be internal.
  MarkedInternal
}

// The library pack applies to what a package publishes: the modules under
// `src/` that aren't internal. Tests and development tools are published
// by no package.
fn reads(module_facts: ModuleFacts(Syntax)) -> Bool {
  string.starts_with(facts.path(module_facts), "src/")
  && !facts.is_internal_module(module_facts, facts.module_name(module_facts))
}

// The public declarations not marked `@internal` that name types in their
// signatures, each with the types written there: a function's annotated
// parameters and return, external functions included, a constant's
// annotation, and the fields of each constructor of a custom type that
// isn't opaque, whose constructors are private to its module.
fn declarations(
  module: glance.Module,
) -> List(#(Declaration, List(glance.Type))) {
  let functions =
    public(module.functions, fn(function) { function.publicity })
    |> list.map(fn(function) {
      let types =
        function.parameters
        |> list.map(fn(parameter) { parameter.type_ })
        |> list.append([function.return])
        |> option.values
      #(Function(function.name), types)
    })
  let constants =
    public(module.constants, fn(constant) { constant.publicity })
    |> list.map(fn(constant) {
      #(Constant(constant.name), option.values([constant.annotation]))
    })
  let constructors =
    public(module.custom_types, fn(custom_type) { custom_type.publicity })
    |> list.filter(fn(custom_type) { !custom_type.opaque_ })
    |> list.flat_map(fn(custom_type) {
      use variant <- list.map(custom_type.variants)
      #(
        Constructor(variant.name, custom_type: custom_type.name),
        list.map(variant.fields, fn(field) { field.item }),
      )
    })
  list.flatten([functions, constants, constructors])
  |> list.filter(fn(declaration) { declaration.1 != [] })
}

// The definitions that are public, as `publicity` reads them, and not
// marked `@internal`.
fn public(
  definitions: List(glance.Definition(definition)),
  publicity: fn(definition) -> glance.Publicity,
) -> List(definition) {
  use glance.Definition(attributes:, definition:) <- list.filter_map(
    definitions,
  )
  case
    publicity(definition) == glance.Public
    && !type_names.is_marked_internal(attributes)
  {
    True -> Ok(definition)
    False -> Error(Nil)
  }
}

fn names(module_facts: ModuleFacts(Syntax)) -> Names {
  let name = facts.module_name(module_facts)
  let syntax = facts.module(module_facts)
  let private_aliases =
    syntax.type_aliases
    |> list.filter(fn(alias) { alias.definition.publicity == glance.Private })
    |> list.map(fn(alias) { alias.definition.name })
    |> set.from_list
  Names(resolver: type_names.resolver(name, syntax), private_aliases:)
}

// A name that doesn't resolve, such as a prelude type, is skipped.
fn reports(
  known: Names,
  module_facts: ModuleFacts(Syntax),
  declarations: List(#(Declaration, List(glance.Type))),
) -> List(Report) {
  use #(declaration, types) <- list.flat_map(declarations)
  use type_ <- list.flat_map(types)
  use written <- list.filter_map(type_names.written_names(type_))
  use #(defined_in, name) <- result.try(type_names.resolve(
    known.resolver,
    written.qualifier,
    written.name,
  ))
  use <- bool.guard(
    when: !facts.is_internal_type(module_facts, module: defined_in, name:),
    return: Error(Nil),
  )
  let reason = reason(known, module_facts, defined_in, name)
  Ok(report(written, name, reason, declaration))
}

fn reason(
  known: Names,
  module_facts: ModuleFacts(Syntax),
  defined_in: String,
  name: String,
) -> Reason {
  case
    facts.is_internal_module(module_facts, defined_in),
    defined_in == facts.module_name(module_facts)
    && set.contains(known.private_aliases, name)
  {
    True, _ -> InInternalModule(defined_in)
    False, True -> PrivateAlias
    False, False -> MarkedInternal
  }
}

// The finding on the internal type `name`, written as `written` in the
// signature of `declaration`.
fn report(
  written: WrittenName,
  name: String,
  reason: Reason,
  declaration: Declaration,
) -> Report {
  let #(label, public_name) = case reason {
    InInternalModule(module:) -> #(
      "`" <> name <> "` is defined in the internal module `" <> module <> "`",
      "Give the type a public name: name a public alias of it here, or add one to this module if naming an existing alias would be an import cycle, or move the type to a module that isn't internal, without `@internal`.",
    )
    PrivateAlias -> #(
      "`" <> name <> "` is a private alias that names an internal type",
      "Make `" <> name <> "` public, so the type has a public name.",
    )
    MarkedInternal -> #(
      "`" <> name <> "` is marked `@internal`",
      "Remove `@internal` from the type if users need it.",
    )
  }
  let #(described, not_for_users) = case declaration {
    Function(name:) -> value("function", name)
    Constant(name:) -> value("constant", name)
    // The compiler refuses `@internal` on a constructor.
    Constructor(name:, custom_type:) -> #(
      "The public constructor `" <> name <> "`",
      "If users shouldn't build or match on `"
        <> name
        <> "`, make `"
        <> custom_type
        <> "` opaque, or mark it `@internal` if no part of it is meant for users.",
    )
  }
  rule.report(at: written.location, label:)
  |> rule.with_message([
    described
    <> " names this type in its signature, so the type is part of the package's public API, but it's internal: the documentation generated for the package has no entry for it.",
  ])
  |> rule.with_hint(public_name <> " " <> not_for_users)
}

// How the message names a public function or constant `name`, which is a
// `noun`, and the hint's sentence for one that isn't meant for users.
fn value(noun: String, name: String) -> #(String, String) {
  #(
    "The public " <> noun <> " `" <> name <> "`",
    "If `" <> name <> "` isn't meant for users, mark it `@internal` instead.",
  )
}
