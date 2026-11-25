//// Code ineffective-double-comparison leaves alone. These functions never
//// run.

import gleam/int

pub fn range(char: Int) -> Bool {
  48 <= char && char <= 57
}

// A later comparison that narrows an earlier one decides nothing, and the
// earlier one is never reported: it still guards what runs in between.
pub fn narrowing(count: Int, ready: Bool) -> Bool {
  count > 0 && ready && count > 5
}

pub fn either_side(count: Int) -> Bool {
  count < 0 || count > 0
}

// The last comparison holds for every Int that reaches it, but not for
// NaN, which JavaScript can produce, and which fails all three.
pub fn always_true_under_or(count: Int) -> Bool {
  count < 0 || count > 0 || count == 0
}

pub fn not_equal(count: Int) -> Bool {
  count != 0 && count != 1
}

pub fn floats(ratio: Float) -> Bool {
  ratio >. 1.0 && ratio >. 0.0
}

pub fn different_subjects(low: Int, high: Int) -> Bool {
  low > 5 && high > 0
}

// A block is opaque, and the chain inside it is judged on its own.
pub fn inside_a_block(count: Int) -> Bool {
  count > 5 && { count > 0 || count < -10 }
}

pub fn calls(count: Int) -> Bool {
  int.absolute_value(count) > 5 && int.absolute_value(count) > 0
}

pub fn tuple_index(pair: #(Int, Int)) -> Bool {
  pair.0 > 5 && pair.0 > 0
}

// `&&` binds tighter than `||`, so this is a chain of `||` with one opaque
// operand, then one comparison.
pub fn mixed_operators(count: Int) -> Bool {
  count > 0 && count > 5 || count > 3
}

// The last comparison is never true here, but only the interval and every
// excluded point together show it, and a report's witness is at most two
// comparisons.
pub fn excluded_points_are_not_combined(count: Int) -> Bool {
  count >= 3 || count == 0 || count == 1 || count == 2 || count >= 0
}
