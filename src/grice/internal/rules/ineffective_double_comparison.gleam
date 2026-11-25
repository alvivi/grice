//// `grice_rules/ineffective-double-comparison`: in a chain of `&&` or of
//// `||`, a comparison of a variable with an Int literal that the
//// comparisons before it in the chain already decide.
////
//// It reads only the syntax tree. A chain is a maximal run of one
//// operator, in either association, and the comparisons in it are judged
//// in the order they run: each against the facts the comparisons before it
//// leave, kept per subject. A subject is a variable or a field access on
//// one, such as `p.x`, identified by its text, since nothing can rebind a
//// name inside one expression. Any other operand is opaque: a block, a
//// call, a `case`, a function, a chain of the other operator, `!=`, a
//// Float comparison. It adds no fact and is never reported, but the facts
//// carry across it, and a chain of the other operator is judged on its
//// own when the walk reaches it.
////
//// In a chain of `&&`, reaching a comparison means the ones before it
//// held, so the facts are an interval of each subject. A comparison the
//// interval implies is always true there, and one it contradicts makes
//// the chain never true. In a chain of `||`, reaching a comparison means
//// the ones before it failed, so the facts are an interval from the failed
//// orderings and the points the failed equalities exclude. A comparison
//// the interval rules out, or an equality with an excluded point, is never
//// true there. One the interval implies isn't reported: on JavaScript an
//// Int can be NaN, which fails every comparison, so it doesn't always hold.
//// The excluded points are never combined with the interval or with each
//// other, so a report has at most two comparisons as its witness.
////
//// An earlier comparison is never reported, even when a later one implies
//// it: it still guards whatever runs between them.

import glance
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set
import grice/internal/rules/int_literal
import grice/rule.{type Report, type Rule}

const code = "grice_rules/ineffective-double-comparison"

/// The rule. Its context holds the spans of the inner nodes of the chains
/// it has judged, which the walk reaches after the chain's outermost node
/// and which aren't chains of their own.
pub fn rule() -> Rule {
  rule.module(code, title: "Comparison decided by an earlier one")
  |> rule.with_context(initial: set.new())
  |> rule.on_expression(fn(inner, expression, _module_facts) {
    case expression {
      glance.BinaryOperator(name: glance.And as operator, location:, ..)
      | glance.BinaryOperator(name: glance.Or as operator, location:, ..) ->
        case set.contains(inner, location) {
          True -> #(set.delete(inner, location), [])
          False -> {
            let #(operands, nodes) = chain(expression, operator)
            // The outermost node is the chain itself, not an inner node.
            let nodes = set.delete(set.from_list(nodes), location)
            #(set.union(inner, nodes), judge(operands, operator))
          }
        }
      _ -> #(inner, [])
    }
  })
  |> rule.build
}

// Chains
//
// A chain's operands, in the order they run, and the comparisons among
// them.

// The operands of the chain of `operator` whose outermost node is
// `expression`, in source order, and the spans of its nodes.
fn chain(
  expression: glance.Expression,
  operator: glance.BinaryOperator,
) -> #(List(glance.Expression), List(glance.Span)) {
  let #(operands, nodes) = flatten(expression, operator, #([], []))
  #(list.reverse(operands), nodes)
}

// Add the operands of `expression` to `found`, the latest first, and the
// spans of its nodes of `operator`.
fn flatten(
  expression: glance.Expression,
  operator: glance.BinaryOperator,
  found: #(List(glance.Expression), List(glance.Span)),
) -> #(List(glance.Expression), List(glance.Span)) {
  case expression {
    glance.BinaryOperator(name:, left:, right:, location:) if name == operator -> {
      let #(operands, nodes) = found
      flatten(left, operator, #(operands, [location, ..nodes]))
      |> flatten(right, operator, _)
    }
    _ -> #([expression, ..found.0], found.1)
  }
}

// The Ints a comparison holds for.
type Range {
  AtLeast(Int)
  AtMost(Int)
  Equal(Int)
}

type Comparison {
  Comparison(subject: String, range: Range, location: glance.Span)
}

