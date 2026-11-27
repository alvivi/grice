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
////
//// `simplify` is an opt-in pack, which `gleam run -m grice` doesn't run:
//// rules for code that is correct but takes the long way round, where the
//// standard library has one function that does the same on the target
//// grice lints for (see `fold_plus` for code also built for JavaScript).
//// No rule is in more than one set, so a project adds the pack to the
//// default set in an entry module of its own:
////
//// ```gleam
//// import gleam/list
//// import grice
//// import grice/rules
////
//// pub fn main() -> Nil {
////   grice.run(list.append(rules.default(), rules.simplify()))
//// }
//// ```
////
//// `library` is the library pack, another opt-in set: rules for a package
//// published to Hex, about what it offers its users. Its rules read only
//// the modules under `src/`, which is what a package publishes. A package
//// runs it beside the default set the same way:
////
//// ```gleam
//// import gleam/list
//// import grice
//// import grice/rules
////
//// pub fn main() -> Nil {
////   grice.run(list.append(rules.default(), rules.library()))
//// }
//// ```

import grice/internal/rules/check_then_assert
import grice/internal/rules/filter_then_length
import grice/internal/rules/fold_plus
import grice/internal/rules/ineffective_double_comparison
import grice/internal/rules/internal_type_in_public_api
import grice/internal/rules/list_map_then_flatten
import grice/internal/rules/map_then_flatten
import grice/internal/rules/no_echo
import grice/internal/rules/no_length_for_emptiness
import grice/internal/rules/reverse_then_first
import grice/rule.{type Rule}

