require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'stringio'
require 'json'
require 'yaml'

require 'support/fixture_repo'
require 'pupgrade/cli/solve'
require 'driftless/inputs/puppetfile'

# `solve` on the fixture control repo, whose clones carry the tags of every
# release.
RSpec.describe Pupgrade::CLI::Solve do
  before(:all) do # rubocop:disable RSpec/BeforeAfterAll
    @tmp     = Dir.mktmpdir
    @fixture = Pupgrade::FixtureRepo.build(File.join(@tmp, 'repo'))
  end

  after(:all) { FileUtils.rm_rf(@tmp) } # rubocop:disable RSpec/BeforeAfterAll

  let(:fixture) { @fixture }

  # [exit status, stdout]
  def run(argv, config: ['-c', fixture.config])
    captured = StringIO.new
    original = $stdout
    $stdout  = captured
    status   = nil
    begin
      described_class.new.run(config + ['-d', fixture.dir] + argv)
    rescue SystemExit => e
      status = e.status
    ensure
      $stdout = original
    end
    [status, captured.string]
  end

  def rows(output)
    output.lines.map(&:rstrip).reject { |l| l.start_with?('--') }.map { |l| l.split('|', -1).map(&:strip) }.drop(1).to_h { |r| [r[0], r[1..]] }
  end

  around(:each) do |ex|
    original = Pupgrade.instance_variable_get(:@config)
    ex.run
  ensure
    Pupgrade.instance_variable_set(:@config, original)
  end

  before(:each) { silence_logger }

  it 'moves every module as far as its constraints allow, holds what cannot follow, and writes the overlay' do
    overlay = File.join(@tmp, 'Puppetfile.solved')
    status, out = run(['-o', overlay])
    expect(status).to eq(0)
    table = rows(out)
    expect(table['puppetlabs-stdlib']).to eq(['tag v8.6.0', 'v9.6.0', '3', 'newest'])
    expect(table['puppetlabs-apache']).to eq(['tag v10.1.1', 'v12.0.0', '2', 'newest'])
    expect(table['puppetlabs-puppetdb']).to eq(['tag v7.13.0', 'v8.1.0', '2', 'newest'])
    expect(table['saz-timezone']).to eq(['tag 6.1.0', '7.0.0', '1', 'newest'])
    expect(table['acme-baseline']).to match(['branch main', '(current)', '0', a_string_starting_with('unresolved: needs puppetlabs/stdlib >= 4.13.1 < 9.0.0, but stdlib moves to 9.6.0')])
    expect(table['puppet-kafka']).to eq(['tag v8.1.0', 'v9.0.0', '1', 'unresolved: needs puppet/zookeeper >= 1.0.0 < 2.0.0, but zookeeper is not on the modulepath'])
    expect(table['puppetlabs-translate']).to match(['2.2.0 (forge)', '(current)', '0', a_string_starting_with('unresolved (Forge module): requires puppet >= 4.10.0 < 8.0.0')])
    expect(table['puppetlabs-apt'].last).to eq('unresolved: supports Ubuntu, Debian, but missing RedHat')
    expect(table).not_to have_key('puppetlabs-facts')

    proposed = Driftless::Inputs::Puppetfile.load_file(overlay)
    expect(proposed.error).to be_nil
    expect(proposed.modules.size).to eq(31)
    stdlib = proposed.modules.find { |m| m.name == 'puppetlabs-stdlib' }
    expect([stdlib.git, stdlib.ref, stdlib.ref_type, stdlib.path]).to eq([File.join(fixture.remotes_dir, 'puppetlabs-stdlib.git'), 'v9.6.0', 'tag', 'modules/stdlib'])
    baseline = proposed.modules.find { |m| m.name == 'acme-baseline' }
    expect(baseline).to be_nil
  end

  it 'moves the least it can from the current versions when driven by a bump, and shows all with --all' do
    _, out = run(['--order', 'oldest', '--bump', 'puppetlabs-stdlib', '--all'])
    table = rows(out)
    expect(table['puppetlabs-stdlib']).to eq(['tag v8.6.0', 'v9.6.0', '3', 'bumped'])
    expect(table['puppetlabs-concat']).to eq(['tag v7.3.0', 'v9.0.0', '2', 'first fit'])
    expect(table['puppetlabs-apache']).to eq(['tag v10.1.1', 'v11.0.0', '2', 'first fit'])
    expect(table['puppetlabs-firewall']).to eq(['tag v5.0.0', 'v7.0.0', '3', 'first fit'])
    expect(table['puppetlabs-facts']).to eq(['1.4.0 (forge)', '(current)', '0', 'Forge module'])

    _, out = run(['--order', 'oldest', '--bump', 'puppetlabs-stdlib=v9.0.0', '--hold', 'puppetlabs-concat'])
    table = rows(out)
    expect(table['puppetlabs-stdlib']).to eq(['tag v8.6.0', 'v9.0.0', '3', 'bumped'])
    expect(table['puppetlabs-concat'][0..2]).to eq(['tag v7.3.0', '(current)', '2'])
    expect(table['puppetlabs-concat'].last).to start_with('held at current: needs puppetlabs/stdlib >= 4.13.1 < 9.0.0, but stdlib moves to 9.0.0')
    # with nothing required of the operating systems or Puppet, the current
    # versions fit and only what cannot fit is listed
    _, out = run(['--order', 'oldest'], config: ['--no-config'])
    table = rows(out)
    expect(table.keys).not_to include('puppetlabs-stdlib', 'puppetlabs-apache')
    expect(table['puppetlabs-tomcat']).to eq(['tag v7.0.0', '(current)', '1',
                                              'held: v7.1.0 needs puppetlabs/stdlib >= 9.0.0 < 10.0.0, but stdlib is 8.6.0; ' \
                                              'needs puppetlabs/concat >= 9.0.0 < 10.0.0, but concat is 7.3.0 (so does v7.0.0)'])
  end

  it 'takes bumps and holds by any spelling, warns about the ones that name nothing, and explains candidates' do
    allow(Driftless).to receive(:logger).and_call_original
    out = nil
    log = capture_log(level: :warning) do
      _, out = run(['--bump', 'voxpupuli-stdlib=v9.4.0', '--bump', 'nope', '--hold', 'orangutan', '--bump', 'puppetlabs-concat=v99',
                    '--explain', 'stdlib,concat'])
    end
    expect(log.lines.map(&:chomp).grep(/\Awarning:/)).to contain_exactly(
      'warning: solve: --bump puppetlabs-concat=v99: v99 is not a candidate of modules/concat (candidates: v9.0.0, v9.1.0; try --fetch)',
      'warning: solve: --bump nope matches no module',
      'warning: solve: --hold orangutan matches no module',
    )
    main, explain = out.split("\n\n", 2)
    expect(rows(main)['puppetlabs-stdlib']).to eq(['tag v8.6.0', 'v9.4.0', '3', 'bumped'])
    expect(rows(main)['puppetlabs-concat']).to eq(['tag v7.3.0', 'v9.1.0', '2', 'newest'])
    verdicts = explain.lines.map(&:rstrip).reject { |l| l.start_with?('--') }.map { |l| l.split('|', -1).map(&:strip) }
    expect(verdicts.first).to eq(%w[module candidate verdict violations])
    expect(verdicts.drop(1).map { |r| r.first(3) }).to eq([
      ['puppetlabs-stdlib', 'v8.6.0 (current)', 'breaks 2'],
      ['puppetlabs-stdlib', 'v9.0.0', 'fits'],
      ['puppetlabs-stdlib', 'v9.4.0', 'chosen (bumped)'],
      ['puppetlabs-stdlib', 'v9.6.0', 'fits'],
      ['puppetlabs-concat', 'v7.3.0 (current)', 'breaks 3'],
      ['puppetlabs-concat', 'v9.0.0', 'fits'],
      ['puppetlabs-concat', 'v9.1.0', 'chosen (newest)'],
    ])
    expect(verdicts[1].last).to eq('supports RedHat 7, 8, but missing RedHat 9; supports Ubuntu 18.04, 20.04, but missing Ubuntu 22.04')
  end

  it 'prunes dependency edges to modules the evidence shows unused, and writes them as exclusions' do
    evidence = File.join(@tmp, 'catalogs')
    FileUtils.mkdir_p(File.join(evidence, 'web01.example.com'))
    File.write(File.join(evidence, 'web01.example.com/probes.json'), JSON.generate(
      'document'  => 'probes', 'schema_version' => 1,
      'classes'   => { 'redis' => { 'module' => 'redis' }, 'stdlib' => { 'module' => 'stdlib' }, 'yumrepo_core' => { 'module' => 'yumrepo_core' } },
      'functions' => { 'stdlib::shout' => { 'module' => 'stdlib', 'sites' => ['modules/yumrepo_core/manifests/init.pp:3'] } },
    ))
    status, out = run(['--hold', 'puppetlabs-apt'])
    expect(status).to eq(0)
    expect(rows(out)['puppet-redis']).to eq(['tag v8.8.0', 'v10.0.0', '2', 'unresolved: needs puppetlabs/apt >= 9.0.0 < 10.0.0, but apt is 8.5.0'])
    expect(rows(out)['puppetlabs-apt']).to match(['tag v8.5.0', '(current)', '2', a_string_starting_with('held at current: ')])

    exclusions = File.join(@tmp, 'exclusions.yaml')
    allow(Driftless).to receive(:logger).and_call_original
    log = capture_log do
      _, out = run(['--hold', 'puppetlabs-apt', '--catalogs-dir', evidence, '--prune-unused', '--exclusions', exclusions])
    end
    expect(rows(out)['puppet-redis']).to eq(['tag v8.8.0', 'v10.0.0', '2', 'newest'])
    expect(YAML.safe_load(File.read(exclusions))).to eq('modules' => { 'exclude_dependencies' => ['puppetlabs-postgresql:puppetlabs/apt', 'puppet-redis:puppetlabs/apt'] })
    expect(log).to include('solve: puppetlabs-yumrepo_core -> stdlib: used, but not a declared dependency')
    expect(log).to include('evidence from 1 node(s)')

    _, out = run(['--ignore', 'apt,zookeeper'])
    expect(rows(out)).not_to have_key('puppetlabs-apt')
    expect(rows(out)['puppet-redis'].last).to start_with('unresolved: needs puppetlabs/apt >= 9.0.0 < 10.0.0, but apt is not on the modulepath')
    expect(run(['--prune-unused']).first).to eq(2)
    expect(run(['--catalogs-dir', File.join(@tmp, 'nope')]).first).to eq(3)
    expect(run(['--order', 'sideways']).first).to eq(2)
  end
end
