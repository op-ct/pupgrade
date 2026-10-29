require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'stringio'
require 'yaml'

require 'support/fixture_repo'
require 'pupgrade/cli/module/release'

RSpec.describe Pupgrade::CLI::ModuleCommand::Release do
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
      described_class.new.run(['--no-config', '--no-color', '-d', fixture.dir] + argv)
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

  it 'lists every tagged release oldest first with its date, the deployed one marked' do
    status, out = run(['stdlib'])
    expect(status).to eq(0)
    expect(cells(out)).to eq([
      ['version', 'tag', 'released', ''],
      ['8.6.0', 'v8.6.0', '2024-01-02', '(deployed)'],
      ['9.0.0', 'v9.0.0', '2024-01-03', ''],
      ['9.4.0', 'v9.4.0', '2024-01-04', ''],
      ['9.6.0', 'v9.6.0', '2024-01-05', ''],
    ])
    # a branch-pinned module sits past its last tag: no tag is deployed, the tip is
    expect(cells(run(['baseline']).last).drop(1)).to eq([['0.1.0', 'v0.1.0', '2024-03-28', '']])
    expect(cells(run(['baseline', '--include-heads']).last).last).to eq(['0.1.0', 'main', '2024-03-29', '(deployed)'])
  end

  it 'follows --branch or the branchfile, with the tip as a last row on request' do
    clone = File.join(fixture.dir, 'modules/stdlib')
    system('git', '-C', clone, 'branch', '-q', 'old', 'v9.0.0', exception: true)
    _, out = run(['stdlib', '--branch', 'nope,old'])
    expect(cells(out).drop(1).map(&:first)).to eq(%w[8.6.0 9.0.0])
    _, out = run(['stdlib', '--branch', 'old', '--include-heads'])
    expect(cells(out).drop(1).map { |r| r[1] }).to eq(%w[v8.6.0 v9.0.0 old])

    branchfile = File.join(@tmp, 'recorded.yaml')
    run(['stdlib', '--branch', 'old', '--branchfile', branchfile])
    expect(YAML.safe_load(File.read(branchfile))).to eq('puppetlabs-stdlib' => 'old')
    expect(cells(run(['stdlib', '--branchfile', branchfile]).last).drop(1).map(&:first)).to eq(%w[8.6.0 9.0.0])
    expect(run(['stdlib', '--branch', 'nope']).first).to eq(3)
  ensure
    system('git', '-C', clone, 'branch', '-q', '-D', 'old', out: File::NULL, err: File::NULL)
  end

  it 'stops for a module with no git releases' do
    expect(run(['facts']).first).to eq(3)
    expect(run(['profile']).first).to eq(3)
    expect(run(['nope']).first).to eq(3)
    expect(run([]).first).to eq(2)
  end
end
