# pupgrade scenarios

End-to-end command sequences for the situations pupgrade is for, each with the
`pupgrade.yaml` keys it reads, followed by installation notes for connected
and isolated hosts.

Every command runs from the deployed control repo (the directory holding
`environment.conf`, `hiera.yaml`, and the Puppetfile, with the modules
deployed under it), so `-d` is left out below. `pupgrade config new` writes a
`pupgrade.yaml` with every key commented out; the fragments shown are the keys
each scenario uses.

Terms used throughout:

- **evidence**: a `compile` output directory, `OUT/<certname>/{catalog,probes}.json`.
  `solve --prune-unused` and `impact` read it to learn what the site uses.
- **overlay**: a Puppetfile holding only the entries that change. `check
  --propose`, `impact --propose`, and `solve -o` all use this shape: an entry
  replaces the current one at the same deploy path; entries left out stay.
- **factsets**: one file per node, either onceover's layout (`name`, `values`,
  `trusted`) or the plain facts hash `driftless export factsets` writes.

## 0. Baseline for every scenario

```yaml
# pupgrade.yaml
modules:
  operatingsystems:          # what every module must declare support for
    RedHat: ['8', '9']
    Ubuntu: ['22.04']
  requirements:
    puppet: '>= 8.0.0 < 9.0.0'   # the Puppet the control repo runs, or is moving to
  exclude_requirements: []       # modules whose Puppet range you have decided to ignore
  exclude_operatingsystems: []
  exclude_dependencies: []
compile:
  factsets: [spec/factsets]      # or wherever driftless exported them
  stubs: pupgrade-stubs.yaml
  output_dir: pupgrade-catalogs
solve:
  evidence: pupgrade-catalogs
```

```sh
# what the deployed modules say about each other today
pupgrade check --summary
pupgrade check --conflicts puppet-version
# catalogs and probe records for every factset: the evidence the later steps use
pupgrade compile
```

`check` exits 1 while conflicts remain; on an old baseline most of them are
operating-system rows. Decide which are noise and put them in
`modules.exclude_*` before going on, so the proposal views show only what a
change does.

## 1. stdlib 8 to stdlib 9

The knot: almost every module depends on stdlib, old releases declare `< 9.0.0`,
and the modules that accept 9 need their own major bumps.

```sh
# 1. what moving stdlib alone would do
cat > Puppetfile.stdlib <<'EOF'
mod 'puppetlabs-stdlib',
  git: 'https://git.example.com/mirrors/puppetlabs-stdlib.git',
  tag: 'v9.6.0'
EOF
pupgrade check --propose Puppetfile.stdlib --by-change
# every dependent whose range excludes 9 appears under the stdlib heading

# 2. let the solver move the dependents with it: stdlib first, everything
#    else to the first release that accepts it
pupgrade solve --order oldest --bump puppetlabs-stdlib=v9.6.0 -o Puppetfile.proposed
# or as far as everything can go:
pupgrade solve -o Puppetfile.proposed

# 3. what the proposal leaves, by the entry that caused it
pupgrade check --propose Puppetfile.proposed --by-change
pupgrade check --propose Puppetfile.proposed --summary

# 4. what the site would feel: removed functions at their call sites,
#    parameters removed or retyped against Hiera and the nodes setting them
pupgrade impact --propose Puppetfile.proposed
pupgrade impact --propose Puppetfile.proposed --modules puppetlabs-stdlib --changelog

# 5. the full API delta of one module, when the finding is not enough
pupgrade surface modules/stdlib -o stdlib-8.json
pupgrade surface --git https://git.example.com/mirrors/puppetlabs-stdlib.git --ref v9.6.0 -o stdlib-9.json
pupgrade surface diff stdlib-8.json stdlib-9.json --surfaces functions --changes removed
```

Modules `solve` holds (exit 1, note starting `held:`) are the ones to decide
on by hand: pin, replace, or drop the edge (scenario 3). Then deploy the
proposed Puppetfile somewhere and compare catalogs (scenario 6).

Keys read: `modules.*` for the constraints, `solve.*` for the candidates,
`compile.output_dir` as `impact`'s default evidence.

## 2. Puppet 7 to OpenVox 8.30