/// The default set, which `gleam run -m grice` runs: every rule below, in
/// the order they're listed.
pub fn default() -> List(Rule) {
  [
    no_echo(),
    ineffective_double_comparison(),
    no_length_for_emptiness(),
    check_then_assert(),
  ]
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

/// `grice_rules/no-length-for-emptiness`: `string.length` or `list.length`
/// compared with 0 or 1, or matched on 0 in a `case`, to check whether a
/// string or a list is empty. Both walk the whole value to count it, and
/// `string.length`'s docs say to avoid it in a loop. It finds the
/// functions by what girard resolved, however they're imported or piped,
/// and leaves alone the `list.length` forms the compiler already warns on.
///
/// Flagged:
///
/// ```gleam
/// pub fn greeting(name: String) -> String {
///   case string.length(name) > 0 {
///     True -> "Hello, " <> name
///     False -> "Hello"
///   }
/// }
/// ```
///
/// Fixed:
///
/// ```gleam
/// pub fn greeting(name: String) -> String {
///   case name != "" {
///     True -> "Hello, " <> name
///     False -> "Hello"
///   }
/// }
/// ```
///
/// [no-length-for-emptiness](https://github.com/alvivi/grice/blob/main/docs/RULES.md#no-length-for-emptiness)
/// in the rule reference.
pub fn no_length_for_emptiness() -> Rule {
  no_length_for_emptiness.rule()
}

/// `grice_rules/check-then-assert`: a `Result` or an `Option` tested with
/// `result.is_ok`, `result.is_error`, `option.is_some` or
/// `option.is_none`, and then `let assert`-ed on a path where the test
/// already proved the asserted variant. Gleam's conventions page calls
/// checking then asserting an anti-pattern that "should never be done".
/// It follows `case` clauses, `bool.guard` and `bool.lazy_guard`, and
/// stays silent wherever the compiler already knows the variant.
///
/// Flagged:
///
/// ```gleam
/// pub fn port(text: String) -> Int {
///   let parsed = int.parse(text)
///   use <- bool.guard(when: result.is_error(parsed), return: 80)
///   let assert Ok(port) = parsed
///   port
/// }
/// ```
///
/// Fixed:
///
/// ```gleam
/// pub fn port(text: String) -> Int {
///   case int.parse(text) {
///     Ok(port) -> port
///     Error(Nil) -> 80
///   }
/// }
/// ```
///
/// [check-then-assert](https://github.com/alvivi/grice/blob/main/docs/RULES.md#check-then-assert)
/// in the rule reference.
pub fn check_then_assert() -> Rule {
  check_then_assert.rule()
}

/// The simplify pack, an opt-in set that `gleam run -m grice` doesn't run:
/// every rule below this one, in the order they're listed. Each flags code
/// that a single standard library function does in one call, with the same
/// result on the target grice lints for, and calls any function passed to
/// it the same way. `fold_plus` says what code also built for JavaScript
/// can see.
pub fn simplify() -> List(Rule) {
  [
    map_then_flatten(),
    list_map_then_flatten(),
    filter_then_length(),
    reverse_then_first(),
    fold_plus(),
  ]
}

/// `grice_rules/map-then-flatten`: `result.map` then `result.flatten`, or
/// `option.map` then `option.flatten`, nested or piped. `result.try` and
/// `option.then` do both in one call, and their docs say they're "the
/// equivalent of calling `map` followed by `flatten`".
///
/// Flagged:
///
/// ```gleam
/// pub fn port(text: String) -> Result(Int, Nil) {
///   text |> int.parse |> result.map(valid_port) |> result.flatten
/// }
/// ```
///
/// Fixed:
///
/// ```gleam
/// pub fn port(text: String) -> Result(Int, Nil) {
///   text |> int.parse |> result.try(valid_port)
/// }
/// ```
///
/// [map-then-flatten](https://github.com/alvivi/grice/blob/main/docs/RULES.md#map-then-flatten)
/// in the rule reference.
pub fn map_then_flatten() -> Rule {
  map_then_flatten.rule()
}

/// `grice_rules/list-map-then-flatten`: `list.map` then `list.flatten`,
/// nested or piped. `list.flat_map` does both in one call: its docs say it
/// "Maps the list with the given function into a list of lists, and then
/// flattens it."
///
/// Flagged:
///
/// ```gleam
/// pub fn words(lines: List(String)) -> List(String) {
///   lines |> list.map(string.split(_, " ")) |> list.flatten
/// }
/// ```
///
/// Fixed:
///
/// ```gleam
/// pub fn words(lines: List(String)) -> List(String) {
///   lines |> list.flat_map(string.split(_, " "))
/// }
/// ```
///
/// [list-map-then-flatten](https://github.com/alvivi/grice/blob/main/docs/RULES.md#list-map-then-flatten)
/// in the rule reference.
pub fn list_map_then_flatten() -> Rule {
  list_map_then_flatten.rule()
}

/// `grice_rules/filter-then-length`: `list.filter` then `list.length`,
/// nested or piped. `list.filter` builds a new list only for `list.length`
/// to walk it, and `list.count` counts the elements that pass without
/// building one. It's silent where the count is checked for emptiness,
/// which `list.count` would still count in full.
///
/// Flagged:
///
/// ```gleam
/// pub fn adults(ages: List(Int)) -> Int {
///   ages |> list.filter(fn(age) { age >= 18 }) |> list.length
/// }
/// ```
///
/// Fixed:
///
/// ```gleam
/// pub fn adults(ages: List(Int)) -> Int {
///   ages |> list.count(fn(age) { age >= 18 })
/// }
/// ```
///
/// [filter-then-length](https://github.com/alvivi/grice/blob/main/docs/RULES.md#filter-then-length)
/// in the rule reference.
pub fn filter_then_length() -> Rule {
  filter_then_length.rule()
}

/// `grice_rules/reverse-then-first`: `list.reverse` then `list.first`,
/// nested or piped. `list.reverse` builds a reversed copy of the list only
/// for `list.first` to take one element of it, and `list.last` walks to
/// the last element without the copy.
///
/// Flagged:
///
/// ```gleam
/// pub fn latest(events: List(String)) -> Result(String, Nil) {
///   events |> list.reverse |> list.first
/// }
/// ```
///
/// Fixed:
///
/// ```gleam
/// pub fn latest(events: List(String)) -> Result(String, Nil) {
///   events |> list.last
/// }
/// ```
///
/// [reverse-then-first](https://github.com/alvivi/grice/blob/main/docs/RULES.md#reverse-then-first)
/// in the rule reference.
pub fn reverse_then_first() -> Rule {
  reverse_then_first.rule()
}

/// `grice_rules/fold-plus`: a `list.fold` that sums a list of ints from 0,
/// with `int.add` or an anonymous function that adds its two parameters.
/// `int.sum` adds up the same numbers: "Sums a list of ints."
///
/// On JavaScript, where an Int is a number, `int.sum` adds each element as
/// `element + total`, and adding in the other order can give a NaN result
/// other bits. So on a project whose target is JavaScript, the rule reads
/// only `fn(total, x) { x + total }`. Code built for JavaScript from a
/// project configured for Erlang, such as a library a JavaScript project
/// uses, gets every finding, and can see that difference.
///
/// Flagged, on a project whose target is Erlang:
///
/// ```gleam
/// pub fn total(prices: List(Int)) -> Int {
///   list.fold(prices, 0, int.add)
/// }
/// ```
///
/// Fixed:
///
/// ```gleam
/// pub fn total(prices: List(Int)) -> Int {
///   int.sum(prices)
/// }
/// ```
///
/// [fold-plus](https://github.com/alvivi/grice/blob/main/docs/RULES.md#fold-plus)
/// in the rule reference.
pub fn fold_plus() -> Rule {
  fold_plus.rule()
}

/// The library pack, an opt-in set that `gleam run -m grice` doesn't run:
/// every rule below this one, in the order they're listed. Each is about
/// what a package published to Hex offers its users, and reads only the
/// modules under `src/`, even when `include` selects `test/` or `dev/`.
pub fn library() -> List(Rule) {
  [internal_type_in_public_api()]
}

/// `grice_rules/internal-type-in-public-api`: a public function, constant
/// or constructor whose signature, as written, names an internal type of
/// the package: a public custom type of an internal module or marked
/// `@internal`, or a type alias that isn't public API (private, marked
/// `@internal` or in an internal module) whose definition names an internal
/// type. The type is then part of the package's public API, though the
/// documentation generated for the package has no entry for it. A type
/// named through a public alias is fine, whatever the alias stands for, and
/// an unannotated declaration isn't read. It reads only modules under `src/`
/// that aren't internal, and knows a package's internal modules from
/// `name` and `internal_modules` in its `gleam.toml`. The compiler planned
/// this warning in gleam-lang/gleam#2234, and the rule retires once the
/// compiler ships it.
///
/// Flagged, where `listener` is the internal module
/// `my_server/internal/listener`:
///
/// ```gleam
/// pub fn start(name: process.Name(listener.Message)) -> Server {
///   todo
/// }
/// ```
///
/// Fixed, with `pub type ListenerMessage = listener.Message` in a module
/// that isn't internal:
///
/// ```gleam
/// pub fn start(name: process.Name(ListenerMessage)) -> Server {
///   todo
/// }
/// ```
///
/// [internal-type-in-public-api](https://github.com/alvivi/grice/blob/main/docs/RULES.md#internal-type-in-public-api)
/// in the rule reference.
pub fn internal_type_in_public_api() -> Rule {
  internal_type_in_public_api.rule()
}