// The operand as a comparison of a subject with an Int literal, either way
// round, or `Error` when it's opaque.
fn comparison(operand: glance.Expression) -> Result(Comparison, Nil) {
  case operand {
    glance.BinaryOperator(name:, left:, right:, location:) -> {
      use #(subject, operator, value) <- result.try(
        case
          subject(left),
          int_literal.value(right),
          int_literal.value(left),
          subject(right)
        {
          Ok(subject), Ok(value), _, _ -> Ok(#(subject, name, value))
          _, _, Ok(value), Ok(subject) ->
            Ok(#(subject, int_literal.mirror(name), value))
          _, _, _, _ -> Error(Nil)
        },
      )
      use range <- result.map(range_of(operator, value))
      Comparison(subject:, range:, location:)
    }
    _ -> Error(Nil)
  }
}

// A variable or a field access on one, as its text.
fn subject(expression: glance.Expression) -> Result(String, Nil) {
  case expression {
    glance.Variable(name:, ..) -> Ok(name)
    glance.FieldAccess(container:, label:, ..) ->
      subject(container) |> result.map(fn(text) { text <> "." <> label })
    _ -> Error(Nil)
  }
}

// The Ints `subject <operator> value` holds for. `!=` holds for no range:
// NaN fails every comparison but `!=`, which it passes. Every other
// operator isn't a comparison of Ints.
fn range_of(operator: glance.BinaryOperator, value: Int) -> Result(Range, Nil) {
  case operator {
    glance.GtInt -> Ok(AtLeast(value + 1))
    glance.GtEqInt -> Ok(AtLeast(value))
    glance.LtInt -> Ok(AtMost(value - 1))
    glance.LtEqInt -> Ok(AtMost(value))
    glance.Eq -> Ok(Equal(value))
    _ -> Error(Nil)
  }
}

// Judging
//
// Each comparison is judged once, against the facts of the comparisons
// before it in its chain, which are then updated with it.

// One bound of a subject's interval, and the comparison that set it.
type Bound {
  Bound(value: Int, location: glance.Span)
}

// What the comparisons before one leave known about its subject: an
// interval, with `None` for an open end, and, in a chain of `||`, the
// points failed equalities exclude.
type Facts {
  Facts(
    low: Option(Bound),
    high: Option(Bound),
    excluded: Dict(Int, glance.Span),
  )
}

// How a comparison was decided, with the comparisons that decide it.
type Verdict {
  // `&&`: the comparison holds wherever it runs.
  AlwaysTrue(witness: List(glance.Span))
  // `&&`: the comparison and the ones before it never hold together.
  Contradiction(witness: List(glance.Span))
  // `||`: the comparison never holds where it runs.
  NeverTrue(witness: List(glance.Span))
}

fn judge(
  operands: List(glance.Expression),
  operator: glance.BinaryOperator,
) -> List(Report) {
  let #(_facts, reports) =
    list.fold(operands, #(dict.new(), []), fn(state, operand) {
      let #(known, reports) = state
      case comparison(operand) {
        Error(Nil) -> state
        Ok(comparison) -> {
          let facts =
            dict.get(known, comparison.subject)
            |> result.unwrap(Facts(low: None, high: None, excluded: dict.new()))
          case decide(facts, comparison.range, operator) {
            Ok(verdict) -> #(known, [report(comparison, verdict), ..reports])
            Error(Nil) -> #(
              dict.insert(
                known,
                comparison.subject,
                learn(facts, comparison, operator),
              ),
              reports,
            )
          }
        }
      }
    })
  list.reverse(reports)
}

// How the facts decide a comparison of `range` in a chain of `operator`, or `Error` when
// they don't.
fn decide(
  facts: Facts,
  range: Range,
  operator: glance.BinaryOperator,
) -> Result(Verdict, Nil) {
  case operator {
    glance.And -> decide_and(facts, range)
    _ -> decide_or(facts, range)
  }
}

// In a chain of `&&`, the interval is never empty: a comparison that
// contradicts it is reported and leaves it as it was.
fn decide_and(facts: Facts, range: Range) -> Result(Verdict, Nil) {
  let Facts(low:, high:, ..) = facts
  case range {
    AtLeast(value) ->
      case low, high {
        Some(low), _ if low.value >= value -> Ok(AlwaysTrue([low.location]))
        _, Some(high) if high.value < value -> Ok(Contradiction([high.location]))
        _, _ -> Error(Nil)
      }
    AtMost(value) ->
      case low, high {
        _, Some(high) if high.value <= value -> Ok(AlwaysTrue([high.location]))
        Some(low), _ if low.value > value -> Ok(Contradiction([low.location]))
        _, _ -> Error(Nil)
      }
    Equal(value) ->
      case low, high {
        Some(low), Some(high) if low.value >= value && high.value <= value ->
          Ok(AlwaysTrue(witness(low, high)))
        _, Some(high) if high.value < value -> Ok(Contradiction([high.location]))
        Some(low), _ if low.value > value -> Ok(Contradiction([low.location]))
        _, _ -> Error(Nil)
      }
  }
}

