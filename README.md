# grice

[![CI](https://github.com/alvivi/grice/actions/workflows/ci.yml/badge.svg)](https://github.com/alvivi/grice/actions/workflows/ci.yml)

A type-aware linter for Gleam, with clear, compiler-style diagnostics.

> **Status: early development.** grice has no built-in rules yet, and it is
> not published on Hex. It has the API for writing rules, which can ask
> girard for types, and a kit for testing them, and runs them from the
> command line, with output in the compiler's style or as JSON. It reports
> what the types don't cover, and diagnostics can be hidden by ignores in
> `gleam.toml` and by `grice-ignore` comments, with a warning for each
> suppression that hides nothing.

## Why?

Gleam already has a strict compiler, and grice never repeats what
`gleam build` reports. What a linter can add is the house rules a team wants
as a CI gate: "no `io` in `view`", "every handler returns our `AppError`",
"don't call `wisp.log_*` outside `web/`". Many of those can't be written
correctly from syntax alone, because they depend on what an expression's type
is or which definition a name refers to.

grice is built for that:

- **Type-aware.** Rules can ask [girard](https://github.com/alvivi/girard)
  for the inferred type of any expression and for the definition any name or
  field access resolved to. When girard has no answer, a rule stays silent
  rather than guessing: a missed warning is cheaper than a false one.
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

grice sits beside [girard](https://github.com/alvivi/girard) (Hindley-Milner
type annotation for Gleam) and [graded](https://github.com/alvivi/graded)
(effect checking for Gleam).

## Usage

grice runs on the Erlang target, so it needs Erlang/OTP installed, even for
a project that targets JavaScript.

### Adding grice

grice is a dev dependency: your code doesn't depend on it, only your lint
runs do.

```sh
gleam add --dev grice
```

grice isn't on Hex yet. Until it is, add it to `[dev_dependencies]` as a
git or path dependency.

### Running the built-in rules

```sh
gleam run -m grice
```

grice lints the project of the nearest `gleam.toml`, from the working
directory upwards, and prints its diagnostics and a summary. Options go
after `--`, which ends `gleam`'s own options:

```sh
gleam run -m grice -- --format json
```

### Running your own rules

Rules are Gleam code. Write them with `grice/rule`, and run them from an
entry module of your own, such as `dev/lint.gleam`:

```gleam
import grice
import lint/no_echo

pub fn main() -> Nil {
  grice.run([no_echo.rule()])
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

A project whose target is JavaScript runs grice on Erlang:

```sh
gleam run --target erlang -m lint -- --strict
```

Its JavaScript builds still compile `dev/lint.gleam`, so nothing else
changes. This works only when the project's own code, in `src/`, `test/`
and `dev/`, calls no JavaScript-only function, whether its own `.mjs` code
or a dependency's: `gleam run` compiles all three for Erlang, and stops
with "Unsupported target" before grice starts. A JavaScript-only dependency
that the code never calls is fine. Projects that call one can't run grice
until it runs on JavaScript.

### Options

| Option | What it does |
|---|---|
| `--format human` | Diagnostics and a summary, for a person. The default. |
| `--format json` | One JSON document, for tools. See [JSON output](https://github.com/alvivi/grice/blob/main/docs/JSON.md). |
| `--warnings-as-errors` | Fail the run when it shows a warning. Severities print unchanged. |
| `--strict` | Fail the run when its coverage has a gap: code grice couldn't parse or type. |
| `--no-color` | Don't colour the output. It's coloured only on a terminal, and never when `NO_COLOR` is set to a non-empty value. |
| `--stats` | Show how long loading and linting took, in milliseconds and reductions. |
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
