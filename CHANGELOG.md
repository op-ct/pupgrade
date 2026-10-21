# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

It's a new gem to help upgrade the module base of large Puppet/OpenVox  control repos without breaking everyone's stuff (or at least having a pretty good idea about what to what out for).

The first `pupgrade` commands were split from unreleased features in the `driftless` gem.

### Added

- Gem skeleton: `pupgrade` CLI with `help` and `version`, layered `pupgrade.yaml`
  config (system, user, project) with strict key validation
- **`pupgrade check`**` [-d DIR] [--propose PUPPETFILE]`

  Resolves deps, OSes, and requirements between all deployed modules'
  `metadata.json`.  If conflicts, it displays them and exits with `1`.

  Notable flags:
  - `--propose` resolves with the info from `PUPPETFILE` overlaid on the
    current entries, fetching `metadata.json` from git for changed modules
    - `--propose` + `--ignore` show every row, marking conflicts introduced
      (`+`, red) and resolved (`-`, green); `--changed-only` drops the
      unchanged rows and `--hide-resolved` the resolved ones
    - `--by-change`: (under a proposal) one table per changed Puppetfile entry
  - `--ignore MODULES` resolves as if those modules were gone (a what-if;
    `modules.exclude_modules` is the standing exclusion)
  - `--summary` displays as a table of modules x conflict types
    - with `--propose`, shows introduced (`+`), resolved (`-`), unchanged (`=`)
  - row filters: `--modules`, `--subjects`, `--conflicts`, `--skip-conflicts`
  - layout flags: `--order`, `--sort-by`
  - one-run exclusions: `--exclude-modules`, `--exclude-deps`,
    `--exclude-requirements`, `--exclude-operatingsystems` (`--exclude-os`)
  - module names match in any spelling: `puppetlabs-stdlib`, `puppetlabs/stdlib`,
    or `stdlib`, in flags, config, and `--ignore`
  - a dependency exclusion may name one edge rather than a module:
    `a-ssh:a-core` ignores ssh's requirement on core, and `a-ssh:a-core < 5.0.0`
    ignores that constraint only, with a warning once ssh's constraint moves on
- **`pupgrade module`**` gitlog MODULE [REF] [-n NUM] [-f] [-t] [--fetch] [--branch BRANCHES]
  [--branchfile FILE]`

  Displays a deployed module's git log (optionally at `REF`)
  * Given a tracking `--branch` or `--branchfile`, shows what is further along
    the tracking branch, beyond the current checkout/`REF`
  * `--branch` takes a comma-separated list; the first branch the clone has
    wins, and is recorded in the branchfile (flag or `modules.branchfile`)
  * `-t`, `--tags-only` shows tags only (and the branch tip with
    `--include-heads`)
- **`pupgrade module list [GLOBS]`**: every module on the modulepath or in the
  Puppetfile, with what the Puppetfile declares, what is deployed, and whether
  they agree
- **`pupgrade module info MODULE [--branchfile FILE] [--fetch]`**: one module
  in full: names, path, declaration, remote, what the clone sits at, metadata
  (dependencies, requirements, OS support), the branch it follows, and the
  tagged versions it could move to

