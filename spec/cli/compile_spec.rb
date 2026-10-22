require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'stringio'
require 'json'

require 'support/fixture_repo'
require 'pupgrade/cli/compile'

# `compile` against the fixture control repo and its two factsets.
RSpec.describe Pupgrade::CLI::Compile do
  before(:all) do # rubocop:disable RSpec/BeforeAfterAll
    @tmp     = Dir.mktmpdir
    @fixture = Pupgrade::FixtureRepo.build(File.join(@tmp, 'repo'))
  end

  after(:all) { FileUtils.rm_rf(@tmp) } # rubocop:disable RSpec/BeforeAfterAll

  let(:fixture) { @fixture }
  let(:out)     { File.join(@tmp, "out-#{rand(1_000_000)}") }

  # [exit status, stdout]
  def run(argv)
    captured = StringIO.new
    original = $stdout
    $stdout  = captured
    status   = nil
    begin
      described_class.new.run(['--no-config', '-d', fixture.dir, '--factsets', 'factsets', '-o', out] + argv)
    rescue SystemExit => e
      status = e.status
    ensure
      $stdout = original
    end
    [status, captured.string]
  end

  def cells(output)
    output.lines.map(&:rstrip).reject { |l| l.start_with?('--') }.map { |l| l.split('|', -1).map(&:strip) }
  end

  def read(certname, name)
    JSON.parse(File.read(File.join(out, certname, name)))
  end

  around(:each) do |ex|
    original = Pupgrade.instance_variable_get(:@config)
    ex.run
  ensure
    Pupgrade.instance_variable_set(:@config, original)
  end

  before(:each) { silence_logger }

  it 'compiles every factset with the mocks, in both layouts, and writes catalog and probes per node' do
    status, text = run(['--mocks', 'pupgrade/mocks.yaml'])
    expect(status).to eq(0)
    expect(cells(text)).to eq([
      %w[certname resources classes warnings leaks status],
      %w[db01.example.com 12 7 2 1 ok],
      %w[web01.example.com 12 7 2 1 ok],
    ])
    expect(Dir.children(out).sort).to eq(%w[db01.example.com web01.example.com])
    expect(Dir.children(File.join(out, 'web01.example.com')).sort).to eq(%w[catalog.json probes.json])

    catalog = read('web01.example.com', 'catalog.json')
    expect(catalog.keys).to eq(%w[catalog_format classes code_id edges environment name resources tags version])
    expect(catalog['name']).to eq('web01.example.com')
    expect(catalog['version']).to eq(0)
    expect(catalog['resources'].map { |r| "#{r['type']}[#{r['title']}]" }).to eq(
      catalog['resources'].map { |r| "#{r['type']}[#{r['title']}]" }.sort_by { |s| s.split('[', 2) },
    )
    fragment = catalog['resources'].find { |r| r['type'] == 'Notify' }
    expect(fragment['parameters']['message']).to eq('RedHat on web01.example.com: RedHat RedHat HI HI hi mocked.example.com time.example.com default')
    firewall = catalog['resources'].find { |r| r['type'] == 'Firewall' }
    expect(firewall['parameters']).to include('provider' => 'iptables', 'action' => 'accept')

    probes = read('web01.example.com', 'probes.json')
    expect(probes).to include('document' => 'probes', 'schema_version' => 1, 'certname' => 'web01.example.com', 'status' => 'ok', 'environment' => 'production')
    expect(probes['functions'].slice('stdlib::shout', 'legacy_shout', 'stdlib::whisper', 'stdlib::run_hostname').transform_values { |f| f['module'] })
      .to eq('stdlib::shout' => 'stdlib', 'legacy_shout' => 'stdlib', 'stdlib::whisper' => 'stdlib', 'stdlib::run_hostname' => 'stdlib')
    expect(probes['functions']['stdlib::shout']).to include('calls' => 1, 'sites' => ['site-modules/profile/manifests/base.pp:10'])
    expect(probes['functions']['include']['module']).to be_nil
    expect(probes['facts']).to eq('kernel' => 1, 'networking.fqdn' => 1, 'os' => 1, 'os.family' => 2, 'os.release.major' => 1)
    expect(probes['legacy_facts']).to eq('osfamily' => 1)
    expect(probes['type_aliases'].keys).to eq(['Stdlib::Port'])
    expect(probes['type_aliases']['Stdlib::Port']).to include('module' => 'stdlib', 'sites' => ['site-modules/profile/manifests/base.pp:4'])
    expect(probes['type_aliases']['Stdlib::Port']['uses']).to be_positive
    expect(read('db01.example.com', 'probes.json')['type_aliases']['Stdlib::Port']).to include('module' => 'stdlib')
    expect(probes['lookups']).to include(
      'profile::base::ntp_servers' => { 'found' => true, 'automatic' => 1, 'explicit' => 1 },
      'profile::base::banner'      => { 'found' => true, 'automatic' => 1, 'explicit' => 0 },
      'profile::base::absent'      => { 'found' => false, 'automatic' => 0, 'explicit' => 1 },
      'ntp::version'               => { 'found' => false, 'automatic' => 1, 'explicit' => 0 },
    )
    expect(probes['deprecations']).to eq([{ 'message' => 'legacy_shout is deprecated; use stdlib::shout' }])
    expect(probes['warnings'].map { |w| w['level'] }).to eq(%w[warning])
    expect(probes['leaks']).to eq([{ 'kind' => 'execute', 'command' => 'hostname -f', 'action' => 'mocked',
                                     'location' => 'site-modules/profile/manifests/base.pp:13 via modules/stdlib/lib/puppet/functions/stdlib/run_hostname.rb:4' }])
    expect(probes['classes']).to include('apache' => { 'module' => 'apache' }, 'profile::base' => { 'module' => 'profile' })
    expect(probes['defined_types']).to eq('concat::fragment' => { 'module' => 'concat', 'resources' => 1 })
    expect(probes['types']).to eq('firewall' => { 'module' => 'firewall', 'resources' => 1 }, 'notify' => { 'module' => nil, 'resources' => 1 })
    expect(probes['providers_named']).to eq('firewall/iptables' => { 'module' => 'firewall', 'resources' => 1 })

    db = read('db01.example.com', 'probes.json')
    expect(db['factset']).to end_with('factsets/db01.example.com.json')
    expect(read('db01.example.com', 'catalog.json')['resources'].find { |r| r['type'] == 'Notify' }['parameters']['message']).to start_with('Debian on db01.example.com')
  end

  it 'removes node directories no factset names after a full run, not after a filtered one or with --keep-stale' do
    gone = File.join(out, 'gone.example.com')
    FileUtils.mkdir_p(gone)
    File.write(File.join(gone, 'probes.json'), "{}\n")
    FileUtils.mkdir_p(File.join(out, 'notes'))
    run(['--mocks', 'pupgrade/mocks.yaml', '--certname', 'web*'])
    expect(Dir.children(out).sort).to eq(%w[gone.example.com notes web01.example.com])
    run(['--mocks', 'pupgrade/mocks.yaml', '--keep-stale'])
    expect(Dir.children(out).sort).to eq(%w[db01.example.com gone.example.com notes web01.example.com])
    run(['--mocks', 'pupgrade/mocks.yaml'])
    expect(Dir.children(out).sort).to eq(%w[db01.example.com notes web01.example.com])
  end

  it 'stops a compile at a command the mocks do not answer, records it, and exits 1' do
    status, text = run([])
    expect(status).to eq(1)
    expect(cells(text).drop(1).map(&:last)).to eq(%w[failed failed])
    expect(Dir.children(File.join(out, 'web01.example.com')).sort).to eq(%w[error.txt probes.json])
    expect(File.read(File.join(out, 'web01.example.com/error.txt'))).to include('execute: "hostname -f" is not answered by the mocks')
    probes = read('web01.example.com', 'probes.json')
    expect(probes['status']).to eq('failed')
    expect(probes['leaks'].first).to include('action' => 'raised')
    expect(probes).not_to have_key('classes')
  end

  it 'compiles code in place of the manifest, with top-scope variables and a certname filter' do
    status, text = run(['--mocks', 'pupgrade/mocks.yaml', '--certname', 'web*', '--code', 'notify { "hello ${role}": }', '--var', 'role=db'])
    expect(status).to eq(0)
    expect(cells(text).drop(1).map(&:first)).to eq(['web01.example.com'])
    catalog = read('web01.example.com', 'catalog.json')
    expect(catalog['resources'].map { |r| r['title'] }).to include('hello db')
    expect(catalog['classes']).to eq(%w[settings])
  end

  it 'takes the manifest, the prepended file, the mocks, and the factsets from the config file' do
    File.write(File.join(fixture.dir, 'before.pp'), "notify { 'from before': }\n")
    File.write(File.join(fixture.dir, 'alt.pp'), "notify { 'from alt': }\n")
    cfg = File.join(@tmp, 'pupgrade.yaml')
    File.write(cfg, <<~YAML)
      compile:
        factsets: [factsets]
        manifest: alt.pp
        prepend_file: before.pp
        mocks: pupgrade/mocks.yaml
        catalogs_dir: #{out}
        vars:
          role: db
    YAML
    captured = StringIO.new
    original = $stdout
    $stdout  = captured
    status   = nil
    begin
      described_class.new.run(['-c', cfg, '-d', fixture.dir, '--certname', 'web01*'])
    rescue SystemExit => e
      status = e.status
    ensure
      $stdout = original
    end
    expect(status).to eq(0)
    titles = read('web01.example.com', 'catalog.json')['resources'].select { |r| r['type'] == 'Notify' }.map { |r| r['title'] }
    expect(titles).to eq(['from alt', 'from before'])
  end

  it 'refuses missing factsets, a bad mock file, and an unknown leak policy' do
    expect(run(['--factsets', 'nope']).first).to eq(3)
    expect(run(['--mocks', 'nope.yaml']).first).to eq(3)
    expect(run(['--on-leak', 'ignore']).first).to eq(2)
    expect(run(['--certname', 'nothing']).first).to eq(3)
  end
end
