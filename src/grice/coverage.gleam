//// How much of a project a run analysed, and what it couldn't.
////
//// grice never reports success over code it didn't analyse. A lint-set
//// module that doesn't parse, a definition girard couldn't type, a module
//// girard returned nothing for, an import it couldn't use, or a dependency
//// whose sources are missing is a gap. Each gap matches one diagnostic of
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
    /// first the modules that don't parse, then the gaps of each module in
    /// lint-set order, then the missing packages.
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
  /// A lint-set module girard returned nothing for: a
  /// `grice/uninferred-module`.
  UninferredModule(path: String)
  /// A module girard couldn't use, which the lint-set module at `path`
  /// imports directly or reaches through other modules: a
  /// `grice/unavailable-import`.
  UnavailableImport(path: String, module: String, cause: Cause)
  /// A manifest package whose sources are missing: a
  /// `grice/missing-package`.
  MissingPackage(package: String)
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