- **`pupgrade module update`**` MODULE REF [--dry-run]`

  Check out `REF` in the deployed git `MODULE`, in place
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
    interpolation, `dig`, `in`, and `Facter.value`, legacy fact variables, lookups
    (automatic and explicit, found or not), warnings and deprecations,
    classes, defined types, resource types, and the providers resources name,
    each with its module, type aliases resolved with the module shipping each
    and the sites using them, and the commands and facts that reached the guard
  - `--environment`, `--manifest PATH`, `--code CODE` (in place of the
    manifest), `--prepend CODE|@FILE`, `--var NAME=VALUE`, `--server-fact
    NAME=VALUE`
  - the execution guard: commands module code runs through Puppet's or
    Facter's execution helpers are answered from `--mocks FILE` (a regexp per
    command with the `stdout` and `exit` status to return, or `action: allow`;
    `when:` limits a mock to factsets with the given fact values), and
    `Facter.value` reads are answered from the factset or the mock file's
    `facts`; a command nothing answers stops that node's compile (`--on-leak
    raise`, the default) or runs and is recorded (`--on-leak allow`); every
    interception is in the probe record
  - default mocks ship with pupgrade (`--[no-]default-mocks`): package queries
    such as `rpm -q` answer per OS family, and exit 127 elsewhere, so a module
    compiled against a factset of another OS fails the way it would there
  - a full run (no `--certname`) removes `OUT/<certname>/` directories no
    factset names any more; `--keep-stale` leaves them
  - config subsystem `compile` in `pupgrade.yaml`: `factsets`, `output_dir`
    (default `pupgrade/cache/catalogs`), `environment`, `manifest`,
    `prepend_file`, `mocks`, `default_mocks`, `on_leak`, `vars`, `server_facts`
- `pupgrade compile diff FROM TO`: what changed between two `compile` runs, node
  by node: resources added and removed, parameters added, removed, and changed
  with their values, classes and relationship edges added and removed, and nodes
  only one run has. `--group` folds identical changes across nodes into one row
  with the nodes it appears on; `--summary` counts per node; row filters
  `--certname`, `--resources`, `--changes`, `--skip-changes`, `--ignore-params`.
  Exits 1 when the catalogs differ
- `pupgrade surface [MODULE[:REF] ...] [--all] [--ref REF] [--fetch]` and
  `surface --git URL --ref REF`: a module's API surfaces as a JSON document,
  kept under `surface.cache_dir` (default `pupgrade/cache/api_surfaces`) as
  `<module>-<version>[--<ref>].json` and read from there on the next run
  (`--refresh` reads again; `-o FILE` or `-o -` for one module instead). A
  module is a directory, or a name on the control repo's modulepath; `NAME:REF`
  and `--ref` read the module's own clone at a ref, after a fetch with
  `--fetch`. The document carries the git sha and ref it was read at.
  Surfaces are: classes and defined types with their
  parameters' types and defaults, Puppet-language functions with parameters and
  return type, 4.x Ruby functions with their dispatch signatures, 3.x functions
  with arity, type aliases, resource types with their attributes (kind, required,
  allowed values, namevars, features), providers with confines, commands,
  defaults, and features, and custom and external facts by name. Ruby surfaces
  are read by loading the module's code, so extraction runs in a process of its
  own, inside an environment holding the control repo's modulepath, so a
  module's dependencies resolve; files that fail to load are listed under
  `errors`
- `pupgrade surface diff FROM TO`: what changed between two surface documents,
  module directories, or modules by name and ref (`stdlib stdlib:v9.0.0`):
  entries added and removed per surface, and each attribute
  that differs, named by its path; `--surfaces`, `--names`, `--changes` filters,
  `--summary`. Exits 1 when the surfaces differ
- `pupgrade solve -d DIR [-o PUPPETFILE]`: depsolve module upgrades across the
  control repo, with hinting based on usage.
  - For every deployed git module with a branch in `modules.branchfile`:
    - Considers tagged commits further along the tracking branch
      - also considers the untagged branch tip with `--include-heads`
  - `--fetch` fetches the latest commits for each module before searching
  - Modules with no branch in the branchfile take their tags past the deployed
    version; the branch tip at HEAD counts as current
  - Solve order: Modules decide their dependencies first, at the first
    candidate that satisfies its own:
    - Module dependency ranges
    - Puppet/OpenVox requirement (site: `modules.requirements`)
    - Operating systems of interest (site: `modules.operatingsystems`)
    ... against what is already decided
    - a module whose newer candidates all break something is `held` at its
      current version, with the reason; a module already at its newest is
      `unresolved` when the current version itself violates a constraint
  - `--order newest` (default) or `oldest`
    `newest` searches from the latest ref and work backward
    `oldest` search forward, tarting from the current (or `--bump`ed) version
  - `--bump=MODULE[=REF]` move `MODULE` to its newest candidate or `REF`
  - `--hold MODULES` - keep these `MODULES` at their current versions (delim:`,`)
  - `--ignore MODULES` - solve as if these modules were gone, like `check`
  - `modules.exclude_modules` and `modules.exclude_dependencies` apply, as in
    `check`
  - `-o` writes moved module versions as a `Puppetfile` overlay for `check
    --propose`.
  - With `--evidence DIR` (a `pupgrade compile` output directory) and
    `--prune-unused`, dependency edges to modules unused in any compile (or
    not deployed at all) are not constraints, and `--exclusions FILE` writes
    the pruned edges the result violates as `modules.exclude_dependencies`
    - functions a module's code calls from a module its metadata does not
      depend on are warned about. Forge entries and modules that are not git
      clones keep their version.
  - Exits 1 when any module is held
  - config subsystem `solve` in `pupgrade.yaml`: `order`, `include_heads`,
    `evidence_dir` (else `compile.output_dir`)
- `pupgrade impact -d DIR --propose PUPPETFILE [--evidence DIR]`: what the site
  would feel from a proposed Puppetfile. For each git module it moves, the
  surface changes between the deployed version and the proposed ref, each
  mapped to its uses: a class removed or a parameter removed, retyped,
  redefaulted, or newly required, to the nodes including the class and the
  Hiera keys naming the parameter; defined-type and resource-type attribute
  changes to the resources concerned; functions removed or changed to their call
  sites; providers removed to the resources naming them; facts removed to the
  nodes reading them. Evidence is a `compile` output directory
  (`compile.output_dir` by default); without one, every change is a finding with
  its use unknown. `--summary` per module with its commit count; `--gitlog` and
  `--changelog` add each module's commits and CHANGELOG sections for the versions
  crossed; `--modules`, `--impacts`, `--all`. Exits 1 when any finding has a use
  - config subsystem `impact` in `pupgrade.yaml`: `evidence_dir` (else
    `compile.output_dir`)
- `pupgrade config new [-p PATH] [--force] [<subsystem.key>=<value> ...]`: writes a
  pupgrade.yaml listing every known key under its subsystem, commented out with
  its default or an example, or set live by an argument; `-p --` prints it.
  Directories in the path are created
- `pupgrade config print [KEY[.SUBKEY...]]`: the configuration as this run
  resolves it, every file in the chain merged with includes and references
  applied, as YAML; a dotted key narrows it to one subtree or value. Keys left
  unset are omitted unless `-d`, `--include-defaults` adds their declared
  defaults; a declared key asked for by name prints its default either way
- The project config is `pupgrade/pupgrade.yaml` or `./pupgrade.yaml` in the
  control repo (an error if both exist); caches default to `pupgrade/cache/`
- Probe records and surface documents carry a `schema_version`, and every reader
  (`solve --evidence`, `impact`, `surface diff`) refuses one of another schema,
  saying whether the file or this pupgrade is the newer
- `rake fixture[DIR]` builds a fixture control repo to run pupgrade against:
  - 32 git modules as bare remotes with a tagged commit per release; stdlib,
    firewall, concat, and simplib also ship functions, a type and provider, a
    defined type, and a custom fact for `compile` to probe
  - two Forge-style modules
  - a `pupgrade/pupgrade.yaml`, a `pupgrade/mocks.yaml`, a site manifest with a
    role and profile, and two factsets in the two layouts `compile` reads
  - a `Puppetfile.proposed` that bumps stdlib a major version and five modules
    with it.
  The current state has every conflict kind; commits carry fixed dates, so
  builds (`spec/support/fixture_repo.rb`) should be 100% repeatable

[unreleased]: https://github.com/op-ct/pupgrade
