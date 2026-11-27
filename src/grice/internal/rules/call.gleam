//// Calls of module functions, as the simplify pack's rules read them: the
//// function girard resolved the callee to, and the arguments in source
//// order, however the call is written.
////
//// A call is read in four forms:
////
//// - direct, `f(a, b)`;
//// - a pipe into the function, `a |> f`;
//// - a pipe into a call, `a |> f(b)` or `a |> f()`, where the piped value
////   is the first positional argument, before the call's own;
//// - a pipe into a capture, `a |> f(b, _)`, where the piped value takes
////   the placeholder's place, with its label if it has one.
////
//// A capture is read only at the pipe that feeds it. Every other form,
//// such as a `use`, a block or a capture on its own, is not a call here.
//// So two calls that a block, a `use` or a `let` stands between, as in
//// `list.first({ list.reverse(xs) })`, aren't read as one on the other,
//// and the rules stay silent on them. A whole composition inside a block
//// is still read.
////
//// The reader doesn't check how many arguments a call has: each rule
//// checks its functions' counts, and a call read with another count isn't
//// one. That rejects the deprecated pipe `a |> f(b)` that calls the result
//// of `f(b)` with `a`, which has one argument too many, and keeps the
//// right-hand side of a pipe, which is one argument short on its own, from
//// being read a second time when the walk reaches it.
////
//// The module also holds what the pack's rules share beyond reading a
//// call: a call of a call, the hint's sentences on labels, and the rule
//// that stays silent inside the function its hint recommends.

import girard
import glance
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import grice/facts.{type ModuleFacts, type Typed}
import grice/rule.{type Report, type Rule}

/// A call of a module function, as girard resolved its callee.
pub type Call {
  Call(
    module: String,
    name: String,
    /// The whole call when it's direct, the part after `|>` when it's
    /// piped: `list.map(f)` in `xs |> list.map(f)`.
    span: glance.Span,
    /// In source order, with a piped value put where it goes.
    arguments: List(Argument),
  )
}

/// One argument of a call.
pub type Argument {
  Argument(
    label: Option(String),
    value: glance.Expression,
    /// Whether the pipe supplied it: the piped value, put first or in a
    /// capture's placeholder.
    piped: Bool,
    form: Form,
  )
}

/// How an argument is written, which a hint that edits it in place needs.
pub type Form {
  /// An expression, labelled or not.
  Written
  /// A shorthand `label:`, whose value is the variable of that name.
  Shorthand
  /// A capture's placeholder, `_` or `label: _`, whose value is the piped
  /// value.
  Placeholder
}

/// `expression` as a call of a module function, in one of the four forms.
pub fn read(
  expression: glance.Expression,
  module_facts: ModuleFacts(Typed),
) -> Result(Call, Nil) {
  case expression {
    glance.Call(location:, function:, arguments:) -> {
      use #(module, name) <- result.map(module_function(function, module_facts))
      Call(module:, name:, span: location, arguments: fields(arguments))
    }
    glance.BinaryOperator(name: glance.Pipe, left:, right:, ..) ->
      piped(left, right, module_facts)
    _ -> Error(Nil)
  }
}

/// The argument for `parameter`, given the labels of the function's
/// parameters in order, as Gleam matches them: a labelled argument by its
/// label, and the others in order into the parameters left.
pub fn argument(
  call: Call,
  parameters: List(String),
  parameter: String,
) -> Result(Argument, Nil) {
  use <- result.lazy_or(labelled(call, parameter))
  let taken =
    list.filter_map(call.arguments, fn(argument) {
      option.to_result(argument.label, Nil)
    })
  let positional =
    list.filter(call.arguments, fn(argument) { argument.label == None })
  parameters
  |> list.filter(fn(name) { !list.contains(taken, name) })
  |> list.zip(positional)
  |> list.key_find(parameter)
}

