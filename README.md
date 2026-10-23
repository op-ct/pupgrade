# pupgrade

A toolkit for helping Puppet/OpenVox control repositories escape from [dependency hell]

## Table of Contents

  - [Overview](#overview)
  - [Quick Start](#quick-start)
  - [Configuration](#configuration)
    - [pupgrade.yaml](#pupgradeyaml)
    - [Factsets](#factsets)
    - [Mocks](#mocks)
    - [ENC rules](#enc-rules)
  - [The commands](#the-commands)
    - [check](#check)
    - [compile](#compile)
    - [solve](#solve)
    - [impact](#impact)
    - [module](#module)
    - [surface](#surface)
    - [lookup](#lookup)
  - [Scenarios](#scenarios)
    - [stdlib 8 to stdlib 9](#stdlib-8-to-stdlib-9)
    - [Puppet 7 to OpenVox 8](#puppet-7-to-openvox-8)
    - [A stubborn dependency](#a-stubborn-dependency)
    - [Finding and fixing compile leaks](#finding-and-fixing-compile-leaks)
    - [Comparing two control repo versions](#comparing-two-control-repo-versions)
  - [Installation](#installation)
    - [With the Bolt AIO](#with-the-bolt-aio)
    - [On an airgapped host](#on-an-airgapped-host)
    - [With the openvox-agent AIO](#with-the-openvox-agent-aio)
  - [Logging and colour](#logging-and-colour)
  - [Developing pupgrade](#developing-pupgrade)


## Overview

pupgrade is designed to help brownfield control repos upgrade

### Control repo Dependency Hades

Upgrading many Puppet modules across major versions in a big control repo generally hits problems in three places:

1. Compatibility between all the upgraded modules' dependencies
2. Alignment of your control repo's code and Hiera and the new API surface of upgraded modules
3. Catalogs compiled from updated modules might manage things differently, or manage different things

pupgrade has a command for each:

| Question                                                                                      | Command              |
|-----------------------------------------------------------------------------------------------|----------------------|
| Do all modules' dependencies agree?  What conflicts will a proposed change resolve/introduce? | `check`              |
| Which version could every module move to, within constraints and what the site uses?          | `solve`              |
| What API surfaces _actually_ change between any two versions of a module?                     | `module diff`        |
| Which of _our_ nodes/resources/code/Hiera keys would be affected by these changes?            | `impact`             |
| Does anything change in the catalogs change ?                                                 | `compile diff`       |
| What bits of each module are we _actually_ using?                                             | `surface`, `compile` |
| What would a node get from Hiera, given its facts and ENC variables?                          | `lookup`             |

Every command runs from your  deployed control repo (the directory holding
`environment.conf`, `hiera.yaml`, and the Puppetfile, with the modules deployed
under it), or against one named with `-d DIR`. pupgrade needs `git` on the host
and otherwise only what the OpenVox AIO ships; it never writes under
`/opt/puppetlabs` and never deploys anything.

### What pupgrade does

pupgrade is a suite of tools to help safely upgrade the entire module base
of a large Puppet/OpenVox control repository without breaking everyone's stuff―
or at least knowing what to expect before it does.

It reads the deployed control repo, the modules' own `metadata.json` and git
history, and catalogs it compiles itself from your factsets, to answer: which
module versions can move together, what each move changes in a module's API,
and which of your nodes, resources, and Hiera keys would feel it.

It is the companion to [driftless](https://github.com/op-ct/driftless), the
control-repo linter. driftless reports "what is"; pupgrade asks "what if".




## Quick Start

**Note:** this assumes you are inside the root of your deployed control repo
and pupgrade is [installed](#installation).

1. Write a config and a directory of factsets:

    ```shell
    pupgrade config new            # pupgrade/pupgrade.yaml, every key commented out
    mkdir -p pupgrade/factsets     # one JSON file per node; see Factsets below
    ```

1. See what the deployed modules say about each other today:

    ```shell
    pupgrade check --summary
    ```

1. Compile a catalog per factset. A command a module runs during the compile
   stops the node until a mock answers it:

    ```shell
    pupgrade compile --factsets pupgrade/factsets
    ```

1. Let the solver propose a Puppetfile, then see what the proposal would do:

    ```shell
    pupgrade solve --prune-unused -o Puppetfile.proposed
    pupgrade check --propose Puppetfile.proposed --by-change
    pupgrade impact Puppetfile.proposed
    ```

## Configuration

### pupgrade.yaml

Lives at `pupgrade/pupgrade.yaml` in the control repo (or `./pupgrade.yaml`,
not both). `pupgrade config new` writes it with every key commented out and
described, and `pupgrade config print -d` shows what is in effect. Keys can
also be given as `--config PATH`, or from `~/.config/pupgrade/config.yaml`.

The keys most sites set:

```yaml
---
modules:
  operatingsystems:                 # what every module must declare support for
    RedHat: ['8', '9']
  requirements:
    puppet: '>= 8.0.0 < 9.0.0'      # the Puppet you run, or are moving to
  exclude_dependencies: []          # edges you have decided to ignore (see solve)
compile:
  factsets: [pupgrade/factsets]
```

Everything else pupgrade reads or writes of its own sits under `pupgrade/`
and is found when present:

| Path | What |
|---|---|
| `pupgrade/factsets/` | the nodes to compile for |
| `pupgrade/compiler-mocks.yaml` | answers for commands and facts module code asks for while compiling |
| `pupgrade/enc.yaml` | rules deciding each node's top-scope variables and classes, as an ENC would |
| `pupgrade/compiler.rb` | Ruby blocks for what the rules cannot say |
| `pupgrade/cache/catalogs/` | what `compile` wrote; what `solve` and `impact` read |
| `pupgrade/cache/api_surfaces/` | the module API documents `module diff` and `impact` compare |

### Factsets

One file per node, in either of two layouts: onceover's (`name`, `values`,
`trusted`) or a plain facts hash named by its file (what `puppet facts` and
`driftless export factsets` write). Trusted facts come from the `trusted`
hash when the file has one, else they are built from the certname.

The smallest set worth having is one node per role. driftless can pick them
from PuppetDB's reports:

```shell
driftless export factsets --onceover-role-tree pupgrade/factsets   # one per role
driftless export factsets -o pupgrade/factsets --role 'role::web*' # or by selection
```

Or, on a node that has the agent:

```shell
puppet facts > pupgrade/factsets/$(hostname -f).json
```

`pupgrade lookup --list` shows every factset with the facts and variables
that place it in your hierarchy, which is the quickest check that the set
covers what the hierarchy keys on.

### Mocks

A compile runs module code, and some of it runs commands: `hostname -f`,
`rpm -q`, a `systemctl` in a custom function. pupgrade's execution guard
catches the commands that go through Puppet's and Facter's execution
helpers, and every `Facter.value` read. A command nothing answers stops that
node's compile (`--on-leak raise`, the default), so you find them one at a
time, or all at once with `--on-leak allow`.

`pupgrade/compiler-mocks.yaml` answers them:

```yaml
---
commands:
  - match: '^hostname'                  # a regexp against the command line
    stdout: "${facts.networking.fqdn}\n" # may reference the node's facts
  - match: '\A/usr/bin/getent '
    stdout: ''
  - match: '\Asystemctl is-active '
    exit: 3                             # a mocked exit status
    when:                               # only on nodes whose facts match
      os.family: [RedHat, Debian]
  - match: 'systemctl list-unit-files'
    action: allow                       # run it for real, but record it
facts:                                  # Facter.value reads the factset lacks
  fips_enabled: false
```

The first entry whose `match` fits and whose `when` holds answers. pupgrade
applies its own mocks after yours, for the probes package providers make as
they load (`pupgrade compile --show-default-mocks` prints them).

Every interception is in the node's `probes.json` under `leaks`; the compile
table counts the answered ones under `mocks` and the rest under `leaks`.

### ENC rules

Hierarchies usually key on something an ENC sets: `$role`, `$site`, a
tenant. `pupgrade/enc.yaml` stands in for the ENC, with rules applied in
order, later assignments winning:

```yaml
---
rules:
  - set:                              # every node
      role: role::base
  - when:
      certname: 'pup*'                # a glob on the certname
    set:
      role: role::puppetserver
    classes: [profile::puppetserver]
  - when:
      facts.os.family: [RedHat]       # a fact, any of the values
    set:
      pkg_manager: dnf
  - set:
      site: '${certname[/\A[^.]+\.([^.]+)\./, 1]}'   # a regexp capture
      family: '${facts.os.family}'
```

For what YAML cannot say, `pupgrade/compiler.rb` is plain Ruby, loaded after
the rules; each block gets the node as resolved so far:

```ruby
variable(:tenant) { |node| node['site'] == 'b' ? 'blue' : 'green' }
classes  { |node| ['profile::el'] if node.fact('os.family') == 'RedHat' }
mock(/\Arpm -q (\S+)\z/) { |node, m| "#{m[1]}-1.0-1.el9\n" }   # a mock answer, too
```

A `variable` block returning nil leaves what the rules set; a `mock` block
returning nil declines, and the YAML mocks are tried. `--var NAME=VALUE`
sets a variable on every node from the command line. What each node was
given is in its `probes.json` under `enc`, and `pupgrade lookup --list`
shows it for every node at once.

## The commands

`pupgrade help` lists them and `pupgrade COMMAND --help` explains each. All of
them take `-d DIR` for a control repo other than the current directory.

### check

Resolves the dependency ranges, Puppet requirements, and operating systems
every deployed module declares against every other, and lists the
conflicts. Exits 1 while any remain.

```shell
pupgrade check                                 # every conflict
pupgrade check --summary                       # one row per module
pupgrade check --conflicts puppet-version      # one kind
pupgrade check --propose Puppetfile.proposed   # what a proposal introduces (+ NEW) and resolves (- FIXD)
pupgrade check --propose Puppetfile.proposed --by-change   # grouped by the entry that caused each
pupgrade check --ignore puppetlabs-translate   # as if a module were gone
```

A proposal is a Puppetfile overlay: only the entries that change, each
replacing the current entry at the same path. `solve -o` writes one.

### compile

Compiles a catalog per factset through Puppet's own compiler, in the
deployed environment, and records what each compile used: functions and
their call sites, facts read, lookups made, types, providers, type aliases,
warnings, deprecations, and the commands the guard intercepted. The
catalogs and `probes.json` records land under `pupgrade/cache/catalogs/`.

```shell
pupgrade compile                              # every factset in compile.factsets
pupgrade compile --certname 'web*' -vv        # some nodes, with each mock answer logged
pupgrade compile --fail-fast                  # stop at the first failure
pupgrade compile --code 'notify { "${site}": }' --certname web01.example.com   # try something
pupgrade compile diff /tmp/before /tmp/after  # catalogs of two runs, node by node
```

`--prepend CODE|@FILE` evaluates Puppet code before the manifest, for the
resources only production has.

### solve

Picks a version for every deployed git module from the tags its clone holds,
dependencies first, each at the first candidate that satisfies its dependency
ranges, your Puppet requirement, and your operating systems against what is
already decided.

```shell
pupgrade solve                                 # newest that fits, every module
pupgrade solve --order oldest --bump puppetlabs-stdlib=v9.6.0   # move stdlib, drag the rest the least
pupgrade solve --hold puppetlabs-apache        # keep one where it is
pupgrade solve --prune-unused -o Puppetfile.proposed   # ignore edges to modules no catalog used
pupgrade solve --explain stdlib,concat         # every candidate's verdict
```

A module that cannot move is `held`, and its note says which candidate was
blocked and by what: `held: v6.0.0 needs puppetlabs/augeas_core >= 3.0.0, but
augeas_core is 2.0.1`. `--explain` shows every candidate's verdict when that
is not enough. Exits 1 when any module is held.

### impact

For every module a proposal moves, the API changes between the deployed
version and the proposed ref, each mapped to what uses it in the catalogs
and data: a parameter removed to the nodes setting it and the Hiera keys
naming it, a function removed to its call sites, a type attribute changed to
the resources declaring it.

```shell
pupgrade impact Puppetfile.proposed
pupgrade impact Puppetfile.proposed --summary                     # one row per module
pupgrade impact Puppetfile.proposed --modules puppetlabs-stdlib --changelog   # with the versions' CHANGELOG sections
```

Exits 1 when any finding has a use. A finding reads `use unknown` when there
are no catalogs to check it against.

### module

```shell
pupgrade module list                           # every module: declared, deployed, and whether they agree
pupgrade module info stdlib                    # one module: names, clone, metadata, candidates
pupgrade module diff stdlib stdlib:v9.6.0      # what changes between two versions
pupgrade module diff stdlib stdlib:v9.6.0 --full   # every value whole, as blocks
pupgrade module gitlog stdlib v9.6.0           # what a ref has beyond the clone
pupgrade module update stdlib v9.6.0           # check the ref out, in place
```

`module diff` compares metadata (dependencies, requirements, operating
systems) and then every API surface: classes and defined types with their
parameters, functions, type aliases, resource types, providers, facts. A
side is a module name, `name:ref` for a ref of its clone, a directory, or a
document `surface` wrote. Module names match by their short name, whoever
owns them: `puppetlabs-stdlib`, `puppet/stdlib`, and `stdlib` are one module.

### surface

Extracts a module's API into a JSON document under
`pupgrade/cache/api_surfaces/`, which `module diff` and `impact` read.

```shell
pupgrade surface stdlib -o -                   # the document, to stdout
pupgrade surface --all                         # every module, into the cache
pupgrade surface --git https://git.example.com/puppetlabs-stdlib.git --ref v9.6.0
```

### lookup

A Hiera lookup as a node would see it: the node from a factset, its
variables and classes from the ENC rules, the hierarchy from the repo.

```shell
pupgrade lookup profile::base::ntp_servers --node web01.example.com
pupgrade lookup profile::base::ntp_servers --node web01.example.com --explain
pupgrade lookup --list                         # every node with the facts and variables that place it
```

`--compile` evaluates the manifests first, for a hierarchy that keys on a
variable the manifests set.

## Scenarios

Each sequence runs from the deployed control repo, with `compile.factsets`
set and a mock file in place. The baseline for all of them is the Quick
Start: `check --summary` to see where you stand, `compile` to have catalogs.

### stdlib 8 to stdlib 9

The knot: almost every module depends on stdlib, old releases declare
`< 9.0.0`, and the modules that accept 9 need their own major bumps.

```shell
# 1. what moving stdlib alone would do: every dependent whose range excludes 9
cat > Puppetfile.stdlib <<'EOF'
mod 'puppetlabs-stdlib',
  git: 'https://git.example.com/mirrors/puppetlabs-stdlib.git',
  tag: 'v9.6.0'
EOF
pupgrade check --propose Puppetfile.stdlib --by-change

# 2. let the solver move the dependents with it: stdlib first, everything
#    else to the first release that accepts it
pupgrade solve --order oldest --bump puppetlabs-stdlib=v9.6.0 -o Puppetfile.proposed

# 3. what the proposal leaves unresolved, and why each held module is held
pupgrade check --propose Puppetfile.proposed --summary
pupgrade solve --order oldest --bump puppetlabs-stdlib=v9.6.0 --explain apache

# 4. what the site would feel: removed functions at their call sites,
#    parameters removed or retyped against the nodes and Hiera keys setting them
pupgrade impact Puppetfile.proposed
pupgrade impact Puppetfile.proposed --modules puppetlabs-stdlib --changelog

# 5. the full API delta of one module, when a finding is not enough
pupgrade module diff stdlib stdlib:v9.6.0 --surfaces functions --changes removed
```

Then move the modules (`module update`, or deploy the proposed Puppetfile
with r10k), compile again, and diff the catalogs.

### Puppet 7 to OpenVox 8

pupgrade runs on OpenVox 8, so modules are assessed and catalogs compiled
under the target. Set the requirement to where you are going:

```yaml
modules:
  requirements:
    puppet: '>= 8.0.0 < 9.0.0'
```

```shell
# 1. modules whose declared Puppet range excludes 8
pupgrade check --conflicts puppet-version
# one that declares '< 8' but is known to work: ignore its claim
pupgrade check --conflicts puppet-version --exclude-requirements puppetlabs-translate

# 2. move what has a release supporting 8; what is held has none
pupgrade solve -o Puppetfile.proposed

# 3. compile every factset under OpenVox 8; the deprecations and warnings
#    each compile raised are in its record
pupgrade compile
jq '.deprecations, .warnings' pupgrade/cache/catalogs/*/probes.json

# 4. the module moves' impact, then catalogs before and after
pupgrade impact Puppetfile.proposed --summary
```

The facts in the factsets are whatever the exporting nodes reported, so
facts that moved between Facter versions show up as missing fact reads in
`probes.json` (`facts`, `legacy_facts`, and leaks of kind `fact`).

### A stubborn dependency

A module declares every dependency any of its code paths could need; a site
uses a few. `solve` holds a module back whenever a declared range blocks it:

```text
voxpupuli-firewalld | tag v5.1.0 | (current) | 1 | held: v6.0.0 needs puppetlabs/augeas_core >= 3.0.0, but augeas_core is 2.0.1
```

Four ways out, from least to most hands-on:

```shell
# 1. see every candidate's verdict: is any version of firewalld fine with 2.0.1?
pupgrade solve --explain firewalld

# 2. let the catalogs decide: an edge to a module nothing uses is not a constraint,
#    and the edges the result still violates are written as exclusions to adopt
pupgrade solve --prune-unused --exclusions pupgrade/exclusions.yaml -o Puppetfile.proposed
cat pupgrade/exclusions.yaml        # modules: exclude_dependencies: [voxpupuli-firewalld:puppetlabs/augeas_core]

# 3. force it: a bump moves the module whatever it breaks, and shows what that is
pupgrade solve --bump firewalld=v6.0.0

# 4. ignore the one edge for good, keeping the version constraint so pupgrade
#    warns when firewalld's own requirement moves on
```

```yaml
modules:
  exclude_dependencies:
    - 'voxpupuli-firewalld:puppetlabs/augeas_core >= 3.0.0'
```

`solve` also warns about the opposite case: a module whose code calls
another module's functions without declaring it (`used, but not a declared
dependency`), an edge the solver cannot see in metadata.

### Finding and fixing compile leaks

A command run during a compile ties the catalog to the compiling host; in a
container it fails. The guard sees commands run through Puppet's and
Facter's execution helpers and every `Facter.value` read (not raw Ruby
backticks, and no provider confines, since the catalog is never applied).

```shell
# 1. find them: a compile stops at the first command nothing answers, and
#    the warning says what asked and from where
pupgrade compile
#   warning: guard: web01.example.com: execute: "hostname -f" is not answered by the
#   mocks at site-modules/profile/manifests/base.pp:13 via modules/stdlib/lib/puppet/functions/stdlib/run_hostname.rb:4

# 2. or find them all at once: every command runs for real, and is recorded
pupgrade compile --on-leak allow
jq '.leaks[] | select(.action == "allowed")' pupgrade/cache/catalogs/*/probes.json

# 3. answer each one in pupgrade/compiler-mocks.yaml (see Mocks), then
pupgrade compile -vv          # each mocked answer logged, with its call site
```

### Comparing two control repo versions

Two deployed directories, compiled with the same factsets, diffed catalog by
catalog. Worktrees keep both checkouts side by side; each needs its modules
deployed.

```shell
git worktree add ../control-next upgrade/stdlib-9
(cd ../control-next && r10k puppetfile install)

pupgrade compile -d . -o /tmp/cat-now
pupgrade compile -d ../control-next --factsets ../control/pupgrade/factsets -o /tmp/cat-next

pupgrade compile diff /tmp/cat-now /tmp/cat-next            # per node
pupgrade compile diff /tmp/cat-now /tmp/cat-next --group    # identical changes folded across nodes
pupgrade compile diff /tmp/cat-now /tmp/cat-next --changes param-changed --resources 'File*'
```

Catalog documents are sorted and carry repo-relative paths, so two checkouts
of the same code produce identical files and the diff shows only what the
code change did. A module's changed Hiera default shows here as a
`param-changed` row, which is the one kind of change `impact` cannot see.

## Installation

pupgrade is two gems, `driftless` and `pupgrade`, both pure Ruby. Everything
else they need (Puppet, Facter, `semantic_puppet`, `deep_merge`) ships with
the OpenVox AIO packages. `git` must be on the host.

### With the Bolt AIO

The OpenBolt AIO ships a real `openvox` gem that RubyGems can resolve by
name, so the two gems install into the user gem directory with no network
access and nothing written under `/opt/puppetlabs`:

```shell
G=/opt/puppetlabs/bolt/bin/gem
$G install --user-install --local driftless-*.gem pupgrade-*.gem
~/.local/share/gem/ruby/3.2.0/bin/pupgrade --version
```

Put that `bin` directory on `PATH`, or call the binstub by path. Its shebang
is the AIO Ruby, so the second Ruby that `compile` and `surface` start is
the same one. Bolt's AIO also ships r10k, for deploying a proposed
Puppetfile.

### On an airgapped host

Build the two `.gem` files on a connected host and carry them over:

```shell
(cd driftless && /opt/puppetlabs/bolt/bin/gem build driftless.gemspec)
(cd pupgrade  && /opt/puppetlabs/bolt/bin/gem build pupgrade.gemspec)
```

Then install as above; `gem install --local` resolves dependencies against
what is already installed and touches no network. What else to bring:

- **Factsets**, exported where PuppetDB is reachable (`driftless export
  factsets --onceover-role-tree`), carried with the control repo.
- **The mock and ENC files**, which are site knowledge and belong in the
  control repo under `pupgrade/`.
- **Reachable module remotes**: `check --propose`, `solve --fetch`, and
  `impact` fetch a module's metadata or surface from its remote when the
  clone does not have the ref. On an isolated network these are the mirrors
  the Puppetfile already names; without them, `solve` reads the deployed
  clones' tags only.

Bundler is not needed; pupgrade has no native extensions.

### With the openvox-agent AIO

The agent AIO carries Puppet as code under `vendor_ruby`, not as a gem
RubyGems can resolve, so `gem install driftless` is refused there over its
`openvox` dependency. Two ways around it:

- Install the Bolt AIO beside the agent and run pupgrade from it. This is the
  path with the fewest moving parts.
- Build driftless from a branch that drops the gemspec's `openvox`
  dependency and lets the host supply Puppet (`openvox-provided-by-host` in
  driftless's repo), then install both gems into a `GEM_HOME` of your own
  with `--ignore-dependencies` off. Puppet is then whatever the agent ships.

Either way, note that the wrappers `/opt/puppetlabs/bin/puppet` and
`/usr/local/bin/bolt` unset `GEM_HOME`, `GEM_PATH`, and `RUBYLIB`; pupgrade's
own binstub is not wrapped, so this only matters when running it through one
of those.

## Logging and colour

Commands say what stage they are at. `-v` adds a line per item worked on,
`-vv` each decision, file, and mock answer, `-vvv` every command run with its
purpose. `-q` keeps errors only. `--[no-]color` overrides the terminal
detection, `--width N` wraps tables to a width, and `logging.level` in the
config takes the same names as Puppet's levels.

## Developing pupgrade

```shell
git clone https://github.com/op-ct/driftless ../driftless   # the Gemfile points at it by path
/opt/puppetlabs/bolt/bin/bundle install
/opt/puppetlabs/bolt/bin/bundle exec rspec
/opt/puppetlabs/bolt/bin/bundle exec rake fixture[/tmp/fixture]   # a control repo to try things on
```

The fixture holds 32 git modules with tagged releases, two Forge modules,
factsets, mocks, ENC rules, and a `Puppetfile.proposed` that bumps stdlib a
major version, so every command above runs against it.

## Licence

Apache 2.0; see `LICENSE`.

[dependency hell]: https://en.wikipedia.org/wiki/Dependency_hell
