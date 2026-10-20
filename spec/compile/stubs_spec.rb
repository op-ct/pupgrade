require 'spec_helper'
require 'tmpdir'

require 'pupgrade/compile/stubs'

RSpec.describe Pupgrade::Compile::Stubs do
  def load(text)
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'stubs.yaml')
      File.write(path, text)
      return described_class.load(path)
    end
  end

  it 'answers commands by the first matching entry and facts by name or dotted path' do
    stubs = load(<<~YAML)
      commands:
        - match: '^hostname'
          stdout: "h\\n"
        - match: 'systemctl'
          action: allow
      facts:
        fips_enabled: false
        os:
          family: RedHat
    YAML
    expect(stubs.for_command('hostname -f')).to have_attributes(action: 'stub', stdout: "h\n")
    expect(stubs.for_command('/bin/systemctl status x')).to have_attributes(action: 'allow', stdout: '')
    expect(stubs.for_command('ls')).to be_nil
    expect(stubs.fact('fips_enabled')).to eq([true, false])
    expect(stubs.fact('os.family')).to eq([true, 'RedHat'])
    expect(stubs.fact('os.name')).to eq([false, nil])
    expect(stubs.fact('kernel')).to eq([false, nil])
    expect(described_class.empty.for_command('hostname')).to be_nil
  end

  it 'refuses a file that is not a mapping, an entry without a match, and an unknown action' do
    expect { load("- 1\n") }.to raise_error(described_class::Error, /expected a mapping/)
    expect { load("commands:\n  - stdout: x\n") }.to raise_error(described_class::Error, /needs a match/)
    expect { load("commands:\n  - match: x\n    action: ignore\n") }.to raise_error(described_class::Error, /"ignore" is not one of stub, allow/)
    expect { described_class.load('/nonexistent/stubs.yaml') }.to raise_error(described_class::Error, /no such file/)
  end
end
