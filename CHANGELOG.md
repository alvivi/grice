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
- **Typed rules.** `rule.typed`, applied right after `rule.module` or
  `rule.project`, gives a rule `Typed` facts. Module and project rules now
  start from one `rule.Schema` type, which replaces `ModuleSchema` and
  `ProjectSchema`: its `ModuleForm` or `ProjectForm` says which kind of
  rule it builds, so `rule.with_context` takes only a module rule's schema
  and `rule.per_module` only a project rule's. The types are inferred once
  per run, and only when a rule of the set is typed. Rules can't be run
  from the command line yet.
- **Type facts.** `Typed` facts answer what girard, the type inference
  grice uses, found in the module: `facts.type_of` gives the type of an
  expression, `facts.resolution_of` what a field access or a name in call
  position resolved to, and `facts.signature` the type of a top-level
  function or constant. Spans match exactly, as glance gives them. A
  query with no answer returns an `Unknown` that says why: girard keeps
  nothing there, the definition it's in couldn't be typed or isn't
  compiled for the target, girard returned nothing for the module, or the
  module reaches modules girard couldn't use, which leaves every query on
  it without an answer.
- **Comments.** `facts.comments` gives a rule the module's comments, which
  glance's syntax tree leaves out, in source order. Each `Comment` has its
  `CommentKind` (`Regular`, `Doc` or `ModuleDoc`, for `//`, `///` and
  `////`), its span in bytes, slashes included, and its text after the
  slashes. A comment inside a definition left out for the other target
  isn't there, as the definition isn't.
- **girard.** grice depends on girard 4. Typed queries return its `Type`,
  `Resolution` and `Scheme`, so a rule that inspects them depends on
  girard too.
