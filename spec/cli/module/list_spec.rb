require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'stringio'

require 'support/fixture_repo'
require 'pupgrade/cli/module/list'

RSpec.describe Pupgrade::CLI::ModuleCommand::List do
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
      described_class.new.run(['--no-config', '-d', fixture.dir] + argv)
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

  it 'lists every module as declared and as deployed, narrowed by any spelling of a name' do
    status, out = run([])
    expect(status).to eq(0)
    rows = cells(out)
    expect(rows.first).to eq(%w[path name declared deployed version])
    expect(rows.size).to eq(Pupgrade::FixtureRepo::CATALOGUE.size + 3)
    expect(rows.find { |r| r.first == 'modules/stdlib' }).to eq(['modules/stdlib', 'puppetlabs-stdlib', 'tag v8.6.0', 'match', '8.6.0'])
    expect(rows.find { |r| r.first == 'modules/facts' }).to eq(['modules/facts', 'puppetlabs-facts', '1.4.0 (forge)', 'match', '1.4.0'])
    expect(rows.find { |r| r.first == 'site-modules/profile' }).to eq(['site-modules/profile', '', '(not in the Puppetfile)', 'unknown', ''])

    _, out = run(['puppetlabs/std*,concat'])
    expect(cells(out).drop(1).map(&:first)).to eq(%w[modules/concat modules/stdlib])

    system('git', '-C', File.join(fixture.dir, 'modules/concat'), 'checkout', '-q', '--detach', 'v9.0.0')
    _, out = run(['concat'])
    expect(cells(out).drop(1)).to eq([['modules/concat', 'puppetlabs-concat', 'tag v7.3.0', 'differ (v9.0.0)', '9.0.0']])
    expect(run(%w[a b]).first).to eq(2)
  end
end
