//// What a rule may ask about the module it's looking at.
////
//// Every rule hook gets the `ModuleFacts` of the module being linted. They
//// describe the module as it's compiled for the project's target: a
//// definition whose `@target` attribute names the other target isn't
//// there, whatever its kind, and neither is an import marked that way.
////
//// The `kind` parameter says which facts a rule can ask for. Every rule
//// gets `Syntax` facts: the module's name, path, source and syntax tree.

import glance
import gleam/result
import grice/internal/config.{type Target}
import grice/internal/line_index.{type LineIndex}
import grice/internal/loader

/// The facts about one module. The phantom `kind` is the kind of facts a
/// rule was built for, such as `Syntax`.
pub opaque type ModuleFacts(kind) {
  ModuleFacts(
    module_name: String,
    path: String,
    source: LineIndex,
    module: glance.Module,
    imports: List(String),
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

/// The module's source. Spans in the syntax tree are byte offsets into it.
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

/// The facts of a loaded module, or an error when it doesn't parse, which
/// the loader has already reported.
@internal
pub fn new(
  module: loader.Module,
  target: Target,
) -> Result(ModuleFacts(Syntax), Nil) {
  use syntax <- result.map(result.replace_error(module.parsed, Nil))
  ModuleFacts(
    module_name: module.name,
    path: module.path,
    source: module.source,
    module: loader.for_target(syntax, target),
    imports: module.imports,
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
  let ModuleFacts(module_name:, path:, source:, module:, imports:) = facts
  ModuleFacts(module_name:, path:, source:, module:, imports:)
}
