//// `grice_rules/check-then-assert`: a `Result` or an `Option` tested with
//// a standard library predicate, and then `let assert`-ed, on a path
//// where the test already proved the asserted variant.
////
//// It's typed, and walks each top-level function itself, since what it
//// needs holds along a path: inside a `case` clause, a guard's callback
//// or a `use` continuation. The walk keeps the function's local bindings
//// in scope, by name, so a binding that shadows another starts with
//// nothing known about it, and for each binding what is known on the
//// current path:
////
//// - whether it's eligible. The compiler infers a variable's variant from
////   a constructor and from what narrows it, and then warns on a
////   redundant assertion itself. So only a parameter, of the function, an
////   anonymous function or a `use` callback, and a `let` of a call or a
////   pipe whose callee girard resolved to a module function are eligible.
//// - whether it's narrowed: matched against a constructor by an earlier
////   `let assert` or an enclosing `case` clause on the path, directly or
////   through `echo`, which tells the compiler its variant.
//// - the variant a check proved, and where the check is.
////
//// A check is `result.is_ok`, `result.is_error`, `option.is_some` or
//// `option.is_none`, by resolution, on a bare variable, called directly or
//// as the function after a pipe, and optionally negated with `!`. It
//// proves a variant along these paths:
////
//// - a `case` on the check, with one subject: a clause whose only pattern
////   is `True` or `False` proves that value, guard or not; a discard or a
////   variable proves the other value only after a clause matched one with
////   a lone pattern and no guard; alternatives prove nothing.
//// - `bool.guard` and `bool.lazy_guard`, by resolution: their arguments
////   are placed in their slots as the compiler places them, labelled ones
////   first, then the unlabelled ones and a `use` continuation in the slots
////   left, in order. `guard`'s `return` is a value,
////   computed before the check, so it's on no path; each other slot runs
////   when the check is true (`lazy_guard`'s `return`) or false (both
////   `otherwise`). Only an anonymous function or a `use` continuation in
////   a slot has a body to walk; a shorthand argument, such as `return:`,
////   is a name, opaque.
////
//// A finding is `let assert P = x` where the check proved the variant `P`
//// asks for, with only discards and variables inside it, and `x` is a
//// `Result` or an `Option`. `P`'s constructor is resolved through the
//// module's imports, not by its written name: girard records no
//// resolution for a constructor in a pattern. Wherever something is
//// unclear, the rule is silent.

import girard
import glance
import gleam/bool
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import grice/facts.{type ModuleFacts, type Typed}
import grice/internal/type_names
import grice/rule.{type Report, type Rule}
import grice/visit

const code = "grice_rules/check-then-assert"

/// The rule.
pub fn rule() -> Rule {
  rule.module(code, title: "Check then assert")
  |> rule.typed
  |> rule.with_context(initial: Nil)
  |> rule.on_function(fn(context, function, module_facts) {
    #(context, check_function(function.definition, module_facts))
  })
  |> rule.build
}

fn check_function(
  function: glance.Function,
  module_facts: ModuleFacts(Typed),
) -> List(Report) {
  // A check calls a function of `gleam/result` or `gleam/option`, which a
  // module can only call by importing it.
  let imports = facts.imports(module_facts)
  use <- bool.guard(
    when: !list.contains(imports, "gleam/result")
      && !list.contains(imports, "gleam/option"),
    return: [],
  )
  let scope =
    list.fold(function.parameters, dict.new(), fn(scope, parameter) {
      bind_name(scope, parameter.name, eligible: True)
    })
  walk_statements(function.body, Env(facts: module_facts, scope:))
}

// The walk
//
// Each part of the body is walked with the bindings in scope there and
// what's known about them on the path. A sequence of statements threads
// them through, since a `let` binds for the statements after it; a nested
// expression gets them and gives nothing back, as nothing it binds
// escapes it.

type Env {
  Env(facts: ModuleFacts(Typed), scope: Dict(String, Binding))
}

// What the walk knows about a local binding on the current path.
type Binding {
  Binding(eligible: Bool, narrowed: Bool, proven: Option(Proof))
}

// The variant a check proved, and the check's span.
type Proof {
  Proof(variant: Variant, check: glance.Span)
}

