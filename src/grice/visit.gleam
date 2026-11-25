//// A walk over a glance syntax tree that calls a hook for each node.
////
//// A `Visitor` holds one hook per kind of node, each a function from an
//// accumulator and the node to the new accumulator. `module` walks a whole
//// module and `expression` walks one expression, threading the accumulator
//// through every hook in the order the walk meets the nodes:
////
//// ```gleam
//// import glance
//// import grice/visit
////
//// pub fn count_calls(module: glance.Module) -> Int {
////   let visitor =
////     visit.new()
////     |> visit.on_expression(fn(count, expression) {
////       case expression {
////         glance.Call(..) -> count + 1
////         _ -> count
////       }
////     })
////   visit.module(module, from: 0, with: visitor)
//// }
//// ```
////
//// The walk follows source order. A module's definitions are walked in the
//// order they appear in the file, whatever their kind, and a node's children
//// in the order they're written. Each node's hook runs before its children
//// are walked. Functions and expressions also have an exit hook, which runs
//// after their children, so a hook can tell when it leaves a function, a
//// block or an anonymous function.
////
//// Some parts of the tree aren't nodes the walk visits. Attributes and their
//// arguments, on definitions and on custom type variants, aren't walked, so
//// `@external(erlang, "m", "f")` doesn't show `erlang` as a variable. The
//// sizes in a bit array pattern aren't walked either, because they're a type
//// of their own, but the size of a bit array expression is an expression and
//// is walked. A shorthand field such as `f(label:)` holds no node. Names
//// stored as plain strings on their parent, such as parameter names, `as`
//// names, labels, the names of an import and type parameters, are read from
//// the parent node.

import glance.{
  type Constant, type CustomType, type Definition, type Expression,
  type Function, type Import, type Pattern, type Statement, type Type,
  type TypeAlias,
}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}

// Visitors
//
// A visitor is a record of hooks, one per kind of node. A kind with no hook
// keeps the accumulator as it is, and adding a hook to a kind that has one
// runs the old hook first and then the new one.

/// The hooks to call during a walk, each returning the new accumulator.
/// Start from `new` and add hooks with the `on_*` functions.
pub opaque type Visitor(acc) {
  Visitor(
    import_: fn(acc, Definition(Import)) -> acc,
    custom_type: fn(acc, Definition(CustomType)) -> acc,
    type_alias: fn(acc, Definition(TypeAlias)) -> acc,
    constant: fn(acc, Definition(Constant)) -> acc,
    function: fn(acc, Definition(Function)) -> acc,
    function_exit: fn(acc, Definition(Function)) -> acc,
    statement: fn(acc, Statement) -> acc,
    expression: fn(acc, Expression) -> acc,
    expression_exit: fn(acc, Expression) -> acc,
    pattern: fn(acc, Pattern) -> acc,
    type_: fn(acc, Type) -> acc,
  )
}

/// A visitor with no hooks. Walking with it returns the accumulator it was
/// given.
pub fn new() -> Visitor(acc) {
  Visitor(
    import_: keep,
    custom_type: keep,
    type_alias: keep,
    constant: keep,
    function: keep,
    function_exit: keep,
    statement: keep,
    expression: keep,
    expression_exit: keep,
    pattern: keep,
    type_: keep,
  )
}

/// Call `hook` on each import, with its attributes. An import has no
/// children.
pub fn on_import(
  visitor: Visitor(acc),
  hook: fn(acc, Definition(Import)) -> acc,
) -> Visitor(acc) {
  Visitor(..visitor, import_: then(visitor.import_, hook))
}

/// Call `hook` on each custom type, with its attributes, before the types of
/// its variants' fields are walked.
pub fn on_custom_type(
  visitor: Visitor(acc),
  hook: fn(acc, Definition(CustomType)) -> acc,
) -> Visitor(acc) {
  Visitor(..visitor, custom_type: then(visitor.custom_type, hook))
}

/// Call `hook` on each type alias, with its attributes, before the aliased
/// type is walked.
pub fn on_type_alias(
  visitor: Visitor(acc),
  hook: fn(acc, Definition(TypeAlias)) -> acc,
) -> Visitor(acc) {
  Visitor(..visitor, type_alias: then(visitor.type_alias, hook))
}

/// Call `hook` on each constant, with its attributes, before its annotation
/// and its value are walked.
pub fn on_constant(
  visitor: Visitor(acc),
  hook: fn(acc, Definition(Constant)) -> acc,
) -> Visitor(acc) {
  Visitor(..visitor, constant: then(visitor.constant, hook))
}

