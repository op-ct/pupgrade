require_relative 'lib/pupgrade/version'

Gem::Specification.new do |spec|
  spec.name        = 'pupgrade'
  spec.version     = Pupgrade::VERSION
  spec.authors     = ['Chris Tessmer']
  spec.email       = ['chris.tessmer@onyxpoint.com']
  spec.summary     = 'Puppet/OpenVox control-repo upgrade helper: what stuff will this break?'
  spec.description = <<~DESC
    Helps plan module upgrades for a Puppet/OpenVox control repo: checks a
    proposed Puppetfile's modules against each other's metadata, follows
    each module's tracking branch, and compares recorded class-param
    schemas between refs. Reads the deployed repo through driftless and
    answers what would change; driftless answers what is.
  DESC
  spec.license = 'Apache-2.0'
  spec.required_ruby_version = ['>= 3.2', '< 4.0']

  spec.files         = Dir['lib/**/*.{rb,yaml}', 'bin/*']
  spec.bindir        = 'bin'
  spec.executables   = ['pupgrade']
  spec.require_paths = ['lib']

  spec.add_dependency 'driftless', '~> 0.4'
end
