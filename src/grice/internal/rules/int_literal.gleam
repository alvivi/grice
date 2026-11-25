//// Int literals as glance parses them, read as values, for the built-in
//// rules that compare with one, and the comparison that puts a literal
//// written first on the right.
////
//// glance keeps a literal's text as it's written, sign included: `-0x10`
//// is `Int(_, "-0x10")`. A minus with a space, `- 5`, is a `NegateInt`
//// around `Int(_, "5")`, which `gleam format` prints as `-5`. A literal is
//// read in every spelling the compiler accepts: decimal, `0x`, `0o` and
//// `0b`, with `_` between digits. Anything else is not a literal: stacked
//// signs, such as `- -0`, which the compiler warns on, and a value outside
//// JavaScript's safe integers, `-(2^53 - 1)` to `2^53 - 1`, so a rule
//// gives the same verdict on both targets and on both runtimes.

import glance
import gleam/bool
import gleam/int
import gleam/result
import gleam/string

// The largest safe integer on JavaScript, 2^53 - 1.
const largest = 9_007_199_254_740_991

/// The value of `expression` when it's an Int literal: an `Int`, or one
/// `NegateInt` around an `Int` written without a sign.
pub fn value(expression: glance.Expression) -> Result(Int, Nil) {
  case expression {
    glance.Int(value: text, ..) -> parse(text)
    glance.NegateInt(value: glance.Int(value: text, ..), ..) ->
      case string.starts_with(text, "-") {
        True -> Error(Nil)
        False -> parse(text) |> result.map(int.negate)
      }
    _ -> Error(Nil)
  }
}

/// The value of an Int literal's text, as glance keeps it in an `Int`
/// expression or an `Int` pattern: an optional `-`, then a decimal, `0x`,
/// `0o` or `0b` number with `_` between its digits.
pub fn parse(text: String) -> Result(Int, Nil) {
  let #(sign, unsigned) = case text {
    "-" <> rest -> #(-1, rest)
    _ -> #(1, text)
  }
  let #(base, digits) = case unsigned {
    "0x" <> rest -> #(16, rest)
    "0o" <> rest -> #(8, rest)
    "0b" <> rest -> #(2, rest)
    _ -> #(10, unsigned)
  }
  // A literal's digits start with a digit, while `base_parse` would also
  // take a sign of its own.
  let starts_with_a_digit = case digits {
    "" | "-" <> _ | "+" <> _ | "_" <> _ -> False
    _ -> True
  }
  use <- bool.guard(when: !starts_with_a_digit, return: Error(Nil))
  use magnitude <- result.try(int.base_parse(
    string.replace(digits, "_", ""),
    base,
  ))
  use <- bool.guard(when: magnitude > largest, return: Error(Nil))
  Ok(sign * magnitude)
}

/// The operator that compares the same way with its operands swapped, so
/// `5 < x` is `x > 5`.
pub fn mirror(operator: glance.BinaryOperator) -> glance.BinaryOperator {
  case operator {
    glance.LtInt -> glance.GtInt
    glance.LtEqInt -> glance.GtEqInt
    glance.GtInt -> glance.LtInt
    glance.GtEqInt -> glance.LtEqInt
    _ -> operator
  }
}