// A variant of `Result` or `Option`.
type Variant {
  ResultOk
  ResultError
  OptionSome
  OptionNone
}

fn walk_statements(body: List(glance.Statement), env: Env) -> List(Report) {
  walk_statements_loop(body, env, [])
}

// Tail-recursive, so a long body can't run out of stack on JavaScript.
fn walk_statements_loop(
  body: List(glance.Statement),
  env: Env,
  found: List(List(Report)),
) -> List(Report) {
  case body {
    [] -> list.flatten(list.reverse(found))
    [glance.Use(patterns:, function:, ..), ..rest] ->
      list.flatten(
        list.reverse([walk_use(patterns, function, rest, env), ..found]),
      )
    [statement, ..rest] -> {
      let #(reports, env) = walk_statement(statement, env)
      walk_statements_loop(rest, env, [reports, ..found])
    }
  }
}

fn walk_statement(
  statement: glance.Statement,
  env: Env,
) -> #(List(Report), Env) {
  case statement {
    glance.Assignment(kind:, pattern:, value:, location:, ..) -> {
      let reports = case kind {
        glance.Let -> walk_expression(value, env)
        glance.LetAssert(message:) ->
          list.flatten([
            walk_expression(value, env),
            walk_optional(message, env),
            assertion(pattern, value, location, env),
          ])
      }
      #(reports, assigned(kind, pattern, value, env))
    }
    glance.Assert(expression: asserted, message:, ..) -> #(
      list.append(walk_expression(asserted, env), walk_optional(message, env)),
      env,
    )
    glance.Expression(inner) -> #(walk_expression(inner, env), env)
    // `walk_statements_loop` walks a `use` with its continuation.
    glance.Use(..) -> #([], env)
  }
}

// The scope after an assignment: an asserted variable is narrowed, and
// then the pattern's names are bound. Only `let x = f(..)`, with `f` a
// module function, binds an eligible name.
fn assigned(
  kind: glance.AssignmentKind,
  pattern: glance.Pattern,
  value: glance.Expression,
  env: Env,
) -> Env {
  let env = case
    kind,
    narrowing_subject(value),
    matches_a_constructor(pattern)
  {
    glance.LetAssert(..), Ok(name), True -> narrow(env, name)
    _, _, _ -> env
  }
  case kind, pattern {
    glance.Let, glance.PatternVariable(name:, ..) ->
      set(env, name, fresh(eligible: calls_a_module_function(value, env.facts)))
    _, _ -> bind_pattern(env, pattern)
  }
}