/// Call `hook` on each function, with its attributes, before its parameter
/// annotations, its return annotation and its body are walked.
pub fn on_function(
  visitor: Visitor(acc),
  hook: fn(acc, Definition(Function)) -> acc,
) -> Visitor(acc) {
  Visitor(..visitor, function: then(visitor.function, hook))
}

/// Call `hook` on each function after its children have been walked.
pub fn on_function_exit(
  visitor: Visitor(acc),
  hook: fn(acc, Definition(Function)) -> acc,
) -> Visitor(acc) {
  Visitor(..visitor, function_exit: then(visitor.function_exit, hook))
}

/// Call `hook` on each statement of a function body, a block, an anonymous
/// function or a `use` callback, before the statement's children are
/// walked.
pub fn on_statement(
  visitor: Visitor(acc),
  hook: fn(acc, Statement) -> acc,
) -> Visitor(acc) {
  Visitor(..visitor, statement: then(visitor.statement, hook))
}

/// Call `hook` on each expression, before its children are walked.
pub fn on_expression(
  visitor: Visitor(acc),
  hook: fn(acc, Expression) -> acc,
) -> Visitor(acc) {
  Visitor(..visitor, expression: then(visitor.expression, hook))
}

/// Call `hook` on each expression after its children have been walked.
pub fn on_expression_exit(
  visitor: Visitor(acc),
  hook: fn(acc, Expression) -> acc,
) -> Visitor(acc) {
  Visitor(..visitor, expression_exit: then(visitor.expression_exit, hook))
}

/// Call `hook` on each pattern, in assignments, `use`, `case` clauses and
/// inside other patterns, before its children are walked.
pub fn on_pattern(
  visitor: Visitor(acc),
  hook: fn(acc, Pattern) -> acc,
) -> Visitor(acc) {
  Visitor(..visitor, pattern: then(visitor.pattern, hook))
}

/// Call `hook` on each type annotation and on each type inside one, before
/// its children are walked.
pub fn on_type(
  visitor: Visitor(acc),
  hook: fn(acc, Type) -> acc,
) -> Visitor(acc) {
  Visitor(..visitor, type_: then(visitor.type_, hook))
}

fn keep(acc: acc, _node: node) -> acc {
  acc
}

fn then(
  first: fn(acc, node) -> acc,
  second: fn(acc, node) -> acc,
) -> fn(acc, node) -> acc {
  fn(acc, node) { second(first(acc, node), node) }
}

// Walking
//
// The order and the parts walked are those of the module documentation.

/// Walk every definition of a module in source order, with its children,
/// and return the final accumulator.
///
/// glance keeps each kind of definition in its own list, so the walk merges
/// them by where they start in the source.
pub fn module(
  module: glance.Module,
  from acc: acc,
  with visitor: Visitor(acc),
) -> acc {
  module
  |> definitions
  |> list.fold(acc, fn(acc, definition) {
    walk_definition(acc, definition, visitor)
  })
}

/// Walk an expression and its children and return the final accumulator.
/// It's useful for looking inside a node from a hook, with a visitor of its
/// own.
pub fn expression(
  expression: Expression,
  from acc: acc,
  with visitor: Visitor(acc),
) -> acc {
  walk_expression(acc, expression, visitor)
}

/// Walk a pattern and the patterns inside it and return the final
/// accumulator.
@internal
pub fn pattern(
  pattern: Pattern,
  from acc: acc,
  with visitor: Visitor(acc),
) -> acc {
  walk_pattern(acc, pattern, visitor)
}

// A top-level definition of any kind.
type TopLevel {
  ImportDefinition(Definition(Import))
  CustomTypeDefinition(Definition(CustomType))
  TypeAliasDefinition(Definition(TypeAlias))
  ConstantDefinition(Definition(Constant))
  FunctionDefinition(Definition(Function))
}

// Every definition of a module, sorted by where it starts.
fn definitions(module: glance.Module) -> List(TopLevel) {
  [
    list.map(module.imports, ImportDefinition),
    list.map(module.custom_types, CustomTypeDefinition),
    list.map(module.type_aliases, TypeAliasDefinition),
    list.map(module.constants, ConstantDefinition),
    list.map(module.functions, FunctionDefinition),
  ]
  |> list.flatten
  |> list.sort(fn(left, right) { int.compare(start(left), start(right)) })
}

fn start(definition: TopLevel) -> Int {
  case definition {
    ImportDefinition(glance.Definition(definition:, ..)) ->
      definition.location.start
    CustomTypeDefinition(glance.Definition(definition:, ..)) ->
      definition.location.start
    TypeAliasDefinition(glance.Definition(definition:, ..)) ->
      definition.location.start
    ConstantDefinition(glance.Definition(definition:, ..)) ->
      definition.location.start
    FunctionDefinition(glance.Definition(definition:, ..)) ->
      definition.location.start
  }
}