pupgrade runs on OpenVox 8 (its dependency on driftless requires openvox 8.28
or later), so the modules are assessed and the catalogs compiled under the
target, not the source. The Puppet 7 side of the comparison comes from the
running fleet: driftless's PuppetDB reports and factsets, and onceover or
`puppet agent --noop` logs for Puppet 7 deprecations.

```yaml
modules:
  requirements:
    puppet: '>= 8.0.0 < 9.0.0'    # the target, as a module's metadata would declare it
  exclude_requirements: []        # fill as you decide which modules' declared ranges to ignore
```

```sh
# 1. modules whose declared Puppet range excludes 8
pupgrade check --conflicts puppet-version
# a module that declares '< 8' but is known to work: ignore its claim
pupgrade check --conflicts puppet-version --exclude-requirements puppetlabs-translate

# 2. move what has a release supporting 8; what is held has none
pupgrade solve -o Puppetfile.proposed

# 3. compile every factset under OpenVox 8.30 (the host pupgrade runs on);
#    deprecations and warnings the compile raised are in each probes.json
pupgrade compile
jq '.deprecations, .warnings' pupgrade-catalogs/*/probes.json
jq -r 'select(.status == "failed") | .certname + ": " + .error' pupgrade-catalogs/*/probes.json

# 4. impact of the module moves, then catalogs before and after (scenario 6)
pupgrade impact --propose Puppetfile.proposed --summary
```

What pupgrade does not do here: it does not run Puppet 7, and it does not
upgrade agents. The facts in the factsets are whatever the exporting nodes
reported, so structured-fact gaps between Facter versions show up as missing
fact reads in `probes.json` (`facts`, `legacy_facts`, and leaks of kind
`fact`), which is the list of fact references to modernise.

## 3. Dep-solving with and without usage hints

A module declares every dependency any of its code paths could need; a site
uses a few. Without evidence the solver holds back whatever a declared range
blocks. With evidence it can drop the edges nothing uses, and record them so
`check` agrees.

```yaml
solve:
  evidence: pupgrade-catalogs      # from `pupgrade compile`
modules:
  exclude_dependencies: []         # or .include an exclusions file (below)
```

```sh
# strict: declared constraints only
pupgrade solve -o Puppetfile.strict
# the note on each held module names the edge in the way, e.g.
#   held: needs puppetlabs/apt >= 9.0.0 < 10.0.0; modules/apt would be 8.5.0

# with evidence: edges to modules no compile used are not constraints
pupgrade compile
pupgrade solve --prune-unused --exclusions pupgrade-exclusions.yaml -o Puppetfile.pruned
# pupgrade-exclusions.yaml holds only the pruned edges the result violates:
#   modules:
#     exclude_dependencies:
#       - puppet-redis:puppetlabs/apt

# make check see the same picture
cat pupgrade-exclusions.yaml                     # review before adopting
pupgrade check --propose Puppetfile.pruned --by-change
```

To adopt the exclusions, either paste the list into `modules.exclude_dependencies`
or include the file:

```yaml
# pupgrade.yaml
.include: pupgrade-exclusions.yaml
```

`solve` also warns about the opposite case: a module whose code calls another
module's functions without declaring it (`used, but not a declared dependency`).
Those are edges the solver cannot see in metadata and worth adding to the
module, or at least knowing about before the dependency moves.

Evidence is only as wide as the factsets compiled. Two nodes of one role show
most modules unused; compile a factset per role at least.

## 4. Finding and fixing compile leaks

Module code that runs a command or reads a live fact during a compile is a
leak: it ties the result to the compiling host, and in a container it fails.
pupgrade's guard sees commands run through Puppet's and Facter's execution
helpers and `Facter.value` reads. It does not see raw Ruby backticks, and it
never converts the catalog to RAL objects, so provider confines (the usual
source of `systemctl` leaks under rspec-puppet) do not run at all.

```yaml
compile:
  stubs: pupgrade-stubs.yaml
  on_leak: raise        # the default: a compile stops at the first unanswered command
```

