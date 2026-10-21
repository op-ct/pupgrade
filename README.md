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
  * Today, they are `check`, `compile`, `compile diff`, `config new`, `config print`, `impact`, `solve`, `surface`, `surface diff`, `module list`, `module info`, `module gitlog`, `module update`, and `params compare`.
  * `pupgrade config new` writes a `pupgrade.yaml` with every key commented out
  * `pupgrade config print [KEY]` shows the config as this run resolves it (`-d` adds unset defaults)
  * `pupgrade module list` and `pupgrade module info MODULE` show what is deployed and what it could move to




```sh
# Compile catalogs from factsets, with mocks answering the commands module code runs
pupgrade compile --factsets pupgrade/factsets/ \
  --mocks pupgrade/mocks.yaml -o pupgrade/cache/catalogs/

pupgrade solve --evidence pupgrade/cache/catalogs/ --prune-unused \
  --exclusions exclusions.yaml -o Puppetfile.solved

pupgrade check --propose Puppetfile.solved --by-change

pupgrade impact --propose Puppetfile.solved --summary
```

To make the steps repeatable, put the inputs in `pupgrade/pupgrade.yaml`:

```yaml
compile:
  factsets: [pupgrade/factsets]
  mocks: pupgrade/mocks.yaml
```

After which `pupgrade compile`, `pupgrade solve --prune-unused`, and `pupgrade
impact` need no flags: `compile` writes to `pupgrade/cache/catalogs` and the
others read from there by default. `pupgrade surface` keeps what it reads under
`pupgrade/cache/api_surfaces`. `pupgrade config print -d` shows every path in
effect.



