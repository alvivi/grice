//// The corpus gate: grice's built-in rules over the Gleam core team's
//// packages, pinned in `test/corpus/`. A rule is on by default only if it
//// runs clean on them, so the snapshot is the gate's manifest: every
//// finding and every coverage gap, never hidden, and a change to any of
//// them is a snapshot diff to review.
////
//// A typed probe that reports nothing runs with the built-in rules, so
//// girard types every package even while no built-in rule needs types,
//// and a module it couldn't type shows up as a coverage note. The
//// packages run in parallel, and the snapshot keeps their order.

import birdie
import gleam/list
import gleam/string
import grice
import grice/corpus
import grice/internal/parallel
import grice/rule.{type Rule}

pub fn core_packages_test() {
  corpus.download()
  let installed = corpus.installed()
  let rules = [probe(), ..grice.built_in_rules()]
  let #(packages, findings) =
    corpus.core
    |> parallel.map(fn(package) {
      let project = corpus.load(package, installed)
      let linted = corpus.lint(project, rules)
      let describe = corpus.describe_diagnostic(package, project, _)
      #(
        package
          <> " "
          <> corpus.version(corpus.directory(package))
          <> ": "
          <> corpus.describe_coverage(linted.coverage),
        list.map(linted.diagnostics, describe),
      )
    })
    |> list.unzip
  let findings = case list.flatten(findings) {
    [] -> ["No findings."]
    found -> found
  }
  [string.join(packages, "\n"), string.join(findings, "\n")]
  |> string.join("\n\n")
  |> birdie.snap(title: "corpus: core packages")
}

// A typed module rule that reports nothing.
fn probe() -> Rule {
  rule.module("corpus/probe", title: "Types every module")
  |> rule.typed
  |> rule.with_context(initial: Nil)
  |> rule.build
}
