require 'spec_helper'
require 'tmpdir'

require 'pupgrade/config'

RSpec.describe Pupgrade::Config do
  it 'searches pupgrade paths, not driftless ones' do
    expect(described_class.search_chain.first).to eq('/etc/puppetlabs/pupgrade/config.yaml')
    expect(described_class.user_path).to end_with('/pupgrade/config.yaml')
    expect(described_class.project_path).to eq(File.join(Dir.pwd, 'pupgrade.yaml'))
    expect(Driftless::Config.project_path).to eq(File.join(Dir.pwd, 'driftless.yaml'))
  end

  it 'loads one explicit file with the driftless loader' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'pupgrade.yaml')
      File.write(path, "logging:\n  level: debug\n")
      config = described_class.load(config_path: path)
      expect(config).to be_a(described_class)
      expect(config.dig('logging', 'level')).to eq('debug')
      expect(config.sources).to eq([path])
    end
  end
end
