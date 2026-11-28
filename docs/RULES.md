# Built-in rules

grice ships a default rule set, which `gleam run -m grice` runs, and two
opt-in packs, simplify and library, which a project adds itself. Every
built-in rule reports a warning, has a code that starts with
`grice_rules/`, and is offered by the `grice/rules` module, so a project
can run it beside rules of its own.

A rule is in the default set only when it passes five tests:

1. **The compiler is silent.** `gleam build` doesn't report the code
   already. Each rule's tests compile the code it flags with
   `--warnings-as-errors` on every compiler and target grice supports.
2. **It's exact.** The rule reads the syntax tree, or asks girard for a
   type or for what a name resolved to. It never matches a name that an
   alias, an unqualified import or a local variable could change, and
   where girard has no answer it stays silent.
3. **It's cited.** The language tour, the conventions page, the standard
   library or the compiler says the flagged code is wrong, or the code is a
   bug with a concrete failure.
4. **It's clean on the core packages.** It runs over the Gleam core team's
   packages with no finding, or each finding there is a real defect,
   recorded with its reason.
5. **It finds real problems.** Real Gleam code makes the mistake.

A pack's rules pass tests 1, 2 and 4, and a project opts in to them. The
simplify pack's rules flag code that no Gleam source calls wrong (test 3):
code that is correct but takes the long way round, where one standard
library function does the same. Each rewrite it suggests gives the same
result, and calls any function passed to it the same way, fold-plus's on
the target grice lints for (see [fold-plus](#fold-plus)). The library
pack's rules are about what a package published to Hex offers its users,
so they matter to a library and not to every project, and they report only
on the modules under `src/`, which is what a package publishes.

A rule that is cited but sometimes wrong to apply doesn't belong in any
built-in set: write it as a rule of your own.

## Running the rules

```sh
gleam run -m grice
```

runs the default set over the project of the nearest `gleam.toml`. To run
it with rules of your own, call `grice.run` from an entry module of your
own, such as `dev/lint.gleam`, and add `rules.default()` to your list:

```gleam
import grice
import grice/rules
import lint/no_io_in_view

pub fn main() -> Nil {
  grice.run([no_io_in_view.rule(), ..rules.default()])
}
```

`rules.simplify()` is the simplify pack, and `rules.library()` the library
pack. No rule is in two sets, so add a pack to the default set in the same
entry module:

```gleam
import gleam/list
import grice
import grice/rules

pub fn main() -> Nil {
  grice.run(list.append(rules.default(), rules.simplify()))
}
```

Each rule is also a function of `grice/rules`, such as `rules.no_echo()`.
To change a rule's severity, list the rules by name and set it with
`rule.with_severity`; a rule you leave out of the list doesn't run:

```gleam
import grice
import grice/diagnostic
import grice/rule
import grice/rules

pub fn main() -> Nil {
  grice.run([rules.no_echo() |> rule.with_severity(diagnostic.Error)])
}
```

To turn a rule off for some files, ignore its code in `gleam.toml`, and to
hide one finding, put a suppression comment above it. Both work for
built-in codes as for any rule's (see
[Configuration](https://github.com/alvivi/grice/blob/main/docs/CONFIGURATION.md)):

```toml
[[tools.grice.ignore]]
paths = ["src/app/cli.gleam"]
rules = ["grice_rules/no-echo"]
reason = "The command line prints its results with echo."
```

```gleam
// grice-ignore grice_rules/no-echo: The demo prints each step.
echo step
```

## The rules

### The default set

| Code | What it flags |
|---|---|
| [`grice_rules/no-echo`](#no-echo) | An `echo` left outside `test/` and `dev/`. |
| [`grice_rules/ineffective-double-comparison`](#ineffective-double-comparison) | A comparison that the comparisons before it in its chain already decide. |
| [`grice_rules/no-length-for-emptiness`](#no-length-for-emptiness) | `string.length` or `list.length` compared with 0 or 1 to check for emptiness. |
| [`grice_rules/check-then-assert`](#check-then-assert) | A `Result` or an `Option` checked with a predicate, then `let assert`-ed where the check already proved its variant. |

### The simplify pack

| Code | What it flags |
|---|---|
| [`grice_rules/map-then-flatten`](#map-then-flatten) | `result.map` then `result.flatten`, or `option.map` then `option.flatten`, for `result.try` or `option.then`. |
| [`grice_rules/list-map-then-flatten`](#list-map-then-flatten) | `list.map` then `list.flatten`, for `list.flat_map`. |
| [`grice_rules/filter-then-length`](#filter-then-length) | `list.filter` then `list.length`, for `list.count`. |
| [`grice_rules/reverse-then-first`](#reverse-then-first) | `list.reverse` then `list.first`, for `list.last`. |
| [`grice_rules/fold-plus`](#fold-plus) | A `list.fold` that sums a list of ints from 0, for `int.sum`. |

Each rule finds the functions by what [girard](https://hexdocs.pm/girard)
resolved the calls to, and reads a call however it's written: nested, as
in `result.flatten(result.map(r, f))`; piped, as in
`r |> result.map(f) |> result.flatten`, with or without empty parentheses;
or piped into a capture, as in `f |> result.map(r, _)`. It doesn't join
two calls that something stands between: a block, as in
`result.flatten({ result.map(r, f) })`, a callback supplied by `use`, or a
value bound with `let` first. Nor does it read a capture nothing is piped
into. A whole composition inside a block is still read. Where girard has no
answer, it stays silent.

A finding's label covers the calls the rewrite replaces, without the value
piped into them. Its hint names the function to call and the call to drop,
as an edit in place, so the arguments are still evaluated in the order they
were (a call's labelled arguments are evaluated in its function's parameter
order, whatever order they're written in), and when the replaced call
labels an argument the new function doesn't take, it says how to write that
argument. Each rule stays silent inside the standard library function it
recommends, which may be written as the code the rule flags.

To suppress a finding, put a `grice-ignore` comment above the line its
label starts on. In a pipe written over several lines, that's the line of
the first call the label covers, after the value piped in, not the pipe's
first line:

```gleam
pub fn port(text: String) -> Result(Int, Nil) {
  text
  |> int.parse
  // grice-ignore grice_rules/map-then-flatten: Kept as two steps here.
  |> result.map(valid_port)
  |> result.flatten
}
```

**The standard library it assumes.** The hints name functions of
gleam_stdlib, and the rules don't check that the linted project's stdlib
has them. A project that runs grice with `gleam run` depends on grice, which
requires stdlib 0.44.0 or later, so it has them all. A project linted
without depending on grice, through the library API or by an entry module
built elsewhere, may have an older stdlib: `list.count`, which
filter-then-length recommends, is in stdlib 0.40.0 and later, and every
other function the hints name in 0.31.0 and later.

### The library pack

| Code | What it flags |
|---|---|
| [`grice_rules/internal-type-in-public-api`](#internal-type-in-public-api) | A public function, constant or constructor whose written signature names an internal type of the package. |
| [`grice_rules/needlessly-public-function`](#needlessly-public-function) | A public function that isn't public API, which no other Gleam module of the project refers to. |

A package published to Hex runs it beside the default set from an entry
module of its own:

```gleam
import gleam/list
import grice
import grice/rules

pub fn main() -> Nil {
  grice.run(list.append(rules.default(), rules.library()))
}
```

Its rules report only on the modules under `src/`, even when `include` in
`gleam.toml` selects `test/` or `dev/`, since tests and development tools
aren't published. needlessly-public-function still reads `test/` and
`dev/`, for the uses it looks for, so a run with the pack reads every
module of the project and its foreign sources. They know which modules are
internal from the package's `gleam.toml`: `internal_modules`, or, when that
key is absent and `name` is set, `<name>/internal` and the modules under
it.
[Configuration](https://github.com/alvivi/grice/blob/main/docs/CONFIGURATION.md#name-and-internal_modules)
says which patterns grice reads, and where its TOML reader differs from
the compiler's.

## no-echo

`grice_rules/no-echo` reports each `echo` in a module outside `test/` and
`dev/`, with or without a message, alone or in a pipeline.

**Why.** `echo` is for debug printing, as the
[release that added it](https://gleam.run/news/hello-echo-hello-git/)
introduces it. `gleam build` accepts it, but `gleam publish` refuses a
package that still has one ("`echo` is only meant for debug printing,
please remove them and try again"), so a library hears about it only when
it's published, and an application never does: it prints whenever the code
runs.

Flagged:

```gleam
pub fn total(prices: List(Int)) -> Int {
  prices |> echo |> int.sum
}
```

Fixed:

```gleam
pub fn total(prices: List(Int)) -> Int {
  prices |> int.sum
}
```

`echo x` is `x`, so remove the `echo` and keep its value. A module that
prints on purpose uses `gleam/io`.

**What it leaves alone.** Modules whose path starts with `test/` or `dev/`,
even when `include` in `gleam.toml` selects them: tests and development
tools may print as they like.

**A known gap.** In `x |> echo as "label" |> f`, the compiler pipes the
`echo`'s result into `f`, but the parser grice uses,
[glance](https://hexdocs.pm/glance), reads `"label" |> f` as the message.
grice reports the `echo` with that span, which runs to the end of `f`.
girard can't type such a definition either, so a run with typed rules,
the default set's among them, also adds a `grice/untyped-definition` note
on it, which `--strict` counts as a gap even when the warning is
suppressed. Braces around the `echo` step,
`{ x |> echo as "label" } |> f`, give the warning its short span, on
`echo as "label"`, and avoid the coverage note.

**Suppressing it.** A module under `src/` that prints with `echo` on
purpose, such as a script, takes an ignore in `gleam.toml` or a
`grice-ignore-file` comment, with the reason.

## ineffective-double-comparison

`grice_rules/ineffective-double-comparison` reports a comparison, in a
chain of `&&` or of `||`, that the comparisons before it already decide.
It compares a variable, or a field access on one such as `point.x`, with an
Int literal, using `<`, `<=`, `>`, `>=` or `==`, with the literal on either
side and in any spelling: decimal, `0x`, `0o` or `0b`, negative or not.

In a chain of `&&`, the comparison is either always true where it runs,
because the ones before it imply it, or never true together with them, so
the whole chain is always `False`. In a chain of `||`, it can only be true
where a comparison before it already was, so it never changes the result.
The diagnostic marks the comparisons that decide it.

**Why.** It's a bug: one of the comparisons doesn't say what was meant.
Most often it's a range written the wrong way round. gleam_stdlib's
`uri.gleam` had three, `{ 48 >= char && char <= 57 }` among them, which
made the JavaScript URI parser reject bracketed IPv6 hosts with the hex
digits b to f
([gleam-lang/stdlib#881](https://github.com/gleam-lang/stdlib/issues/881)).

Flagged, since `48 >= char` is `char <= 48`, so `char <= 57` is always true
where it runs:

```gleam
pub fn is_digit(char: Int) -> Bool {
  48 >= char && char <= 57
}
```

Fixed:

```gleam
pub fn is_digit(char: Int) -> Bool {
  48 <= char && char <= 57
}
```

**What it leaves alone.**

- The earlier comparison, even when a later one implies it, as in
  `count > 0 && ready && count > 5`: it still guards what runs in between.
- A comparison that is always true in a chain of `||`, as the last one in
  `count < 0 || count > 0 || count == 0`. On JavaScript an Int can be NaN,
  which fails all three.
- `!=`, which NaN passes, comparisons of Floats, and comparisons of
  anything but a variable or a field access with an Int literal, such as
  of a call or a tuple index, or with a named constant in place of the
  literal. Any other operand, such as a call or a block, adds nothing, but
  the facts carry across it, so `count > 5 && ready && count > 0` is still
  reported. A block or a chain of the other operator is judged on its own.
- A literal outside JavaScript's safe integers, `-(2^53 - 1)` to
  `2^53 - 1`, so the verdict is the same on both targets.
- A decision that takes more than two comparisons to show, such as
  `count >= 3 || count == 0 || count == 1 || count == 2 || count >= 0`.

**Suppressing it.** The rule doesn't guess, so a finding is a mistake to
fix. To keep one, as in generated code, put
`// grice-ignore grice_rules/ineffective-double-comparison: <reason>` on
the line above it, or ignore the rule for the file in `gleam.toml`.

## no-length-for-emptiness

`grice_rules/no-length-for-emptiness` reports `string.length` or
`list.length` used to check whether a string or a list is empty: compared
with 0 or 1 as `== 0`, `!= 0`, `> 0`, `>= 1`, `< 1` or `<= 0`, with the
literal on either side and in any spelling, or matched in a `case` with a
lone `0` pattern followed by a discard.

It finds the two functions by what [girard](https://hexdocs.pm/girard)
resolved the call to, so it sees them under any alias, imported
unqualified, or as the function after a pipe, with or without empty
parentheses: `name |> string.length == 0`. Where girard has no answer, it
stays silent.

**Why.** Both functions walk the whole value to count it, to answer a
question comparing with `""` or `[]` answers at once.
[`string.length`](https://hexdocs.pm/gleam_stdlib/gleam/string.html#length)'s
docs say so: "This function has to iterate across the whole string to
count the number of graphemes, so it runs in linear time. Avoid using this
in a loop." The compiler says the same of `list.length` when it warns on
`list.length(items) == 0`.

Flagged:

```gleam
pub fn greeting(name: String) -> String {
  case string.length(name) > 0 {
    True -> "Hello, " <> name
    False -> "Hello"
  }
}
```

Fixed:

```gleam
pub fn greeting(name: String) -> String {
  case name != "" {
    True -> "Hello, " <> name
    False -> "Hello"
  }
}
```

A `case string.length(name) { 0 -> ... _ -> ... }` becomes
`case name { "" -> ... _ -> ... }`.

**What it leaves alone.**

- The `list.length` forms the compiler already warns on: a direct call
  through a module access, as in `list.length(items)` under any alias,
  compared with a literal written exactly `0` or `-0` as `== 0`, `!= 0`,
  `> 0` or `<= 0`, or exactly `1` as `< 1`, with the literal on either
  side. The compiler's boundary is the spelling, so the rule reports the
  rest: `>= 1`, `== 0x0`, pipes, unqualified calls and the `case` form.
- A `case` that counts rather than checks for emptiness: one that matches
  another number, binds the length, guards the `0` clause or gives it an
  alternative.
- A comparison with any other number, with a named constant, or with
  another length.

**Suppressing it.** Comparing with `""` or `[]` is never slower, so a
finding is worth fixing. To keep one, put
`// grice-ignore grice_rules/no-length-for-emptiness: <reason>` on the
line above it.

## check-then-assert

`grice_rules/check-then-assert` reports a `let assert` on a `Result` or an
`Option` that a check has already proved: `result.is_ok`,
`result.is_error`, `option.is_some` or `option.is_none` on the same
variable, called directly or after a pipe, negated with `!` or not. It
follows the check along the paths where it holds:

- a `case` on the check: a `True` or `False` clause, guarded or not, and a
  fallback after an unguarded `True` or `False` clause;
- `bool.guard` and `bool.lazy_guard`, with their arguments placed as the
  compiler places them: labelled ones in the slots of their labels, then
  unlabelled ones and the `use` continuation in the slots left, in order.
  The paths are the `use` continuation, and an anonymous function passed
  as `lazy_guard`'s `return` or as either guard's `otherwise`.

The assert's pattern must ask for no more than the variant, with only
discards and variables inside it, such as `Ok(value)` or `None`. The rule
finds the predicates and the guards by what girard resolved, and reads the
pattern's constructor through the module's imports, so
`import gleam/option.{Some as Present}` makes `Present(value)` the same as
`Some(value)`.

**Why.** Gleam's
[conventions page](https://gleam.run/documentation/conventions-patterns-and-anti-patterns/),
in its "Check-then-assert" section, calls checking a value and then
asserting its shape "an anti-pattern in functional languages like Gleam,
and it should never be done". The check and the assert can drift apart as
the code changes, and a `case` says the same thing once.

Flagged:

```gleam
pub fn port(text: String) -> Int {
  let parsed = int.parse(text)
  use <- bool.guard(when: result.is_error(parsed), return: 80)
  let assert Ok(port) = parsed
  port
}
```

Fixed:

```gleam
pub fn port(text: String) -> Int {
  case int.parse(text) {
    Ok(port) -> port
    Error(Nil) -> 80
  }
}
```

**What it leaves alone.**

- What the compiler already reports. When the compiler knows a variable's
  variant, it warns on a redundant assertion itself, so the rule only
  looks at a function's parameters, the parameters of an anonymous
  function or a `use` callback, and a `let` of a call or a pipe into a
  module function. It's silent on a variable bound to a constructor or to
  another variable, and on one an earlier `let assert` or an enclosing
  `case` clause has matched against a constructor, directly or through
  `echo`.
- An assert the check disproves, such as `let assert Error(e) = x` where
  `result.is_ok(x)` is true: it always fails, a sharper problem than this
  rule's.
- An assert that asks for more than the variant, such as `Ok(0)`, and one
  with `as` on its pattern or a spread, such as `Ok(v) as result` or
  `Ok(..)`.
- A fallback that can still see either value, as after a guarded
  `True if allowed ->` clause, a clause with alternatives, a `case` on
  several subjects, a check stored in a variable, and a guard's callback
  passed by name. `bool.guard`'s `return` is computed before the check, so
  it's on no path.
- A variable rebound since the check, by a `let`, a pattern or a
  parameter.

**Suppressing it.** Rewrite the check and the assert as one `case`. To keep
one, put `// grice-ignore grice_rules/check-then-assert: <reason>` on the
line above the assert.

## map-then-flatten

`grice_rules/map-then-flatten` reports `result.map` followed by
`result.flatten`, and `option.map` followed by `option.flatten`, in every
form the pack reads: `result.flatten(result.map(r, f))`,
`result.map(r, f) |> result.flatten` and
`r |> result.map(f) |> result.flatten`.

**Why.** [`result.try`](https://hexdocs.pm/gleam_stdlib/gleam/result.html#try)
does both in one call: its docs say it "is the equivalent of calling `map`
followed by `flatten`", and it's the function `use` chains fallible steps
with. [`option.then`](https://hexdocs.pm/gleam_stdlib/gleam/option.html#then)
is the same for `Option`. Each calls the function once on an `Ok` or a
`Some`, never on an `Error` or a `None`, and gives the same result as the
two calls.

Flagged:

```gleam
pub fn port(text: String) -> Result(Int, Nil) {
  text |> int.parse |> result.map(valid_port) |> result.flatten
}
```

Fixed:

```gleam
pub fn port(text: String) -> Result(Int, Nil) {
  text |> int.parse |> result.try(valid_port)
}
```

`result.try` and `option.then` take their first argument unlabelled and
label their function `apply:`, so the hint says how to write labelled
arguments: `result.map(over: r, with: f)` becomes
`result.try(r, apply: f)`, and a shorthand `with:` becomes `apply: with`.

**What it leaves alone.** A `map` or a `flatten` alone, a `map` followed by
another function, and the forms the pack doesn't read. Inside `result.try`
and `option.then` themselves.

**Suppressing it.** The rewrite gives the same result, so a finding is
worth fixing. To keep the two steps, put
`// grice-ignore grice_rules/map-then-flatten: <reason>` on the line above
it.

## list-map-then-flatten

`grice_rules/list-map-then-flatten` reports `list.map` followed by
`list.flatten`, in every form the pack reads:
`list.flatten(list.map(xs, f))`, `list.map(xs, f) |> list.flatten` and
`xs |> list.map(f) |> list.flatten`.

**Why.** [`list.flat_map`](https://hexdocs.pm/gleam_stdlib/gleam/list.html#flat_map)
does both in one call. Its docs say it "Maps the list with the given
function into a list of lists, and then flattens it", and the standard
library writes it as exactly that, so it calls the function the same way
and gives the same list. It has a code of its own, apart from
map-then-flatten, as it's far more common in application code, so a
project can take one rule without the other.

Flagged:

```gleam
pub fn words(lines: List(String)) -> List(String) {
  lines |> list.map(string.split(_, " ")) |> list.flatten
}
```

Fixed:

```gleam
pub fn words(lines: List(String)) -> List(String) {
  lines |> list.flat_map(string.split(_, " "))
}
```

**What it leaves alone.** A `map` or a `flatten` alone, a `map` followed by
another function, a `flatten` followed by a `map`, and the forms the pack
doesn't read. Inside `list.flat_map` itself, which the standard library
writes as `flatten(map(list, fun))`.

**Suppressing it.** The rewrite gives the same result, so a finding is
worth fixing. To keep the two steps, put
`// grice-ignore grice_rules/list-map-then-flatten: <reason>` on the line
above it.

## filter-then-length

`grice_rules/filter-then-length` reports `list.filter` followed by
`list.length`, in every form the pack reads:
`list.length(list.filter(xs, p))`, `list.filter(xs, p) |> list.length`
and `xs |> list.filter(p) |> list.length`, with `list.length`'s `of:`
label or without.

**Why.** `list.filter` builds a new list that `list.length` then walks to
count. [`list.count`](https://hexdocs.pm/gleam_stdlib/gleam/list.html#count)
counts the elements that pass without building one: "Counts the number of
elements in a given list satisfying a given predicate." It calls the
predicate once per element, first to last, as `list.filter` does.

Flagged:

```gleam
pub fn adults(ages: List(Int)) -> Int {
  ages |> list.filter(fn(age) { age >= 18 }) |> list.length
}
```

Fixed:

```gleam
pub fn adults(ages: List(Int)) -> Int {
  ages |> list.count(fn(age) { age >= 18 })
}
```

`list.count` labels its predicate `where:`, where `list.filter` has
`keeping:`, so the hint says how to write a labelled one:
`list.filter(xs, keeping: p)` becomes `list.count(xs, where: p)`, and a
shorthand `keeping:` becomes `where: keeping`.

**What it leaves alone.**

- A count checked for emptiness, such as
  `xs |> list.filter(p) |> list.length > 0` or a `case` on it with a lone
  `0` clause: `list.count` would still count every element. The compiler
  reports `list.length(list.filter(xs, p)) == 0`, and
  no-length-for-emptiness the pipe and the `case`. Their fix checks the
  filtered list in place of its count: `list.filter(xs, p) != []` for a
  count checked as not empty (`> 0`, `!= 0`, `>= 1`),
  `list.filter(xs, p) == []` for one checked as empty (`== 0`, `< 1`,
  `<= 0`), and a `case` on `list.filter(xs, p)` with an `[]` clause in
  place of the `0` clause. Each still runs the filter in full and builds
  its list, but doesn't count it. A captured length,
  `xs |> list.filter(p) |> list.length(of: _) > 0`, gets no finding from
  either today. A count compared with any other number, such as `> 1`, is
  reported.
- A `filter` or a `length` alone, a `filter` followed by another function,
  and the forms the pack doesn't read. Inside `list.count` itself.

**Suppressing it.** The rewrite gives the same count, so a finding is worth
fixing. To keep the two steps, put
`// grice-ignore grice_rules/filter-then-length: <reason>` on the line
above it.

## reverse-then-first

`grice_rules/reverse-then-first` reports `list.reverse` followed by
`list.first`, in every form the pack reads:
`list.first(list.reverse(xs))`, `list.reverse(xs) |> list.first` and
`xs |> list.reverse |> list.first`.

**Why.** `list.reverse` builds a reversed copy of the whole list only for
`list.first` to take one element of it.
[`list.last`](https://hexdocs.pm/gleam_stdlib/gleam/list.html#last) walks
to the last element without the copy. Both give `Error(Nil)` for an empty
list and the last element otherwise, and neither takes a function.

Flagged:

```gleam
pub fn latest(events: List(String)) -> Result(String, Nil) {
  events |> list.reverse |> list.first
}
```

Fixed:

```gleam
pub fn latest(events: List(String)) -> Result(String, Nil) {
  events |> list.last
}
```

**What it leaves alone.** A `reverse` or a `first` alone, a `reverse`
followed by another function, a `first` of anything else, and the forms the
pack doesn't read. Inside `list.last` itself.

**Suppressing it.** The rewrite gives the same result, so a finding is
worth fixing. To keep the two steps, put
`// grice-ignore grice_rules/reverse-then-first: <reason>` on the line
above it.

## fold-plus

`grice_rules/fold-plus` reports a `list.fold` that sums a list of ints
from 0: its initial value is the literal `0`, written without a sign in
any spelling, such as `0x0`, and its function is `int.add`, under any
alias, or an anonymous function of two named parameters whose body is
only their sum, annotated or not: `fn(total, x) { total + x }` or
`fn(total, x) { x + total }`. The arguments are matched as Gleam matches
them, so `list.fold(xs, with: int.add, from: 0)` is read too, and a piped
fold only when the pipe supplies the list: `xs |> list.fold(0, int.add)`.

**Why.** [`int.sum`](https://hexdocs.pm/gleam_stdlib/gleam/int.html#sum)
adds up the same numbers: "Sums a list of ints." On Erlang both add the
same integers from 0, left to right.

On JavaScript, where an Int is a number, `int.sum` adds each element as
`element + total`, while the fold with `int.add` or
`fn(total, x) { total + x }` adds `total + element`. Swapping the operands
of an addition keeps the number, but a NaN result, as from an Int that
overflowed, can come out with other bits, which a float segment of a bit
array, or the order of a dict's entries on JavaScript, can show. So on a
project whose target is JavaScript, the rule reads only
`fn(total, x) { x + total }`, which adds as `int.sum` does, and leaves
`int.add` and `fn(total, x) { total + x }` alone. The target is the one in
`gleam.toml`, the one grice lints for: code of a project configured for
Erlang, or with no target, gets every finding even when it's also built
for JavaScript, as a library a JavaScript project uses or with
`gleam run --target javascript`, and there it can see that difference.

Flagged, on a project whose target is Erlang:

```gleam
pub fn total(prices: List(Int)) -> Int {
  list.fold(prices, 0, int.add)
}
```

Fixed:

```gleam
pub fn total(prices: List(Int)) -> Int {
  int.sum(prices)
}
```

**What it leaves alone.**

- A fold from anything but an unsigned `0`: `-0` is negative zero on
  JavaScript, which the fold returns for an empty list and `int.sum`
  doesn't.
- A function that does more than add its two parameters, such as
  `fn(sum, row) { sum + width(row) }`, adds a parameter to itself, or
  discards one; a named function other than `int.add`; and `add` passed
  unqualified, which girard doesn't resolve as a value.
- A fold piped its initial value or its function, such as
  `0 |> list.fold(xs, _, int.add)`, which the edit would turn into
  `0 |> int.sum(xs)`.
- Floats: `list.fold(xs, 0.0, float.add)` isn't read.
- Inside `int.sum` itself.

**Suppressing it.** The rewrite gives the same sum, so a finding is worth
fixing. To keep the fold, put
`// grice-ignore grice_rules/fold-plus: <reason>` on the line above it.

## internal-type-in-public-api

`grice_rules/internal-type-in-public-api` reports a type name, written in
the signature of a public declaration of the package, that stands for an
internal type. It reads, in a module under `src/` that isn't internal, the
public declarations not marked `@internal`: each annotated parameter and
the return annotation of a function, external ones included, the
annotation of a constant, and the fields of each constructor of a custom
type that isn't opaque. Within an annotation it reads every named type, at
any depth: in type arguments, in the parameters and return of a function
type, and in the elements of a tuple. Each internal one is a finding, at
the name, so a signature that names two internal types, or one twice,
gets a finding for each.

A type is internal when it's a public custom type of an internal module,
or one marked `@internal`, or a type alias that isn't public API, because
it's private, marked `@internal` or in an internal module, and that names
an internal type. A type name resolves as the compiler resolves it, from
the module's imports and the types it defines, so an import's alias or an
unqualified import doesn't hide a type.

**Why.** The gleam.toml reference says "An internal module is a module
that is not part of the public API of the package", and `@internal` marks a
single definition the same way. A public signature that names an internal
type makes it part of the public API all the same: users get values of it
and write code against it, though the package marked it as outside its
public API, and the documentation generated for the package has no entry
for it. The compiler planned this warning in
[gleam-lang/gleam#2234](https://github.com/gleam-lang/gleam/issues/2234):
it was added in the v1.1 release candidates and reverted, and waits on how
the compiler handles type aliases. As the issue asks, a type named through
a public alias is fine.

Flagged, where `listener` is the internal module
`my_server/internal/listener`:

```gleam
import gleam/erlang/process
import my_server/internal/listener

pub fn start(name: process.Name(listener.Message)) -> Server {
  todo
}
```

Fixed, with a public alias the module can import:

```gleam
import gleam/erlang/process
import my_server/internal/listener

pub type ListenerMessage =
  listener.Message

pub fn start(name: process.Name(ListenerMessage)) -> Server {
  todo
}
```

Each finding's hint offers the fixes in turn: give the type a public name,
with a public alias or by moving it to a module that isn't internal; for a
type marked `@internal`, remove the attribute if users need the type; for a
private alias, make it public. When the module that defines a public alias
of the type imports the flagged module, naming that alias would be an
import cycle, so the hint offers adding a public alias to the flagged
module instead. If the declaration isn't meant for users, mark it
`@internal` instead. A constructor can't be marked `@internal`, so for one
the hint offers making its type opaque, or marking the whole type
`@internal`.

**What it leaves alone.**

- A type named through a public alias, a public type alias in a module
  that isn't internal and not marked `@internal`, whatever it stands for:
  the package chose a public name for it. That holds for a private alias
  of a public alias too, though the documentation can print the private
  alias's name. The written arguments of a public alias still count:
  `a.BoxAlias(thing.Thing)` names `thing.Thing`.
- Type alias definitions themselves: a public alias is how a package gives
  an internal type a public name.
- A declaration with no annotation, whose inferred type the rule doesn't
  read, since inference can't tell a public alias from the type it names.
- Private declarations, declarations marked `@internal`, the constructors
  of an opaque type, and annotations inside a function's body.
- Internal modules themselves, and every module outside `src/`.
- A dependency's types, whatever its `gleam.toml` says: grice doesn't read
  a dependency's configuration.
- A type grice can't see: one of a module that doesn't parse, or one it
  didn't load because no linted module imports its module.
- Declarations and imports for the other target, as the rest of grice
  leaves them out.

**What the documentation shows.** `gleam docs build` prints a signature's
inferred type, not the one written. Where that type holds an internal type,
it prints an alias of it instead, if one with the same parameters is
registered, which depends on aliases elsewhere in the package and on the
order its modules compile in. So a page can print a public name for a type
the rule reports, and an internal type for an alias the rule accepts. The
rule follows the written signature, which the package controls, and its
message claims nothing about the page.

**Internal modules.** The rule knows them from `name` and
`internal_modules` in `gleam.toml`. grice reads only literal characters,
`*` and `?` in a pattern there, and any other glob syntax stops the run.
[Configuration](https://github.com/alvivi/grice/blob/main/docs/CONFIGURATION.md#module-patterns)
gives the syntax, the rewrites the compiler reads the same way for a few
common patterns, what to do for the others, and the spellings grice's TOML
reader reads differently from the compiler's. A project with no `name` has
no default internal modules.

**Suppressing it.** The fix is usually one name, so a finding is worth
fixing. To keep a signature as it is, put
`// grice-ignore grice_rules/internal-type-in-public-api: <reason>` on the
line above the type's name, or ignore the code in `gleam.toml` for the
paths it covers.

**Retirement.** The rule retires when the compiler ships gleam#2234, which
would report the same code.

## needlessly-public-function

`grice_rules/needlessly-public-function` reports a public function that
isn't part of the package's public API and that no other Gleam module of
the project refers to. It reads the public
functions, external ones included, of each linted module under `src/`, as
compiled for the target, that are in an internal module or marked
`@internal`, and reports each one nothing else uses, at its name.

A use is read in every module of the project, under `src/`, `test/` and
`dev/`, linted or not, and in its code for every target, so a function
that only the JavaScript build, or only a test, calls is used. It's any of:

- `q.f`, in a function or a constant of another module, where `q`
  qualifies an import of the function's module: the import's alias, or
  the module's last segment.
- An unqualified import of the function, `import m.{f}` or
  `import m.{f as g}`, whether or not it's used.
- An `@external` that names the module and the function, by the module's
  Erlang name, such as `@external(erlang, "my_app@internal@parser", "f")`,
  or by its JavaScript file, such as
  `@external(javascript, "./internal/parser.mjs", "f")`, in any module,
  the function's own included: there the compiler still calls it as an
  export. A JavaScript module that isn't a relative path to a `.mjs`
  file, such as a subpath of the package's own name,
  `@external(javascript, "my_app/parser-api", "f")`, which `package.json`
  may lead to any module, makes it a use of every candidate with that
  function's name.
- A foreign source that names the module and the function as written:
  one of the compiler's native files under `src/`, `test/` or `dev/`,
  ending in `.erl`, `.hrl`, `.ex`, `.js`, `.mjs`, `.cjs`, `.jsx`, `.ts`,
  `.mts`, `.cts` or `.tsx`, that holds the module's Erlang name as a word,
  or its JavaScript file name, such as `parser.mjs`, with no directory, and
  the function's name as a word.

A plain call in the function's own module doesn't count: once the function
is private, the compiler reports it if its module doesn't use it either.

**Why.** The gleam.toml reference says "An internal module is a module
that is not part of the public API of the package", and `@internal` marks a
single definition the same way. The compiler warns about a private function
nothing uses, and says nothing about a public one. A public function
that isn't public API and that no other module uses doesn't need `pub`,
which only hides it from that warning. Making it private hands it back to
the compiler. Other public functions are left alone: they're the package's
public API, which users call though no module of the package does.

Flagged, where `my_app/internal/parser` is an internal module and no other
module refers to `parse_line`:

```gleam
pub fn parse_line(line: String) -> Result(Entry, Nil) {
  todo
}
```

Fixed:

```gleam
fn parse_line(line: String) -> Result(Entry, Nil) {
  todo
}
```

**Foreign code.** The foreign check keeps the rule silent where a foreign
file plainly names the function, so most FFI uses don't show. It reads
names only as they're written in one file: it doesn't resolve escapes,
such as JavaScript's `\u0065` or Erlang's `\x{61}`, includes or macros,
module aliases such as an import map in `package.json`, or names built at
run time, as Erlang's `apply` does with an atom made from a string. So the
finding claims only that no other Gleam module refers to the function,
and asks you to check that no foreign code uses it, re-exports included,
before making it private.

**How it reads.** A name the compiler accepts means one thing, so the rule
reads the syntax tree and needs no types. Where it can't tell, it counts a
use: a parameter named like a qualifier, as in `fn(parser) { parser.parse }`,
or the names anywhere in a foreign source, even in a comment.

**What it leaves alone.**

- `main`, which `gleam run -m` runs, and `start` in the module that
  `application_start_module` in `gleam.toml`'s `[erlang]` table names,
  which the Erlang runtime calls when the application starts.
  [Configuration](https://github.com/alvivi/grice/blob/main/docs/CONFIGURATION.md#application_start_module)
  says how grice reads that key.
- Functions of a module that isn't internal, unless they're marked
  `@internal`, private functions, and functions for the other target.
- Modules outside `src/`, and modules `exclude` leaves out of the lint
  set: their functions aren't read, though their uses are.
- Reachability: functions that only call each other, none called from
  outside, count as used.

**A whole-project rule.** It reads every module of the project and its
foreign sources, which grice loads only for a rule like it. A file under
`src/`, `test/` or `dev/` that grice can't list, such as a dangling link,
or a module of the lint set and what it imports that can't be read, stops
the run, as in every run. When any other module or foreign source can't
be read, a `.gleam` file there isn't one grice can name as a module, or
any module of the project doesn't parse, the lint set's included, the
rule doesn't run, since a use there could make a finding false, and a
`grice/incomplete-project` note lists the files. A package published to Hex ships no
`test/`, so linted from its Hex tarball rather than its repository, a
function only its tests use reads as unused.

**Suppressing it.** To keep a function public, put
`// grice-ignore grice_rules/needlessly-public-function: <reason>` on the
line above it, or ignore the code in `gleam.toml` for the paths it covers.
