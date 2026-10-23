# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

It's a new gem to help upgrade the module base of large Puppet/OpenVox  control repos without breaking everyone's stuff (or at least having a pretty good idea about what to what out for).  A toolkit to deliver massively multi-tenant brownfield control repos with lots of modules, profiles, and hiera from stdlib-stasis and dependency hell!

### Added

- **`pupgrade check`**` [-d DIR] [--propose PUPPETFILE]`

  Resolves deps, OSes, and requirements between all deployed modules'
  `metadata.json`.  Conflicts are displayed and return an exit code of `1`.

  Notable flags:
  - `--propose` resolves with the info from `PUPPETFILE` overlaid on the
    current entries, fetching `metadata.json` from git for changed modules
    - `--propose` + `--ignore` show every row, marking conflicts introduced
      (`+ NEW`, red) and resolved (`- FIXD`, green); `--changed-only` drops
      the unchanged rows and `--hide-resolved` the resolved ones
    - an introduced row is yellow, a resolved row grey, the kind coloured;
      the part of a detail in the way is red; summary zeros are grey
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

- **`pupgrade module`**` gitlog [options] MODULE [REF]`

  Displays a deployed module's git log (optionally at `REF`)
  * Given a tracking `--branch` or `--branchfile`, shows what is further along
    the tracking branch, beyond the current checkout/`REF`; `--from-start`
    logs `REF` from its first commit instead
  * A rev expression (`HEAD~3`, `main@{2.weeks.ago}`) goes to git as written;
    a plain name is tried as `origin/<name>` first
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

- **`pupgrade module update`**` MODULE REF [--dry-run] [--force]`

  Check out `REF` in the deployed git `MODULE`, in place; `--force` goes
  ahead over uncommitted changes
- **`pupgrade module diff FROM TO`**

  Show what changed between two versions of a module:
  * metadata (dependencies, requirements, operating systems)
  * API surfaces (classes, defines, params, facts, functions, etc)
  - `FROM` and `TO` can be a module name (`stdlib`), name:ref
    (`stdlib:v9.7.0`), module dir, or `surface` json API document.
  - rows read `item | difference | detail`
    - the kind of each item is cyan, its namespace grey
    - a parameter reads `Boolean $x = $is_slave`; signatures as `(a, b)`
    - only Variant, Enum, Pattern, Struct, Tuple, Hash, Array, Regexp fold
      to `[…]`; two sides that still read alike get `[…¹] -> […²]`
  - `--full` prints each change as a block with its values whole
  - `--surfaces`, `--names`, `--changes` filters, `--summary`
  - exits `1` when the two differ

- Config subsystem `modules` in `pupgrade.yaml`:
  - `operatingsystems`, `requirements`, `exclude_modules`,
    `exclude_dependencies`, `exclude_requirements`,
    `exclude_operatingsystems`, `branchfile`, `check_order`, `check_sort`

- **`pupgrade compile`**` [options]`

  compiles one catalog per factset, deployed environment directory using
  Puppet's compiler (like onceover, but much faster without rspec-puppet)

  * prints a green P or red F per factset as it goes (disable with
    `--no-progress`)
  * `--fail-fast` stops at the first failure
  * `--show-default-mocks` prints the shipped mocks
  * in the post-compile summary table:
    - `mocks` column counts answered commands
    - `leaks` counts what got through unmocked (red = one failed the compile)
    - failures are displayed under the table
  * unanswered commands log at warning, mocked ones at `--on-mock LEVEL`
  * `pupgrade/compiler-mocks.yaml` is read by default when present
  * dynamic ENC and execution guard mocks: rules can return results based
    on a node's certname + facts, using YAML rules and/or Ruby logic
    - YAML rules in `enc.yaml` + `compiler-mocks.yaml` can reference the
      node's `${certname}` and `${facts.a.b}`, and transform them with
      regex + capture groups
    - `pupgrade/compiler.rb` defines rule logic for both as Ruby blocks:
      `variable` & `classes` for the ENC, `mock` for the exec guard
    - ENC classes from `enc.yaml` and `compiler.rb` are merged; other
      `compiler.rb` rules override their YAML counterparts
    - config keys `compile.enc` + `compile.ruby`, flags `--enc` and `--ruby`
    - `probes.json` records what each node was given under `enc`

  * records usage information per factset, used by `solve`:
    - full Puppet catalog
    - records functions, facts, and data types used during the compile
  * factsets can be:
    - in onceover's layout (`name`, `values`, `trusted`)
    - in `puppet lookup` format (a plain facts hash).  
    - exported by `driftless export factsets`
  * `OUT/<certname>/catalog.json`: Puppet's catalog data hash
  * `OUT/<certname>/probes.json`: calls record during compile
  * `--environment`, `--manifest PATH`, `--code CODE` (in place of the
    manifest), `--prepend CODE|@FILE`, `--var NAME=VALUE`, `--server-fact
    NAME=VALUE`
  * Comes with an execution guard/mocking system to stub server-side functions
    (aka execution leaks) and direct calls to Facter's execution helpers
    - mocks are defined in `--mocks FILE`
    - unmocked commands stops that node's compile (`--on-leak raise`, default)
      or runs and is recorded (`--on-leak allow`)
    - interception is in the probe record
  * default mocks ship with pupgrade (`--[no-]default-mocks`)
    - package queries such as `rpm -q` answer per OS family, so code compiled
      against factsets from another OS behave the way it would there
  * a full factset run (no `--certname`) removes `OUT/<certname>/` directories
    that don't match any of the compiled factset names
    - `--keep-stale` leaves them be

