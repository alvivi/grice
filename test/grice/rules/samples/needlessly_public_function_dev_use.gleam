//// A clean sample of needlessly-public-function, linted under `dev/`: a
//// development module's call counts. Nothing here runs.

import grice/internal/rules/samples/referenced

pub fn in_a_tool() -> Int {
  referenced.from_dev()
}