/// The module and name of the module function girard resolved
/// `reference`, a name or a module access, to.
pub fn module_function(
  reference: glance.Expression,
  module_facts: ModuleFacts(Typed),
) -> Result(#(String, String), Nil) {
  case facts.resolution_of(module_facts, reference.location) {
    Ok(girard.ModuleFn(module:, name:)) -> Ok(#(module, name))
    _ -> Error(Nil)
  }
}

// A pipe `left |> right`, read as a call of the function `right` names.
fn piped(
  left: glance.Expression,
  right: glance.Expression,
  module_facts: ModuleFacts(Typed),
) -> Result(Call, Nil) {
  let first = Argument(label: None, value: left, piped: True, form: Written)
  case right {
    glance.Call(location:, function:, arguments:) -> {
      use #(module, name) <- result.map(module_function(function, module_facts))
      Call(module:, name:, span: location, arguments: [
        first,
        ..fields(arguments)
      ])
    }
    glance.FnCapture(
      location:,
      label:,
      function:,
      arguments_before:,
      arguments_after:,
    ) -> {
      use #(module, name) <- result.map(module_function(function, module_facts))
      let placeholder =
        Argument(label:, value: left, piped: True, form: Placeholder)
      let arguments =
        list.flatten([
          fields(arguments_before),
          [placeholder],
          fields(arguments_after),
        ])
      Call(module:, name:, span: location, arguments:)
    }
    _ -> {
      use #(module, name) <- result.map(module_function(right, module_facts))
      Call(module:, name:, span: right.location, arguments: [first])
    }
  }
}

// A call's fields as arguments. A shorthand field holds no expression in
// glance: its value is the variable of its name, at its span.
fn fields(fields: List(glance.Field(glance.Expression))) -> List(Argument) {
  list.map(fields, fn(field) {
    case field {
      glance.UnlabelledField(item:) ->
        Argument(label: None, value: item, piped: False, form: Written)
      glance.LabelledField(label:, item:, ..) ->
        Argument(label: Some(label), value: item, piped: False, form: Written)
      glance.ShorthandField(label:, location:) ->
        Argument(
          label: Some(label),
          value: glance.Variable(location:, name: label),
          piped: False,
          form: Shorthand,
        )
    }
  })
}

// Compositions
//
// A call of one function on the result of another, which a single standard
// library function does: `list.flatten(list.map(xs, f))`, or
// `xs |> list.map(f) |> list.flatten`.

/// A call whose only argument is itself a call, and the span from the
/// earlier call's span to the later's, which covers
/// `list.flatten(list.map(xs, f))` whole and `list.map(f) |> list.flatten`
/// in a pipe, without the value piped in.
pub type Composition {
  Composition(outer: Call, inner: Call, span: glance.Span)
}

/// `expression` as a call of one of `outer`, each `#(module, name)`, whose
/// only argument, labelled or not, is a call, both read as `read` reads
/// them.
pub fn composition(
  expression: glance.Expression,
  module_facts: ModuleFacts(Typed),
  outer functions: List(#(String, String)),
) -> Result(Composition, Nil) {
  case read(expression, module_facts) {
    Ok(Call(module:, name:, span:, arguments: [argument]) as outer) ->
      case list.contains(functions, #(module, name)) {
        True ->
          read(argument.value, module_facts)
          |> result.map(fn(inner) {
            Composition(outer:, inner:, span: cover(span, inner.span))
          })
        False -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

// From the earlier start to the later end of two spans.
fn cover(a: glance.Span, b: glance.Span) -> glance.Span {
  glance.Span(start: int.min(a.start, b.start), end: int.max(a.end, b.end))
}

// Relabelling
//
// A hint that rewrites a call in place, to a function whose parameters
// have other labels, says how to rewrite each labelled argument so it
// keeps its value. It never writes out the user's code.

/// The sentences that rewrite the labels of `call` for a function that
/// takes its first parameter unlabelled, where `call`'s function labels it
/// `first`, and calls each `#(old, new)` of `renamed` `new`: one sentence
/// per such argument, the first parameter's first. A shorthand keeps its
/// variable, and a placeholder labelled `first` is dropped, so the piped
/// value goes first.
pub fn relabel(
  call: Call,
  first first: Option(String),
  renamed renamed: List(#(String, String)),
) -> List(String) {
  let moved = case first {
    Some(first) -> labelled(call, first) |> result.map(move(_, first))
    None -> Error(Nil)
  }
  let renamed =
    list.filter_map(renamed, fn(rename) {
      let #(old, new) = rename
      labelled(call, old) |> result.map(rename_to(_, old, new))
    })
  case moved {
    Ok(sentence) -> [sentence, ..renamed]
    Error(Nil) -> renamed
  }
}

fn labelled(call: Call, label: String) -> Result(Argument, Nil) {
  list.find(call.arguments, fn(argument) { argument.label == Some(label) })
}

// A positional argument can't follow a labelled one, so the first
// parameter's value moves to the front.
fn move(argument: Argument, label: String) -> String {
  case argument.form {
    Written -> "Move the `" <> label <> ":` value first, without its label."
    Shorthand -> "Move `" <> label <> ":` first, as `" <> label <> "`."
    Placeholder -> "Drop `" <> label <> ": _`; the piped value goes first."
  }
}

fn rename_to(argument: Argument, old: String, new: String) -> String {
  case argument.form {
    Written -> "Write `" <> old <> ":` as `" <> new <> ":`."
    Shorthand -> "Write `" <> old <> ":` as `" <> new <> ": " <> old <> "`."
    Placeholder -> "Write `" <> old <> ": _` as `" <> new <> ": _`."
  }
}

// The function a hint recommends
//
// A rule stays silent inside the function its hint recommends, which may
// well be written as the code the rule flags: the standard library's
// `list.flat_map` is `flatten(map(list, fun))`.

/// The typed module rule of `schema` that reports what `check` finds in
/// each expression, except inside the top-level functions of
/// `recommended`, each `#(module, name)`.
pub fn build(
  schema: rule.Schema(rule.ModuleForm, Typed),
  silent_inside recommended: List(#(String, String)),
  on_expression check: fn(glance.Expression, ModuleFacts(Typed)) -> List(Report),
) -> Rule {
  schema
  // Whether the walk is inside one of `recommended`.
  |> rule.with_context(initial: False)
  |> rule.on_function(fn(_exempt, function, module_facts) {
    #(defines(module_facts, function, recommended), [])
  })
  |> rule.on_function_exit(fn(_exempt, _function, _module_facts) {
    #(False, [])
  })
  |> rule.on_expression(fn(exempt, expression, module_facts) {
    case exempt {
      True -> #(exempt, [])
      False -> #(exempt, check(expression, module_facts))
    }
  })
  |> rule.build
}

/// Whether `function`, a top-level function of the module of
/// `module_facts`, is one of `functions`, each `#(module, name)`.
pub fn defines(
  module_facts: ModuleFacts(kind),
  function: glance.Definition(glance.Function),
  functions: List(#(String, String)),
) -> Bool {
  list.contains(functions, #(
    facts.module_name(module_facts),
    function.definition.name,
  ))
}
