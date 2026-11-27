# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **The simplify pack.** `rules.simplify()` in `grice/rules` is an opt-in
  set of built-in rules for code that is correct but takes the long way
  round, where one standard library function does the same: the rewrite
  each finding suggests gives the same result, and calls any function
  passed to it the same way. `gleam run -m grice` still runs the default
  set alone; add the pack in an entry module of your own with
  `grice.run(list.append(rules.default(), rules.simplify()))`. Each rule
  finds its functions by what girard resolved, reads the calls nested or
  piped, and reports a warning.
  [Built-in rules](https://github.com/alvivi/grice/blob/main/docs/RULES.md)
  describes each one:
  - `grice_rules/map-then-flatten`: `result.map` then `result.flatten`, or
    `option.map` then `option.flatten`, which `result.try` and
    `option.then` do in one call.
  - `grice_rules/list-map-then-flatten`: `list.map` then `list.flatten`,
    which `list.flat_map` does in one call.

## [0.2.0] - 2026-11-26

### Added

- **The default rule set.** `gleam run -m grice` runs grice's first
  built-in rules, and the new `grice/rules` module offers them: `default()`,
  the set `gleam run -m grice` runs, and a function per rule, so an entry
  module of your own can run them beside its rules, change a rule's
  severity or leave one out. Each reports a warning, and its code starts
  with `grice_rules/`, so ignores and suppression comments hide it like
  any rule's. [Built-in rules](https://github.com/alvivi/grice/blob/v0.2.0/docs/RULES.md)
  describes each one:
  - `grice_rules/no-echo`: an `echo` left in a module outside `test/` and
    `dev/`, which `gleam publish` refuses and an application prints.
  - `grice_rules/ineffective-double-comparison`: in a chain of `&&` or
    `||`, a comparison of a variable with an Int literal that the
    comparisons before it already decide, such as the second half of
    `48 >= char && char <= 57`, a range written the wrong way round.
  - `grice_rules/no-length-for-emptiness`: `string.length` or
    `list.length` compared with 0 or 1, or matched on 0 in a `case`, to
    check whether a string or a list is empty, found by what girard
    resolved, and leaving alone the `list.length` forms the compiler
    already warns on. With it, `gleam run -m grice` runs girard.
  - `grice_rules/check-then-assert`: a `Result` or an `Option` checked
    with `result.is_ok`, `result.is_error`, `option.is_some` or
    `option.is_none`, then `let assert`-ed on a path where the check
    already proved the variant, through a `case`, `bool.guard` or
    `bool.lazy_guard`, which the conventions page says should never be
    done.

### Changed

- **girard 4.0.2.** grice requires girard 4.0.2, which types more of the
  code the compiler accepts, so fewer definitions get a
  `grice/untyped-definition` note. A pipe into `echo`, as in `x |> echo`,
  now types as the piped value. A note's reason for a type mismatch may
  name the two types in the other order, as girard now checks some
  constructs in the compiler's order.

## [0.1.0] - 2026-11-20

### Added

- Module and project rules with type facts from
  [girard](https://hexdocs.pm/girard), compiler-style diagnostics, ignores
  and suppression comments, JSON output, a testing kit for rules, and both
  targets, Erlang and JavaScript on Node.

[0.2.0]: https://github.com/alvivi/grice/releases/tag/v0.2.0
[0.1.0]: https://github.com/alvivi/grice/releases/tag/v0.1.0
