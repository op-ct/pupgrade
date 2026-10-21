require 'spec_helper'

require 'pupgrade/module_name'

RSpec.describe Pupgrade::ModuleName do
  it 'matches a module by any of its spellings, case-insensitively' do
    %w[simp/fips simp-fips fips SIMP-FIPS].each do |glob|
      expect(described_class.match?(glob, 'simp-fips')).to be(true), glob
      expect(described_class.match?(glob, 'simp/fips')).to be(true), glob
    end
    expect(described_class.match?('fips', 'simp-fips_other')).to be(false)
    expect(described_class.match?('simp-*', 'simp/fips')).to be(true)
    expect(described_class.match?('*/fips', 'simp-fips')).to be(true)
    expect(described_class.match?('fips', nil, 'simp-fips')).to be(true)
  end

  it 'lets a glob with an owner name a module that declares none, unless the glob has wildcards' do
    expect(described_class.match?('puppet-augeasproviders', 'augeasproviders')).to be(true)
    expect(described_class.match?('puppet-*', 'augeasproviders')).to be(false)
    expect(described_class.match?('puppet-augeasproviders', 'other-augeasproviders')).to be(false)
  end

  it 'gives the short name and a list check' do
    expect(described_class.short('simp/fips')).to eq('fips')
    expect(described_class.short('fips')).to eq('fips')
    expect(described_class.any?(%w[stdlib concat], 'puppetlabs-concat')).to be(true)
    expect(described_class.any?([], 'puppetlabs-concat')).to be(false)
  end
end
