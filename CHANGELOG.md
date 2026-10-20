# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Gem skeleton: `pupgrade` CLI with `help` and `version`, layered `pupgrade.yaml`
  config (system, user, project) with strict key validation
- Moved from driftless, unreleased there, as the first `pupgrade` commands:
  - `pupgrade modules resolve [-d DIR] [--propose PUPPETFILE]`:
    - display conflicts between the deployed modules' `metadata.json`
      (dependencies, Puppet versions, operating systems), exit 1 if any
    - `--propose` resolves as if `PUPPETFILE` replaced the current entries,
      fetching `metadata.json` from git for changed modules
    - `--ignore MODULES` resolves as if those modules were removed
    - row filters: `--modules`, `--subjects`, `--conflicts`, `--skip-conflicts`
    - layout: `--order`, `--sort-by`, `--summary`
    - one-run exclusions: `--exclude-modules`, `--exclude-deps`,
      `--exclude-requirements`, `--exclude-operatingsystems`
  - `pupgrade modules gitlog MODULE [REF] [-n NUM] [-f] [--fetch] [--branch BRANCH]
    [--branchfile FILE]`
    - a deployed module's git log, or what a ref or its tracking branch has beyond it
  - `pupgrade modules update MODULE REF [--dry-run]`
    - check out a ref in a deployed git module, in place
  - `pupgrade params compare FROM TO`: what changed between two schemas that
    driftless's `params record` wrote
  - Config subsystem `modules` in `pupgrade.yaml`:
    - `operatingsystems`, `requirements`, `exclude_modules`,
      `exclude_dependencies`, `exclude_requirements`,
      `exclude_operatingsystems`, `branchfile`, `resolve_order`, `resolve_sort`
- `rake fixture[DIR]` builds a fixture control repo to run pupgrade against:
  - 32 git modules as bare remotes with a tagged commit per release
  - two Forge-style modules
  - a `pupgrade.yaml`
  - a `Puppetfile.proposed` that bumps stdlib a major version and five modules
    with it.
  The current state has every conflict kind; commits carry fixed dates, so
  builds (`spec/support/fixture_repo.rb`) should be 100% repeatable

[unreleased]: https://github.com/op-ct/pupgrade