fn walk_definition(
  acc: acc,
  definition: TopLevel,
  visitor: Visitor(acc),
) -> acc {
  case definition {
    ImportDefinition(import_) -> visitor.import_(acc, import_)
    CustomTypeDefinition(custom_type) ->
      visitor.custom_type(acc, custom_type)
      |> each(variant_field_types(custom_type.definition), visitor, walk_type)
    TypeAliasDefinition(type_alias) ->
      visitor.type_alias(acc, type_alias)
      |> walk_type(type_alias.definition.aliased, visitor)
    ConstantDefinition(constant) ->
      visitor.constant(acc, constant)
      |> maybe(constant.definition.annotation, visitor, walk_type)
      |> walk_expression(constant.definition.value, visitor)
    FunctionDefinition(function) -> {
      let glance.Function(parameters:, return:, body:, ..) = function.definition
      visitor.function(acc, function)
      |> each(
        option.values(list.map(parameters, fn(parameter) { parameter.type_ })),
        visitor,
        walk_type,
      )
      |> maybe(return, visitor, walk_type)
      |> each(body, visitor, walk_statement)
      |> visitor.function_exit(function)
    }
  }
}

fn variant_field_types(custom_type: CustomType) -> List(Type) {
  use variant <- list.flat_map(custom_type.variants)
  use field <- list.map(variant.fields)
  field.item
}

fn walk_statement(
  acc: acc,
  statement: Statement,
  visitor: Visitor(acc),
) -> acc {
  let acc = visitor.statement(acc, statement)
  case statement {
    glance.Use(patterns:, function:, ..) ->
      acc
      |> each(patterns, visitor, fn(acc, use_pattern, visitor) {
        acc
        |> walk_pattern(use_pattern.pattern, visitor)
        |> maybe(use_pattern.annotation, visitor, walk_type)
      })
      |> walk_expression(function, visitor)
    glance.Assignment(kind:, pattern:, annotation:, value:, ..) -> {
      let acc =
        acc
        |> walk_pattern(pattern, visitor)
        |> maybe(annotation, visitor, walk_type)
        |> walk_expression(value, visitor)
      case kind {
        glance.Let -> acc
        glance.LetAssert(message:) ->
          maybe(acc, message, visitor, walk_expression)
      }
    }
    glance.Assert(expression:, message:, ..) ->
      acc
      |> walk_expression(expression, visitor)
      |> maybe(message, visitor, walk_expression)
    glance.Expression(expression) -> walk_expression(acc, expression, visitor)
  }
}

fn walk_expression(
  acc: acc,
  expression: Expression,
  visitor: Visitor(acc),
) -> acc {
  let acc = visitor.expression(acc, expression)
  let acc = case expression {
    glance.Int(..)
    | glance.Float(..)
    | glance.String(..)
    | glance.Variable(..) -> acc
    glance.NegateInt(value:, ..) | glance.NegateBool(value:, ..) ->
      walk_expression(acc, value, visitor)
    glance.Block(statements:, ..) ->
      each(acc, statements, visitor, walk_statement)
    glance.Panic(message:, ..) | glance.Todo(message:, ..) ->
      maybe(acc, message, visitor, walk_expression)
    glance.Tuple(elements:, ..) -> each(acc, elements, visitor, walk_expression)
    glance.List(elements:, rest:, ..) ->
      acc
      |> each(elements, visitor, walk_expression)
      |> maybe(rest, visitor, walk_expression)
    glance.Fn(arguments:, return_annotation:, body:, ..) ->
      acc
      |> each(
        option.values(list.map(arguments, fn(argument) { argument.type_ })),
        visitor,
        walk_type,
      )
      |> maybe(return_annotation, visitor, walk_type)
      |> each(body, visitor, walk_statement)
    glance.RecordUpdate(record:, fields:, ..) ->
      acc
      |> walk_expression(record, visitor)
      // A shorthand field holds no expression.
      |> each(
        option.values(list.map(fields, fn(field) { field.item })),
        visitor,
        walk_expression,
      )
    glance.FieldAccess(container:, ..) ->
      walk_expression(acc, container, visitor)
    glance.Call(function:, arguments:, ..) ->
      acc
      |> walk_expression(function, visitor)
      |> each(field_items(arguments), visitor, walk_expression)
    glance.TupleIndex(tuple:, ..) -> walk_expression(acc, tuple, visitor)
    glance.FnCapture(function:, arguments_before:, arguments_after:, ..) ->
      acc
      |> walk_expression(function, visitor)
      |> each(field_items(arguments_before), visitor, walk_expression)
      |> each(field_items(arguments_after), visitor, walk_expression)
    glance.BitString(segments:, ..) ->
      each(acc, segments, visitor, fn(acc, segment, visitor) {
        let #(value, options) = segment
        acc
        |> walk_expression(value, visitor)
        |> each(list.filter_map(options, size_value), visitor, walk_expression)
      })
    glance.Case(subjects:, clauses:, ..) ->
      acc
      |> each(subjects, visitor, walk_expression)
      |> each(clauses, visitor, walk_clause)
    glance.BinaryOperator(left:, right:, ..) ->
      acc
      |> walk_expression(left, visitor)
      |> walk_expression(right, visitor)
    glance.Echo(expression:, message:, ..) ->
      acc
      |> maybe(expression, visitor, walk_expression)
      |> maybe(message, visitor, walk_expression)
  }
  visitor.expression_exit(acc, expression)
}

