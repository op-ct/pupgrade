require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'stringio'
require 'json'

require 'support/fixture_repo'
require 'pupgrade/cli/impact'
require 'pupgrade/cli/catalog'

# `impact` on the fixture: a proposal moving stdlib, firewall, and apache,
# with evidence from a compile of both factsets.
RSpec.describe Pupgrade::CLI::Impact do
  before(:all) do # rubocop:disable RSpec/BeforeAfterAll
    @tmp      = Dir.mktmpdir
    @fixture  = Pupgrade::FixtureRepo.build(File.join(@tmp, 'repo'))
    @catalogs = File.join(@tmp, 'catalogs')
    @proposed = File.join(@tmp, 'Puppetfile.proposed')
    File.write(@proposed, %w[stdlib=v9.6.0 firewall=v8.0.0 apache=v12.0.0].map { |pair|
      short, tag = pair.split('=')
      "mod 'puppetlabs-#{short}',\n  git: '#{File.join(@fixture.remotes_dir, "puppetlabs-#{short}.git")}',\n  tag: '#{tag}'\n"
    }.join)
    silently { Pupgrade::CLI::Catalog::Compile.new.run(['--no-config', '-d', @fixture.dir, '--factsets', 'factsets', '-o', @catalogs, '--mocks', 'pupgrade/compiler-mocks.yaml']) }
  end

  after(:all) { FileUtils.rm_rf(@tmp) } # rubocop:disable RSpec/BeforeAfterAll

  let(:fixture)  { @fixture }
  let(:catalogs) { @catalogs }
  let(:proposed) { @proposed }

  # [exit status, stdout]
  def run(argv)
    status = nil
    out = silently do
      described_class.new.run(['--no-config', '-d', fixture.dir] + argv + [proposed])
    rescue SystemExit => e
      status = e.status
    end
    [status, out]
  end

  def silently
    captured = StringIO.new
    original = $stdout
    $stdout  = captured
    yield
    captured.string
  rescue SystemExit
    captured.string
  ensure
    $stdout = original
  end

  def cells(output)
    output.lines.map(&:rstrip).reject { |l| l.start_with?('--') }.map { |l| l.split('|', -1).map(&:strip) }
  end

  before(:each) { silence_logger }

  it 'maps each surface change to the nodes, resources, and call sites the evidence shows' do
    status, out = run(['--compile-cache', catalogs])
    expect(status).to eq(1)
    rows = cells(out).drop(1).map { |r| r.first(4) }
    expect(rows).to eq([
      # a removed param whose key nothing reads any more leaves dead data; one some lookup() still reads lives on as plain Hiera data
      ['puppetlabs-apache', 'class-param-removed', 'apache::dead_opt', 'nodes: db01.example.com, web01.example.com; hiera: data/common.yaml:6'],
      ['puppetlabs-apache', 'class-param-hiera-only', 'apache::legacy_opt',
       'nodes: db01.example.com, web01.example.com; hiera: data/common.yaml:5; lookups: site-modules/profile/manifests/base.pp:16'],
      ['puppetlabs-apache', 'class-param-default-changed', 'apache::version', 'nodes: db01.example.com, web01.example.com'],
      ['puppetlabs-firewall', 'type-attribute-changed', 'firewall action',
       'resources: firewall[100 allow ntp 123] on db01.example.com, firewall[100 allow ntp 123] on web01.example.com'],
      ['puppetlabs-stdlib', 'function-removed', 'legacy_shout', 'sites: site-modules/profile/manifests/base.pp:11'],
      ['puppetlabs-stdlib', 'function-changed', 'stdlib::shout', 'sites: site-modules/profile/manifests/base.pp:10'],
      ['puppetlabs-stdlib', 'type-alias-changed', 'Stdlib::Port', 'nodes: db01.example.com, web01.example.com'],
    ])
    expect(cells(out).find { |r| r[2] == 'stdlib::shout' }.last).to eq('changed signatures: (text) -> (text, times)')
  end

  it 'summarises per module with the commits crossed, and prints the history on request' do
    _, out = run(['--compile-cache', catalogs, '--summary'])
    expect(cells(out)).to eq([
      %w[module from to commits findings used],
      ['puppetlabs-apache', 'tag v10.1.1', 'tag v12.0.0', '2', '3', '3'],
      ['puppetlabs-firewall', 'tag v5.0.0', 'tag v8.0.0', '3', '1', '1'],
      ['puppetlabs-stdlib', 'tag v8.6.0', 'tag v9.6.0', '3', '3', '3'],
    ])
    _, out = run(['--compile-cache', catalogs, '--modules', 'puppetlabs-stdlib', '--gitlog', '--changelog'])
    expect(out).to include('puppetlabs-stdlib: tag v8.6.0 -> tag v9.6.0, 3 commit(s)', 'Release 9.0.0', '## 9.6.0')
    expect(out).not_to include('puppetlabs-apache:')
  end

  it 'reports every change with its use unknown without evidence, and filters by kind' do
    status, out = run(['--no-catalogs'])
    expect(status).to eq(1) # the Hiera references are known without catalogs
    expect(cells(out).drop(1).map { |r| [r[1], r[3]] }).to all(match([a_string_matching(/\A(class|type|function)-/), a_string_matching(/\A(use unknown|hiera: )/)]))
    expect(cells(out).drop(1).map { |r| r[1] }).to include('type-alias-changed')
    _, out = run(['--compile-cache', catalogs, '--impacts', 'function-removed'])
    expect(cells(out).drop(1).map { |r| r[2] }).to eq(['legacy_shout'])
    expect(run(['--impacts', 'bogus']).first).to eq(2)
    expect(run(['--compile-cache', File.join(@tmp, 'nope')]).first).to eq(3)
  end

  it 'keeps the surfaces it reads in the cache, reuses them, and takes --propose as well as the positional' do
    cache = File.join(fixture.dir, 'pupgrade/cache/api_surfaces')
    newer = fixture.surface_file('stdlib', '9.6.0', 'v9.6.0')
    expect(Dir.children(cache)).to include(fixture.surface_file('stdlib', '8.6.0'), newer, fixture.surface_file('apache', '10.1.1'))
    stamp = File.mtime(File.join(cache, newer))
    allow(Driftless).to receive(:logger).and_call_original
    log = capture_log do
      status = nil
      silently do
        described_class.new.run(['--no-config', '-vv', '-d', fixture.dir, '--no-catalogs', '--propose', proposed])
      rescue SystemExit => e
        status = e.status
      end
      expect(status).to eq(1) # the two apache keys have Hiera uses
    end
    expect(log).to include("debug: surface: #{File.join(fixture.dir, 'modules/stdlib')}:v9.6.0: cached at")
    expect(log).to include('info: impact: puppetlabs-stdlib: surfaces at v8.6.0 and v9.6.0')
    expect(File.mtime(File.join(cache, newer))).to eq(stamp)
    expect(run(['extra', 'args']).first).to eq(2)
  end
end