```sh
# 1. find them: with `raise`, the first leak stops that node's compile
pupgrade compile
cat pupgrade-catalogs/web01.example.com/error.txt
#   execute: "hostname -f" is not answered by the stubs
#   (site-modules/profile/manifests/base.pp:13 via modules/stdlib/lib/puppet/functions/stdlib/run_hostname.rb:4)

# 2. or find them all at once: `allow` runs each command and records it
pupgrade compile --on-leak allow
jq '.leaks[] | select(.action == "allowed")' pupgrade-catalogs/*/probes.json

# 3. answer each one in the stub file
cat > pupgrade-stubs.yaml <<'EOF'
commands:
  - match: '^hostname'          # a regexp against the command line
    stdout: "stub.example.com\n"
  - match: '^/usr/bin/getent '
    stdout: ''
  - match: 'systemctl list-unit-files'
    action: allow               # run it for real, but record it
facts:                          # Facter.value reads the factset lacks
  fips_enabled: false
EOF

# 4. back to `raise`, which now passes; every interception stays in the record
pupgrade compile
jq '.leaks' pupgrade-catalogs/web01.example.com/probes.json
```

A stubbed command shows as `action: stubbed`; an allowed one as `allowed`; a
missing fact as kind `fact`, `action: missing`, which means the module read a
fact the factset does not carry.

## 5. Reading a module's API with `surface`

```sh
# the deployed module
pupgrade surface modules/apache -o apache-now.json
# a release, through the module's remote
pupgrade surface --git https://git.example.com/mirrors/puppetlabs-apache.git --ref v12.0.0 -o apache-12.json
# what the document holds
jq 'keys' apache-now.json
jq '.functions | keys' apache-now.json
jq '.types.firewall.params' firewall-now.json

# differences, as entries added and removed per surface and each attribute that changed
pupgrade surface diff apache-now.json apache-12.json
pupgrade surface diff modules/apache apache-12.json --surfaces classes,defined_types
pupgrade surface diff apache-now.json apache-12.json --summary
```

Extraction loads the module's Ruby (functions, types, providers, facts), so
it runs in a process of its own under the same Ruby and Puppet pupgrade runs
on. Files that fail to load are listed under `errors` in the document and the
rest is still produced; a provider for a type another module ships is one
such case, since the type is not loadable from the module alone.

## 6. Comparing two control repo versions

Two deployed directories, compiled with the same factsets, diffed catalog by
catalog. Worktrees keep both checkouts of one repo side by side; each still
needs its modules deployed.

```sh
# 1. the second version, deployed
git worktree add ../control-next upgrade/stdlib-9
cd ../control-next
r10k puppetfile install          # or copy Puppetfile.proposed over Puppetfile first
cd -

# 2. compile both with the same factsets and stubs
pupgrade compile -d . --factsets spec/factsets --stubs pupgrade-stubs.yaml -o /tmp/cat-now
pupgrade compile -d ../control-next --factsets spec/factsets --stubs pupgrade-stubs.yaml -o /tmp/cat-next

# 3. what changed, per node, and folded across nodes
pupgrade compile diff /tmp/cat-now /tmp/cat-next
pupgrade compile diff /tmp/cat-now /tmp/cat-next --group
pupgrade compile diff /tmp/cat-now /tmp/cat-next --summary
pupgrade compile diff /tmp/cat-now /tmp/cat-next --changes param-changed --resources 'File*'
```

Catalog documents are sorted and carry paths relative to their repo, so two
checkouts of the same code produce identical files and the diff shows only
what the code change did. The catalog version is each checkout's git sha. A
module's changed Hiera default shows here as a `param-changed` row, which is
the one kind of change `impact` does not report.

The probe records are worth diffing too; there is no command for it yet, but
`jq` over `functions`, `lookups`, and `deprecations` of the two runs shows
which functions a change stopped calling and which lookups it stopped making.

# Installation

pupgrade is two gems, `driftless` and `pupgrade`, neither on rubygems.org.
Both are pure Ruby. Everything else they need ships with the OpenVox AIOs:
Puppet, Facter, `semantic_puppet`, and `deep_merge`. `git` must be on the
host; `check --propose`, `solve`, `surface --git`, and `impact` call it.

## Which AIO Ruby

| | OpenBolt AIO (`/opt/puppetlabs/bolt/bin`) | openvox-agent AIO (`/opt/puppetlabs/puppet/bin`) |
|---|---|---|
| Puppet | a real `openvox` gem (8.28.0 here), resolvable by name | code in `vendor_ruby`, with a gemspec stub whose file name says `puppet` and whose contents say `openvox`; RubyGems cannot resolve it by name |
| `gem install --local driftless-*.gem` | works: the openvox dependency resolves | refused: `Could not find a valid gem 'openvox'`, and `--ignore-dependencies` still fails at activation |
| also ships | r10k, for deploying a proposed Puppetfile | nothing extra |

