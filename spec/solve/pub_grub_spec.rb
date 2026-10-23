require 'spec_helper'
require 'semantic_puppet'

require 'pupgrade/solve/pub_grub'

RSpec.describe Pupgrade::Solve::PubGrub do
  def version(text)
    SemanticPuppet::Version.parse(text)
  end

  it 'maps a SemanticPuppet range, a union, and an open end onto the solver\'s ranges' do
    range = described_class.range(SemanticPuppet::VersionRange.parse('>= 9.0.0 < 10.0.0'))
    expect(range.include?(version('9.6.0'))).to be(true)
    expect(range.include?(version('10.0.0'))).to be(false)
    union = described_class.range(SemanticPuppet::VersionRange.parse('>= 1.0.0 < 2.0.0 || >= 3.0.0'))
    expect([version('1.5.0'), version('2.5.0'), version('99.0.0')].map { |v| union.include?(v) }).to eq([true, false, true])
    expect(described_class.range(nil).any?).to be(true)
    expect(described_class.range(SemanticPuppet::VersionRange.parse('< 2.0.0')).to_s).to eq('< 2.0.0')
    expect(described_class.except(version('8.6.0')).include?(version('8.6.0'))).to be(false)
    expect(described_class.except(version('8.6.0')).include?(version('8.6.1'))).to be(true)
    expect(described_class.up_to(version('8.6.0')).include?(version('8.6.1'))).to be(false)
  end

  # Two modules, one of which has no version fitting the other's newest:
  # the solver finds the older pair, and asked for the newer one explains
  # itself through its leaves.
  it 'solves a source and explains a failure from its leaves' do
    versions = { 'stdlib' => [version('9.0.0'), version('8.0.0')], 'app' => [version('2.0.0'), version('1.0.0')] }
    deps     = { 'app' => { 'stdlib' => SemanticPuppet::VersionRange.parse('>= 1.0.0 < 9.0.0') } }
    source = ->(facts) do
      described_class::Source.new(versions: versions, dependencies: ->(p, _v) { deps.fetch(p) { {} } },
                                  reasons: ->(p, v) { (p == 'app' && v.to_s == '2.0.0') ? [['os RedHat', 'app 2.0.0 supports Debian, but not RedHat 9']] : [] },
                                  facts: facts)
    end
    decisions, failure = described_class.solve(source.call([]))
    expect(failure).to be_nil
    expect(decisions.transform_values(&:to_s)).to eq('stdlib' => '8.0.0', 'app' => '1.0.0')

    asked = described_class::Fact.new(package: 'stdlib', range: described_class.up_to(version('8.0.0')), text: 'stdlib is asked past 8.0.0')
    src   = source.call([asked])
    decisions, failure = described_class.solve(src)
    expect(decisions).to be_nil
    texts = described_class.leaves(failure.incompatibility).map { |l| src.keys.fetch(l) { [nil, nil, l.to_s] } }
    expect(texts).to include(['app', 'stdlib', 'every version of app depends on stdlib >= 1.0.0, < 9.0.0'], [nil, nil, 'stdlib is asked past 8.0.0'])

    bump = described_class::Fact.new(package: 'app', range: described_class.except(version('2.0.0')), text: 'app is bumped to 2.0.0 (--bump)')
    _decisions, failure = described_class.solve(source.call([bump]))
    expect(failure.explanation).to include('app 2.0.0 supports Debian, but not RedHat 9', 'app is bumped to 2.0.0 (--bump)')
  end
end
