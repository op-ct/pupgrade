# pupgrade

_What stuff will this break?_

## Description

A control-repo upgrade helper for Puppet/OpenVox. It analyzes module upgrades
for a large control repository: checks a proposed set of modules against
each other's `metadata.json`, follows each module's tracking branch, and
compares recorded class-param schemas between refs.

This is a companion project to the Puppet control repo jankiness-linter, [driftless](https://github.com/op-ct/driftless).
If driftless's job is to report "what is", pupgrade's job is to figure "what if".


## Setup

pupgrade runs on the Ruby shipped in the openvox-agent AIO package.

```sh
bundle install
bundle exec pupgrade --help
```

### Config files

* Configuration lives in `pupgrade.yaml` in the control repo.
  * You can also use `~/.config/pupgrade/config.yaml` (user), and `/etc/puppetlabs/pupgrade/config.yaml` (system), but system seems a bit silly

## Usage

* `pupgrade help` lists the commands.
  * Today, they are `check`, `compile`, `compile diff`, `config new`, `impact`, `solve`, `surface`, `surface diff`, `module gitlog`, `module update`, and `params compare`.
  * `pupgrade config new` writes a `pupgrade.yaml` with every key commented out




```sh
# Compile catalogs from factsets + stubbed functions
pupgrade compile --factsets pupgrade/factsets/ \
  --stubs pupgrade-stubs.yaml -o pupgrade/catalogs/

pupgrade solve --evidence pupgrade/catalogs/ --prune-unused \
  --exclusions exclusions.yaml -o Puppetfile.solved

pupgrade check --propose Puppetfile.solved --by-change
```

To make the second and third steps repeatable, put the inputs in `pupgrade.yaml`:

```yaml
compile:
  factsets: [factsets]
  stubs: pupgrade-stubs.yaml
  output_dir: pupgrade/catalogs
solve:
  evidence: pupgrade/catalogs
```

After which `pupgrade compile` and `pupgrade solve --prune-unused` need no flags.