- **`pupgrade lookup`**` [options] KEY... --node CERTNAME`

  Locally simulate an operational puppet lookup, using pupgrade's config and
  factsets, allowing you to model lookups `puppet lookup` can't handle, like
  using the mock ENC to set top-scope variables (even without compiling), and
  injecting puppet language preconditions.
  * Mimics puppet lookup options `--explain` and `--explain-options`
  * `--compile` evaluates manifests first, using pupguard's mocks and guards
  * `--list` displays all factset nodes, alongside important facts and
    variables (config: `lookup.columns`)
  * exits `1` when the key is not found

- **`pupgrade compile diff`**` FROM TO`

  Shows what changed between two `compile` runs, node by node: resources,
  parameters, classes, and relationship edges added, removed, or changed.
  * `--group` folds identical changes across nodes into one row
  * `--summary` counts changes per node
  * exits `1` when the catalogs differ

- **`pupgrade surface`**` [options] [MODULE[:REF] ...]`

  Reads a module's API surfaces (classes, defines, functions, types,
  providers, facts, type aliases) and its `metadata.json` into a JSON
  document under `pupgrade/cache/api_surfaces/`, for `module diff` and
  `impact`.
  * `MODULE` is a name on the modulepath or a directory; `stdlib:v9.7.0`
    reads the clone at a ref; `--all` reads every module
  * cached API surface files are named `<module>-<version>--<tag>__<sha>.json`
    - pupgrade matches on the `<sha>`; the `<tag>` is a convenience for users
      listing files
  * documents are reused until `--refresh`
  * nothing goes to stdout but `-o -`; the document's path is logged at
    debug
  * Ruby surfaces are read in a process of its own, with the control repo's
    modulepath in reach
  * types and providers are read as Puppet loads them: the extractor asks
    Puppet for each type and records what `provide` is called with, so no
    file loads twice; a file in `lib/puppet/provider/` that defines no
    provider is skipped as a helper
  * a cached surface using an older schema is refreshed automatically;
    `--refresh[=schema]` refreshes only stale schemas

- **`pupgrade solve`**` [options] [-o PUPPETFILE]`

  Picks a version for every deployed git module from the tags its clone
  holds, dependencies first, each at the first candidate that satisfies its
  dependency ranges, the Puppet requirement (`modules.requirements`), and the
  operating systems of interest (`modules.operatingsystems`).
  * `-o` writes the moves as a Puppetfile overlay for `check --propose` and
    `impact`
  * `--order newest` (default) moves as far as the constraints allow;
    `oldest` moves the least, driven by `--bump MODULE[=REF]`
  * `--hold MODULES` and `--ignore MODULES` pin or drop modules for the run
  * a module that cannot move is `held`, and the note names the candidate
    that was blocked and why:
    `held: v6.0.0 needs puppetlabs/augeas_core >= 3.0.0, but augeas_core is 2.0.1`
  * `--explain MODULES` shows every candidate's verdict
  * `--prune-unused` ignores dependency edges to modules no compile used
    (needs `compile` output); `--exclusions FILE` records the pruned edges
    the result violates as `modules.exclude_dependencies`
  * exits `1` when any module is held
  * config subsystem `solve`: `order`, `include_heads`, `catalogs_dir`

- **`pupgrade impact`**` [options] PUPPETFILE`

  Shows what the site would feel from a proposed Puppetfile: every API change
  between the deployed version and the proposed ref of each module it moves,
  mapped to the nodes, resources, call sites, and Hiera keys that use it,
  from the `compile` output.
  * a finding nothing is known to use reads `use unknown`; `--no-catalogs`
    reads no compile output at all
  * `--summary` gives one row per module; `--gitlog` and `--changelog` add
    each module's commits and CHANGELOG sections for the versions crossed
  * `--modules`, `--impacts`, `--all` filters
  * `use unknown` and `no catalogs` red, detail verbs coloured
  * exits `1` when any finding has a use
  * config subsystem `impact`: `catalogs_dir`

- **`pupgrade config`**` new|print`

  * `new` writes a `pupgrade.yaml` with every key commented out, or set by
    `key=value` arguments
  * `print [KEY]` shows the config as this run resolves it; `-d` adds the
    unset defaults
  * the project config is `pupgrade/pupgrade.yaml` (or `./pupgrade.yaml`)

- Module names match by short name wherever one is given:
  `voxpupuli-firewalld`, `puppet/firewalld`, and `firewalld` name the same
  module. `puppet-*` is the one way to say "owned by".
- Logging levels follow Puppet's, `notice` the default; `-v` (info), `-vv`
  (debug), and `-vvv` (trace) show progressively more of what a command is
  doing, wherever they sit on the command line.
- Tables wrap to the terminal width (`--width N` overrides; `0` for none).
- `--help` prints the command's desc; subcommands sort by name
- commands log their stages at notice before slow work; every git trace
  line names its purpose, e.g. `(resolving v9.6.0)`
- removed the `params` command (moved `params compare` to driftless)
- `rake fixture[DIR]` builds a fixture control repo to try pupgrade against:
  32 git modules with tagged releases, two Forge modules, factsets, mocks,
  and a `Puppetfile.proposed`.

[unreleased]: https://github.com/op-ct/pupgrade
