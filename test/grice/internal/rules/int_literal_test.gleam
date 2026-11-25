//// Tests for reading Int literals, in each spelling the compiler accepts.

import glance
import grice/internal/rules/int_literal

pub fn parse_reads_each_base_test() {
  assert int_literal.parse("42") == Ok(42)
  assert int_literal.parse("00") == Ok(0)
  assert int_literal.parse("0x1F") == Ok(31)
  assert int_literal.parse("0xff") == Ok(255)
  assert int_literal.parse("0o17") == Ok(15)
  assert int_literal.parse("0b101") == Ok(5)
}

pub fn parse_reads_separators_and_signs_test() {
  assert int_literal.parse("10_000") == Ok(10_000)
  assert int_literal.parse("0x1_F") == Ok(31)
  assert int_literal.parse("-0") == Ok(0)
  assert int_literal.parse("-0x10") == Ok(-16)
}

pub fn parse_rejects_what_is_not_a_literal_test() {
  assert int_literal.parse("") == Error(Nil)
  assert int_literal.parse("0x") == Error(Nil)
  assert int_literal.parse("--1") == Error(Nil)
  assert int_literal.parse("-+1") == Error(Nil)
  assert int_literal.parse("1.0") == Error(Nil)
}

// JavaScript's safe integers run from -(2^53 - 1) to 2^53 - 1.
pub fn parse_reads_only_safe_integers_test() {
  assert int_literal.parse("9007199254740991") == Ok(9_007_199_254_740_991)
  assert int_literal.parse("-0x1F_FFFF_FFFF_FFFF") == Ok(-9_007_199_254_740_991)
  assert int_literal.parse("9007199254740992") == Error(Nil)
  assert int_literal.parse("-0x20_0000_0000_0000") == Error(Nil)
}

pub fn value_reads_one_sign_around_an_unsigned_literal_test() {
  let span = glance.Span(0, 0)
  assert int_literal.value(glance.Int(span, "7")) == Ok(7)
  assert int_literal.value(glance.Int(span, "-7")) == Ok(-7)
  assert int_literal.value(glance.NegateInt(span, glance.Int(span, "7")))
    == Ok(-7)
  assert int_literal.value(glance.NegateInt(span, glance.Int(span, "-7")))
    == Error(Nil)
  assert int_literal.value(glance.NegateInt(
      span,
      glance.NegateInt(span, glance.Int(span, "7")),
    ))
    == Error(Nil)
  assert int_literal.value(glance.Variable(span, "count")) == Error(Nil)
}
