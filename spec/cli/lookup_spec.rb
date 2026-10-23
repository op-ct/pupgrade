require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'stringio'
require 'yaml'

require 'support/fixture_repo'
require 'pupgrade/cli/lookup'

RSpec.describe Pupgrade::CLI::Lookup do
  before(:all) do # rubocop:disable RSpec/BeforeAfterAll
    @tmp     = Dir.mktmpdir
    @fixture = Pupgrade::FixtureRepo.build(File.join(@tmp, 'repo'))
  end

  after(:all) { FileUtils.rm_rf(@tmp) } # rubocop:disable RSpec/BeforeAfterAll

  let(:fixture) { @fixture }

  # [exit status, stdout]
  def run(argv)
    captured = StringIO.new
    original = $stdout
    $stdout  = captured
    status   = nil
    begin
      described_class.new.run(['--no-config', '--no-color', '-d', fixture.dir, '--factsets', 'factsets'] + argv)
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

  around(:each) do |ex|
    original = Pupgrade.instance_variable_get(:@config)
    ex.run
  ensure
    Pupgrade.instance_variable_set(:@config, original)
  end

  before(:each) { silence_logger }

  it 'looks a key up as the node, with the hierarchy interpolating its facts, and explains on request' do
    status, out = run(['--node', 'WEB01.example.com', 'profile::base::banner'])
    expect([status, YAML.safe_load(out)]).to eq([0, 'RedHat on web01.example.com'])
    status, out = run(['--node', 'db01.example.com', '--render-as', 'json', 'profile::base::ntp_servers'])
    expect([status, JSON.parse(out)]).to eq([0, ['time.example.com']])
    status, out = run(['--node', 'web01.example.com', 'profile::base::absent', 'profile::base::banner'])
    expect([status, out]).to eq([0, "--- RedHat on web01.example.com\n"])

    status, out = run(['--node', 'web01.example.com', '--explain', 'profile::base::banner'])
    expect(status).to eq(0)
    expect(out).to include('common.yaml', 'Found key: "profile::base::banner"')
    status, out = run(['--node', 'web01.example.com', '--explain-options'])
    expect(status).to eq(0)
    expect(out).to include('lookup_options')

    status, out = run(['--node', 'web01.example.com', 'profile::base::absent'])
    expect(status).to eq(1)
    expect(run(['--node', 'nope.example.com', 'x']).first).to eq(3)
    expect(run(['profile::base::banner']).first).to eq(2)
    expect(run(['--node', 'web01.example.com']).first).to eq(2)
  end

  it 'compiles the manifests first on request, so a lookup sees what they set, with the guard in force' do
    File.write(File.join(fixture.dir, 'data/common.yaml'), File.read(File.join(fixture.dir, 'data/common.yaml')) + "profile::base::from_site: \"%{site}-%{tenant}\"\n")
    status, out = run(['--node', 'web01.example.com', 'profile::base::from_site'])
    expect([status, YAML.safe_load(out)]).to eq([0, 'example-blue'])
    status, out = run(['--node', 'web01.example.com', '--compile', 'profile::base::from_site'])
    expect([status, YAML.safe_load(out)]).to eq([0, 'example-blue'])
    expect(run(['--node', 'web01.example.com', '--compile', '--mocks', File.join(@tmp, 'none.yaml'), 'profile::base::banner']).first).to eq(3)
  end

  it 'lists the nodes with the facts and variables that place them' do
    status, out = run(['--list'])
    expect(status).to eq(0)
    expect(cells(out)).to eq([
      ['certname', 'os.name', 'os.release.major', '$pkg_manager', '$site', '$tenant'],
      ['db01.example.com', 'Ubuntu', '22.04', '', 'example', 'blue'],
      ['web01.example.com', 'Rocky', '9', 'dnf', 'example', 'blue'],
    ])
    _, out = run(['--list', '--columns', 'networking.fqdn,$site', '--certname', 'web*'])
    expect(cells(out)).to eq([['certname', 'networking.fqdn', '$site', '$pkg_manager', '$tenant'], ['web01.example.com', 'web01.example.com', 'example', 'dnf', 'blue']])
  end
end
