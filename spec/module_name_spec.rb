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

  it 'disregards the owner: a module is its short name, whoever owns it' do
    expect(described_class.match?('voxpupuli-firewalld', 'puppet-firewalld')).to be(true)
    expect(described_class.match?('puppet/authselect', 'jcpunk-authselect')).to be(true)
    expect(described_class.match?('puppet-augeasproviders', 'augeasproviders')).to be(true)
    expect(described_class.match?('augeasproviders', 'puppet-augeasproviders')).to be(true)
    expect(described_class.match?('puppet-augeasproviders', 'other-augeasproviders_core')).to be(false)
    expect(described_class.match?('puppet-augeas*', 'other-augeasproviders_core')).to be(true)
  end

  it 'takes a wildcard in the owner part as "owned by", matched on the full name' do
    expect(described_class.match?('puppet-*', 'puppet-fips')).to be(true)
    expect(described_class.match?('puppet-*', 'simp-fips')).to be(false)
    expect(described_class.match?('puppet-*', 'augeasproviders')).to be(false)
    expect(described_class.match?('*-fips', 'simp/fips')).to be(true)
    expect(described_class.match?('*/fips', 'fips')).to be(false)
  end

  it 'gives the short name and a list check' do
    expect(described_class.short('simp/fips')).to eq('fips')
    expect(described_class.short('fips')).to eq('fips')
    expect(described_class.any?(%w[stdlib concat], 'puppetlabs-concat')).to be(true)
    expect(described_class.any?([], 'puppetlabs-concat')).to be(false)
  end
end
