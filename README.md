# grice

[![CI](https://github.com/alvivi/grice/actions/workflows/ci.yml/badge.svg)](https://github.com/alvivi/grice/actions/workflows/ci.yml)

A type-aware linter for Gleam, with clear, compiler-style diagnostics.

## Why?

Gleam already has a strict compiler, and grice never repeats what
`gleam build` reports. What a linter can add is the house rules a team wants
as a CI gate: "no `io` in `view`", "every handler returns our `AppError`",
"don't call `wisp.log_*` outside `web/`". Many of those can't be written
correctly from syntax alone, because they depend on what an expression's type
is or which definition a name refers to.

grice is built for that:

- **Type-aware.** Rules can ask [girard](https://hexdocs.pm/girard) for the
  inferred type of any expression and for the definition any name or field
  access resolved to. When [girard](https://hexdocs.pm/girard) has no
  answer, a rule stays silent rather than guessing: a missed warning is
  cheaper than a false one.
- **Compiler-style diagnostics.** Output follows the Gleam compiler's
  layout, and the messages say what is wrong, why it matters and how to fix
  it. Every diagnostic has a stable rule code, and there is a versioned JSON
  form for tools.
- **Rules are Gleam code.** The rule set and its severities are ordinary Gleam
  values, checked by the compiler. `gleam.toml` holds only paths and ignores,
  and grice rejects configuration it doesn't understand instead of ignoring
  it.
- **Fast by construction.** Each file is parsed once, modules are linted in
  parallel, and type inference only runs when an enabled rule needs it.

## Usage

grice runs on Erlang or on JavaScript, with Node. `gleam run` compiles a
module for the target of the package it belongs to, unless `--target`
names another: a project's own entry module runs on the project's target,
and `grice`, a module of grice's, which sets no target, runs on Erlang.

### Adding grice

grice is a dev dependency: your code doesn't depend on it, only your lint
runs do. grice won't be on Hex until 1.0. Until then, each release is a tag
on GitHub, which you add to `[dev_dependencies]` in your `gleam.toml`:

```toml
[dev_dependencies]
grice = { git = "https://github.com/alvivi/grice.git", ref = "v0.2.0" }
```

### Running the built-in rules

`gleam run -m grice` runs grice's default rule set. Each rule reports a
warning:

- `grice_rules/no-echo`: an `echo` left outside `test/` and `dev/`.
- `grice_rules/ineffective-double-comparison`: a comparison that the ones
  before it in a chain of `&&` or `||` already decide, such as a range
  written the wrong way round.
- `grice_rules/no-length-for-emptiness`: `string.length` or `list.length`
  compared with 0 or 1, or matched on 0, to check for emptiness.
- `grice_rules/check-then-assert`: a `Result` or an `Option` checked with a
  predicate, then `let assert`-ed where the check already proved it.

[Built-in rules](https://github.com/alvivi/grice/blob/main/docs/RULES.md)
describes each rule, what it leaves alone and why, and how to change its
severity or turn it off.

```sh
gleam run -m grice
```

grice lints the project of the nearest `gleam.toml`, from the working
directory upwards, and prints its diagnostics and a summary. Options go
after `--`, which ends `gleam`'s own options:

```sh
gleam run -m grice -- --format json
```

This runs grice on Erlang, whatever the project's target. To run the
built-in rules on Node, name the target:

```sh
gleam run --target javascript -m grice
```

The simplify pack is a second set of built-in rules, which
`gleam run -m grice` doesn't run: code that is correct but takes the long
way round, where one standard library function does the same, with the same
result on the target grice lints for. fold-plus's rewrite can give a NaN
sum other bits in code also built for JavaScript, as its section of the
reference says:

- `grice_rules/map-then-flatten`: `result.map` then `result.flatten`, or
  `option.map` then `option.flatten`, for `result.try` or `option.then`.
- `grice_rules/list-map-then-flatten`: `list.map` then `list.flatten`, for
  `list.flat_map`.
- `grice_rules/filter-then-length`: `list.filter` then `list.length`, for
  `list.count`.
- `grice_rules/reverse-then-first`: `list.reverse` then `list.first`, for
  `list.last`.
- `grice_rules/fold-plus`: a `list.fold` that sums a list of ints from 0,
  for `int.sum`.

To run it, add `rules.simplify()` to the default set in an entry module of
your own, as [Running your own rules](#running-your-own-rules) shows:

```gleam
grice.run(list.append(rules.default(), rules.simplify()))
```

### Running your own rules

Rules are Gleam code. Write them with `grice/rule`, and run them from an
entry module of your own, such as `dev/lint.gleam`, with the built-in rules
of `grice/rules` you want beside them:

```gleam
import grice
import grice/rules
import lint/no_io_in_view

pub fn main() -> Nil {
  grice.run([no_io_in_view.rule(), ..rules.default()])
}
```

Then run that module:

```sh
gleam run -m lint -- --strict
```

Modules in `dev/` can use dev dependencies, and they aren't linted unless
`include` in `gleam.toml` selects them.

### Testing your rules

`grice/testing` runs rules over a small project built in memory, the way
`grice.run` runs them over yours. It needs no other dependency and works
with any test runner:

```gleam
import grice/testing
import my_rules/no_echo

pub fn no_echo_reports_each_echo_test() {
  testing.module("pub fn main() {\n  echo 1\n  echo 2\n}\n")
  |> testing.run([no_echo.rule()])
  |> testing.expect_codes(["my_rules/no-echo", "my_rules/no-echo"])
}

pub fn no_echo_is_silent_without_echo_test() {
  testing.module("pub fn main() {\n  1\n}\n")
  |> testing.run([no_echo.rule()])
  |> testing.expect_none
}
```

`testing.module` is a project with one module, `src/app.gleam`.
`testing.expect_codes` checks that the run shows exactly the codes given,
in order, and `testing.expect_none` that it shows none. When they don't
match, the test fails with the fixture and what grice printed for it.

[Testing rules](https://github.com/alvivi/grice/blob/main/docs/TESTING.md)
covers projects with several modules, typed rules, and the other ways to
check a run: reading its diagnostics, and snapshots of what grice prints.

### JavaScript projects

A project whose target is JavaScript runs grice as any other, on its own
target:

```sh
gleam run -m lint -- --strict
```

grice then runs on Node, with the same diagnostics, JSON and exit codes as
on Erlang. Node's stack is much smaller than Erlang's, though, so a very
large module or very deeply nested code can run grice out of stack there.

### Options

| Option | What it does |
|---|---|
| `--format human` | Diagnostics and a summary, for a person. The default. |
| `--format json` | One JSON document, for tools. See [JSON output](https://github.com/alvivi/grice/blob/main/docs/JSON.md). |
| `--warnings-as-errors` | Fail the run when it shows a warning. Severities print unchanged. |
| `--strict` | Fail the run when its coverage has a gap: code grice couldn't parse or type. |
| `--no-color` | Don't colour the output. It's coloured only on a terminal, and never when `NO_COLOR` is set to a non-empty value. |
| `--stats` | Show how long loading and linting took, in milliseconds, and on Erlang in reductions. |
| `-h`, `--help` | Show the help. |

Each option may be given once, and in any order. grice takes no paths:
`include` and `exclude` in `gleam.toml` choose what it lints (see
[Configuration](https://github.com/alvivi/grice/blob/main/docs/CONFIGURATION.md)).

### Exit codes

| Code | Meaning |
|---|---|
| 0 | No error shown. |
| 1 | An error shown, or a warning or a coverage gap that `--warnings-as-errors` or `--strict` counts as one. Notes never fail a run. |
| 2 | No result: a usage error, no `gleam.toml`, a project that couldn't be loaded, a rule set with problems, or an internal error. |

### Configuration

`[tools.grice]` in `gleam.toml` chooses the files to lint and holds
ignores, and `grice-ignore` comments hide a diagnostic in the source. Both
are described in [Configuration](https://github.com/alvivi/grice/blob/main/docs/CONFIGURATION.md).

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the development workflow and the
code and commit conventions, and [`AGENTS.md`](AGENTS.md) for the design
principles and the planned architecture.

## License

grice is licensed under the [Apache License 2.0](LICENSE).
