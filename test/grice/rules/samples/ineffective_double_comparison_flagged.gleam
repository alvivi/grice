//// Each form ineffective-double-comparison reports, one per function.
//// These functions never run: the module is here to be linted, and
//// compiled by every build with `--warnings-as-errors`, which shows the
//// compiler is silent on it.

pub type Point {
  Point(x: Int, y: Int)
}

pub type Size {
  Size(width: Int, height: Int)
}

pub type Box {
  Box(size: Size)
}

pub fn implied(count: Int) -> Bool {
  count > 5 && count > 0
}

pub fn contradicted(count: Int) -> Bool {
  count > 5 && count < 3
}

pub fn ruled_out(count: Int) -> Bool {
  count > 5 || count > 7
}

pub fn equality_excluded(count: Int) -> Bool {
  count == 1 || count == 2 || count == 1
}

// Each range is written the wrong way round, as gleam_stdlib's `uri.gleam`
// had it (gleam-lang/stdlib#881): `48 >= char` is `char <= 48`.
pub fn is_hex_digit(char: Int) -> Bool {
  { 48 >= char && char <= 57 } || { 97 >= char && char <= 102 }
}

pub fn literal_first(count: Int) -> Bool {
  5 < count && 0 < count
}

pub fn field_access(point: Point) -> Bool {
  point.x > 0 && point.x >= 1
}

pub fn nested_field_access(box: Box) -> Bool {
  box.size.width >= 10 && box.size.width > 9
}

pub fn hexadecimal_and_binary(count: Int) -> Bool {
  count >= 0x10 && count > 0b1111
}

pub fn octal_and_separators(count: Int) -> Bool {
  count < 0o17 && count <= 10_000
}

pub fn negative(count: Int) -> Bool {
  count < -16 && count < -1
}

pub fn across_an_opaque_operand(count: Int, ready: Bool) -> Bool {
  count > 5 && ready && count > 0
}

pub fn equality_implied(count: Int) -> Bool {
  count >= 3 && count <= 3 && count == 3
}

pub fn equality_contradicted(count: Int) -> Bool {
  count == 3 && count == 4
}

// `count > 3` holds wherever it runs, but isn't reported, since NaN fails
// it. Only NaN gets past it, and fails `count >= 2` too.
pub fn ruled_out_by_both_bounds(count: Int) -> Bool {
  count <= 5 || count > 3 || count >= 2
}

pub fn in_a_guard(count: Int) -> Int {
  case count {
    _ if count > 5 && count > 0 -> 1
    _ -> 0
  }
}
