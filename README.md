# grice

[![CI](https://github.com/alvivi/grice/actions/workflows/ci.yml/badge.svg)](https://github.com/alvivi/grice/actions/workflows/ci.yml)

A type-aware linter for Gleam, with clear, compiler-style diagnostics.

> **Status: early development.** grice has no rules and no public API yet,
> and it is not published on Hex. This repository currently holds the
> project scaffold and its conventions.

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

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the development workflow and the
code and commit conventions, and [`AGENTS.md`](AGENTS.md) for the design
principles and the planned architecture.

## License

grice is licensed under the [Apache License 2.0](LICENSE).