fn walk_clause(acc: acc, clause: glance.Clause, visitor: Visitor(acc)) -> acc {
  acc
  |> each(list.flatten(clause.patterns), visitor, walk_pattern)
  |> maybe(clause.guard, visitor, walk_expression)
  |> walk_expression(clause.body, visitor)
}

/// The expression of a segment's `size` option. The other options hold no
/// expression.
@internal
pub fn size_value(
  option: glance.BitStringSegmentOption(Expression),
) -> Result(Expression, Nil) {
  case option {
    glance.SizeValueOption(size) -> Ok(size)
    glance.BytesOption
    | glance.IntOption
    | glance.FloatOption
    | glance.BitsOption
    | glance.Utf8Option
    | glance.Utf16Option
    | glance.Utf32Option
    | glance.Utf8CodepointOption
    | glance.Utf16CodepointOption
    | glance.Utf32CodepointOption
    | glance.SignedOption
    | glance.UnsignedOption
    | glance.BigOption
    | glance.LittleOption
    | glance.NativeOption
    | glance.SizeOption(_)
    | glance.UnitOption(_) -> Error(Nil)
  }
}

fn walk_pattern(acc: acc, pattern: Pattern, visitor: Visitor(acc)) -> acc {
  let acc = visitor.pattern(acc, pattern)
  case pattern {
    glance.PatternInt(..)
    | glance.PatternFloat(..)
    | glance.PatternString(..)
    | glance.PatternDiscard(..)
    | glance.PatternVariable(..)
    | glance.PatternConcatenate(..) -> acc
    glance.PatternTuple(elements:, ..) ->
      each(acc, elements, visitor, walk_pattern)
    glance.PatternList(elements:, tail:, ..) ->
      acc
      |> each(elements, visitor, walk_pattern)
      |> maybe(tail, visitor, walk_pattern)
    glance.PatternAssignment(pattern:, ..) ->
      walk_pattern(acc, pattern, visitor)
    glance.PatternVariant(arguments:, ..) ->
      each(acc, field_items(arguments), visitor, walk_pattern)
    // A segment's options hold its size, which isn't a pattern.
    glance.PatternBitString(segments:, ..) ->
      each(
        acc,
        list.map(segments, fn(segment) { segment.0 }),
        visitor,
        walk_pattern,
      )
  }
}

fn walk_type(acc: acc, type_: Type, visitor: Visitor(acc)) -> acc {
  let acc = visitor.type_(acc, type_)
  case type_ {
    glance.NamedType(parameters:, ..) ->
      each(acc, parameters, visitor, walk_type)
    glance.TupleType(elements:, ..) -> each(acc, elements, visitor, walk_type)
    glance.FunctionType(parameters:, return:, ..) ->
      acc
      |> each(parameters, visitor, walk_type)
      |> walk_type(return, visitor)
    glance.VariableType(..) | glance.HoleType(..) -> acc
  }
}

/// The items of the fields that hold one. A shorthand field holds none.
@internal
pub fn field_items(fields: List(glance.Field(item))) -> List(item) {
  list.filter_map(fields, fn(field) {
    case field {
      glance.LabelledField(item:, ..) | glance.UnlabelledField(item:) ->
        Ok(item)
      glance.ShorthandField(..) -> Error(Nil)
    }
  })
}

fn each(
  acc: acc,
  nodes: List(node),
  visitor: Visitor(acc),
  walk: fn(acc, node, Visitor(acc)) -> acc,
) -> acc {
  case nodes {
    [] -> acc
    [node, ..rest] -> each(walk(acc, node, visitor), rest, visitor, walk)
  }
}

fn maybe(
  acc: acc,
  node: Option(node),
  visitor: Visitor(acc),
  walk: fn(acc, node, Visitor(acc)) -> acc,
) -> acc {
  case node {
    Some(node) -> walk(acc, node, visitor)
    None -> acc
  }
}
