require 'spec_helper'

require 'pupgrade/surface/diff'

RSpec.describe Pupgrade::Surface::Diff::Change do
  def default(old, new)
    described_class.new(section: 'classes', name: 'apache', path: %w[params version default], kind: 'changed', old: old, new: new)
  end

  it 'tells a default changed only in its quotes from one whose value changed' do
    expect(default("'100'", '100').requoted?).to be(true)
    expect(default('"on"', "'on'").requoted?).to be(true)
    expect(default("'8.6.0'", "'9.6.0'").requoted?).to be(false)
    expect(default('"${x}"', "'${x}'").requoted?).to be(false)
    expect(default("'100'", "'100'").requoted?).to be(false)
    expect(described_class.new(section: 'classes', name: 'apache', path: %w[params version type], kind: 'changed',
                               old: "'100'", new: '100').requoted?).to be(false)
  end
end
