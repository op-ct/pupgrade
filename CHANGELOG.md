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
- `pupgrade compile -d DIR --factsets PATH -o OUT`: one catalog per factset,
  compiled against the deployed environment directory through Puppet's own
  compiler, with a record of what each compile used
  - factsets in onceover's layout (`name`, `values`, `trusted`) or as a plain
    facts hash named by its file (what `driftless export factsets` writes); a
    file, a directory, or an onceover role tree, `--certname GLOB` to select
  - `OUT/<certname>/catalog.json`: Puppet's catalog data hash with resources,
    edges, classes, and keys sorted, the version set to the repo's git sha,
    and the per-run uuid dropped, so compiles of the same code are identical
  - `OUT/<certname>/probes.json`: functions called (with the module providing
    each and the call sites), facts read through `$facts`, `$trusted`, Hiera
    interpolation, and `Facter.value`, legacy fact variables, lookups
    (automatic and explicit, found or not), warnings and deprecations,
    classes, defined types, resource types, and the providers resources name,
    each with its module, and the commands and facts that reached the guard
  - `--environment`, `--manifest PATH`, `--code CODE` (in place of the
    manifest), `--prepend CODE|@FILE`, `--var NAME=VALUE`, `--server-fact
    NAME=VALUE`
  - the execution guard: commands module code runs through Puppet's or
    Facter's execution helpers are answered from `--stubs FILE` (a regexp per
    command with the output to return, or `action: allow`), and `Facter.value`
    reads are answered from the factset or the stub file's `facts`; a command
    nothing answers stops that node's compile (`--on-leak raise`, the default)
    or runs and is recorded (`--on-leak allow`); every interception is in the
    probe record
  - config subsystem `compile` in `pupgrade.yaml`: `factsets`, `output_dir`,
    `environment`, `manifest`, `prepend_file`, `stubs`, `on_leak`, `vars`,
    `server_facts`
- `pupgrade compile diff FROM TO`: what changed between two `compile` runs, node
  by node: resources added and removed, parameters added, removed, and changed
  with their values, classes and relationship edges added and removed, and nodes
  only one run has. `--group` folds identical changes across nodes into one row
  with the nodes it appears on; `--summary` counts per node; row filters
  `--certname`, `--resources`, `--changes`, `--skip-changes`, `--ignore-params`.
  Exits 1 when the catalogs differ
- `pupgrade surface MODULE-DIR [-o FILE]` and `surface --git URL --ref REF`: a
  module's API surfaces as a JSON document: classes and defined types with their
  parameters' types and defaults, Puppet-language functions with parameters and
  return type, 4.x Ruby functions with their dispatch signatures, 3.x functions
  with arity, type aliases, resource types with their attributes (kind, required,
  allowed values, namevars, features), providers with confines, commands,
  defaults, and features, and custom and external facts by name. Ruby surfaces
  are read by loading the module's code, so extraction runs in a process of its
  own; files that fail to load are listed under `errors`
- `pupgrade surface diff FROM TO`: what changed between two surface documents or
  module directories: entries added and removed per surface, and each attribute
  that differs, named by its path; `--surfaces`, `--names`, `--changes` filters,
  `--summary`. Exits 1 when the surfaces differ
- `pupgrade config new [-p PATH] [--force] [<subsystem.key>=<value> ...]`: writes a
  pupgrade.yaml listing every known key under its subsystem, commented out with
  its default or an example, or set live by an argument; `-p --` prints it
- `rake fixture[DIR]` builds a fixture control repo to run pupgrade against:
  - 32 git modules as bare remotes with a tagged commit per release; stdlib,
    firewall, concat, and simplib also ship functions, a type and provider, a
    defined type, and a custom fact for `compile` to probe
  - two Forge-style modules
  - a `pupgrade.yaml`, a `pupgrade-stubs.yaml`, a site manifest with a role and
    profile, and two factsets in the two layouts `compile` reads
  - a `Puppetfile.proposed` that bumps stdlib a major version and five modules
    with it.
  The current state has every conflict kind; commits carry fixed dates, so
  builds (`spec/support/fixture_repo.rb`) should be 100% repeatable

[unreleased]: https://github.com/op-ct/pupgrade
