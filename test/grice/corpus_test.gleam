//// The corpus gate: grice's built-in rules over the Gleam core team's
//// packages, pinned in `test/corpus/`. A rule is on by default only if it
//// runs clean on them, so the gate asserts that every package is clean:
//// no diagnostic, which covers every finding and every coverage gap, and
//// every module typed. A failure lists each package that isn't, with its
//// findings.
////
//// A typed probe that reports nothing runs with the built-in rules, so
//// girard types every package even while no built-in rule needs types,
//// and a module it couldn't type shows up as a coverage note. The gate
//// checks that the types were requested, so a probe that stopped being
//// typed fails it instead of passing over untyped packages.
////
//// A built-in rule that keeps a finding on these packages needs a written
//// reason for it. When the first one does, the gate gains a committed list
//// of the findings it allows, each with its reason.

import gleam/list
import gleam/string
import grice/corpus
import grice/coverage.{Requested}
import grice/internal/parallel
import grice/rule.{type Rule}
import grice/rules

pub fn core_packages_are_clean_test() {
  corpus.download()
  let installed = corpus.installed()
  let rule_set = [probe(), ..rules.default()]
  let problems =
    corpus.core
    |> parallel.map(fn(package) {
      let project = corpus.load(package, installed)
      let linted = corpus.lint(project, rule_set)
      let coverage = linted.coverage
      let typed = Requested(full: coverage.modules, partial: 0, none: 0)
      let describe = corpus.describe_diagnostic(package, project, _)
      case linted.diagnostics, coverage.types == typed {
        [], True -> []
        diagnostics, _ -> [
          package <> ": " <> corpus.describe_coverage(coverage),
          ..list.map(diagnostics, describe)
        ]
      }
    })
    |> list.flatten
  assert problems == []
    as { "The core packages aren't clean:\n" <> string.join(problems, "\n") }
}

// A typed module rule that reports nothing.
fn probe() -> Rule {
  rule.module("corpus/probe", title: "Types every module")
  |> rule.typed
  |> rule.with_context(initial: Nil)
  |> rule.build
}
