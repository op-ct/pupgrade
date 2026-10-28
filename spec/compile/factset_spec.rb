require 'spec_helper'
require 'tmpdir'
require 'json'

require 'pupgrade/compile/factset'

RSpec.describe Pupgrade::Compile::Factset do
  it 'reads onceover and plain layouts, naming the node from the file when the facts do not' do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'a.example.com.json'), JSON.generate('name' => 'a.example.com', 'values' => { 'kernel' => 'Linux' },
                                                                      'trusted' => { 'certname' => 'a.example.com' }, 'trusted_external' => { 'x' => 1 }))
      File.write(File.join(dir, 'b.example.com.yaml'), "---\nkernel: Linux\nos:\n  family: Debian\n")
      a = described_class.load(File.join(dir, 'a.example.com.json'))
      expect([a.certname, a.values, a.trusted, a.trusted_external]).to eq(['a.example.com', { 'kernel' => 'Linux' }, { 'certname' => 'a.example.com' }, { 'x' => 1 }])
      b = described_class.load(File.join(dir, 'b.example.com.yaml'))
      expect([b.certname, b.values['os'], b.trusted, b.trusted_external]).to eq(['b.example.com', { 'family' => 'Debian' }, nil, {}])
    end
  end

  it 'names the node from the facts\' trusted certname, else their clientcert, before the file name' do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'one.json'), JSON.generate('trusted' => { 'certname' => 'a.example.com' }, 'clientcert' => 'b.example.com'))
      File.write(File.join(dir, 'two.json'), JSON.generate('clientcert' => 'b.example.com'))
      File.write(File.join(dir, 'three.json'), JSON.generate('values' => { 'clientcert' => 'c.example.com' }))
      File.write(File.join(dir, 'four.json'), JSON.generate('name' => 'd.example.com', 'values' => { 'clientcert' => 'c.example.com' }))
      expect(%w[one two three four].map { |n| described_class.load(File.join(dir, "#{n}.json")).certname })
        .to eq(%w[a.example.com b.example.com c.example.com d.example.com])
    end
  end

  it 'loads every factset under a directory tree, sorted, and names what it cannot read' do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, 'role::web'))
      File.write(File.join(dir, 'role::web/z.json'), '{"kernel": "Linux"}')
      File.write(File.join(dir, 'a.json'), '{"kernel": "Linux"}')
      File.write(File.join(dir, 'README'), 'not a factset')
      expect(described_class.load_all([dir]).map(&:certname)).to eq(%w[a z])
      File.write(File.join(dir, 'bad.json'), '{')
      expect { described_class.load_all([dir]) }.to raise_error(described_class::Error, /bad\.json: /)
      expect { described_class.load_all([File.join(dir, 'nope')]) }.to raise_error(described_class::Error, /no such file/)
      File.write(File.join(dir, 'bad.json'), '[1]')
      expect { described_class.load(File.join(dir, 'bad.json')) }.to raise_error(described_class::Error, /expected a mapping, got Array/)
    end
  end
end