So the OpenBolt AIO is the one to install into today. The agent AIO needs
driftless built from its `openvox-provided-by-host` branch, which drops the
gemspec dependency and lets the host supply Puppet; that branch exists and is
verified to install offline into a fresh `GEM_HOME` on the agent AIO, but it
is not merged. (The details are in driftless's
`local_notes/design/driftless-gem-considerations.md`.)

One thing to know about both AIOs: the wrappers `/usr/local/bin/bolt` and
`/opt/puppetlabs/bin/puppet` unset `GEM_HOME`, `GEM_PATH`, `RUBYLIB`, and
`RUBYOPT`. pupgrade's own binstub is not wrapped, so this only matters if
you try to run it through one of those.

## Connected host

From the two checkouts, build and install into the user gem directory of the
AIO Ruby. Nothing is written under `/opt/puppetlabs`.

```sh
G=/opt/puppetlabs/bolt/bin/gem
(cd ~/src/driftless && $G build driftless.gemspec)
(cd ~/src/pupgrade  && $G build pupgrade.gemspec)
$G install --user-install --local ~/src/driftless/driftless-*.gem ~/src/pupgrade/pupgrade-*.gem
~/.local/share/gem/ruby/3.2.0/bin/pupgrade --version
```

Put `~/.local/share/gem/ruby/3.2.0/bin` on `PATH`, or call the binstub by
path. Its shebang is the AIO Ruby, so `pupgrade compile` and `pupgrade
surface`, which start a second Ruby, find the same one.

For development, run from the checkout instead:

```sh
cd ~/src/pupgrade
/opt/puppetlabs/bolt/bin/bundle install      # Gemfile points at ../driftless by path
/opt/puppetlabs/bolt/bin/bundle exec bin/pupgrade --help
```

The Gemfile resolves `openvox` from rubygems.org, so the checkout runs on a
newer Puppet than the AIO's (8.31.0 against 8.28.0 here). Pin it in the
Gemfile if the version matters for what you are checking.

## Isolated host

Bring the two `.gem` files. Build them on a connected host as above and
copy them; RubyGems installs a local gem whose dependencies are already
present without touching the network.

```sh
G=/opt/puppetlabs/bolt/bin/gem
$G install --user-install --local driftless-0.4.0.gem pupgrade-0.1.0.gem
```

What else the host needs, and what to bring if it lacks it:

- **git**, for everything that reads module history or remotes.
- **Reachable module remotes**: `check --propose` fetches `metadata.json` from
  each changed module's remote, `surface --git` fetches a ref, and `solve
  --fetch` updates clones. On an isolated network these are the internal
  mirrors the Puppetfile already names. `solve` without `--fetch` and `surface
  DIR` read the deployed clones only.
- **Factsets**, exported where PuppetDB is reachable: `driftless export
  factsets --onceover-role-tree` writes one per role, which is the smallest
  set worth compiling. Carry the directory with the control repo.
- **The stub file** (`pupgrade-stubs.yaml`), which is site knowledge and
  belongs in the control repo.
- **r10k**, to deploy a proposed Puppetfile for scenario 6. The OpenBolt AIO
  ships it; the agent AIO does not.

Bundler is not needed for pupgrade. It is the right tool for stacks with many
gems and native extensions, such as onceover's, and the recipe that works on
the AIOs (`path.system` plus a project `GEM_HOME`, `bundle cache` on the
connected host, `bundle install --local` on the isolated one, with the
AIO-provided gems pinned so Bundler reuses them) is written up in
`puppet-rebugger/_local_notes/handoff-onceover-aio.md`. If pupgrade ever joins
such a bundle, its two gems go into `vendor/cache` like any other, and the
pins keep openvox at the AIO's version.

## Verifying an install

```sh
pupgrade --version
pupgrade config new -p -- | head          # every key the install knows, with defaults
cd /path/to/control-repo && pupgrade check --summary
```

`check` needs only the deployed repo. If it runs, the gems, Puppet, and
`semantic_puppet` are all in place; `compile` additionally needs the factsets,
and `solve` the clones' tags.
