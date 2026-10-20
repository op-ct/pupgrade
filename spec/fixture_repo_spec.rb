require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'stringio'

require 'support/fixture_repo'
require 'driftless/module_inventory'
require 'pupgrade/module_resolver'
require 'pupgrade/module_proposal'
require 'pupgrade/cli/check'

RSpec.describe Pupgrade::FixtureRepo do
  # Built once: it clones every module.
  before(:all) do # rubocop:disable RSpec/BeforeAfterAll
    @tmp    = Dir.mktmpdir
    @result = described_class.build(File.join(@tmp, 'repo'))
  end

  after(:all) { FileUtils.rm_rf(@tmp) } # rubocop:disable RSpec/BeforeAfterAll

  let(:result)    { @result }
  let(:inventory) { Driftless::ModuleInventory.new(result.dir) }
  let(:git_mods)  { described_class::CATALOGUE.reject(&:forge) }

  def resolver
    Pupgrade::ModuleResolver.new(operatingsystems: { 'RedHat' => %w[8 9], 'Ubuntu' => ['22.04'] },
                                 requirements: { 'puppet' => '>= 8.0.0 < 9.0.0' })
  end

  it 'deploys every catalogue module at its declared version' do
    entries = inventory.entries
    expect(inventory.warnings).to eq([])
    expect(entries.map(&:path)).to include(*described_class::CATALOGUE.map { |m| "modules/#{m.short}" })
    declared = entries.select(&:declared)
    expect(declared.size).to eq(described_class::CATALOGUE.size)
    expect(declared.map(&:deployed).uniq).to eq([:match])
    expect(declared.to_h { |e| [e.metadata.name, e.metadata.version] })
      .to eq(described_class::CATALOGUE.to_h { |m| [m.name, m.deployed] })
  end

  it 'gives each remote one tag per release, and unreleased work past the last tag where declared' do
    git_mods.each do |m|
      tags = `git -C #{result.remotes_dir}/#{m.name}.git tag`.split
      expect(tags).to match_array(m.releases.map { |r| m.tag(r.version) }), m.name
      last  = m.tag(m.releases.last.version)
      ahead = `git -C #{result.remotes_dir}/#{m.name}.git rev-list --count #{last}..#{m.branch}`.strip.to_i
      expect(ahead).to eq(m.unreleased ? 1 : 0), m.name
    end
  end

  it 'has every conflict kind in its current state' do
    current = resolver.resolve(inventory.entries)
    kinds   = current.conflicts.map(&:kind).uniq
    expect(kinds).to match_array(Pupgrade::ModuleResolver::KINDS)
    expect(current.conflicts.map { |c| [c.kind, c.module, c.subject] }).to include(
      ['missing-dependency', 'puppet-kafka', 'puppet/zookeeper'],
      ['dependency-version', 'puppetlabs-tomcat', 'puppetlabs/stdlib'],
      %w[puppet-version saz-timezone puppet],
      ['operatingsystem', 'puppetlabs-apt', 'RedHat 8'],
    )
  end

  it 'proposes a stdlib major bump that introduces many conflicts and resolves a few' do
    current  = resolver.resolve(inventory.entries)
    proposal = Pupgrade::ModuleProposal.new(inventory, result.proposed, remote: ->(url) { Pupgrade::GitRemote.new(url, cache_dir: nil) })
    proposed = resolver.resolve(proposal.entries)
    expect(proposal.warnings).to all(include('Forge module'))
    key = ->(c) { [c.kind, c.module, c.subject] }
    introduced = proposed.conflicts.map(&key) - current.conflicts.map(&key)
    resolved   = current.conflicts.map(&key) - proposed.conflicts.map(&key)
    expect(introduced.size).to be > 15
    expect(introduced).to include(['dependency-version', 'puppet-nginx', 'puppetlabs/stdlib'])
    expect(resolved).to include(['dependency-version', 'puppetlabs-tomcat', 'puppetlabs/stdlib'])
  end

  it 'runs under check with its own config' do
    out      = StringIO.new
    original = $stdout
    $stdout  = out
    status   = nil
    begin
      Pupgrade::CLI::Check.new.run(['-c', result.config, '-d', result.dir, '--summary'])
    rescue SystemExit => e
      status = e.status
    ensure
      $stdout = original
    end
    expect(status).to eq(1)
    expect(out.string.lines.first).to start_with('module ')
  end

  it 'builds the same commits twice, and refuses a directory with contents' do
    Dir.mktmpdir do |other|
      again = described_class.build(File.join(other, 'repo'))
      sha = ->(r, m) { `git -C #{r.dir}/modules/#{m.short} rev-parse HEAD`.strip }
      git_mods.each { |m| expect(sha.call(again, m)).to eq(sha.call(result, m)), m.name }
      expect { described_class.build(File.join(other, 'repo')) }.to raise_error(ArgumentError, /not empty/)
    end
  end
end
