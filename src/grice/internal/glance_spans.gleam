//// A workaround for a glance bug on JavaScript, where a string literal
//// outside ASCII gets a wrong span (lpil/glance#47).
////
//// glexer, the lexer glance uses, counts UTF-16 code units on JavaScript,
//// and glance ends a string literal at its start plus the UTF-8 byte size
//// of its text. So the end of such a literal, and of every node that takes
//// its end, such as a `let`, an `echo` or a constant, is neither bytes nor
//// code units. Two nodes can even share a span: in
//// `"\u{E9}\u{E9}\u{E9}\u{E9}\u{E9}" == x`, the literal's wrong end is
//// the comparison's end, and girard's index, keyed by spans, then gives
//// both the type of one of them.
////
//// `correct` rebuilds a module children first, so every span counts code
//// units: a literal ends at its start plus the UTF-16 length of its source
//// text and its two quotes, and a node whose end glance takes from a child
//// takes its corrected child's end. Every other span ends at a token
//// glexer placed, or after an ASCII name or number, so it's already right
//// and is kept. A tree that's already right comes out unchanged, so the
//// correction gives the same tree whichever glance release built it.

import glance.{type Expression, type Pattern, type Statement}
import gleam/function
import gleam/list
import gleam/option.{type Option, None, Some}
import grice/internal/line_index

/// `module` with every span counted in UTF-16 code units, as glexer counts
/// them on JavaScript. Run it on a module glance parsed on JavaScript from
/// a source with a character outside ASCII: elsewhere, glance's spans are
/// already right.
pub fn correct(module: glance.Module) -> glance.Module {
  glance.Module(
    imports: list.map(module.imports, definition(_, function.identity)),
    custom_types: list.map(module.custom_types, definition(_, custom_type)),
    type_aliases: list.map(module.type_aliases, definition(_, function.identity)),
    constants: list.map(module.constants, definition(_, constant)),
    functions: list.map(module.functions, definition(_, function)),
  )
}

// Definitions
//
// Imports and type aliases hold no expression, but their attributes may,
// as variants' attributes may.

fn definition(
  definition: glance.Definition(a),
  correct: fn(a) -> a,
) -> glance.Definition(a) {
  glance.Definition(
    attributes: list.map(definition.attributes, attribute),
    definition: correct(definition.definition),
  )
}

fn attribute(attribute: glance.Attribute) -> glance.Attribute {
  glance.Attribute(
    ..attribute,
    arguments: list.map(attribute.arguments, expression),
  )
}

fn custom_type(custom_type: glance.CustomType) -> glance.CustomType {
  glance.CustomType(
    ..custom_type,
    variants: list.map(custom_type.variants, fn(variant) {
      glance.Variant(
        ..variant,
        attributes: list.map(variant.attributes, attribute),
      )
    }),
  )
}

// A constant ends with its value.
fn constant(constant: glance.Constant) -> glance.Constant {
  let value = expression(constant.value)
  glance.Constant(
    ..constant,
    location: end_at(constant.location, value),
    value:,
  )
}

fn function(function: glance.Function) -> glance.Function {
  glance.Function(..function, body: list.map(function.body, statement))
}

// Statements
//
// A `use` ends with its function, a `let` with its value or its message,
// and an `assert` with its subject or its message.

fn statement(node: Statement) -> Statement {
  case node {
    glance.Use(location:, patterns:, function:) -> {
      let function = expression(function)
      glance.Use(
        location: end_at(location, function),
        patterns: list.map(patterns, fn(use_pattern) {
          glance.UsePattern(
            ..use_pattern,
            pattern: pattern(use_pattern.pattern),
          )
        }),
        function:,
      )
    }
    glance.Assignment(location:, kind:, pattern: assigned, annotation:, value:) -> {
      let value = expression(value)
      let #(kind, last) = case kind {
        glance.LetAssert(message: Some(message)) -> {
          let message = expression(message)
          #(glance.LetAssert(message: Some(message)), message)
        }
        glance.LetAssert(message: None) | glance.Let -> #(kind, value)
      }
      glance.Assignment(
        location: end_at(location, last),
        kind:,
        pattern: pattern(assigned),
        annotation:,
        value:,
      )
    }
    glance.Assert(location:, expression: subject, message:) -> {
      let subject = expression(subject)
      let message = option.map(message, expression)
      glance.Assert(
        location: end_at(location, option.unwrap(message, subject)),
        expression: subject,
        message:,
      )
    }
    glance.Expression(inner) -> glance.Expression(expression(inner))
  }
}

// Expressions
//
// A string literal's end is worked out from its text. A negation ends
// with its operand, a binary operator with its right operand, an `echo`
// with its message or its expression, and a `panic` or a `todo` with its
// message. Every other expression keeps its span.

