//// How much of a project a run analysed, and what it couldn't.
////
//// grice never reports success over code it didn't analyse. A lint-set
//// module that doesn't parse, a definition girard couldn't type, a module
//// girard returned nothing for, an import it couldn't use, a dependency
//// whose sources are missing, or a project that couldn't be read whole
//// for the rules that see all of it is a gap. Each gap matches one
//// diagnostic of
//// the run, and `grice.coverage` gives them all in one value, so a tool can
//// pattern-match on them instead of reading the diagnostics' text.

/// How much of the lint set a run analysed.
pub type Coverage {
  Coverage(
    /// The number of modules in the lint set.
    modules: Int,
    /// The number of lint-set modules that parse.
    parsed: Int,
    /// How much of the parsed lint-set modules girard typed.
    types: TypeCoverage,
    /// Everything the run couldn't analyse, each matching one diagnostic:
    /// first the lint-set modules that don't parse, then the type gaps of
    /// each module in path order (the lint set's, or every module's that a
    /// typed rule built with `rule.whole_project` saw), then the missing
    /// packages, then an incomplete project.
    gaps: List(Gap),
  )
}

/// How much of the parsed lint-set modules girard typed.
pub type TypeCoverage {
  /// No rule of the run is typed, so girard didn't run.
  NotRequested
  /// How many modules girard typed completely, how many it typed with
  /// gaps, and how many it returned nothing for. Together they are the
  /// parsed lint-set modules.
  Requested(full: Int, partial: Int, none: Int)
}

/// Something the run couldn't analyse, and the diagnostic that reports it.
pub type Gap {
  /// A lint-set module that doesn't parse: a `grice/parse-error`.
  UnparsedModule(path: String)
  /// A definition girard couldn't type: a `grice/untyped-definition`.
  UntypedDefinition(path: String, definition: String)
  /// A module girard returned nothing for, of the lint set or seen by a
  /// typed whole-project rule: a `grice/uninferred-module`.
  UninferredModule(path: String)
  /// A module girard couldn't use, which the module at `path`, of the lint
  /// set or seen by a typed whole-project rule, imports directly or reaches
  /// through other modules: a `grice/unavailable-import`.
  UnavailableImport(path: String, module: String, cause: Cause)
  /// A manifest package whose sources are missing: a
  /// `grice/missing-package`.
  MissingPackage(package: String)
  /// The rules built with `rule.whole_project`, by code in the order of the
  /// rule set, which didn't run because the files at `paths` couldn't be
  /// read, don't parse or couldn't be included: modules of the project,
  /// linted or not, and foreign sources, sorted by path. A
  /// `grice/incomplete-project`.
  IncompleteProject(rules: List(String), paths: List(String))
}

/// Why girard couldn't use a module.
pub type Cause {
  /// It's a project module glance can't parse.
  ProjectModuleUnparsable
  /// It's a project module that parses, which girard couldn't use.
  ProjectModuleUnusable
  /// It's a dependency module glance can't parse.
  DependencyUnparsable
  /// No project or dependency module has its name.
  NoSuchModule
}