// In a chain of `||`, the interval can be empty, when a comparison that
// held wherever it ran wasn't reported: then only NaN reaches what follows,
// and fails it.
fn decide_or(facts: Facts, range: Range) -> Result(Verdict, Nil) {
  let Facts(low:, high:, excluded:) = facts
  let empty = case low, high {
    Some(low), Some(high) if low.value > high.value -> Ok(witness(low, high))
    _, _ -> Error(Nil)
  }
  let ruled_out = case range, low, high {
    AtLeast(value), _, Some(high)
    | Equal(value), _, Some(high)
      if high.value < value
    -> Ok([high.location])
    AtMost(value), Some(low), _
    | Equal(value), Some(low), _
      if low.value > value
    -> Ok([low.location])
    Equal(value), _, _ ->
      dict.get(excluded, value) |> result.map(fn(location) { [location] })
    _, _, _ -> Error(Nil)
  }
  result.or(ruled_out, empty) |> result.map(NeverTrue)
}

// The comparisons that set both bounds, once each, in source order.
fn witness(low: Bound, high: Bound) -> List(glance.Span) {
  case low.location == high.location, low.location.start < high.location.start {
    True, _ -> [low.location]
    False, True -> [low.location, high.location]
    False, False -> [high.location, low.location]
  }
}

// The facts once `comparison`, which they didn't decide, has run: in a
// chain of `&&` it held, in a chain of `||` it failed.
fn learn(
  facts: Facts,
  comparison: Comparison,
  operator: glance.BinaryOperator,
) -> Facts {
  let Comparison(range:, location:, ..) = comparison
  case operator, range {
    glance.And, AtLeast(value) -> raise_low(facts, value, location)
    glance.And, AtMost(value) -> lower_high(facts, value, location)
    glance.And, Equal(value) ->
      raise_low(facts, value, location) |> lower_high(value, location)
    _, AtLeast(value) -> lower_high(facts, value - 1, location)
    _, AtMost(value) -> raise_low(facts, value + 1, location)
    // An excluded point decides an equality, so this one isn't excluded
    // yet.
    _, Equal(value) ->
      Facts(..facts, excluded: dict.insert(facts.excluded, value, location))
  }
}

fn raise_low(facts: Facts, value: Int, location: glance.Span) -> Facts {
  case facts.low {
    Some(low) if low.value >= value -> facts
    _ -> Facts(..facts, low: Some(Bound(value:, location:)))
  }
}

fn lower_high(facts: Facts, value: Int, location: glance.Span) -> Facts {
  case facts.high {
    Some(high) if high.value <= value -> facts
    _ -> Facts(..facts, high: Some(Bound(value:, location:)))
  }
}

// Reports

fn report(comparison: Comparison, verdict: Verdict) -> Report {
  let #(label, message, witness) = case verdict {
    AlwaysTrue(witness:) -> #(
      "This is always true here",
      "The comparison has no effect: the comparisons before it already make it true whenever it runs.",
      witness,
    )
    Contradiction(witness:) -> #(
      "This can never be true together with the comparisons before it",
      "It contradicts a comparison before it, so the whole `&&` chain is always `False`.",
      witness,
    )
    NeverTrue(witness:) -> #(
      "This is never true here",
      "It can only be true where a comparison before it already was, so it never changes the result.",
      witness,
    )
  }
  let witness_label = case witness {
    [_] -> "This comparison already decides it"
    _ -> "This comparison decides it with the other one marked"
  }
  witness
  |> list.fold(rule.report(at: comparison.location, label:), fn(report, at) {
    rule.with_label(report, at:, label: witness_label)
  })
  |> rule.with_message([message])
  |> rule.with_hint(
    "A range check is written `low <= x && x <= high`. Check both comparisons against it.",
  )
}
