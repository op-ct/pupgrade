require 'spec_helper'
require 'tmpdir'

require 'pupgrade/compile/mocks'

RSpec.describe Pupgrade::Compile::Mocks do
  def load(text, defaults: false)
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'mocks.yaml')
      File.write(path, text)
      return described_class.load(path, defaults: defaults)
    end
  end

  it 'answers commands by the first matching entry whose conditions the node meets, and facts by name or path' do
    mocks = load(<<~YAML)
      commands:
        - match: '^hostname'
          stdout: "h\\n"
          when:
            os.family: [RedHat, Suse]
        - match: '^hostname'
          exit: 127
        - match: 'systemctl'
          action: allow
      facts:
        fips_enabled: false
        os:
          family: RedHat
    YAML
    redhat = { 'os' => { 'family' => 'RedHat' } }
    debian = { 'os' => { 'family' => 'Debian' } }
    expect(mocks.for_command('hostname -f', redhat)).to have_attributes(action: 'mock', stdout: "h\n", exit: 0)
    expect(mocks.for_command('hostname -f', debian)).to have_attributes(action: 'mock', stdout: '', exit: 127)
    expect(mocks.for_command('/bin/systemctl status x', {})).to have_attributes(action: 'allow')
    expect(mocks.for_command('ls', redhat)).to be_nil
    expect(mocks.fact('fips_enabled')).to eq([true, false])
    expect(mocks.fact('os.family')).to eq([true, 'RedHat'])
    expect(mocks.fact('os.name')).to eq([false, nil])
    expect(mocks.fact('kernel')).to eq([false, nil])
  end

  it 'applies the shipped defaults after the site file, by operating system' do
    mocks = load("commands:\n  - match: '\\A/usr/bin/rpm --version\\z'\n    stdout: \"site\\n\"\n", defaults: true)
    expect(mocks.for_command('/usr/bin/rpm --version', 'os' => { 'family' => 'RedHat' })).to have_attributes(stdout: "site\n")
    expect(mocks.for_command('rpm -ql rpm', 'os' => { 'family' => 'RedHat' })).to have_attributes(stdout: "/usr/bin/rpm\n", exit: 0)
    expect(mocks.for_command('rpm -ql rpm', 'os' => { 'family' => 'Debian' })).to have_attributes(exit: 127)
    expect(described_class.empty.for_command('rpm --version', 'os' => { 'family' => 'Suse' })).to have_attributes(stdout: "RPM version 4.16.1.3\n")
    expect(described_class.empty(defaults: false).for_command('rpm --version', {})).to be_nil
  end

  it 'refuses a file that is not a mapping, an entry without a match, an unknown action, and a bad exit code' do
    expect { load("- 1\n") }.to raise_error(described_class::Error, /expected a mapping/)
    expect { load("commands:\n  - stdout: x\n") }.to raise_error(described_class::Error, /needs a match/)
    expect { load("commands:\n  - match: x\n    action: ignore\n") }.to raise_error(described_class::Error, /"ignore" is not one of mock, allow/)
    expect { load("commands:\n  - match: x\n    exit: many\n") }.to raise_error(described_class::Error, /invalid value for Integer/)
    expect { described_class.load('/nonexistent/mocks.yaml') }.to raise_error(described_class::Error, /no such file/)
  end
end
