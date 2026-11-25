# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
