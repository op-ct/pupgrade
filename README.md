# pupgrade

What stuff will this break?

A control-repo upgrade helper for Puppet/OpenVox. It plans module upgrades
for a large control repository: checks a proposed set of modules against
each other's `metadata.json`, follows each module's tracking branch, and
compares recorded class-param schemas between refs.

pupgrade answers "what if". [driftless](https://github.com/op-ct/driftless)
answers "what is", and pupgrade reads the deployed control repo through it.

## Running

pupgrade runs on the Ruby shipped in the openvox-agent AIO package.

```sh
bundle install
bundle exec pupgrade --help
```

`pupgrade help` lists the commands. Today they are `modules resolve`,
`modules gitlog`, `modules update`, and `params compare`, moved here from
driftless.

Configuration lives in `pupgrade.yaml` (project), `~/.config/pupgrade/config.yaml`
(user), and `/etc/puppetlabs/pupgrade/config.yaml` (system), merged in that
order of precedence. `pupgrade config` subcommands are not yet available;
`pupgrade help` lists what is.
