//// A clean sample of needlessly-public-function, linted under `test/`: a
//// test module's call counts. Nothing here runs.

import grice/internal/rules/samples/referenced

pub fn in_a_test() -> Int {
  referenced.from_test()
}
