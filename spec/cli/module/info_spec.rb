require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'stringio'
require 'yaml'

require 'support/fixture_repo'
require 'pupgrade/cli/module/info'

RSpec.describe Pupgrade::CLI::ModuleCommand::Info do
  before(:all) do # rubocop:disable RSpec/BeforeAfterAll
    @tmp     = Dir.mktmpdir
    @fixture = Pupgrade::FixtureRepo.build(File.join(@tmp, 'repo'))
  end

  after(:all) { FileUtils.rm_rf(@tmp) } # rubocop:disable RSpec/BeforeAfterAll

  let(:fixture) { @fixture }

  # [exit status, {label => value}]
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
    [status, captured.string.lines.to_h { |l| l.split(':', 2).map(&:strip) }]
  end

  before(:each) { silence_logger }

  it 'shows a git module: names, declaration, clone, metadata, and candidates past the current tag' do
    status, info = run(['stdlib'])
    expect(status).to eq(0)
    expect(info).to include(
      'name'         => 'puppetlabs-stdlib',
      'path'         => 'modules/stdlib',
      'declared'     => 'tag v8.6.0',
      'remote'       => File.join(fixture.remotes_dir, 'puppetlabs-stdlib.git'),
      'deployed'     => 'match',
      'version'      => '8.6.0',
      'requirements' => 'puppet >= 7.0.0 < 9.0.0',
      'candidates'   => 'v9.0.0, v9.4.0, v9.6.0',
    )
    expect(info['clone']).to match(/\Atag v8\.6\.0, [0-9a-f]{12}\z/)
    expect(info['OS support']).to start_with('RedHat 7/8')
    expect(info).not_to have_key('branch')

    _, info = run(['puppetlabs/firewall'])
    expect(info['dependencies']).to eq('puppetlabs/stdlib >= 4.13.1 < 9.0.0')
  end

  it 'names the branch followed, and says why a module has no candidates' do
    File.write(File.join(fixture.dir, 'branches.yaml'), YAML.dump('puppetlabs-stdlib' => 'main'))
    _, info = run(['stdlib', '--branchfile', 'branches.yaml'])
    expect(info['branch']).to eq('main')
    expect(run(['facts']).last['candidates']).to eq('none (Forge module)')
    expect(run(['profile']).last).to include('declared' => 'not in the Puppetfile', 'candidates' => 'none (not in the Puppetfile)')
    expect(run(['nope']).first).to eq(3)
    expect(run([]).first).to eq(2)
  end
end
