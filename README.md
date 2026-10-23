# pupgrade

_What stuff will this break?_

## Description

A control-repo upgrade helper for Puppet/OpenVox. Given a control repo with
its modules deployed, pupgrade answers "what if": which module versions could
move together, what each move would change in a module's API, and which of
those changes the site's own catalogs, data, and code would feel.

It is a companion to [driftless](https://github.com/op-ct/driftless), the
control-repo linter. driftless reports "what is"; pupgrade asks "what if".

## Setup

pupgrade runs on the Ruby an openvox-agent or Bolt package ships. With
Bolt's bundler, for example:

```sh
/opt/puppetlabs/bolt/bin/bundle install
/opt/puppetlabs/bolt/bin/bundle exec pupgrade --help
```

## The loop

Run from the deployed control repo (or pass `-d DIR`).

```sh
# 1. Compile a catalog per factset, recording what each compile used.
pupgrade compile --factsets pupgrade/factsets/

# 2. Pick a version for every module along its tags, within the constraints
#    the modules declare and the catalogs show in use; write the result as a
#    Puppetfile overlay.
pupgrade solve --prune-unused -o Puppetfile.solved

# 3. See what the proposal introduces and resolves among the modules'
#    dependency, Puppet, and OS constraints.
pupgrade check --propose Puppetfile.solved --by-change

# 4. See what each move would change in a module's API, and which nodes,
#    resources, call sites, and Hiera keys use it.
pupgrade impact Puppetfile.solved --summary
pupgrade module diff stdlib stdlib:v9.6.0

# 5. Move a module, in place, and compile again.
pupgrade module update stdlib v9.6.0
```

`pupgrade help` lists the commands: `check`, `compile`, `compile diff`,
`config new`, `config print`, `impact`, `lookup`, `module list`, `module
info`, `module diff`, `module gitlog`, `module update`, `solve`, `surface`,
and `version`. Every command's `--help` says what it is for.

## Files

Everything pupgrade reads or writes of its own sits under `pupgrade/` in the
control repo, found by default when present:

| Path | What |
|---|---|
| `pupgrade/pupgrade.yaml` | configuration; `pupgrade config new` writes one with every key commented out, `config print` shows what is in effect |
| `pupgrade/factsets/` | factsets to compile for, in onceover's layout or as plain facts hashes (`driftless export factsets` writes them) |
| `pupgrade/enc.yaml` | rules deciding each node's top-scope variables and classes from its certname and facts, as an ENC would |
| `pupgrade/compiler.rb` | Ruby blocks for what the rules cannot say: variables, classes, and mock answers |
| `pupgrade/compiler-mocks.yaml` | answers for the commands and facts module code asks for while compiling |
| `pupgrade/cache/catalogs/` | what `compile` wrote; what `solve` and `impact` read |
| `pupgrade/cache/api_surfaces/` | the module API documents `surface` extracts; what `module diff` and `impact` read |

`pupgrade lookup --list` shows every node with the facts and variables that
place it in the hierarchy, and `pupgrade lookup KEY --node CERTNAME` looks a
key up as that node would see it.

## What pupgrade reads

Each command reads the Puppetfile, the deployed modules, or a module's git
clone, as its question needs:

| Command | Reads |
|---|---|
| `check` | the deployed `metadata.json` of every module; with `--propose`, the proposed refs' metadata from the clone or the remote |
| `solve` | the Puppetfile for what is declared, the deployed metadata for the current version, the clone's tags for the candidates |
| `impact` | the Puppetfile and the proposal for what moves, the deployed module and the clone at the proposed ref for the surfaces, the catalogs for the uses |
| `module list`, `module info` | the Puppetfile and the deployed modules side by side |
| `module diff`, `module gitlog`, `module update`, `surface` | the clone; the Puppetfile only to find a module by name, and `update` warns when it then disagrees |
| `compile`, `lookup` | neither: `environment.conf` and what is on disk |

## Logging and colour

Commands say what stage they are at. `-v` adds a line per item worked on,
`-vv` each decision and file, `-vvv` every command run. `--[no-]color`
overrides the terminal detection, and `--width N` wraps tables to a width.

## Licence

Apache 2.0; see `LICENSE`.
