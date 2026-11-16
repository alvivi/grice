//// The types of a project's modules, inferred by girard.
////
//// girard runs once, over every parsed load-set module, in an order that
//// puts each module after the project modules it imports, so girard finds
//// each of those in its cache and never parses one again. The resolver it
//// gets answers only for dependency modules, from the sources the loader
//// read, so girard never reads from disk. Each lint-set module girard
//// returns gets an index of its types, built once here and handed to the
//// module's facts.

import girard
import glance
import gleam/bool
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/result
import gleam/set.{type Set}
import grice/internal/config
import grice/internal/loader.{type Project, Project}

// Inference
//
// One call to girard over the whole load set, and an index per lint-set
// module of what it found, so a query is a dictionary lookup. An index
// holds its own module's data only, since a copy goes to every task that
// lints the module.

/// What girard found for one module, indexed by span and by name.
pub type ModuleTypes {
  ModuleTypes(
    /// The type of each expression girard records, by its span. Should
    /// girard record a span more than once, the first entry is kept.
    expressions: Dict(glance.Span, girard.Type),
    /// What each reference girard records resolved to, by its span: every
    /// field access, and every name in call position.
    resolutions: Dict(glance.Span, girard.Resolution),
    /// The scheme of each top-level function and constant girard typed, by
    /// name.
    schemes: Dict(String, girard.Scheme),
    /// The definitions girard couldn't type, in source order.
    skipped: List(Skipped),
    /// The definitions girard left out for the other target.
    dropped: List(girard.Dropped),
    /// The modules girard couldn't use, imported directly or reached
    /// through other modules, sorted by module name.
    unavailable: List(girard.UnavailableModule),
    /// Whether girard typed every definition and could use every module it
    /// needed, as `girard.is_complete` says.
    complete: Bool,
  )
}

/// A top-level function or constant girard couldn't type.
pub type Skipped {
  Skipped(
    name: String,
    /// The definition's span, from its first keyword to its last token, so
    /// every span inside it lies inside this one.
    span: glance.Span,
    /// Why girard couldn't type it.
    error: girard.Error,
  )
}

/// Infer the types of the project's parsed load-set modules, in `order`,
/// with `resolver` answering for the modules they import from outside the
/// project, and index those of the lint set. A lint-set module that doesn't
/// parse, or that girard returned nothing for, has no entry.
pub fn infer(
  project: Project,
  resolver: girard.Resolver,
) -> Dict(String, ModuleTypes) {
  let target = project.config.target
  let options =
    girard.default_options()
    |> girard.with_resolver(resolver)
    |> girard.with_target(case target {
      config.Erlang -> girard.Erlang
      config.JavaScript -> girard.JavaScript
    })
  let results = girard.annotate_package(order(project), options)
  project.lint_set
  |> list.filter_map(fn(name) {
    use module <- result.try(dict.get(project.modules, name))
    use syntax <- result.try(result.replace_error(module.parsed, Nil))
    use found <- result.map(dict.get(results, name))
    #(name, index(found, loader.for_target(syntax, target)))
  })
  |> dict.from_list
}

/// The index of what girard found for a module, whose view for the target
/// is `view`. Skipped definitions are located by name in it: girard leaves
/// out the other target's definitions as the view does, so each one it
/// skipped is there.
@internal
pub fn index(found: girard.ModuleResult, view: glance.Module) -> ModuleTypes {
  let girard.ModuleResult(annotated:, skipped:) = found
  ModuleTypes(
    // `dict.from_list` keeps the last entry for a key, so the list is
    // reversed to keep the first.
    expressions: annotated.expressions
      |> list.reverse
      |> list.map(fn(annotation) { #(annotation.span, annotation.type_) })
      |> dict.from_list,
    resolutions: annotated.resolutions
      |> list.map(fn(reference) { #(reference.span, reference.resolution) })
      |> dict.from_list,
    schemes: dict.from_list(list.append(
      annotated.functions,
      annotated.constants,
    )),
    skipped: locate_skipped(view, dict.from_list(skipped)),
    dropped: annotated.dropped,
    unavailable: annotated.unavailable,
    complete: girard.is_complete(found),
  )
}

fn locate_skipped(
  view: glance.Module,
  skipped: Dict(String, girard.Error),
) -> List(Skipped) {
  let constants =
    list.map(view.constants, fn(constant) {
      #(constant.definition.name, constant.definition.location)
    })
  let functions =
    list.map(view.functions, fn(function) {
      #(function.definition.name, function.definition.location)
    })
  list.append(constants, functions)
  |> list.filter_map(fn(definition) {
    let #(name, span) = definition
    dict.get(skipped, name) |> result.map(Skipped(name:, span:, error: _))
  })
  |> list.sort(fn(left, right) {
    int.compare(left.span.start, right.span.start)
  })
}

// Order
//
// girard caches the interface of each module it has typed, so a module
// typed after the project modules it imports finds them all there. The
// order is a depth-first walk over each module's imports for the target,
// the same graph the loader followed, which has no cycle on either target
// even where the imports of both targets together would.

/// The parsed load-set modules, each after the parsed load-set modules it
/// imports for the target: a depth-first walk from each lint-set module in
/// turn. Each comes with its whole syntax tree, since girard leaves out
/// the other target's definitions itself and reports them as dropped.
pub fn order(project: Project) -> List(#(String, glance.Module)) {
  let #(_entered, ordered) =
    list.fold(project.lint_set, #(set.new(), []), fn(state, name) {
      walk(project.modules, name, state)
    })
  list.reverse(ordered)
}

// Add the module `name` after the modules it imports, unless the walk has
// entered it already: then it's either ordered, or still being walked, and
// the import that leads back to it closes a cycle, which the compiler
// rejects. `ordered` is newest first.
fn walk(
  modules: Dict(String, loader.Module),
  name: String,
  state: #(Set(String), List(#(String, glance.Module))),
) -> #(Set(String), List(#(String, glance.Module))) {
  let #(entered, ordered) = state
  use <- bool.guard(when: set.contains(entered, name), return: state)
  case dict.get(modules, name) {
    Ok(loader.Module(parsed: Ok(syntax), imports:, ..)) -> {
      let #(entered, ordered) =
        list.fold(
          imports,
          #(set.insert(entered, name), ordered),
          fn(state, import_name) { walk(modules, import_name, state) },
        )
      #(entered, [#(name, syntax), ..ordered])
    }
    // girard gets neither project modules that don't parse nor dependency
    // modules: the resolver answers for the latter.
    Ok(loader.Module(parsed: Error(_), ..)) | Error(Nil) -> state
  }
}

// Resolver
//
// What girard reads an imported module from when it isn't in its cache.

/// The resolver girard is given: the source of each dependency module, as
/// the loader read it. It never answers for a project module, parsed or
/// not. girard has every project module that parses from `order`, and it
/// reports one that doesn't parse as unavailable to the modules that
/// import it.
pub fn resolver(project: Project) -> girard.Resolver {
  let Project(modules:, dependencies:, ..) = project
  fn(name) {
    use <- bool.guard(when: dict.has_key(modules, name), return: Error(Nil))
    dict.get(dependencies, name)
  }
}
