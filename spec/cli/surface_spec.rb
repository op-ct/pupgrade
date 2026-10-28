require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'stringio'
require 'json'

require 'support/fixture_repo'
require 'pupgrade/cli/surface'

RSpec.describe Pupgrade::CLI::Surface do
  before(:all) do # rubocop:disable RSpec/BeforeAfterAll
    @tmp     = Dir.mktmpdir
    @fixture = Pupgrade::FixtureRepo.build(File.join(@tmp, 'repo'))
  end

  after(:all) { FileUtils.rm_rf(@tmp) } # rubocop:disable RSpec/BeforeAfterAll

  let(:fixture) { @fixture }
  let(:cache)   { File.join(fixture.dir, 'pupgrade/cache/api_surfaces') }

  # [exit status, stdout]
  def run(command, argv)
    captured = StringIO.new
    original = $stdout
    $stdout  = captured
    status   = nil
    begin
      command.new.run(['--no-config', '-d', fixture.dir] + argv)
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

  before(:each) { silence_logger }

  it 'reads modules by name or directory into the cache, by version and ref, and reuses what it holds' do
    concat = fixture.surface_file('concat', '7.3.0')
    expect(run(described_class, ['concat'])).to eq([0, ''])
    expect(JSON.parse(File.read(File.join(cache, concat)))['defined_types'].keys).to eq(['concat::fragment'])

    stdlib = fixture.surface_file('stdlib', '9.6.0', 'v9.6.0')
    allow(Driftless).to receive(:logger).and_call_original
    log = capture_log { expect(run(described_class, ['-vv', 'stdlib:v9.6.0', File.join(fixture.dir, 'modules/concat')])).to eq([0, '']) }
    expect(log).to include("debug: surface: stdlib:v9.6.0: wrote #{cache}/#{stdlib}", "cached at #{cache}/#{concat}")
    doc = JSON.parse(File.read(File.join(cache, stdlib)))
    expect(doc['module']['version']).to eq('9.6.0')
    expect(doc['source']).to include('ref' => 'v9.6.0', 'sha' => fixture.sha('stdlib', 'v9.6.0'), 'tags' => ['v9.6.0'])

    # the commit is what is matched, whatever the file is called
    File.rename(File.join(cache, stdlib), File.join(cache, "stdlib-9.6.0--renamed__#{fixture.sha('stdlib', 'v9.6.0')[0, 10]}.json"))
    log = capture_log { run(described_class, ['stdlib:v9.6.0']) }
    expect(log).to include('(cached)')

    # a dirty tree is written with its mark and never served
    File.write(File.join(fixture.dir, 'modules/concat/manifests/extra.pp'), "class concat::extra {}\n")
    log = capture_log { run(described_class, ['-vv', 'concat']) }
    expect(log).to include("wrote #{cache}/#{concat.sub('.json', '-dirty.json')}")
    expect(JSON.parse(File.read(File.join(cache, concat.sub('.json', '-dirty.json'))))['source']).to include('dirty' => true)
    log = capture_log { run(described_class, ['concat']) }
    expect(log).not_to include('(cached)')
    File.delete(File.join(fixture.dir, 'modules/concat/manifests/extra.pp'))
    # a spec/ directory removed, as r10k deploys modules, is not dirt
    concat_dir = File.join(fixture.dir, 'modules/concat')
    FileUtils.mkdir_p(File.join(concat_dir, 'spec'))
    File.write(File.join(concat_dir, 'spec/concat_spec.rb'), "# a spec\n")
    git = ->(*args) { system({ 'GIT_CONFIG_GLOBAL' => '/dev/null' }, 'git', '-C', concat_dir, '-c', 'user.name=x', '-c', 'user.email=x@example.com', '-c', 'commit.gpgsign=false', *args, exception: true) }
    git.call('add', 'spec')
    git.call('commit', '-q', '-m', 'spec')
    FileUtils.rm_rf(File.join(concat_dir, 'spec'))
    concat = fixture.surface_file('concat', '7.3.0', 'HEAD').sub('--HEAD', '')
    log = capture_log { run(described_class, ['-vv', 'concat']) }
    expect(log).to include("wrote #{cache}/#{concat}")
    expect(concat).not_to include('dirty')
    expect(capture_log { run(described_class, ['concat']) }).to include('(cached)')

    stamp = File.mtime(File.join(cache, concat))
    log = capture_log { run(described_class, ['concat']) }
    expect(log).to include('(cached)')
    expect(File.mtime(File.join(cache, concat))).to eq(stamp)
    log = capture_log { run(described_class, ['concat', '--refresh']) }
    expect(log).not_to include('(cached)')

    # a document of an older schema is extracted again as it is read
    stale = JSON.parse(File.read(File.join(cache, concat)))
    File.write(File.join(cache, concat), JSON.generate(stale.merge('schema_version' => 1)))
    log = capture_log { run(described_class, ['-v', 'concat']) }
    expect(log).to include('extracting again; ')
    expect(JSON.parse(File.read(File.join(cache, concat)))['schema_version']).to eq(Pupgrade::Surface::Extract::SCHEMA_VERSION)
    File.write(File.join(cache, concat), JSON.generate(stale.merge('schema_version' => 99)))
    expect(run(described_class, ['concat']).first).to eq(3)
    File.write(File.join(cache, concat), JSON.generate(stale))
    expect(run(described_class, ['concat', '--refresh=schema']).first).to eq(0)
    expect(run(described_class, ['concat', '--refresh=sideways']).first).to eq(2)
  end

  it 'reads each module at its future tags with --future-tags, on the branch it follows' do
    FileUtils.rm_rf(cache)
    expect(run(described_class, ['-F', 'stdlib']).first).to eq(0)
    expect(Dir.children(cache).sort).to eq([fixture.surface_file('stdlib', '8.6.0'), fixture.surface_file('stdlib', '9.0.0', 'v9.0.0'),
                                            fixture.surface_file('stdlib', '9.4.0', 'v9.4.0'), fixture.surface_file('stdlib', '9.6.0', 'v9.6.0')].sort)

    # a branch ending at the deployed tag has no tags past it
    FileUtils.rm_rf(cache)
    system('git', '-C', File.join(fixture.dir, 'modules/stdlib'), 'branch', '-q', 'old', 'v8.6.0', exception: true)
    expect(run(described_class, ['--future-tags', '--branch', 'nope,old', 'stdlib']).first).to eq(0)
    expect(Dir.children(cache)).to eq([fixture.surface_file('stdlib', '8.6.0')])
    expect(run(described_class, ['-F', 'facts']).first).to eq(0)
    expect(run(described_class, ['--branch', 'old', 'stdlib']).first).to eq(2)
  end

  it 'reads every module with --all, one to a file or stdout, and a remote at a ref' do
    expect(run(described_class, ['--all'])).to eq([0, ''])
    # a clone is keyed on its commit; a Forge install on its version alone
    expect(Dir.children(cache)).to include(fixture.surface_file('stdlib', '8.6.0'), 'translate-2.2.0.json')

    path = File.join(@tmp, 'firewall.json')
    expect(run(described_class, ['firewall', '-o', path])).to eq([0, "#{path}\n"])
    expect(JSON.parse(File.read(path))['types'].keys).to eq(%w[conntrack firewall])
    _, out = run(described_class, ['firewall', '-o', '-'])
    expect(JSON.parse(out)['providers'].keys).to eq(%w[conntrack/iptables firewall/iptables firewall/ipv6])

    expect(run(described_class, ['--git', File.join(fixture.remotes_dir, 'puppetlabs-stdlib.git'), '--ref', 'v9.0.0'])).to eq([0, ''])
    expect(Dir.children(cache)).to include(fixture.surface_file('stdlib', '9.0.0', 'v9.0.0'))
    # read back from the cache the next time
    allow(Driftless).to receive(:logger).and_call_original
    log = capture_log { run(described_class, ['--git', File.join(fixture.remotes_dir, 'puppetlabs-stdlib.git'), '--ref', 'v9.0.0']) }
    expect(log).to include('(cached)')

    expect(run(described_class, []).first).to eq(2)
    expect(run(described_class, ['--git', 'x']).first).to eq(2)
    expect(run(described_class, ['concat', 'firewall', '-o', path]).first).to eq(2)
    expect(run(described_class, ['nope']).first).to eq(3)
    expect(run(described_class, ['stdlib:v0']).first).to eq(3)
  end
end
