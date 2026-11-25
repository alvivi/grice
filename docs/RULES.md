# Built-in rules

grice ships a default rule set, which `gleam run -m grice` runs. Every rule
in it reports a warning, has a code that starts with `grice_rules/`, and is
offered by the `grice/rules` module, so a project can run it beside rules
of its own.

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

A rule that is cited but sometimes wrong to apply doesn't belong in the
default set: write it as a rule of your own, or wait for an opt-in set.

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

| Code | What it flags |
|---|---|
| [`grice_rules/no-echo`](#no-echo) | An `echo` left outside `test/` and `dev/`. |
| [`grice_rules/ineffective-double-comparison`](#ineffective-double-comparison) | A comparison that the comparisons before it in its chain already decide. |

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
grice reports the `echo` with that span, which runs to the end of `f`, and
since girard can't type such a definition, a run with typed rules also adds
a `grice/untyped-definition` note on it, which `--strict` counts as a gap
even when the warning is suppressed. Braces around the `echo` step,
`{ x |> echo as "label" } |> f`, avoid both.

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

**Suppressing it.** The rule doesn't guess, so a finding is a real mistake
to fix. If a chain is generated and meant to stay as it is, ignore the rule
for that file in `gleam.toml`.
