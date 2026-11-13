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
