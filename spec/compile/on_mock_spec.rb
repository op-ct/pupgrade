require 'spec_helper'

require 'pupgrade/compile/factset'
require 'pupgrade/compile/on_mock'

RSpec.describe Pupgrade::Compile::OnMock do
  def factset(certname, values)
    Pupgrade::Compile::Factset.new(certname: certname, values: values, trusted: {}, trusted_external: {}, path: '')
  end

  let(:web) { factset('web01.example.com', 'os' => { 'family' => 'RedHat', 'name' => 'Rocky' }) }
  let(:db)  { factset('db01.example.com', 'os' => { 'family' => 'Debian', 'name' => 'Ubuntu' }) }

  it 'gives every node the level of a bare rule, and debug with none' do
    expect(described_class.parse([]).level_for(web)).to eq('debug')
    expect(described_class.parse('silent').level_for(web)).to eq('silent')
    expect(described_class.parse(%w[silent notice]).level_for(db)).to eq('notice')
  end

  it 'filters by certname globs and fact values, the last matching rule deciding' do
    rules = described_class.parse(['silent', 'certname=web*,other*:info', 'facts.os.name=Ubuntu:notice'])
    expect(rules.level_for(web)).to eq('info')
    expect(rules.level_for(db)).to eq('notice')
    both = described_class.parse('certname=web*;facts.os.family=redhat*:trace')
    expect(both.level_for(web)).to eq('trace')
    expect(both.level_for(db)).to eq('debug')
    expect(both.to_s).to eq('certname=web*:facts.os.family=redhat*:trace')
  end

  it 'refuses a level or a filter it does not know' do
    expect { described_class.parse('loud') }.to raise_error(described_class::Error, /loud/)
    expect { described_class.parse('node=web*:info') }.to raise_error(described_class::Error, /certname=GLOB or facts.PATH=VALUE/)
    expect { described_class.parse('certname=:info') }.to raise_error(described_class::Error)
  end
end
