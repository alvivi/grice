# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **The diagnostic model.** The new `grice/diagnostic` module defines what
  every grice diagnostic is made of: a rule code, a `Severity`, a title,
  message paragraphs, a hint, and an optional `Location` that owns the file
  path, the primary and secondary `Label`s and a reserved `Fix`. Spans are
  byte offsets into the file's source.
- **A syntax tree walk.** The new `grice/visit` module walks a glance
  module, or a single expression, and calls a hook for each import, custom
  type, type alias, constant, function, statement, expression, pattern and
  type it meets, threading an accumulator through them. The walk follows
  source order, definitions of every kind included, and functions and
  expressions also have exit hooks, called after their children. Attribute
  arguments and the sizes in bit array patterns aren't walked. grice has no
  command line yet, so nothing runs a walk over a project.
- **Rules.** The new `grice/rule` module builds rules. A module rule looks
  at one module at a time: `rule.module` names it, `rule.with_context` gives
  it the context it threads through the module, the `on_*` functions add
  hooks, called during a `grice/visit` walk, and `rule.build` makes the
  `Rule`. A project rule summarises each linted module with
  `rule.per_module` and reports on all of them together with `rule.final`.
  Hooks return `Report`s, built from glance spans, with a primary label,
  secondary labels, a message and a hint. Rules report warnings unless
  `rule.with_severity` sets another severity. A rule code is a
  package-style prefix, a slash and a kebab-case name, such as
  `my_app/no-echo`, and the `grice/` prefix is reserved for grice's own
  diagnostics. Rules can't be run from the command line yet.
- **Module facts.** The new `grice/facts` module holds what a rule hook
  knows about the module it's looking at: its name, path, source, imports
  and syntax tree, as the module is compiled for the project's target. A
  definition whose `@target` attribute names the other target is left
  out, and each list of definitions is in source order.
