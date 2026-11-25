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
