//// The rules grice ships. For the API that writes rules, see `grice/rule`.
////
//// `default` is the default set, which `gleam run -m grice` runs. Each
//// built-in rule is also a function of its own, so a project with an entry
//// module of its own, such as `dev/lint.gleam`, can run the default set
//// beside its own rules:
////
//// ```gleam
//// import grice
//// import grice/rules
//// import my_app/lint/no_io_in_view
////
//// pub fn main() -> Nil {
////   grice.run([no_io_in_view.rule(), ..rules.default()])
//// }
//// ```
////
//// Every built-in rule reports warnings. To make one an error, list the
//// rules by name and change its severity:
////
//// ```gleam
//// import grice
//// import grice/diagnostic
//// import grice/rule
//// import grice/rules
////
//// pub fn main() -> Nil {
////   grice.run([rules.no_echo() |> rule.with_severity(diagnostic.Error)])
//// }
//// ```
////
//// A rule left out of that list doesn't run. To turn a rule off for some
//// paths only, ignore its code in `gleam.toml` instead. Built-in codes
//// start with `grice_rules/`, and are ignored and suppressed like any
//// rule's. [Built-in rules](https://github.com/alvivi/grice/blob/main/docs/RULES.md)
//// describes each rule.

import grice/internal/rules/ineffective_double_comparison
import grice/internal/rules/no_echo
import grice/rule.{type Rule}

/// The default set, which `gleam run -m grice` runs: every rule below, in
/// the order they're listed.
pub fn default() -> List(Rule) {
  [no_echo(), ineffective_double_comparison()]
}

/// `grice_rules/no-echo`: an `echo` left in a module outside `test/` and
/// `dev/`. `gleam build` accepts it, but `gleam publish` refuses a package
/// that has one, and an application prints it whenever the code runs.
///
/// Flagged:
///
/// ```gleam
/// pub fn total(prices: List(Int)) -> Int {
///   prices |> echo |> int.sum
/// }
/// ```
///
/// Fixed:
///
/// ```gleam
/// pub fn total(prices: List(Int)) -> Int {
///   prices |> int.sum
/// }
/// ```
///
/// [no-echo](https://github.com/alvivi/grice/blob/main/docs/RULES.md#no-echo)
/// in the rule reference.
pub fn no_echo() -> Rule {
  no_echo.rule()
}

/// `grice_rules/ineffective-double-comparison`: in a chain of `&&` or of
/// `||`, a comparison of a variable or a field access with an Int literal
/// that the comparisons before it already decide. It's always true where
/// it runs, never true there, or the whole `&&` chain can never be true.
/// It's most often a range written the wrong way round.
///
/// Flagged, since `48 >= char` is `char <= 48`, which makes `char <= 57`
/// always true:
///
/// ```gleam
/// pub fn is_digit(char: Int) -> Bool {
///   48 >= char && char <= 57
/// }
/// ```
///
/// Fixed:
///
/// ```gleam
/// pub fn is_digit(char: Int) -> Bool {
///   48 <= char && char <= 57
/// }
/// ```
///
/// [ineffective-double-comparison](https://github.com/alvivi/grice/blob/main/docs/RULES.md#ineffective-double-comparison)
/// in the rule reference.
pub fn ineffective_double_comparison() -> Rule {
  ineffective_double_comparison.rule()
}