// A `use`: its function is called with the continuation, the statements
// after it, as a callback taking the `use` patterns. A guard runs the
// continuation on one side of its check.
fn walk_use(
  patterns: List(glance.UsePattern),
  function: glance.Expression,
  continuation: List(glance.Statement),
  env: Env,
) -> List(Report) {
  let #(reports, continuation_env) = case
    guard(function, implicit: True, module_facts: env.facts)
  {
    Ok(#(return_side, slots)) -> walk_guard(return_side, slots, env)
    Error(Nil) -> #(walk_expression(function, env), env)
  }
  let continuation_env =
    list.fold(patterns, continuation_env, fn(env, use_pattern) {
      case use_pattern.pattern {
        glance.PatternVariable(name:, ..) ->
          set(env, name, fresh(eligible: True))
        pattern -> bind_pattern(env, pattern)
      }
    })
  list.append(reports, walk_statements(continuation, continuation_env))
}

fn walk_expression(expression: glance.Expression, env: Env) -> List(Report) {
  case expression {
    glance.Int(..)
    | glance.Float(..)
    | glance.String(..)
    | glance.Variable(..) -> []
    glance.NegateInt(value:, ..) | glance.NegateBool(value:, ..) ->
      walk_expression(value, env)
    glance.Block(statements: body, ..) -> walk_statements(body, env)
    glance.Panic(message:, ..) | glance.Todo(message:, ..) ->
      walk_optional(message, env)
    glance.Tuple(elements:, ..) -> walk_each(elements, env)
    glance.List(elements:, rest:, ..) ->
      list.append(walk_each(elements, env), walk_optional(rest, env))
    glance.Fn(arguments:, body:, ..) ->
      walk_anonymous_function(arguments, body, env)
    glance.RecordUpdate(record:, fields:, ..) ->
      list.append(
        walk_expression(record, env),
        walk_each(
          option.values(list.map(fields, fn(field) { field.item })),
          env,
        ),
      )
    glance.FieldAccess(container:, ..) -> walk_expression(container, env)
    glance.Call(function: callee, arguments:, ..) ->
      case guard(expression, implicit: False, module_facts: env.facts) {
        Ok(#(return_side, slots)) -> walk_guard(return_side, slots, env).0
        Error(Nil) ->
          list.append(
            walk_expression(callee, env),
            walk_each(visit.field_items(arguments), env),
          )
      }
    glance.TupleIndex(tuple:, ..) -> walk_expression(tuple, env)
    glance.FnCapture(function:, arguments_before:, arguments_after:, ..) ->
      list.flatten([
        walk_expression(function, env),
        walk_each(visit.field_items(arguments_before), env),
        walk_each(visit.field_items(arguments_after), env),
      ])
    glance.BitString(segments:, ..) ->
      list.flat_map(segments, fn(segment) {
        let #(value, options) = segment
        list.append(
          walk_expression(value, env),
          walk_each(list.filter_map(options, visit.size_value), env),
        )
      })
    glance.Case(subjects:, clauses:, ..) -> walk_case(subjects, clauses, env)
    glance.BinaryOperator(left:, right:, ..) ->
      list.append(walk_expression(left, env), walk_expression(right, env))
    glance.Echo(expression: echoed, message:, ..) ->
      list.append(walk_optional(echoed, env), walk_optional(message, env))
  }
}

fn walk_anonymous_function(
  arguments: List(glance.FnParameter),
  body: List(glance.Statement),
  env: Env,
) -> List(Report) {
  let scope =
    list.fold(arguments, env.scope, fn(scope, argument) {
      bind_name(scope, argument.name, eligible: True)
    })
  walk_statements(body, Env(..env, scope:))
}

fn walk_each(expressions: List(glance.Expression), env: Env) -> List(Report) {
  list.flat_map(expressions, walk_expression(_, env))
}

fn walk_optional(
  expression: Option(glance.Expression),
  env: Env,
) -> List(Report) {
  case expression {
    Some(inner) -> walk_expression(inner, env)
    None -> []
  }
}

// Bindings
//
// Each name a pattern or a parameter binds replaces what the scope held
// for it, so a shadowing binding starts with nothing known.

fn fresh(eligible eligible: Bool) -> Binding {
  Binding(eligible:, narrowed: False, proven: None)
}

fn set(env: Env, name: String, binding: Binding) -> Env {
  Env(..env, scope: dict.insert(env.scope, name, binding))
}

fn bind_name(
  scope: Dict(String, Binding),
  name: glance.AssignmentName,
  eligible eligible: Bool,
) -> Dict(String, Binding) {
  case name {
    glance.Named(name) -> dict.insert(scope, name, fresh(eligible:))
    glance.Discarded(_) -> scope
  }
}

// Bind every name `pattern` binds, none of them eligible.
fn bind_pattern(env: Env, pattern: glance.Pattern) -> Env {
  visit.pattern(pattern, from: env, with: binding_names())
}

// A visitor that binds each name a pattern binds: a variable, an `as`
// name, a string prefix and its rest, and a shorthand field.
fn binding_names() -> visit.Visitor(Env) {
  use env, pattern <- visit.on_pattern(visit.new())
  let names = case pattern {
    glance.PatternVariable(name:, ..) | glance.PatternAssignment(name:, ..) -> [
      glance.Named(name),
    ]
    glance.PatternConcatenate(prefix_name:, rest_name:, ..) ->
      option.values([prefix_name, Some(rest_name)])
    glance.PatternVariant(arguments:, ..) ->
      list.filter_map(arguments, fn(argument) {
        case argument {
          glance.ShorthandField(label:, ..) -> Ok(glance.Named(label))
          glance.LabelledField(..) | glance.UnlabelledField(..) -> Error(Nil)
        }
      })
    _ -> []
  }
  Env(
    ..env,
    scope: list.fold(names, env.scope, fn(scope, name) {
      bind_name(scope, name, eligible: False)
    }),
  )
}

// Whether matching `pattern` tells the compiler the value's variant.
fn matches_a_constructor(pattern: glance.Pattern) -> Bool {
  case pattern {
    glance.PatternVariant(..) -> True
    glance.PatternAssignment(pattern:, ..) -> matches_a_constructor(pattern)
    _ -> False
  }
}

// The variable a narrowing match is on: the compiler narrows a variable
// matched directly or through `echo`.
fn narrowing_subject(expression: glance.Expression) -> Result(String, Nil) {
  case expression {
    glance.Variable(name:, ..) -> Ok(name)
    glance.Echo(expression: Some(inner), ..) -> narrowing_subject(inner)
    _ -> Error(Nil)
  }
}

fn narrow(env: Env, name: String) -> Env {
  case dict.get(env.scope, name) {
    Ok(binding) -> set(env, name, Binding(..binding, narrowed: True))
    Error(Nil) -> env
  }
}

// Whether `value` is a call, direct or after a pipe, whose callee girard
// resolved to a module function. A constructor, or a local variable
// holding one, tells the compiler the variant.
fn calls_a_module_function(
  value: glance.Expression,
  module_facts: ModuleFacts(Typed),
) -> Bool {
  case value {
    glance.Call(function: callee, ..)
    | glance.BinaryOperator(
        name: glance.Pipe,
        right: glance.Call(function: callee, ..),
        ..,
      )
    | glance.BinaryOperator(name: glance.Pipe, right: callee, ..) ->
      case facts.resolution_of(module_facts, callee.location) {
        Ok(girard.ModuleFn(..)) -> True
        _ -> False
      }
    _ -> False
  }
}

// Checks
//
// A predicate call on a bare variable, and the paths along which it proves
// a variant.

// A check of the binding `name`: the variant it proves when it's true and
// when it's false, and its span.
type Check {
  Check(
    name: String,
    when_true: Variant,
    when_false: Variant,
    location: glance.Span,
  )
}

fn check(expression: glance.Expression, env: Env) -> Result(Check, Nil) {
  case expression {
    glance.NegateBool(value:, location:) -> {
      use check <- result.map(check(value, env))
      Check(
        ..check,
        when_true: check.when_false,
        when_false: check.when_true,
        location:,
      )
    }
    glance.Call(
      function: callee,
      arguments: [glance.UnlabelledField(glance.Variable(name:, ..))],
      location:,
    )
    | glance.BinaryOperator(
        name: glance.Pipe,
        left: glance.Variable(name:, ..),
        right: glance.Call(function: callee, arguments: [], ..),
        location:,
      )
    | glance.BinaryOperator(
        name: glance.Pipe,
        left: glance.Variable(name:, ..),
        right: callee,
        location:,
      ) -> {
      use #(when_true, when_false) <- result.map(predicate(callee, env.facts))
      Check(name:, when_true:, when_false:, location:)
    }
    _ -> Error(Nil)
  }
}

// The variants a predicate proves when it's true and when it's false.
fn predicate(
  callee: glance.Expression,
  module_facts: ModuleFacts(Typed),
) -> Result(#(Variant, Variant), Nil) {
  case facts.resolution_of(module_facts, callee.location) {
    Ok(girard.ModuleFn(module: "gleam/result", name: "is_ok")) ->
      Ok(#(ResultOk, ResultError))
    Ok(girard.ModuleFn(module: "gleam/result", name: "is_error")) ->
      Ok(#(ResultError, ResultOk))
    Ok(girard.ModuleFn(module: "gleam/option", name: "is_some")) ->
      Ok(#(OptionSome, OptionNone))
    Ok(girard.ModuleFn(module: "gleam/option", name: "is_none")) ->
      Ok(#(OptionNone, OptionSome))
    _ -> Error(Nil)
  }
}

// The scope on `side` of the check, if any: its binding gets the variant
// proved, when it's eligible and not narrowed.
fn prove(env: Env, checked: Result(Check, Nil), side: Option(Bool)) -> Env {
  let proved = {
    use check <- result.try(checked)
    use value <- result.try(option.to_result(side, Nil))
    use binding <- result.try(dict.get(env.scope, check.name))
    use <- bool.guard(
      when: !binding.eligible || binding.narrowed,
      return: Error(Nil),
    )
    let variant = case value {
      True -> check.when_true
      False -> check.when_false
    }
    let proof = Proof(variant:, check: check.location)
    Ok(set(env, check.name, Binding(..binding, proven: Some(proof))))
  }
  result.unwrap(proved, env)
}

// `case`

fn walk_case(
  subjects: List(glance.Expression),
  clauses: List(glance.Clause),
  env: Env,
) -> List(Report) {
  let checked = case subjects {
    [subject] -> check(subject, env)
    _ -> Error(Nil)
  }
  let #(_matched, reports) =
    list.map_fold(clauses, None, fn(matched, clause) {
      let #(side, matched) = clause_side(clause, matched)
      let clause_env =
        narrow_subjects(env, subjects, clause.patterns)
        |> prove(checked, side)
        |> list.fold(list.flatten(clause.patterns), _, bind_pattern)
      #(
        matched,
        list.append(
          walk_optional(clause.guard, clause_env),
          walk_expression(clause.body, clause_env),
        ),
      )
    })
  list.append(walk_each(subjects, env), list.flatten(reports))
}

// The value of the check a clause's body runs with, if the clause proves
// one, given `matched`, the value an earlier clause matched with a lone
// pattern and no guard, if any; and that value once the clause has run.
fn clause_side(
  clause: glance.Clause,
  matched: Option(Bool),
) -> #(Option(Bool), Option(Bool)) {
  case clause.patterns {
    [[pattern]] ->
      case bool_pattern(pattern), pattern, matched {
        Ok(value), _, _ if clause.guard == None -> #(Some(value), Some(value))
        Ok(value), _, _ -> #(Some(value), matched)
        Error(Nil), glance.PatternDiscard(..), Some(value)
        | Error(Nil), glance.PatternVariable(..), Some(value)
        -> #(Some(!value), matched)
        _, _, _ -> #(None, matched)
      }
    _ -> #(None, matched)
  }
}

// The Bool a lone `True` or `False` pattern matches.
fn bool_pattern(pattern: glance.Pattern) -> Result(Bool, Nil) {
  case pattern {
    glance.PatternVariant(module: None, constructor: "True", arguments: [], ..) ->
      Ok(True)
    glance.PatternVariant(module: None, constructor: "False", arguments: [], ..) ->
      Ok(False)
    _ -> Error(Nil)
  }
}

// The scope in a clause: each subject that is a variable, directly or
// through `echo`, is narrowed when a pattern of the clause matches it
// against a constructor.
fn narrow_subjects(
  env: Env,
  subjects: List(glance.Expression),
  alternatives: List(List(glance.Pattern)),
) -> Env {
  use env, patterns <- list.fold(alternatives, env)
  use env, #(subject, pattern) <- list.fold(list.zip(subjects, patterns), env)
  case narrowing_subject(subject), matches_a_constructor(pattern) {
    Ok(name), True -> narrow(env, name)
    _, _ -> env
  }
}

// Guards
//
// `bool.guard` and `bool.lazy_guard`, with their arguments in their
// slots.

// What fills a slot: an argument, a shorthand argument, which is a name
// and opaque, or the `use` continuation.
type Slot {
  Argument(glance.Expression)
  Opaque
  Continuation
}

type Slots {
  Slots(when: Slot, return: Slot, otherwise: Slot)
}

// A call of `bool.guard` or `bool.lazy_guard`: the side of the check its
// `return` runs on, none for `bool.guard`'s value, and its arguments in
// their slots, with the `use` continuation, when `implicit`, in the slot
// they leave. A placement that isn't clear is an `Error`.
fn guard(
  expression: glance.Expression,
  implicit implicit: Bool,
  module_facts module_facts: ModuleFacts(Typed),
) -> Result(#(Option(Bool), Slots), Nil) {
  use #(callee, arguments) <- result.try(case expression {
    glance.Call(function:, arguments:, ..) -> Ok(#(function, arguments))
    _ -> Error(Nil)
  })
  use return_side <- result.try(
    case facts.resolution_of(module_facts, callee.location) {
      Ok(girard.ModuleFn(module: "gleam/bool", name: "guard")) -> Ok(None)
      Ok(girard.ModuleFn(module: "gleam/bool", name: "lazy_guard")) ->
        Ok(Some(True))
      _ -> Error(Nil)
    },
  )
  use slots <- result.map(place(arguments, implicit))
  #(return_side, slots)
}

const labels = ["when", "return", "otherwise"]

// As the compiler places them: labelled arguments, shorthand ones
// included, take the slots of their labels, then the unlabelled ones, and
// last the continuation, fill the slots left in order.
fn place(
  arguments: List(glance.Field(glance.Expression)),
  implicit: Bool,
) -> Result(Slots, Nil) {
  let labelled =
    list.filter_map(arguments, fn(argument) {
      case argument {
        glance.LabelledField(label:, item:, ..) -> Ok(#(label, Argument(item)))
        glance.ShorthandField(label:, ..) -> Ok(#(label, Opaque))
        glance.UnlabelledField(..) -> Error(Nil)
      }
    })
  let unlabelled =
    list.filter_map(arguments, fn(argument) {
      case argument {
        glance.UnlabelledField(item:) -> Ok(Argument(item))
        glance.LabelledField(..) | glance.ShorthandField(..) -> Error(Nil)
      }
    })
  let fillers = case implicit {
    True -> list.append(unlabelled, [Continuation])
    False -> unlabelled
  }
  let left =
    list.filter(labels, fn(label) {
      result.is_error(list.key_find(labelled, label))
    })
  use <- bool.guard(
    when: list.length(left) != list.length(fillers),
    return: Error(Nil),
  )
  let filled = list.append(labelled, list.zip(left, fillers))
  // Each slot once: three slots filled, each found by its label.
  use <- bool.guard(when: list.length(filled) != 3, return: Error(Nil))
  use when <- result.try(list.key_find(filled, "when"))
  use return <- result.try(list.key_find(filled, "return"))
  use otherwise <- result.map(list.key_find(filled, "otherwise"))
  Slots(when:, return:, otherwise:)
}

// Walk a guard's slots: its check, its value, and each callback on the
// side of the check it runs on. Also give the scope a `use` continuation
// gets: the side of its slot, or the scope as it was.
fn walk_guard(
  return_side: Option(Bool),
  slots: Slots,
  env: Env,
) -> #(List(Report), Env) {
  // A shorthand `when:` holds no check, and a continuation can't be the
  // Bool the guard checks.
  let #(checked, when_reports) = case slots.when {
    Argument(when) -> #(check(when, env), walk_expression(when, env))
    Opaque | Continuation -> #(Error(Nil), [])
  }
  let reports =
    list.flatten([
      when_reports,
      walk_slot(slots.return, return_side, checked, env),
      walk_slot(slots.otherwise, Some(False), checked, env),
    ])
  let continuation = case slots.return, slots.otherwise {
    Continuation, _ -> prove(env, checked, return_side)
    _, Continuation -> prove(env, checked, Some(False))
    _, _ -> env
  }
  #(reports, continuation)
}

// Walk one slot, whose callback runs on `side` of the check, if any.
fn walk_slot(
  slot: Slot,
  side: Option(Bool),
  checked: Result(Check, Nil),
  env: Env,
) -> List(Report) {
  case slot, side {
    Opaque, _ | Continuation, _ -> []
    Argument(glance.Fn(arguments: [], body:, ..)), Some(_) ->
      walk_statements(body, prove(env, checked, side))
    Argument(argument), _ -> walk_expression(argument, env)
  }
}

// Asserts

fn assertion(
  pattern: glance.Pattern,
  value: glance.Expression,
  location: glance.Span,
  env: Env,
) -> List(Report) {
  let found = {
    use name <- result.try(case value {
      glance.Variable(name:, ..) -> Ok(name)
      _ -> Error(Nil)
    })
    use proof <- result.try(case dict.get(env.scope, name) {
      Ok(Binding(eligible: True, narrowed: False, proven: Some(proof))) ->
        Ok(proof)
      _ -> Error(Nil)
    })
    let imports =
      list.map(facts.module(env.facts).imports, fn(import_) {
        import_.definition
      })
    use variant <- result.try(asserted(pattern, imports))
    use <- bool.guard(when: variant != proof.variant, return: Error(Nil))
    use type_ <- result.try(
      facts.type_of(env.facts, value.location) |> result.replace_error(Nil),
    )
    use <- bool.guard(when: !holds(type_, variant), return: Error(Nil))
    Ok(report(location, name, proof.check))
  }
  case found {
    Ok(report) -> [report]
    Error(Nil) -> []
  }
}

// Whether a value of `type_` can be `variant`.
fn holds(type_: girard.Type, variant: Variant) -> Bool {
  case type_, variant {
    girard.Named(module: "gleam", name: "Result", ..), ResultOk
    | girard.Named(module: "gleam", name: "Result", ..), ResultError
    | girard.Named(module: "gleam/option", name: "Option", ..), OptionSome
    | girard.Named(module: "gleam/option", name: "Option", ..), OptionNone
    -> True
    _, _ -> False
  }
}

// The variant a pattern asks for, when it's a constructor of `Result` or
// `Option`, resolved through the imports, with its arity and nothing but
// discards and variables inside.
fn asserted(
  pattern: glance.Pattern,
  imports: List(glance.Import),
) -> Result(Variant, Nil) {
  case pattern {
    glance.PatternVariant(
      module:,
      constructor:,
      arguments:,
      with_spread: False,
      ..,
    ) -> {
      use variant <- result.try(constructor_variant(
        module,
        constructor,
        imports,
      ))
      let arity = case variant {
        ResultOk | ResultError | OptionSome -> 1
        OptionNone -> 0
      }
      use <- bool.guard(
        when: list.length(arguments) != arity,
        return: Error(Nil),
      )
      let binds_only =
        list.all(arguments, fn(argument) {
          case argument {
            glance.UnlabelledField(glance.PatternDiscard(..))
            | glance.UnlabelledField(glance.PatternVariable(..)) -> True
            _ -> False
          }
        })
      use <- bool.guard(when: !binds_only, return: Error(Nil))
      Ok(variant)
    }
    _ -> Error(Nil)
  }
}

// Imports
//
// What the module's imports make a constructor's written name mean.

// The variant `module.name`, or `name` unqualified, means: through an
// import of `gleam/option` or `gleam`, or, for `Ok` and `Error` that no
// import introduces, the prelude's. Any other import, or any other name,
// is not a variant this rule knows.
fn constructor_variant(
  module: Option(String),
  name: String,
  imports: List(glance.Import),
) -> Result(Variant, Nil) {
  case module {
    Some(module) -> {
      use import_ <- result.try(
        list.find(imports, fn(import_) {
          type_names.qualifier(import_) == Ok(module)
        }),
      )
      variant(import_.module, name)
    }
    None -> {
      let imported =
        list.find_map(imports, fn(import_) {
          list.find_map(import_.unqualified_values, fn(value) {
            case option.unwrap(value.alias, value.name) == name {
              True -> Ok(#(import_.module, value.name))
              False -> Error(Nil)
            }
          })
        })
      case imported, name {
        Ok(#(module, original)), _ -> variant(module, original)
        Error(Nil), "Ok" -> Ok(ResultOk)
        Error(Nil), "Error" -> Ok(ResultError)
        Error(Nil), _ -> Error(Nil)
      }
    }
  }
}

fn variant(module: String, name: String) -> Result(Variant, Nil) {
  case module, name {
    "gleam", "Ok" -> Ok(ResultOk)
    "gleam", "Error" -> Ok(ResultError)
    "gleam/option", "Some" -> Ok(OptionSome)
    "gleam/option", "None" -> Ok(OptionNone)
    _, _ -> Error(Nil)
  }
}

// Reports

fn report(location: glance.Span, name: String, checked: glance.Span) -> Report {
  let name = "`" <> name <> "`"
  rule.report(
    at: location,
    label: name <> " was already checked, so this assert can't fail",
  )
  |> rule.with_label(at: checked, label: name <> " is checked here")
  |> rule.with_message([
    "Gleam's conventions call checking a value and then asserting its shape an anti-pattern that \"should never be done\". The check and the assert can drift apart as the code changes.",
  ])
  |> rule.with_hint(
    "Match on "
    <> name
    <> " with `case` and use the value the pattern binds, instead of checking it first.",
  )
}
