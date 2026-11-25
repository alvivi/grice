# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **The default rule set.** `gleam run -m grice` runs grice's first
  built-in rules, and the new `grice/rules` module offers them: `default()`,
  the set `gleam run -m grice` runs, and a function per rule, so an entry
  module of your own can run them beside its rules, change a rule's
  severity or leave one out. Each reports a warning, and its code starts
  with `grice_rules/`, so ignores and suppression comments hide it like
  any rule's. [Built-in rules](https://github.com/alvivi/grice/blob/main/docs/RULES.md)
  describes each one:
  - `grice_rules/no-echo`: an `echo` left in a module outside `test/` and
    `dev/`, which `gleam publish` refuses and an application prints.

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

[0.1.0]: https://github.com/alvivi/grice/releases/tag/v0.1.0
