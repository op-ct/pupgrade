# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Gem skeleton: `pupgrade` CLI with `help` and `version`, layered `pupgrade.yaml`
  config (system, user, project) with strict key validation
- Split the first `pupgrade` commands from unreleased changes in the `driftless` gem:
  - `pupgrade check [-d DIR] [--propose PUPPETFILE]` (was `driftless modules resolve`):
    - display conflicts between the deployed modules' `metadata.json`
      (dependencies, Puppet versions, operating systems), exit 1 if any
    - `--propose` resolves as if `PUPPETFILE` replaced the current entries,
      fetching `metadata.json` from git for changed modules
    - `--ignore MODULES` resolves as if those modules were removed
      - `--propose` or `--ignore` only show a row change (`+`) or resolve (`-`)
      - `--all-conflicts` adds the unchanged rows
      - `--by-change`: (under a proposal) one table per changed Puppetfile entry
    - row filters: `--modules`, `--subjects`, `--conflicts`, `--skip-conflicts`
    - layout: `--order`, `--sort-by`, `--summary` (one row per module with a
      count per kind; under a proposal `+a -b =c` for introduced, resolved,
      unchanged)
    - one-run exclusions: `--exclude-modules`, `--exclude-deps`,
      `--exclude-requirements`, `--exclude-operatingsystems`
  - `pupgrade module gitlog MODULE [REF] [-n NUM] [-f] [--fetch] [--branch BRANCH]
    [--branchfile FILE]`
    - a deployed module's git log, or what a ref or its tracking branch has beyond it
  - `pupgrade module update MODULE REF [--dry-run]`
    - check out a ref in a deployed git module, in place
  - `pupgrade params compare FROM TO`: what changed between two schemas that
    driftless's `params record` wrote
  - Config subsystem `modules` in `pupgrade.yaml`:
    - `operatingsystems`, `requirements`, `exclude_modules`,
      `exclude_dependencies`, `exclude_requirements`,
      `exclude_operatingsystems`, `branchfile`, `check_order`, `check_sort`
- `rake fixture[DIR]` builds a fixture control repo to run pupgrade against:
  - 32 git modules as bare remotes with a tagged commit per release
  - two Forge-style modules
  - a `pupgrade.yaml`
  - a `Puppetfile.proposed` that bumps stdlib a major version and five modules
    with it.
  The current state has every conflict kind; commits carry fixed dates, so
  builds (`spec/support/fixture_repo.rb`) should be 100% repeatable

[unreleased]: https://github.com/op-ct/pupgrade
