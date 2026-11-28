//// A clean sample of needlessly-public-function: a call through an alias
//// of `referenced`. Nothing here runs.

import grice/internal/rules/samples/referenced as named

pub fn through_alias() -> Int {
  named.aliased()
}