fn expression(node: Expression) -> Expression {
  case node {
    glance.Int(..) | glance.Float(..) | glance.Variable(..) -> node
    glance.String(location:, value:) ->
      glance.String(..node, location: string_span(location, value))
    glance.NegateInt(location:, value:) -> {
      let value = expression(value)
      glance.NegateInt(location: end_at(location, value), value:)
    }
    glance.NegateBool(location:, value:) -> {
      let value = expression(value)
      glance.NegateBool(location: end_at(location, value), value:)
    }
    glance.Block(statements:, ..) ->
      glance.Block(..node, statements: list.map(statements, statement))
    glance.Panic(location:, message:) -> {
      let message = option.map(message, expression)
      glance.Panic(location: end_with(location, message), message:)
    }
    glance.Todo(location:, message:) -> {
      let message = option.map(message, expression)
      glance.Todo(location: end_with(location, message), message:)
    }
    glance.Tuple(elements:, ..) ->
      glance.Tuple(..node, elements: list.map(elements, expression))
    glance.List(elements:, rest:, ..) ->
      glance.List(
        ..node,
        elements: list.map(elements, expression),
        rest: option.map(rest, expression),
      )
    glance.Fn(body:, ..) -> glance.Fn(..node, body: list.map(body, statement))
    glance.RecordUpdate(record:, fields:, ..) ->
      glance.RecordUpdate(
        ..node,
        record: expression(record),
        fields: list.map(fields, fn(field) {
          glance.RecordUpdateField(
            ..field,
            item: option.map(field.item, expression),
          )
        }),
      )
    glance.FieldAccess(container:, ..) ->
      glance.FieldAccess(..node, container: expression(container))
    glance.Call(function:, arguments:, ..) ->
      glance.Call(
        ..node,
        function: expression(function),
        arguments: list.map(arguments, field(_, expression)),
      )
    glance.TupleIndex(tuple:, ..) ->
      glance.TupleIndex(..node, tuple: expression(tuple))
    glance.FnCapture(function:, arguments_before:, arguments_after:, ..) ->
      glance.FnCapture(
        ..node,
        function: expression(function),
        arguments_before: list.map(arguments_before, field(_, expression)),
        arguments_after: list.map(arguments_after, field(_, expression)),
      )
    glance.BitString(segments:, ..) ->
      glance.BitString(
        ..node,
        segments: list.map(segments, fn(segment) {
          let #(value, options) = segment
          #(expression(value), list.map(options, segment_option))
        }),
      )
    glance.Case(subjects:, clauses:, ..) ->
      glance.Case(
        ..node,
        subjects: list.map(subjects, expression),
        clauses: list.map(clauses, clause),
      )
    glance.BinaryOperator(location:, left:, right:, ..) -> {
      let right = expression(right)
      glance.BinaryOperator(
        ..node,
        location: end_at(location, right),
        left: expression(left),
        right:,
      )
    }
    glance.Echo(location:, expression: echoed, message:) -> {
      let echoed = option.map(echoed, expression)
      let message = option.map(message, expression)
      glance.Echo(
        location: end_with(location, option.or(message, echoed)),
        expression: echoed,
        message:,
      )
    }
  }
}

fn clause(clause: glance.Clause) -> glance.Clause {
  glance.Clause(
    patterns: list.map(clause.patterns, list.map(_, pattern)),
    guard: option.map(clause.guard, expression),
    body: expression(clause.body),
  )
}

fn field(field: glance.Field(t), correct: fn(t) -> t) -> glance.Field(t) {
  case field {
    glance.LabelledField(item:, ..) ->
      glance.LabelledField(..field, item: correct(item))
    glance.ShorthandField(..) -> field
    glance.UnlabelledField(item:) -> glance.UnlabelledField(correct(item))
  }
}

// Only a size option holds an expression.
fn segment_option(
  option: glance.BitStringSegmentOption(Expression),
) -> glance.BitStringSegmentOption(Expression) {
  case option {
    glance.SizeValueOption(size) -> glance.SizeValueOption(expression(size))
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
    | glance.UnitOption(_) -> option
  }
}

// Patterns
//
// A string pattern's end is worked out from its text, and every other
// pattern keeps its span: a concatenation such as `"\u{E9}" <> rest` ends
// with the name after it. The sizes in a bit array pattern hold no string.

fn pattern(node: Pattern) -> Pattern {
  case node {
    glance.PatternInt(..)
    | glance.PatternFloat(..)
    | glance.PatternDiscard(..)
    | glance.PatternVariable(..)
    | glance.PatternConcatenate(..) -> node
    glance.PatternString(location:, value:) ->
      glance.PatternString(..node, location: string_span(location, value))
    glance.PatternTuple(elements:, ..) ->
      glance.PatternTuple(..node, elements: list.map(elements, pattern))
    glance.PatternList(elements:, tail:, ..) ->
      glance.PatternList(
        ..node,
        elements: list.map(elements, pattern),
        tail: option.map(tail, pattern),
      )
    glance.PatternAssignment(pattern: assigned, ..) ->
      glance.PatternAssignment(..node, pattern: pattern(assigned))
    glance.PatternBitString(segments:, ..) ->
      glance.PatternBitString(
        ..node,
        segments: list.map(segments, fn(segment) {
          let #(value, options) = segment
          #(pattern(value), options)
        }),
      )
    glance.PatternVariant(arguments:, ..) ->
      glance.PatternVariant(
        ..node,
        arguments: list.map(arguments, field(_, pattern)),
      )
  }
}

// Spans

// A string literal's span: its text as written between the quotes, escapes
// included, and the two quotes.
fn string_span(location: glance.Span, text: String) -> glance.Span {
  glance.Span(
    ..location,
    end: location.start + line_index.utf16_length(text) + 2,
  )
}

// `location`, ending where `last` ends.
fn end_at(location: glance.Span, last: Expression) -> glance.Span {
  glance.Span(..location, end: last.location.end)
}

// `location`, ending where `last` ends when there's one.
fn end_with(location: glance.Span, last: Option(Expression)) -> glance.Span {
  case last {
    Some(last) -> end_at(location, last)
    None -> location
  }
}
