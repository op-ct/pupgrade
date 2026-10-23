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
    status, out = run(described_class, ['concat'])
    expect(status).to eq(0)
    expect(out).to eq("#{cache}/concat-7.3.0.json\n")
    expect(JSON.parse(File.read(File.join(cache, 'concat-7.3.0.json')))['defined_types'].keys).to eq(['concat::fragment'])

    status, out = run(described_class, ['stdlib:v9.6.0', File.join(fixture.dir, 'modules/concat')])
    expect(status).to eq(0)
    expect(out).to eq("#{cache}/stdlib-9.6.0--v9.6.0.json\n\n#{cache}/concat-7.3.0.json\n")
    doc = JSON.parse(File.read(File.join(cache, 'stdlib-9.6.0--v9.6.0.json')))
    expect(doc['module']['version']).to eq('9.6.0')
    expect(doc['source']).to include('ref' => 'v9.6.0')
    expect(doc['source']['sha']).to match(/\A[0-9a-f]{40}\z/)

    stamp = File.mtime(File.join(cache, 'concat-7.3.0.json'))
    allow(Driftless).to receive(:logger).and_call_original
    log = capture_log { run(described_class, ['concat']) }
    expect(log).to include('(cached)')
    expect(File.mtime(File.join(cache, 'concat-7.3.0.json'))).to eq(stamp)
    log = capture_log { run(described_class, ['concat', '--refresh']) }
    expect(log).not_to include('(cached)')
  end

  it 'reads every module with --all, one to a file or stdout, and a remote at a ref' do
    status, out = run(described_class, ['--all'])
    expect(status).to eq(0)
    expect(out.lines.reject { |l| l.strip.empty? }.size).to eq(Pupgrade::FixtureRepo::CATALOGUE.size)
    expect(Dir.children(cache)).to include('stdlib-8.6.0.json', 'translate-2.2.0.json')

    path = File.join(@tmp, 'firewall.json')
    expect(run(described_class, ['firewall', '-o', path])).to eq([0, "#{path}\n"])
    expect(JSON.parse(File.read(path))['types'].keys).to eq(%w[conntrack firewall])
    _, out = run(described_class, ['firewall', '-o', '-'])
    expect(JSON.parse(out)['providers'].keys).to eq(%w[conntrack/iptables firewall/iptables firewall/ipv6])

    status, out = run(described_class, ['--git', File.join(fixture.remotes_dir, 'puppetlabs-stdlib.git'), '--ref', 'v9.0.0'])
    expect(status).to eq(0)
    expect(out).to eq("#{cache}/stdlib-9.0.0--v9.0.0.json\n")

    expect(run(described_class, []).first).to eq(2)
    expect(run(described_class, ['--git', 'x']).first).to eq(2)
    expect(run(described_class, ['concat', 'firewall', '-o', path]).first).to eq(2)
    expect(run(described_class, ['nope']).first).to eq(3)
    expect(run(described_class, ['stdlib:v0']).first).to eq(3)
  end
end
